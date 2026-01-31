variable "aws_region" {
  type        = string
  description = "AWS region for the bootstrap resources."
}

variable "state_bucket_name" {
  type        = string
  description = "S3 bucket name for Terraform state."
}

variable "lock_table_name" {
  type        = string
  description = "DynamoDB table name for Terraform state locking."
}

variable "force_destroy" {
  type        = bool
  description = "Allow terraform destroy to delete the state bucket even if non-empty."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to bootstrap resources."
  default     = {}
}
