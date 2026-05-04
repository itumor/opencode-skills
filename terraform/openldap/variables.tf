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

  validation {
    condition     = var.masters_per_vpc >= 1
    error_message = "masters_per_vpc must be >= 1."
  }
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

variable "ssh_public_key_path" {
  type        = string
  description = "Path to an SSH public key to register as an EC2 key pair when ssh_key_name is empty."
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

variable "write_lb_single_az" {
  type        = string
  description = "If set, pin the *write* NLBs (live/dr) to a single Availability Zone by selecting only subnets in that AZ. Empty means use all VPC public subnets."
  default     = ""
}

variable "pause_mode" {
  type        = bool
  description = "Pause control for this stack. true stops LDAP EC2 instances and can disable selected optional services."
  default     = false
}

variable "pause_disable_global_accelerator" {
  type        = bool
  description = "When pause_mode=true, disable Global Accelerator to reduce idle cost."
  default     = true
}

variable "pause_disable_keepalived" {
  type        = bool
  description = "When pause_mode=true, disable keepalived EIP resources to reduce idle cost."
  default     = true
}

variable "enable_global_accelerator" {
  type        = bool
  description = "Expose global endpoints via AWS Global Accelerator (see global_accelerator_mode)."
  default     = true
}

variable "global_accelerator_mode" {
  type        = string
  description = "Global Accelerator topology. shared=exactly 2 accelerators total (1 read + 1 write) routing to both Live+DR LBs."
  default     = "shared"

  validation {
    condition     = var.global_accelerator_mode == "shared"
    error_message = "global_accelerator_mode is restricted to \"shared\" (2 accelerators total: read + write)."
  }
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

variable "ldaps_port" {
  type        = number
  description = "LDAPS TCP port."
  default     = 636
}

variable "ldap_tls_mode" {
  type        = string
  description = "LDAP listener TLS mode. starttls_and_ldaps keeps 389+636; ldaps_only exposes only 636."
  default     = "starttls_and_ldaps"

  validation {
    condition     = contains(["starttls_and_ldaps", "ldaps_only"], var.ldap_tls_mode)
    error_message = "ldap_tls_mode must be one of: starttls_and_ldaps, ldaps_only."
  }
}

variable "require_tls_simple_binds" {
  type        = bool
  description = "Require TLS for simple binds (plain LDAP binds on 389 without StartTLS fail)."
  default     = true
}

variable "tls_cert_mode" {
  type        = string
  description = "TLS certificate strategy: external_or_self_signed, self_signed, external_required."
  default     = "external_or_self_signed"

  validation {
    condition     = contains(["external_or_self_signed", "self_signed", "external_required"], var.tls_cert_mode)
    error_message = "tls_cert_mode must be one of: external_or_self_signed, self_signed, external_required."
  }
}

variable "tls_ca_cert_pem" {
  type        = string
  description = "Optional external CA certificate PEM content."
  sensitive   = true
  default     = ""
}

variable "tls_cert_pem" {
  type        = string
  description = "Optional external server certificate PEM content."
  sensitive   = true
  default     = ""
}

variable "tls_key_pem" {
  type        = string
  description = "Optional external server key PEM content."
  sensitive   = true
  default     = ""
}

variable "tls_dns_names" {
  type        = list(string)
  description = "Extra DNS SAN entries for generated TLS server certificates."
  default     = []
}

variable "tls_ips" {
  type        = list(string)
  description = "Extra IP SAN entries for generated TLS server certificates."
  default     = []
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

variable "ldaps_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to connect to LDAPS (in addition to VPC + peer). If empty, ldap_cidr_blocks is used."
  default     = []
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

variable "keepalived_allow_failover" {
  type        = bool
  description = "If true, allow keepalived to move the EIP between instances (Terraform will not pin the association)."
  default     = false
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

variable "run_ansible" {
  type        = bool
  description = "If true, Terraform will run the Ansible OpenLDAP bootstrap + LDIF apply + verification after EC2 provisioning completes."
  default     = true
}

variable "ansible_connection" {
  type        = string
  description = "Ansible connection type used by Terraform-run Ansible (ssh|ssm)."
  default     = "ssh"

  validation {
    condition     = contains(["ssh", "ssm"], var.ansible_connection)
    error_message = "ansible_connection must be \"ssh\" or \"ssm\"."
  }
}

variable "ansible_enable_keepalived" {
  type        = bool
  description = "If true, Ansible will install/configure keepalived on the master nodes. Recommended to keep false for stable convergence."
  default     = false
}

variable "ansible_ssh_user" {
  type        = string
  description = "SSH username for Ansible when ansible_connection=ssh."
  default     = "ec2-user"
}

variable "ansible_ssh_private_key_path" {
  type        = string
  description = "Path to SSH private key for Ansible when ansible_connection=ssh. If empty, defaults to terraform/openldap/.local-ssh/openldap_mm."
  default     = ""
}
