variable "region" {
  description = "AWS region for backend bucket (EU)"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "events-analytics"
}

