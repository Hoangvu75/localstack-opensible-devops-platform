# ==============================================================================
# S3 — Storage
# ==============================================================================
#
# Two buckets, intentionally separated:
#
#   learn-opensible-tfstate          ← OpenTofu state. NOT declared here (see note below).
#   learn-opensible-cicd-artifacts   ← source.zip for CodeBuild. Managed by OpenTofu.
#
# Why the state bucket is outside OpenTofu: the state cannot manage the bucket containing itself;
# `tofu destroy` would delete state during destruction. Bootstrapped and hardened via playbooks.
#
# Why not combine them: separating buckets ensures clean IAM permission boundaries.

resource "aws_s3_bucket" "cicd_artifacts" {
  bucket        = "${var.project_name}-cicd-artifacts"
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-cicd-artifacts"
    Environment = var.env
    Component   = "cicd"
  }
}

# --- Default Hardening ---
# Production defaults: block public access, enable at-rest encryption, and enable versioning.
resource "aws_s3_bucket_public_access_block" "cicd_artifacts" {
  bucket = aws_s3_bucket.cicd_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cicd_artifacts" {
  bucket = aws_s3_bucket.cicd_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "cicd_artifacts" {
  bucket = aws_s3_bucket.cicd_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Retain old versions for 7 days to assist in troubleshooting failed builds.
resource "aws_s3_bucket_lifecycle_configuration" "cicd_artifacts" {
  bucket = aws_s3_bucket.cicd_artifacts.id

  rule {
    id     = "expire-old-source-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- Outputs ---
output "cicd_bucket_name" {
  value       = aws_s3_bucket.cicd_artifacts.id
  description = "S3 Bucket containing source.zip for CodeBuild"
}
