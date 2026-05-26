output "vpc_id" {
  description = "VPC ID for the OpenLDAP network."
  value       = aws_vpc.this.id
}

output "subnet_a_id" {
  description = "Subnet A ID (master)."
  value       = aws_subnet.public[0].id
}

output "subnet_b_id" {
  description = "Subnet B ID (replica)."
  value       = aws_subnet.public[1].id
}

output "subnet_a_cidr" {
  description = "Subnet A CIDR."
  value       = aws_subnet.public[0].cidr_block
}

output "subnet_b_cidr" {
  description = "Subnet B CIDR."
  value       = aws_subnet.public[1].cidr_block
}

output "sg_id" {
  description = "Security group ID for LDAP."
  value       = aws_security_group.ldap.id
}

output "state_bucket" {
  description = "S3 bucket for terraform state."
  value       = aws_s3_bucket.tf_state.bucket
}

output "state_lock_table" {
  description = "DynamoDB table for terraform state locking."
  value       = aws_dynamodb_table.tf_lock.name
}
