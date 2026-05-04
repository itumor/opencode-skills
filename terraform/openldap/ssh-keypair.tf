resource "aws_key_pair" "auto" {
  count = var.ssh_key_name == "" ? 1 : 0

  key_name_prefix = "${var.project_name}-"
  public_key      = file(local.ssh_public_key_path)

  tags = merge(var.tags, {
    Name = "${var.project_name}-ssh"
  })
}

locals {
  ssh_key_name_effective = var.ssh_key_name != "" ? var.ssh_key_name : aws_key_pair.auto[0].key_name
}

