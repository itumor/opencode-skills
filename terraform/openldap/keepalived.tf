resource "aws_eip" "keepalived" {
  count = var.enable_keepalived && var.keepalived_eip_allocation_id == "" ? 1 : 0
  vpc   = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-keepalived"
  })
}

locals {
  keepalived_eip_allocation_id = var.keepalived_eip_allocation_id != "" ? var.keepalived_eip_allocation_id : try(aws_eip.keepalived[0].id, "")
}

resource "aws_eip_association" "keepalived" {
  count         = var.enable_keepalived ? 1 : 0
  instance_id   = aws_instance.node[local.keepalived_live_key].id
  allocation_id = local.keepalived_eip_allocation_id
}
