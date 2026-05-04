locals {
  ansible_dir = "${local.repo_root}/ansible/openldap"

  # Keep generated files inside an already-committed directory so we don't need any mkdir provisioners.
  # IMPORTANT: use absolute paths. `path.module` is "." in the root module, and
  # Terraform will otherwise emit "./reports/..." which breaks once local-exec
  # changes directories.
  ansible_inventory_path  = abspath("${path.module}/reports/ansible_inventory.ini")
  ansible_extra_vars_path = abspath("${path.module}/reports/ansible_extra_vars.json")

  ansible_ssh_key_path = var.ansible_ssh_private_key_path != "" ? abspath(var.ansible_ssh_private_key_path) : abspath("${path.module}/.local-ssh/openldap_mm")

  ansible_files = fileset(local.ansible_dir, "**")
  ansible_hash = sha256(join("", [
    for f in sort(local.ansible_files) : filesha256("${local.ansible_dir}/${f}")
  ]))

  ansible_connection_effective = var.ansible_connection == "ssm" ? "amazon.aws.aws_ssm" : "ssh"

  ssh_host_ip_by_node = {
    for k in keys(aws_instance.node) :
    k => try(data.aws_instance.node[k].public_ip, aws_instance.node[k].public_ip)
  }

  ansible_inventory = join("\n", compact(concat(
    [
      "[all]"
    ],
    [
      for k, inst in aws_instance.node :
      format(
        "%s ansible_host=%s ec2_instance_id=%s ec2_private_ip_address=%s ec2_public_ip_address=%s",
        "${var.project_name}-${k}",
        (var.ansible_connection == "ssm" ? inst.id : local.ssh_host_ip_by_node[k]),
        inst.id,
        inst.private_ip,
        try(local.ssh_host_ip_by_node[k], "")
      )
    ],
    [
      "",
      "[role_master]"
    ],
    [
      for k, _n in local.master_nodes : "${var.project_name}-${k}"
    ],
    [
      "",
      "[role_replica]"
    ],
    [
      for k, _n in local.replica_nodes : "${var.project_name}-${k}"
    ],
    [
      "",
      "[vpc_live]"
    ],
    [
      for k, n in local.nodes_by_name : "${var.project_name}-${k}" if n.vpc == "live"
    ],
    [
      "",
      "[vpc_dr]"
    ],
    [
      for k, n in local.nodes_by_name : "${var.project_name}-${k}" if n.vpc == "dr"
    ]
  )))

  ansible_extra_vars = jsonencode({
    ansible_connection           = local.ansible_connection_effective
    ansible_user                 = var.ansible_ssh_user
    ansible_ssh_private_key_file = local.ansible_ssh_key_path

    openldap_use_terraform_outputs           = false
    openldap_project_name                    = var.project_name
    openldap_base_dn                         = var.base_dn
    openldap_org_name                        = var.org_name
    openldap_admin_dn                        = "cn=admin,${var.base_dn}"
    openldap_admin_pw                        = var.admin_password
    openldap_repl_dn                         = "cn=replicator,${var.base_dn}"
    openldap_repl_pw                         = var.replication_password
    openldap_ldap_port                       = var.ldap_port
    openldap_ldaps_port                      = var.ldaps_port
    openldap_tls_mode                        = var.ldap_tls_mode
    openldap_require_tls_simple_binds        = var.require_tls_simple_binds
    openldap_tls_cert_mode                   = var.tls_cert_mode
    openldap_tls_ca_cert_pem                 = var.tls_ca_cert_pem
    openldap_tls_cert_pem                    = var.tls_cert_pem
    openldap_tls_key_pem                     = var.tls_key_pem
    openldap_tls_dns_names                   = var.tls_dns_names
    openldap_tls_ips                         = var.tls_ips
    openldap_enable_keepalived               = var.ansible_enable_keepalived
    openldap_keepalived_auth_pass            = var.keepalived_auth_pass
    openldap_keepalived_eip_allocation_id    = local.keepalived_eip_allocation_id
    openldap_ldif_public_ips_apply_cross_vpc = true
    openldap_write_lb_dns_by_vpc = {
      live = aws_lb.write["live"].dns_name
      dr   = aws_lb.write["dr"].dns_name
    }
    openldap_aws_region = var.aws_region
  })
}

data "aws_instance" "node" {
  for_each    = aws_instance.node
  instance_id = each.value.id

  # Ensure we observe the post-association public IP for the node.
  depends_on = [
    aws_eip_association.keepalived,
    aws_eip_association.keepalived_failover,
  ]
}

resource "local_file" "ansible_inventory" {
  filename = local.ansible_inventory_path
  content  = "${local.ansible_inventory}\n"
}

resource "local_file" "ansible_extra_vars" {
  filename = local.ansible_extra_vars_path
  content  = "${local.ansible_extra_vars}\n"
}

resource "null_resource" "ansible_apply" {
  count = local.effective_run_ansible ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.ansible_connection != "ssh" || var.assign_public_ip
      error_message = "ansible_connection=ssh requires assign_public_ip=true so the controller can reach instances."
    }
  }

  triggers = {
    instance_ids  = sha256(join(",", sort([for _k, v in aws_instance.node : v.id])))
    ansible_hash  = local.ansible_hash
    inventory_sha = sha256(local_file.ansible_inventory.content)
    vars_sha      = sha256(local_file.ansible_extra_vars.content)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = join(" && ", [
      "cd \"${local.ansible_dir}\"",
      "ansible-galaxy collection install -r requirements.yml",
      "ANSIBLE_CONFIG=\"${local.ansible_dir}/ansible.cfg\" ansible-playbook -i \"${local_file.ansible_inventory.filename}\" playbooks/terraform_apply.yml --extra-vars \"@${local_file.ansible_extra_vars.filename}\""
    ])

    environment = {
      AWS_REGION         = var.aws_region
      AWS_DEFAULT_REGION = var.aws_region
    }
  }

  depends_on = [
    local_file.ansible_inventory,
    local_file.ansible_extra_vars,
    aws_instance.node,
    aws_lb.write,
    aws_lb.read
  ]
}
