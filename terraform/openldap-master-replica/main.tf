data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "rhel" {
  count       = var.rhel_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-${var.rhel_major_version}*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
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
  ami_id               = var.rhel_ami_id != "" ? var.rhel_ami_id : data.aws_ami.rhel[0].id
  azs                  = slice(data.aws_availability_zones.available.names, 0, 2)
  ssh_public_key_path  = abspath(var.ssh_public_key_path)
  ssh_private_key_path = abspath(var.ssh_private_key_path)
  ldap_ingress_cidrs   = distinct(concat([var.vpc_cidr], var.ldap_cidr_blocks))
  common_tags = merge(var.tags, {
    Project = var.project_name
    Stack   = "openldap-master-replica"
  })
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-${count.index + 1}"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ldap" {
  name        = "${var.project_name}-ldap"
  description = "OpenLDAP master/replica access"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr_blocks
  }

  ingress {
    description = "LDAP"
    from_port   = 389
    to_port     = 389
    protocol    = "tcp"
    cidr_blocks = local.ldap_ingress_cidrs
  }

  ingress {
    description = "LDAPS reserved"
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = local.ldap_ingress_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ldap-sg"
  })
}

resource "aws_key_pair" "auto" {
  count = var.ssh_key_name == "" ? 1 : 0

  key_name_prefix = "${var.project_name}-"
  public_key      = file(local.ssh_public_key_path)

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ssh"
  })
}

locals {
  ssh_key_name_effective = var.ssh_key_name != "" ? var.ssh_key_name : aws_key_pair.auto[0].key_name
}

resource "aws_instance" "master" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  private_ip                  = cidrhost(aws_subnet.public[0].cidr_block, 10)
  vpc_security_group_ids      = [aws_security_group.ldap.id]
  associate_public_ip_address = true
  key_name                    = local.ssh_key_name_effective

  user_data = base64encode(templatefile("${path.module}/scripts/bootstrap-userdata.sh.tpl", {
    role          = "master"
    private_ip    = cidrhost(aws_subnet.public[0].cidr_block, 10)
    master_ip     = ""
    base_dn       = var.base_dn
    org_name      = var.org_name
    admin_pw      = var.admin_password
    repl_pw       = var.replication_password
    server_id     = "1"
    ldap_port     = "389"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-master-1"
    Role = "master"
  })
}

resource "aws_instance" "replica" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[1].id
  private_ip                  = cidrhost(aws_subnet.public[1].cidr_block, 10)
  vpc_security_group_ids      = [aws_security_group.ldap.id]
  associate_public_ip_address = true
  key_name                    = local.ssh_key_name_effective

  depends_on = [aws_instance.master]

  user_data = base64encode(templatefile("${path.module}/scripts/bootstrap-userdata.sh.tpl", {
    role          = "replica"
    private_ip    = cidrhost(aws_subnet.public[1].cidr_block, 10)
    master_ip     = cidrhost(aws_subnet.public[0].cidr_block, 10)
    base_dn       = var.base_dn
    org_name      = var.org_name
    admin_pw      = var.admin_password
    repl_pw       = var.replication_password
    server_id     = "2"
    ldap_port     = "389"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-replica-1"
    Role = "replica"
  })
}
