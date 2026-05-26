data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs                = slice(data.aws_availability_zones.available.names, 0, 2)
  ldap_ingress_cidrs = distinct(concat([var.vpc_cidr], var.ldap_cidr_blocks))
  common_tags = merge(var.tags, {
    Project = var.project_name
    Stack   = "openldap-master-replica"
  })
  account_id = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# VPC + Networking
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Terraform S3 Backend — state storage for instances/
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket = "openldap-tfstate-${local.account_id}"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-tfstate"
  })
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "openldap-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-tfstate-lock"
  })
}

# ---------------------------------------------------------------------------
# SSM permissions for CI runner
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "ci_ssm" {
  name        = "${var.project_name}-ci-ssm"
  description = "Allow CI runner to use SSM Run Command on tagged instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation",
          "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      }
    ]
  })
}
