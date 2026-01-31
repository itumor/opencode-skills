output "write_lb_dns" {
  description = "Write (master) NLB DNS names by VPC."
  value       = { for k, v in aws_lb.write : k => v.dns_name }
}

output "read_lb_dns" {
  description = "Read (replica) NLB DNS names by VPC."
  value       = { for k, v in aws_lb.read : k => v.dns_name }
}

output "instance_public_ips" {
  description = "Public IPs for LDAP instances (if assigned)."
  value       = { for k, v in aws_instance.node : k => v.public_ip }
}

output "instance_private_ips" {
  description = "Private IPs for LDAP instances."
  value       = { for k, v in aws_instance.node : k => v.private_ip }
}

output "artifacts_bucket_name" {
  description = "S3 bucket name storing scripts and LDIFs."
  value       = local.artifacts_bucket_name
}

output "keepalived_eip_allocation_id" {
  description = "Allocation ID for the keepalived EIP."
  value       = local.keepalived_eip_allocation_id
}

output "keepalived_eip_public_ip" {
  description = "Public IP of the keepalived EIP (if created)."
  value       = try(aws_eip.keepalived[0].public_ip, "")
}

output "ga_read_dns" {
  description = "Global Accelerator DNS name for read traffic (if enabled)."
  value       = try(aws_globalaccelerator_accelerator.read[0].dns_name, "")
}

output "ga_write_dns" {
  description = "Global Accelerator DNS name for write traffic (if enabled)."
  value       = try(aws_globalaccelerator_accelerator.write[0].dns_name, "")
}
