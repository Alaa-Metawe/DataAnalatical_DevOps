terraform {
  backend "s3" {
    bucket = "events-analytics-tfstate-a5ccc8"
    key    = "infra/terraform.tfstate"
    region = "eu-west-1"
    encrypt = true
  }
}

