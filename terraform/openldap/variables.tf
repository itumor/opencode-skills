variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "project_name" {
  type        = string
  description = "Prefix for resource names and tags. Keep it short for AWS name limits."
  default     = "openldap-mm"
}

variable "live_vpc_cidr" {
  type        = string
  description = "CIDR block for the live VPC."
  default     = "10.10.0.0/16"
}

variable "dr_vpc_cidr" {
  type        = string
  description = "CIDR block for the DR VPC."
  default     = "10.20.0.0/16"
}

variable "subnet_newbits" {
  type        = number
  description = "New bits added when carving subnets from the VPC CIDR."
  default     = 8
}

variable "masters_per_vpc" {
  type        = number
  description = "Number of MirrorMode masters per VPC."
  default     = 1
}

variable "replicas_per_vpc" {
  type        = number
  description = "Number of read-only replicas per VPC."
  default     = 2
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for all LDAP nodes."
  default     = "t3.micro"
}

variable "rhel_major_version" {
  type        = number
  description = "RHEL major version to look up when rhel_ami_id is empty."
  default     = 9
}

variable "rhel_ami_id" {
  type        = string
  description = "Optional explicit AMI ID for RHEL. If empty, the latest RHEL AMI is looked up."
  default     = ""
}

variable "ssh_key_name" {
  type        = string
  description = "Existing EC2 key pair name for SSH access. Leave empty to skip SSH key injection."
  default     = ""
}

variable "assign_public_ip" {
  type        = bool
  description = "Assign public IPs to LDAP instances (no NAT required)."
  default     = true
}

variable "lb_internal" {
  type        = bool
  description = "Whether the LDAP load balancers are internal-only."
  default     = false
}

variable "enable_global_accelerator" {
  type        = bool
  description = "Expose two global endpoints (read/write) via AWS Global Accelerator."
  default     = true
}

variable "global_accelerator_region" {
  type        = string
  description = "AWS region used for Global Accelerator API calls."
  default     = "us-west-2"
}

variable "ldap_port" {
  type        = number
  description = "LDAP TCP port."
  default     = 389
}

variable "base_dn" {
  type        = string
  description = "Base DN for the directory."
  default     = "dc=cae,dc=local"
}

variable "org_name" {
  type        = string
  description = "Organization name for the base entry."
  default     = "CAE"
}

variable "admin_password" {
  type        = string
  description = "Admin password for cn=admin."
  sensitive   = true
  default     = "admin"
}

variable "replication_password" {
  type        = string
  description = "Password for cn=replicator."
  sensitive   = true
  default     = "replpass"
}

variable "admin_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to SSH to the instances."
  default     = ["0.0.0.0/0"]
}

variable "ldap_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to connect to LDAP (in addition to VPC + peer)."
  default     = ["0.0.0.0/0"]
}

variable "create_artifacts_bucket" {
  type        = bool
  description = "Create an S3 bucket for scripts and LDIF artifacts."
  default     = true
}

variable "artifacts_bucket_name" {
  type        = string
  description = "Existing S3 bucket name for scripts/LDIFs. Leave empty to auto-create."
  default     = ""
}

variable "upload_local_artifacts" {
  type        = bool
  description = "Upload local scripts/LDIFs into the artifacts bucket."
  default     = true
}

variable "enable_keepalived" {
  type        = bool
  description = "Enable keepalived on the primary masters (live/dr) to move an EIP."
  default     = true
}

variable "keepalived_eip_allocation_id" {
  type        = string
  description = "Existing EIP allocation ID for keepalived. Leave empty to allocate a new one."
  default     = ""
}

variable "keepalived_auth_pass" {
  type        = string
  description = "Keepalived authentication password."
  sensitive   = true
  default     = "openldap"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}
