# AWS Cost Estimate (1h / 1d / 1w / 1m)

This is a rough cost estimate for the AWS services used by this repo, based on the current `terraform/openldap/terraform.tfvars` defaults and **light usage** assumptions.

## Assumptions (matches repo defaults unless noted)

From `terraform/openldap/terraform.tfvars` / `terraform/openldap/variables.tf`:

- Region: `us-east-1`
- Nodes: 2 VPCs (`live` + `dr`)
- Per VPC: `masters_per_vpc=1`, `replicas_per_vpc=2` -> **3 EC2 per VPC**
- Total EC2 instances: **6**
- Instance type: default `t3.micro`
- Load balancers: **4 Network Load Balancers** (read + write per VPC)
- Global Accelerator: **disabled** (`enable_global_accelerator=false`)
- Keepalived + EIP: **disabled** (`enable_keepalived=false`)
- Public IPv4 usage: **enabled** (instances get public IPv4 because `assign_public_ip=true`; NLBs are internet-facing because `lb_internal=false`)

Additional cost assumptions (not explicitly set in Terraform):

- EBS root volume: **10 GiB gp3 per instance** (60 GiB total).
- NLB usage: **1 NLCU-hour per NLB-hour** (very light traffic; real workloads can be higher).
- S3 storage: **~1 GB total** (Terraform state + artifacts).
- Data transfer: **not included** (can dominate costs if internet-facing and/or cross-AZ heavy).

## Unit Prices Used (USD)

- EC2 `t3.micro` on-demand in `us-east-1`: **$0.0104 / hour**. citeturn4search0
- EBS gp3 storage: **$0.08 / GiB-month**. citeturn5search7
- Network Load Balancer: **$0.0225 / hour** and **$0.006 / NLCU-hour** (example uses US East). citeturn1search2
- Public IPv4 (in-use): **$0.005 / IP-hour**. citeturn6search0
- SSM Run Command: **no additional charges** (limits may apply). citeturn3search0turn3search1

## Baseline Inventory And Hourly Cost

### EC2 compute

- 6 instances * $0.0104/hr = **$0.0624/hr**

### EBS (gp3) storage

- 60 GiB * $0.08/GiB-month = **$4.80/month** = **$0.00667/hr** (assuming 720h/month)

### NLB (hours) + NLCUs

- 4 NLB * $0.0225/hr = **$0.0900/hr**
- 4 NLB * 1 NLCU/hr * $0.006/NLCU-hr = **$0.0240/hr**

### Public IPv4 charges (big one)

Counts (assuming 2 AZs, which the Terraform code slices to 2 AZs):

- EC2 public IPv4: 6
- NLB public IPv4: 4 NLB * 2 AZs = 8
- Total in-use public IPv4: **14**
- 14 * $0.005/hr = **$0.0700/hr**

### S3 + DynamoDB (Terraform state + artifacts)

- Usually pennies at this scale; excluded from totals below (storage + request volume dependent).

## Totals

All totals below include: EC2 compute + EBS gp3 storage + NLB hours + NLCU estimate + public IPv4 charges.

| Period | Estimated total |
|---|---:|
| 1 hour | **$0.2531** |
| 1 day (24h) | **$6.07** |
| 1 week (168h) | **$42.52** |
| 1 month (30d = 720h) | **$182.26** |

## How To Reduce Cost Fast (In This Repo)

1. Turn off public IPv4 where possible (this alone is ~$50/month in this baseline).
   - Set `assign_public_ip=false` and use SSM (already used here) or a bastion/VPN.
   - Consider `lb_internal=true` if you do not need internet-facing LDAP endpoints.
2. Reduce the number of NLBs (each NLB costs hourly + NLCUs + public IPv4s).
3. Reduce instance count and/or size.

## Optional Features (Not In Current tfvars)

- Global Accelerator: adds a monthly fixed fee (AWS pricing example shows $18/month per accelerator running 24x7). citeturn3search2
  - Also adds in-use public IPv4 addresses (2 per accelerator) which are billed at $0.005/IP-hour. citeturn6search0

