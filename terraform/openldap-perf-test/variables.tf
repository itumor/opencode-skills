variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
  default     = "us-west-2"
}

variable "project_name" {
  type        = string
  description = "Prefix for AWS resource names and tags."
  default     = "openldap-perf"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the OpenLDAP perf-test VPC."
  default     = "10.40.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for LDAP master and replica."
  default     = "m5a.2xlarge"
}

variable "loadgen_instance_type" {
  type        = string
  description = "EC2 instance type for JMeter load generators."
  default     = "t3.medium"
}

variable "rhel_major_version" {
  type        = number
  description = "RHEL major version to look up when rhel_ami_id is empty."
  default     = 9
}

variable "rhel_ami_id" {
  type        = string
  description = "Optional explicit RHEL AMI ID. Empty means latest matching RHEL AMI."
  default     = ""
}

variable "ssh_key_name" {
  type        = string
  description = "Existing EC2 key pair name. Empty means Terraform creates one from ssh_public_key_path."
  default     = ""
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to public SSH key registered as an EC2 key pair when ssh_key_name is empty."
  default     = ".local-ssh/openldap_master_replica.pub"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to private SSH key used by helper scripts."
  default     = ".local-ssh/openldap_master_replica"
}

variable "admin_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to SSH and test LDAP/LDAPS from outside the VPC."
  default     = ["0.0.0.0/0"]
}

variable "ldap_cidr_blocks" {
  type        = list(string)
  description = "Extra CIDR blocks allowed to LDAP/LDAPS, in addition to the VPC CIDR."
  default     = ["0.0.0.0/0"]
}

variable "base_dn" {
  type        = string
  description = "Base DN for the OpenLDAP directory."
  default     = "dc=perf,dc=bank,dc=local"
}

variable "org_name" {
  type        = string
  description = "Organization name for the base entry."
  default     = "PerfBank"
}

variable "admin_password" {
  type        = string
  description = "Password for cn=admin."
  sensitive   = true
  default     = "TheN1le1"
}

variable "replication_password" {
  type        = string
  description = "Password for cn=replicator."
  sensitive   = true
  default     = "replpass"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
