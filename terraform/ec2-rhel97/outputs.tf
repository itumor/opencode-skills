output "instance_id" {
  value       = aws_instance.this.id
  description = "EC2 instance ID."
}

output "public_ip" {
  value       = aws_instance.this.public_ip
  description = "Public IPv4 address for SSH."
}

output "public_dns" {
  value       = aws_instance.this.public_dns
  description = "Public DNS name."
}

output "ssh_user" {
  value       = "ec2-user"
  description = "Default SSH username for RHEL on AWS."
}

output "ami_id" {
  value       = aws_instance.this.ami
  description = "AMI used by the instance."
}

