terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # S3 bucket names are globally unique. Using a project-prefixed name prevents collisions on real AWS.
    bucket = "learn-opensible-tfstate"
    key    = "infra/terraform.tfstate"
    region = "us-east-1"
    # Other configs (endpoint, access_key, dynamodb_table) are passed via -backend-config.
    #
    # State locking uses a DynamoDB table that is deliberately NOT managed by this state:
    # the lock must already exist before `tofu init` can acquire it. The playbooks bootstrap
    # it alongside the state bucket.
  }
}

provider "aws" {
  region                      = var.region
  access_key                  = var.aws_access_key
  secret_key                  = var.aws_secret_key
  skip_credentials_validation = var.is_local
  skip_metadata_api_check     = var.is_local
  skip_requesting_account_id  = var.is_local
  s3_use_path_style           = var.is_local

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [var.aws_endpoint] : []
    content {
      s3             = endpoints.value
      dynamodb       = endpoints.value
      sqs            = endpoints.value
      sns            = endpoints.value
      eks            = endpoints.value
      iam            = endpoints.value
      ec2            = endpoints.value
      sts            = endpoints.value
      ecr            = endpoints.value
      route53        = endpoints.value
      cloudfront     = endpoints.value
      elbv2          = endpoints.value
      codebuild      = endpoints.value
      secretsmanager = endpoints.value
      acm            = endpoints.value
    }
  }
}

# ==============================================================================
# Secondary Provider pinned to us-east-1
# ==============================================================================
#
# CloudFront ONLY accepts ACM certificates created in us-east-1, regardless of the region
# where the rest of the infrastructure resides.
# Certificates for CloudFront must be issued through this provider.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  access_key                  = var.aws_access_key
  secret_key                  = var.aws_secret_key
  skip_credentials_validation = var.is_local
  skip_metadata_api_check     = var.is_local
  skip_requesting_account_id  = var.is_local
  s3_use_path_style           = var.is_local

  dynamic "endpoints" {
    for_each = var.aws_endpoint != "" ? [var.aws_endpoint] : []
    content {
      acm        = endpoints.value
      cloudfront = endpoints.value
      route53    = endpoints.value
      sts        = endpoints.value
    }
  }
}
