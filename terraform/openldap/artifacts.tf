resource "random_id" "artifacts_suffix" {
  count       = var.create_artifacts_bucket && var.artifacts_bucket_name == "" ? 1 : 0
  byte_length = 4
}

resource "aws_s3_bucket" "artifacts" {
  count  = var.create_artifacts_bucket ? 1 : 0
  bucket = local.artifacts_bucket_name

  tags = merge(var.tags, {
    Name = "${var.project_name}-artifacts"
  })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  count  = var.create_artifacts_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count  = var.create_artifacts_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  count  = var.create_artifacts_bucket ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "bootstrap" {
  for_each = var.upload_local_artifacts && local.enable_artifacts ? {
    for f in local.bootstrap_files : f => f
  } : {}

  bucket     = local.artifacts_bucket_name
  key        = "bootstrap/${each.key}"
  source     = "${local.artifacts_bootstrap_dir}/${each.value}"
  etag       = filemd5("${local.artifacts_bootstrap_dir}/${each.value}")
  depends_on = [aws_s3_bucket.artifacts]
}

resource "aws_s3_object" "script" {
  for_each = var.upload_local_artifacts && local.enable_artifacts ? {
    for f in local.script_files : f => f
  } : {}

  bucket     = local.artifacts_bucket_name
  key        = "script/${each.key}"
  source     = "${local.artifacts_script_dir}/${each.value}"
  etag       = filemd5("${local.artifacts_script_dir}/${each.value}")
  depends_on = [aws_s3_bucket.artifacts]
}

resource "aws_s3_object" "ldif" {
  for_each = var.upload_local_artifacts && local.enable_artifacts ? {
    for f in local.ldif_files : f => f
  } : {}

  bucket     = local.artifacts_bucket_name
  key        = "ldif/${each.key}"
  source     = "${local.artifacts_ldif_dir}/${each.value}"
  etag       = filemd5("${local.artifacts_ldif_dir}/${each.value}")
  depends_on = [aws_s3_bucket.artifacts]
}

resource "aws_s3_object" "mirrormode_script" {
  for_each = var.upload_local_artifacts && local.enable_artifacts ? {
    for f in local.mirrormode_script_files : f => f
  } : {}

  bucket     = local.artifacts_bucket_name
  key        = "mirrormode-scripts/${each.key}"
  source     = "${local.artifacts_mirrormode_scripts_dir}/${each.value}"
  etag       = filemd5("${local.artifacts_mirrormode_scripts_dir}/${each.value}")
  depends_on = [aws_s3_bucket.artifacts]
}
