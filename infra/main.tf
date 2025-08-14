terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

# -------------- Naming helpers --------------
resource "random_id" "suffix" {
  byte_length = 3
}
locals {
  name            = "${var.project_name}-${random_id.suffix.hex}"
  landing_bucket  = "${var.project_name}-landing-${random_id.suffix.hex}"
  redshift_db     = "events_db"
  redshift_schema = "public"
}

# -------------- S3 (landing, versioned) --------------
resource "aws_s3_bucket" "landing" {
  bucket = local.landing_bucket
}

resource "aws_s3_bucket_versioning" "landing" {
  bucket = aws_s3_bucket.landing.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "landing" {
  bucket = aws_s3_bucket.landing.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -------------- SNS (topic) --------------
resource "aws_sns_topic" "events" {
  name = "events-topic"
}

# -------------- SQS (pull-style subscription) --------------
resource "aws_sqs_queue" "events_subscription" {
  name = "events-subscription"
  visibility_timeout_seconds = 60
}

# Allow SNS topic to send messages to SQS
data "aws_iam_policy_document" "sqs_from_sns" {
  statement {
    sid = "AllowSNS2SQS"
    actions = ["sqs:SendMessage"]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    resources = [aws_sqs_queue.events_subscription.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "events_subscription" {
  queue_url = aws_sqs_queue.events_subscription.id
  policy    = data.aws_iam_policy_document.sqs_from_sns.json
}

# Subscribe SQS to SNS
resource "aws_sns_topic_subscription" "to_sqs" {
  topic_arn = aws_sns_topic.events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.events_subscription.arn
}

# -------------- IAM: publisher role (can publish to SNS) --------------
data "aws_iam_policy_document" "publisher_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com","lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "publisher" {
  name               = "${local.name}-publisher"
  assume_role_policy = data.aws_iam_policy_document.publisher_assume.json
}

data "aws_iam_policy_document" "publisher_policy" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.events.arn]
  }
}

resource "aws_iam_policy" "publisher" {
  name   = "${local.name}-publisher"
  policy = data.aws_iam_policy_document.publisher_policy.json
}

resource "aws_iam_role_policy_attachment" "publisher_attach" {
  role       = aws_iam_role.publisher.name
  policy_arn = aws_iam_policy.publisher.arn
}

# -------------- Lambda processor (SQS -> S3) --------------
# Role for the Lambda to read SQS and write S3, & basic logging
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "processor" {
  name               = "${local.name}-processor"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "processor_policy" {
  statement {
    actions   = ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.events_subscription.arn]
  }

  statement {
    actions   = ["s3:PutObject","s3:AbortMultipartUpload","s3:ListBucket","s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.landing.arn,
      "${aws_s3_bucket.landing.arn}/*"
    ]
  }

  statement {
    actions   = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_policy" "processor" {
  name   = "${local.name}-processor"
  policy = data.aws_iam_policy_document.processor_policy.json
}

resource "aws_iam_role_policy_attachment" "processor_attach" {
  role       = aws_iam_role.processor.name
  policy_arn = aws_iam_policy.processor.arn
}

# Zip the lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "processor" {
  function_name = "${local.name}-processor"
  role          = aws_iam_role.processor.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  environment {
    variables = {
      LANDING_BUCKET = aws_s3_bucket.landing.bucket
    }
  }
}

# Trigger Lambda from SQS
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.events_subscription.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 10
}

# -------------- Redshift Serverless --------------
# Role Redshift uses to read from S3 for COPY
data "aws_iam_policy_document" "redshift_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com","redshift-serverless.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redshift_s3" {
  name               = "${local.name}-redshift-s3"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume.json
}

data "aws_iam_policy_document" "redshift_s3_policy" {
  statement {
    actions   = ["s3:GetObject","s3:ListBucket"]
    resources = [
      aws_s3_bucket.landing.arn,
      "${aws_s3_bucket.landing.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "redshift_s3" {
  name   = "${local.name}-redshift-s3"
  policy = data.aws_iam_policy_document.redshift_s3_policy.json
}

resource "aws_iam_role_policy_attachment" "redshift_s3_attach" {
  role       = aws_iam_role.redshift_s3.name
  policy_arn = aws_iam_policy.redshift_s3.arn
}

# Redshift Serverless namespace & workgroup
resource "aws_redshiftserverless_namespace" "ns" {
  namespace_name = "${local.name}-ns"
  db_name        = local.redshift_db
  iam_roles      = [aws_iam_role.redshift_s3.arn]
}

resource "aws_redshiftserverless_workgroup" "wg" {
  workgroup_name  = "${local.name}-wg"
  base_capacity   = var.redshift_base_capacity_rpus
  namespace_name  = aws_redshiftserverless_namespace.ns.namespace_name
  publicly_accessible = true
}

# -------------- Optional: a minimal table to load into --------------
# Create a simple events table using Redshift Data API at apply-time
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "redshift_data_api" {
  name               = "${local.name}-redshift-dataapi"
  assume_role_policy = data.aws_iam_policy_document.publisher_assume.json
}

resource "aws_iam_policy" "redshift_data_api" {
  name   = "${local.name}-redshift-dataapi"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = ["redshift-data:ExecuteStatement","redshift-data:DescribeStatement","redshift-data:GetStatementResult","redshift-data:ListSchemas","redshift-data:ListTables"],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "redshift_data_attach" {
  role       = aws_iam_role.redshift_data_api.name
  policy_arn = aws_iam_policy.redshift_data_api.arn
}

# Use null_resource + local-exec to run a CREATE TABLE once workgroup is live
resource "null_resource" "create_table" {
  # Re-run if workgroup or namespace changes
  triggers = {
    workgroup_id = aws_redshiftserverless_workgroup.wg.id
    namespace_id = aws_redshiftserverless_namespace.ns.id
  }

  provisioner "local-exec" {
    # Uses AWS CLI's redshift-data to run SQL (assumes AWS creds present locally/CI)
    command = <<EOT
aws redshift-data execute-statement \
  --region ${var.region} \
  --workgroup-name ${aws_redshiftserverless_workgroup.wg.workgroup_name} \
  --database ${local.redshift_db} \
  --sql "create table if not exists ${local.redshift_schema}.events(id varchar(64), event_time timestamp, payload super);" >/dev/null
EOT
  }
}

