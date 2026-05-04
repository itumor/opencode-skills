variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "name" {
  type        = string
  description = "Name prefix for created resources."
  default     = "rhel97"
}

variable "tags" {
  type        = map(string)
  description = "Extra tags to apply to resources."
  default     = {}
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type."
  default     = "t3.micro"
}

variable "architecture" {
  type        = string
  description = "AMI/instance architecture: x86_64 or arm64."
  default     = "x86_64"
}

variable "rhel_owner_id" {
  type        = string
  description = "Owner ID used to look up official RHEL AMIs on AWS."
  default     = "309956199498"
}

variable "rhel_version_prefix" {
  type        = string
  description = "RHEL version prefix used in the AMI name filter (example: 9.7 matches 9.7.0, 9.7.1, etc)."
  default     = "9.7"
}

variable "rhel_ami_id" {
  type        = string
  description = "Optional explicit AMI ID. If empty, a matching RHEL 9.7 AMI is looked up."
  default     = ""
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "Your laptop public IP in CIDR notation (example: 203.0.113.10/32)."

  validation {
    condition     = can(cidrnetmask(var.ssh_ingress_cidr))
    error_message = "ssh_ingress_cidr must be a valid CIDR, for example 203.0.113.10/32."
  }
}

variable "create_key_pair" {
  type        = bool
  description = "If true, create an EC2 Key Pair from ssh_public_key_path."
  default     = true
}

variable "key_pair_name" {
  type        = string
  description = "Key pair name to create/use."
  default     = "rhel97-ssh"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to your local SSH public key (*.pub). Used when create_key_pair=true."
  default     = ""
}

variable "existing_key_pair_name" {
  type        = string
  description = "Existing EC2 key pair name to use when create_key_pair=false."
  default     = ""
}

variable "vpc_id" {
  type        = string
  description = "Optional VPC ID. If empty, the default VPC is used."
  default     = ""
}

variable "subnet_id" {
  type        = string
  description = "Optional subnet ID. If empty, a default subnet in the chosen VPC is used."
  default     = ""
}

variable "root_volume_size_gb" {
  type        = number
  description = "Root EBS volume size in GB."
  default     = 20
}

variable "ldaps_host" {
  type        = string
  description = "Optional LDAPS host to test from this instance (example: Global Accelerator DNS name)."
  default     = ""
}

variable "ldaps_port" {
  type        = number
  description = "LDAPS TCP port to test."
  default     = 636
}
