variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "project_name" {
  type    = string
  default = "openldap-mr"
}

# --- VPC references (set from vpc/outputs) ---

variable "vpc_id" {
  type        = string
  description = "VPC ID from persistent vpc/ terraform."
}

variable "subnet_a_id" {
  type        = string
  description = "Subnet A ID (master)."
}

variable "subnet_b_id" {
  type        = string
  description = "Subnet B ID (replica)."
}

variable "sg_id" {
  type        = string
  description = "Security group ID."
}

variable "subnet_a_cidr" {
  type        = string
  description = "Subnet A CIDR (for private IP calculation)."
}

variable "subnet_b_cidr" {
  type        = string
  description = "Subnet B CIDR (for private IP calculation)."
}

# --- Instance config ---

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "rhel_ami_id" {
  type    = string
  default = ""
}

variable "rhel_major_version" {
  type    = number
  default = 9
}

variable "ssh_key_name" {
  type    = string
  default = ""
}

variable "ssh_public_key_path" {
  type    = string
  default = ".local-ssh/openldap_master_replica.pub"
}

# --- LDAP config ---

variable "base_dn" {
  type    = string
  default = "dc=cae,dc=local"
}

variable "org_name" {
  type    = string
  default = "CAE"
}

variable "admin_password" {
  type      = string
  sensitive = true
  default   = "admin"
}

variable "replication_password" {
  type      = string
  sensitive = true
  default   = "replpass"
}

variable "s3_scripts_bucket" {
  type        = string
  description = "S3 bucket name for CI scripts."
  default     = "nextgenopen-ci-scripts"
}

variable "tags" {
  type    = map(string)
  default = {}
}
