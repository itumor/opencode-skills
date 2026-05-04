locals {
  artifacts_bucket_arn = local.enable_artifacts ? "arn:aws:s3:::${local.artifacts_bucket_name}" : ""
  iam_statements = concat(
    local.enable_artifacts ? [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.artifacts_bucket_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.artifacts_bucket_arn}/*"]
      }
    ] : [],
    local.effective_enable_keepalived ? [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeAddresses",
          "ec2:AssociateAddress",
          "ec2:DisassociateAddress"
        ]
        Resource = "*"
      }
    ] : []
  )
}

resource "aws_iam_role" "ldap" {
  name = "${var.project_name}-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ldap" {
  count = length(local.iam_statements) > 0 ? 1 : 0

  name = "${var.project_name}-ec2"
  role = aws_iam_role.ldap.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.iam_statements
  })
}

resource "aws_iam_instance_profile" "ldap" {
  name = "${var.project_name}-ec2"
  role = aws_iam_role.ldap.name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ldap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
