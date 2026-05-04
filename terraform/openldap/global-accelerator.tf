resource "aws_globalaccelerator_accelerator" "read" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  name    = "${local.short_name}-read"
  enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-ga-read"
  })

  lifecycle {
    precondition {
      condition     = var.lb_internal == false
      error_message = "Global Accelerator requires internet-facing NLBs. Set lb_internal=false or disable enable_global_accelerator."
    }
  }
}

resource "aws_globalaccelerator_accelerator" "write" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  name    = "${local.short_name}-write"
  enabled = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-ga-write"
  })

  lifecycle {
    precondition {
      condition     = var.lb_internal == false
      error_message = "Global Accelerator requires internet-facing NLBs. Set lb_internal=false or disable enable_global_accelerator."
    }
  }
}

resource "aws_globalaccelerator_listener" "read" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  accelerator_arn = aws_globalaccelerator_accelerator.read[0].id
  protocol        = "TCP"
  client_affinity = "NONE"

  port_range {
    from_port = var.ldap_port
    to_port   = var.ldap_port
  }
}

resource "aws_globalaccelerator_listener" "read_ldaps" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  accelerator_arn = aws_globalaccelerator_accelerator.read[0].id
  protocol        = "TCP"
  client_affinity = "NONE"

  port_range {
    from_port = var.ldaps_port
    to_port   = var.ldaps_port
  }
}

resource "aws_globalaccelerator_listener" "write" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  accelerator_arn = aws_globalaccelerator_accelerator.write[0].id
  protocol        = "TCP"
  client_affinity = "NONE"

  port_range {
    from_port = var.ldap_port
    to_port   = var.ldap_port
  }
}

resource "aws_globalaccelerator_listener" "write_ldaps" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  accelerator_arn = aws_globalaccelerator_accelerator.write[0].id
  protocol        = "TCP"
  client_affinity = "NONE"

  port_range {
    from_port = var.ldaps_port
    to_port   = var.ldaps_port
  }
}

resource "aws_globalaccelerator_endpoint_group" "read" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  listener_arn          = aws_globalaccelerator_listener.read[0].id
  endpoint_group_region = var.aws_region

  health_check_port             = var.ldap_port
  health_check_protocol         = "TCP"
  health_check_interval_seconds = 10
  threshold_count               = 3
  traffic_dial_percentage       = 100

  endpoint_configuration {
    endpoint_id = aws_lb.read["live"].arn
    weight      = 128
  }

  endpoint_configuration {
    endpoint_id = aws_lb.read["dr"].arn
    weight      = 128
  }
}

resource "aws_globalaccelerator_endpoint_group" "read_ldaps" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  listener_arn          = aws_globalaccelerator_listener.read_ldaps[0].id
  endpoint_group_region = var.aws_region

  health_check_port             = var.ldaps_port
  health_check_protocol         = "TCP"
  health_check_interval_seconds = 10
  threshold_count               = 3
  traffic_dial_percentage       = 100

  endpoint_configuration {
    endpoint_id = aws_lb.read["live"].arn
    weight      = 128
  }

  endpoint_configuration {
    endpoint_id = aws_lb.read["dr"].arn
    weight      = 128
  }
}

resource "aws_globalaccelerator_endpoint_group" "write" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  listener_arn          = aws_globalaccelerator_listener.write[0].id
  endpoint_group_region = var.aws_region

  health_check_port             = var.ldap_port
  health_check_protocol         = "TCP"
  health_check_interval_seconds = 10
  threshold_count               = 3
  traffic_dial_percentage       = 100

  endpoint_configuration {
    endpoint_id = aws_lb.write["live"].arn
    weight      = 128
  }

  endpoint_configuration {
    endpoint_id = aws_lb.write["dr"].arn
    weight      = 128
  }
}

resource "aws_globalaccelerator_endpoint_group" "write_ldaps" {
  count    = (local.effective_enable_global_accelerator && var.global_accelerator_mode == "shared") ? 1 : 0
  provider = aws.global

  listener_arn          = aws_globalaccelerator_listener.write_ldaps[0].id
  endpoint_group_region = var.aws_region

  health_check_port             = var.ldaps_port
  health_check_protocol         = "TCP"
  health_check_interval_seconds = 10
  threshold_count               = 3
  traffic_dial_percentage       = 100

  endpoint_configuration {
    endpoint_id = aws_lb.write["live"].arn
    weight      = 128
  }

  endpoint_configuration {
    endpoint_id = aws_lb.write["dr"].arn
    weight      = 128
  }
}
