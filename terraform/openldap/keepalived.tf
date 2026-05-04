resource "aws_eip" "keepalived" {
  count  = local.effective_enable_keepalived && var.keepalived_eip_allocation_id == "" ? 1 : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-keepalived"
  })
}

locals {
  keepalived_eip_allocation_id = var.keepalived_eip_allocation_id != "" ? var.keepalived_eip_allocation_id : try(aws_eip.keepalived[0].id, "")
}

resource "aws_eip_association" "keepalived" {
  count         = local.effective_enable_keepalived && !var.keepalived_allow_failover ? 1 : 0
  instance_id   = aws_instance.node[local.keepalived_live_key].id
  allocation_id = local.keepalived_eip_allocation_id
}

resource "aws_eip_association" "keepalived_failover" {
  count         = local.effective_enable_keepalived && var.keepalived_allow_failover ? 1 : 0
  instance_id   = aws_instance.node[local.keepalived_live_key].id
  allocation_id = local.keepalived_eip_allocation_id

  lifecycle {
    # When keepalived is enabled, the EIP may legitimately move. Ignore drift
    # so Terraform doesn't constantly fight the VRRP leader.
    ignore_changes = [instance_id]
  }
}
