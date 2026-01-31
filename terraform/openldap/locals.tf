data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  short_name = substr(var.project_name, 0, 12)
  vpc_cidrs  = [for v in local.vpcs : v.cidr]

  repo_root                        = abspath("${path.module}/../..")
  artifacts_script_dir             = "${local.repo_root}/script"
  artifacts_ldif_dir               = "${local.repo_root}/openldap-mirrormode/ldif"
  artifacts_mirrormode_scripts_dir = "${local.repo_root}/openldap-mirrormode/scripts"
  artifacts_bootstrap_dir          = "${path.module}/artifacts"

  script_files            = try(fileset(local.artifacts_script_dir, "**"), [])
  ldif_files              = try(fileset(local.artifacts_ldif_dir, "*.ldif"), [])
  mirrormode_script_files = try(fileset(local.artifacts_mirrormode_scripts_dir, "*.sh"), [])
  bootstrap_files         = try(fileset(local.artifacts_bootstrap_dir, "*.sh"), [])

  enable_artifacts = var.artifacts_bucket_name != "" || var.create_artifacts_bucket
  bucket_prefix    = replace(replace(lower(var.project_name), "_", "-"), " ", "-")
  artifacts_bucket_name = var.artifacts_bucket_name != "" ? var.artifacts_bucket_name : (
    var.create_artifacts_bucket ? "${local.bucket_prefix}-artifacts-${random_id.artifacts_suffix[0].hex}" : ""
  )

  vpcs = {
    live = {
      cidr = var.live_vpc_cidr
    }
    dr = {
      cidr = var.dr_vpc_cidr
    }
  }

  subnets = merge([
    for vpc_name, v in local.vpcs : {
      for idx, az in local.azs :
      "${vpc_name}-public-${idx}" => {
        vpc  = vpc_name
        az   = az
        cidr = cidrsubnet(v.cidr, var.subnet_newbits, idx)
      }
    }
  ]...)

  subnet_keys_by_vpc = {
    for vpc_name in keys(local.vpcs) :
    vpc_name => [for k, s in local.subnets : k if s.vpc == vpc_name]
  }

  nodes = flatten([
    for vpc_name, v in local.vpcs : concat(
      [for i in range(var.masters_per_vpc) : {
        name       = "${vpc_name}-master-${i + 1}"
        role       = "master"
        vpc        = vpc_name
        index      = i
        subnet_key = "${vpc_name}-public-${i % length(local.azs)}"
        server_id  = i + 1
        private_ip = cidrhost(local.subnets["${vpc_name}-public-${i % length(local.azs)}"].cidr, 10 + i)
      }],
      [for i in range(var.replicas_per_vpc) : {
        name       = "${vpc_name}-replica-${i + 1}"
        role       = "replica"
        vpc        = vpc_name
        index      = i
        subnet_key = "${vpc_name}-public-${(i + var.masters_per_vpc) % length(local.azs)}"
        server_id  = 101 + i
        private_ip = cidrhost(local.subnets["${vpc_name}-public-${(i + var.masters_per_vpc) % length(local.azs)}"].cidr, 30 + i)
      }]
    )
  ])

  nodes_by_name = {
    for n in local.nodes :
    n.name => n
  }

  master_nodes = {
    for k, n in local.nodes_by_name :
    k => n if n.role == "master"
  }

  replica_nodes = {
    for k, n in local.nodes_by_name :
    k => n if n.role == "replica"
  }

  masters_by_vpc = {
    for vpc_name in keys(local.vpcs) :
    vpc_name => [for n in local.nodes : n.private_ip if n.vpc == vpc_name && n.role == "master"]
  }

  ldap_ingress_cidrs = {
    for vpc_name, v in local.vpcs :
    vpc_name => distinct(compact(concat(
      [v.cidr],
      [for other_name, other in local.vpcs : other.cidr if other_name != vpc_name],
      var.ldap_cidr_blocks
    )))
  }

  keepalived_candidates = var.enable_keepalived ? {
    for k, n in local.master_nodes :
    k => n if n.index == 0
  } : {}

  keepalived_live_key = var.enable_keepalived ? [for k, n in local.keepalived_candidates : k if n.vpc == "live"][0] : ""
  keepalived_dr_key   = var.enable_keepalived ? [for k, n in local.keepalived_candidates : k if n.vpc == "dr"][0] : ""

  keepalived_peer_ip = var.enable_keepalived ? {
    (local.keepalived_live_key) = local.keepalived_candidates[local.keepalived_dr_key].private_ip
    (local.keepalived_dr_key)   = local.keepalived_candidates[local.keepalived_live_key].private_ip
  } : {}

  keepalived_role = var.enable_keepalived ? {
    (local.keepalived_live_key) = "MASTER"
    (local.keepalived_dr_key)   = "BACKUP"
  } : {}

  keepalived_priority = var.enable_keepalived ? {
    (local.keepalived_live_key) = 200
    (local.keepalived_dr_key)   = 150
  } : {}
}
