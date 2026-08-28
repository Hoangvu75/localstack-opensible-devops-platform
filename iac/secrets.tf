# ==============================================================================
# Secret Management — Ownership Boundaries
# ==============================================================================
#
# Secret values are intentionally NOT declared in this file.
#
# Rationale 1 — Bootstrap loop: Playbooks require tokens to clone this repo.
# Tofu cannot create the key to access its own definitions.
#
# Rationale 2 — State security: Declaring `aws_secretsmanager_secret_version` would
# store raw secret values in the tfstate file.
#
# Division of responsibilities:
#   playbooks/1.manage-secrets.yml  → creates/populates secrets (out-of-band)
#   AWS Secrets Manager             → single source of truth for secret values
#   OpenTofu (this file)            → grants IAM read access without exposing values
#
# Wildcard ARN pattern: Secrets Manager appends 6 random characters to ARNs upon creation.
# Using a scoped prefix pattern preserves least-privilege without rigid run-order dependencies.
# ==============================================================================

data "aws_caller_identity" "current" {}

locals {
  # Naming convention: all project secrets follow "<project_name>/<name>".
  secrets_arn_pattern = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/*"

  # Secret name containing GitHub PAT.
  github_token_secret_id = "${var.project_name}/github-token"
}

output "github_token_secret_id" {
  value       = local.github_token_secret_id
  description = "Secret name containing GitHub PAT — populated by playbooks/1.manage-secrets.yml"
}

output "secrets_arn_pattern" {
  value       = local.secrets_arn_pattern
  description = "ARN scope allowed for project IAM roles"
}
