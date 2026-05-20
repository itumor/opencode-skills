output "master_instance_id" {
  description = "Master EC2 instance ID."
  value       = aws_instance.master.id
}

output "replica_instance_id" {
  description = "Replica EC2 instance ID."
  value       = aws_instance.replica.id
}

output "master_public_ip" {
  description = "Master public IP."
  value       = aws_instance.master.public_ip
}

output "replica_public_ip" {
  description = "Replica public IP."
  value       = aws_instance.replica.public_ip
}

output "master_private_ip" {
  description = "Master private IP."
  value       = aws_instance.master.private_ip
}

output "replica_private_ip" {
  description = "Replica private IP."
  value       = aws_instance.replica.private_ip
}

output "ssh_private_key_path" {
  description = "Private SSH key path used by helper scripts."
  value       = local.ssh_private_key_path
}

output "ldap_admin_dn" {
  description = "LDAP admin DN."
  value       = "cn=admin,${var.base_dn}"
}
