variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
  default     = "us-west-2"
}

variable "project_name" {
  type        = string
  description = "Prefix for AWS resource names and tags."
  default     = "openldap-mr"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the OpenLDAP VPC."
  default     = "10.30.0.0/16"
}

variable "admin_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to SSH."
  default     = ["0.0.0.0/0"]
}

variable "ldap_cidr_blocks" {
  type        = list(string)
  description = "Extra CIDR blocks for LDAP/LDAPS."
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
