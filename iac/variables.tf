# ==============================================================================
# Variables — Global Infrastructure Configuration
# ==============================================================================

# --- Provider & Authentication ---
variable "aws_access_key" {
  type        = string
  default     = "mock_access_key"
  description = "AWS Access Key ID"
}

variable "aws_secret_key" {
  type        = string
  default     = "mock_secret_key"
  description = "AWS Secret Key"
}

variable "aws_endpoint" {
  description = "AWS endpoint URL for all services (e.g., http://localstack:4566). Leave empty for real AWS."
  type        = string
  default     = ""
}

variable "is_local" {
  description = "Set to true when using local emulators like LocalStack to skip cloud-only validations."
  type        = bool
  default     = false
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS Region"
}

# --- Project ---
variable "project_name" {
  type        = string
  default     = "learn-opensible"
  description = "Project name prefix used for resource naming"
}

variable "env" {
  type        = string
  default     = "dev"
  description = "Environment name (dev, staging, prod)"
}

# --- DNS ---
variable "dns_zone_name" {
  type        = string
  default     = "learn-opensible.localhost.localstack.cloud"
  description = <<-EOT
    Hosted zone name. On LocalStack, keep this under localhost.localstack.cloud:
    that domain has a public wildcard A record pointing at 127.0.0.1, so a browser on the
    host resolves the name with no hosts-file entry and still sends the right Host header
    for LocalStack to route on.
    On real AWS, set this to a domain you actually own.
  EOT
}

# --- EKS ---
variable "eks_version" {
  type        = string
  default     = "1.31"
  description = "Kubernetes version for EKS Cluster"
}

variable "eks_node_instance_type" {
  type        = string
  default     = "t3.medium"
  description = "Instance type for EKS Worker Nodes"
}

variable "eks_node_desired" {
  type        = number
  default     = 2
  description = "Desired number of worker nodes"
}

variable "eks_node_min" {
  type        = number
  default     = 1
  description = "Minimum number of worker nodes"
}

variable "eks_node_max" {
  type        = number
  default     = 3
  description = "Maximum number of worker nodes"
}

variable "eks_admin_principal_arn" {
  type        = string
  default     = ""
  description = <<-EOT
    ARN of the IAM role/user used by the Ansible worker for EKS cluster access.
    Applicable only on real AWS (LocalStack does not enforce EKS IAM auth).
    Leave blank when the identity running `tofu apply` also runs kubectl.
    Must be the role ARN (e.g. arn:aws:iam::123456789012:role/ansible-worker),
    not an assumed-role session ARN.
  EOT
}

