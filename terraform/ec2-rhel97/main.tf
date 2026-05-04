locals {
  tags = merge(var.tags, {
    Name = var.name
  })
}

data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_vpc" "by_id" {
  count = var.vpc_id != "" ? 1 : 0
  id    = var.vpc_id
}

locals {
  selected_vpc_id = var.vpc_id != "" ? data.aws_vpc.by_id[0].id : data.aws_vpc.default[0].id
}

data "aws_subnets" "default_for_az" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.selected_vpc_id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  selected_subnet_id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default_for_az[0].ids[0]
}

data "aws_ami" "rhel97" {
  count       = var.rhel_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = [var.rhel_owner_id]

  filter {
    name   = "name"
    values = ["RHEL-${var.rhel_version_prefix}*_HVM-*-${var.architecture}-*-Hourly2-GP3"]
  }

  filter {
    name   = "architecture"
    values = [var.architecture]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  ami_id   = var.rhel_ami_id != "" ? var.rhel_ami_id : data.aws_ami.rhel97[0].id
  key_name = var.create_key_pair ? try(aws_key_pair.this[0].key_name, "") : var.existing_key_pair_name
}

resource "aws_security_group" "ssh" {
  name        = "${var.name}-ssh"
  description = "SSH access from a single laptop CIDR"
  vpc_id      = local.selected_vpc_id

  ingress {
    description = "SSH from laptop"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_key_pair" "this" {
  count = var.create_key_pair ? 1 : 0

  key_name   = var.key_pair_name
  public_key = file(pathexpand(var.ssh_public_key_path))

  lifecycle {
    precondition {
      condition     = var.ssh_public_key_path != ""
      error_message = "create_key_pair=true requires ssh_public_key_path to be set."
    }
  }

  tags = local.tags
}

resource "aws_instance" "this" {
  ami           = local.ami_id
  instance_type = var.instance_type
  subnet_id     = local.selected_subnet_id

  vpc_security_group_ids      = [aws_security_group.ssh.id]
  associate_public_ip_address = true

  key_name = local.key_name != "" ? local.key_name : null

  user_data = templatefile("${path.module}/templates/user-data.sh.tmpl", {
    ldaps_host = var.ldaps_host
    ldaps_port = var.ldaps_port
  })

  # This stack is often used as a test/jump box; avoid replacements on small user_data edits.
  user_data_replace_on_change = false

  lifecycle {
    precondition {
      condition     = var.create_key_pair ? true : var.existing_key_pair_name != ""
      error_message = "create_key_pair=false requires existing_key_pair_name to be set."
    }
    precondition {
      condition     = var.create_key_pair ? var.ssh_public_key_path != "" : true
      error_message = "create_key_pair=true requires ssh_public_key_path to be set."
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = local.tags
}
