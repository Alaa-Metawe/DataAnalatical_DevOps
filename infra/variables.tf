variable "region" {
  description = "AWS region (EU)"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "events-analytics"
}

variable "redshift_base_capacity_rpus" {
  description = "Redshift Serverless base capacity (RPUs)"
  type        = number
  default     = 8
}

