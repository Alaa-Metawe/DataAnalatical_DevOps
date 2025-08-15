output "sns_topic_arn"         { value = aws_sns_topic.events.arn }
output "sqs_queue_url"         { value = aws_sqs_queue.events_subscription.id }
output "s3_landing_bucket"     { value = aws_s3_bucket.landing.bucket }
output "lambda_function_name"  { value = aws_lambda_function.processor.function_name }
output "redshift_workgroup"    { value = aws_redshiftserverless_workgroup.wg.workgroup_name }
output "redshift_database"     { value = local.redshift_db }
output "redshift_s3_role_arn"  { value = aws_iam_role.redshift_s3.arn }
