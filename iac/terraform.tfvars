# ==============================================================================
# Variable Values for Lab Environment (LocalStack Emulator)
# ==============================================================================

aws_access_key = "mock_access_key"
aws_secret_key = "mock_secret_key"
project_name   = "learn-opensible"
region         = "us-east-1"
env            = "dev"
aws_endpoint   = "http://localstack:4566"

# --- EKS ---
eks_version            = "1.31"
eks_node_instance_type = "t3.medium"
eks_node_desired       = 2
eks_node_min           = 1
eks_node_max           = 3

# ==============================================================================
# Configuration when migrating to real AWS
# ==============================================================================
#
# is_local     = false
# aws_endpoint = ""                          # Leave blank for real AWS endpoints
# aws_access_key / aws_secret_key            # REMOVE COMPLETELY — use IAM roles, avoid static keys in git
# dns_zone_name = "hoangvu75.space"          # Your actual domain name
#
# eks_admin_principal_arn = "arn:aws:iam::<account>:role/<worker-role>"
#   Only required when the Ansible worker runs under an identity DIFFERENT from the one running `tofu apply`.
#
# Before the first apply: run `tofu output route53_nameservers` and update registrar NS records.
