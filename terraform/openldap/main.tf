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
  ami_id = var.rhel_ami_id != "" ? var.rhel_ami_id : data.aws_ami.rhel[0].id
}

resource "aws_vpc" "main" {
  for_each = local.vpcs

  cidr_block           = each.value.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}"
  })
}

resource "aws_internet_gateway" "igw" {
  for_each = local.vpcs

  vpc_id = aws_vpc.main[each.key].id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}-igw"
  })
}

resource "aws_subnet" "public" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main[each.value.vpc].id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}"
  })
}

resource "aws_route_table" "public" {
  for_each = local.vpcs

  vpc_id = aws_vpc.main[each.key].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw[each.key].id
  }

  # Keep the VPC peering route inline to avoid conflicts between aws_route_table.route
  # and separate aws_route resources (which causes perpetual diffs).
  dynamic "route" {
    for_each = [
      each.key == "live" ? local.vpcs["dr"].cidr : local.vpcs["live"].cidr
    ]
    content {
      cidr_block                = route.value
      vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = local.subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[each.value.vpc].id
}

resource "aws_vpc_peering_connection" "peer" {
  vpc_id      = aws_vpc.main["live"].id
  peer_vpc_id = aws_vpc.main["dr"].id
  auto_accept = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-live-dr-peer"
  })
}

resource "aws_security_group" "ldap" {
  for_each = local.vpcs

  name        = "${var.project_name}-${each.key}-ldap"
  description = "LDAP access for ${each.key}"
  vpc_id      = aws_vpc.main[each.key].id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr_blocks
  }

  ingress {
    description = "LDAP"
    from_port   = var.ldap_port
    to_port     = var.ldap_port
    protocol    = "tcp"
    cidr_blocks = local.ldap_ingress_cidrs[each.key]
  }

  ingress {
    description = "LDAPS"
    from_port   = var.ldaps_port
    to_port     = var.ldaps_port
    protocol    = "tcp"
    cidr_blocks = local.ldaps_ingress_cidrs[each.key]
  }

  dynamic "ingress" {
    for_each = local.effective_enable_keepalived ? [1] : []
    content {
      description = "Keepalived VRRP"
      from_port   = 0
      to_port     = 0
      protocol    = "112"
      cidr_blocks = local.vpc_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}-ldap"
  })
}

resource "aws_lb" "write" {
  for_each = local.vpcs

  name               = "${local.short_name}-${each.key}-w"
  internal           = var.lb_internal
  load_balancer_type = "network"
  subnets            = [for k in local.write_lb_subnet_keys_by_vpc[each.key] : aws_subnet.public[k].id]

  lifecycle {
    precondition {
      condition     = var.write_lb_single_az == "" || length(local.write_lb_subnet_keys_by_vpc[each.key]) > 0
      error_message = "write_lb_single_az is set, but no public subnets matched that AZ for this VPC. Check locals.azs / subnet creation."
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}-write"
  })
}

resource "aws_lb" "read" {
  for_each = local.vpcs

  name               = "${local.short_name}-${each.key}-r"
  internal           = var.lb_internal
  load_balancer_type = "network"
  subnets            = [for k in local.subnet_keys_by_vpc[each.key] : aws_subnet.public[k].id]

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}-read"
  })
}

resource "aws_lb_target_group" "write" {
  for_each = local.vpcs

  name        = "${local.short_name}-${each.key}-w"
  port        = var.ldap_port
  protocol    = "TCP"
  vpc_id      = aws_vpc.main[each.key].id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = var.ldap_port
  }

  tags = var.tags
}

resource "aws_lb_target_group" "read" {
  for_each = local.vpcs

  name        = "${local.short_name}-${each.key}-r"
  port        = var.ldap_port
  protocol    = "TCP"
  vpc_id      = aws_vpc.main[each.key].id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = var.ldap_port
  }

  tags = var.tags
}

resource "aws_lb_target_group" "write_ldaps" {
  for_each = local.vpcs

  name        = "${local.short_name}-${each.key}-w636"
  port        = var.ldaps_port
  protocol    = "TCP"
  vpc_id      = aws_vpc.main[each.key].id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = var.ldaps_port
  }

  tags = var.tags
}

resource "aws_lb_target_group" "read_ldaps" {
  for_each = local.vpcs

  name        = "${local.short_name}-${each.key}-r636"
  port        = var.ldaps_port
  protocol    = "TCP"
  vpc_id      = aws_vpc.main[each.key].id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = var.ldaps_port
  }

  tags = var.tags
}

resource "aws_lb_listener" "write" {
  for_each = local.vpcs

  load_balancer_arn = aws_lb.write[each.key].arn
  port              = var.ldap_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.write[each.key].arn
  }
}

resource "aws_lb_listener" "read" {
  for_each = local.vpcs

  load_balancer_arn = aws_lb.read[each.key].arn
  port              = var.ldap_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.read[each.key].arn
  }
}

resource "aws_lb_listener" "write_ldaps" {
  for_each = local.vpcs

  load_balancer_arn = aws_lb.write[each.key].arn
  port              = var.ldaps_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.write_ldaps[each.key].arn
  }
}

resource "aws_lb_listener" "read_ldaps" {
  for_each = local.vpcs

  load_balancer_arn = aws_lb.read[each.key].arn
  port              = var.ldaps_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.read_ldaps[each.key].arn
  }
}

resource "aws_instance" "node" {
  for_each = local.nodes_by_name

  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[each.value.subnet_key].id
  private_ip             = each.value.private_ip
  vpc_security_group_ids = [aws_security_group.ldap[each.value.vpc].id]
  iam_instance_profile   = aws_iam_instance_profile.ldap.name

  associate_public_ip_address = var.assign_public_ip
  key_name                    = local.ssh_key_name_effective

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.key}"
    Role = each.value.role
    VPC  = each.value.vpc
  })
}

resource "aws_ec2_instance_state" "node" {
  for_each = aws_instance.node

  instance_id = each.value.id
  state       = local.desired_instance_state
}

resource "aws_lb_target_group_attachment" "write" {
  for_each = local.master_nodes

  target_group_arn = aws_lb_target_group.write[each.value.vpc].arn
  target_id        = aws_instance.node[each.key].id
  port             = var.ldap_port
}

resource "aws_lb_target_group_attachment" "read" {
  for_each = local.replica_nodes

  target_group_arn = aws_lb_target_group.read[each.value.vpc].arn
  target_id        = aws_instance.node[each.key].id
  port             = var.ldap_port
}

resource "aws_lb_target_group_attachment" "write_ldaps" {
  for_each = local.master_nodes

  target_group_arn = aws_lb_target_group.write_ldaps[each.value.vpc].arn
  target_id        = aws_instance.node[each.key].id
  port             = var.ldaps_port
}

resource "aws_lb_target_group_attachment" "read_ldaps" {
  for_each = local.replica_nodes

  target_group_arn = aws_lb_target_group.read_ldaps[each.value.vpc].arn
  target_id        = aws_instance.node[each.key].id
  port             = var.ldaps_port
}
