output "master_instance_id" {
  description = "Master EC2 instance ID."
  value       = aws_instance.master.id
}

output "replica_instance_id" {
  description = "Replica EC2 instance ID."
  value       = aws_instance.replica.id
}

output "loadgen1_instance_id" {
  description = "Load-gen-1 EC2 instance ID."
  value       = aws_instance.loadgen[0].id
}

output "loadgen2_instance_id" {
  description = "Load-gen-2 EC2 instance ID."
  value       = aws_instance.loadgen[1].id
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

output "loadgen1_public_ip" {
  description = "Load-gen-1 public IP."
  value       = aws_instance.loadgen[0].public_ip
}

output "loadgen2_public_ip" {
  description = "Load-gen-2 public IP."
  value       = aws_instance.loadgen[1].public_ip
}

output "loadgen1_private_ip" {
  description = "Load-gen-1 private IP."
  value       = aws_instance.loadgen[0].private_ip
}

output "loadgen2_private_ip" {
  description = "Load-gen-2 private IP."
  value       = aws_instance.loadgen[1].private_ip
}

output "ssh_private_key_path" {
  description = "Private SSH key path used by helper scripts."
  value       = local.ssh_private_key_path
}

output "ldap_admin_dn" {
  description = "LDAP admin DN."
  value       = "cn=admin,${var.base_dn}"
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}
