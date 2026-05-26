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
  ssh_public_key_path  = abspath(var.ssh_public_key_path)
  common_tags = merge(var.tags, {
    Project = var.project_name
    Stack   = "openldap-master-replica"
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

# ---------------------------------------------------------------------------
# EC2 instances — ephemeral, created/destroyed every CI run
# ---------------------------------------------------------------------------

resource "aws_instance" "master" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_a_id
  private_ip                  = cidrhost(var.subnet_a_cidr, 10)
  vpc_security_group_ids      = [var.sg_id]
  associate_public_ip_address = true
  key_name                    = local.ssh_key_name_effective

  user_data = base64encode(templatefile("${path.module}/scripts/bootstrap-userdata.sh.tpl", {
    role       = "master"
    private_ip = cidrhost(var.subnet_a_cidr, 10)
    master_ip  = ""
    base_dn    = var.base_dn
    org_name   = var.org_name
    admin_pw   = var.admin_password
    repl_pw    = var.replication_password
    server_id  = "1"
    ldap_port  = "389"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-master-1"
    Role = "master"
  })
}

resource "aws_instance" "replica" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_b_id
  private_ip                  = cidrhost(var.subnet_b_cidr, 10)
  vpc_security_group_ids      = [var.sg_id]
  associate_public_ip_address = true
  key_name                    = local.ssh_key_name_effective

  depends_on = [aws_instance.master]

  user_data = base64encode(templatefile("${path.module}/scripts/bootstrap-userdata.sh.tpl", {
    role       = "replica"
    private_ip = cidrhost(var.subnet_b_cidr, 10)
    master_ip  = cidrhost(var.subnet_a_cidr, 10)
    base_dn    = var.base_dn
    org_name   = var.org_name
    admin_pw   = var.admin_password
    repl_pw    = var.replication_password
    server_id  = "2"
    ldap_port  = "389"
  }))

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-replica-1"
    Role = "replica"
  })
}
