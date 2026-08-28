# ==============================================================================
# AWS ECR (Elastic Container Registry) — Container Image Repositories
# ==============================================================================

resource "aws_ecr_repository" "web_app" {
  name = "${var.project_name}-web-app"

  # force_delete allows `tofu destroy` to clean up repositories that contain images.
  # In production, consider setting this to false to prevent accidental deletion 
  # of images, including those currently used in production.
  force_delete = true

  # MUTABLE for local lab testing; switch to IMMUTABLE in production environments
  # to ensure image tags are reliable and cannot be overwritten.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-web-app"
    Environment = var.env
    Component   = "registry"
  }
}

# Lifecycle policy prevents the repository from growing indefinitely and increasing 
# storage costs.
resource "aws_ecr_lifecycle_policy" "web_app" {
  repository = aws_ecr_repository.web_app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after 1 day (prunes intermediate multi-stage build layers)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the latest 10 tagged images for rollback capabilities"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ==============================================================================
# Repositories for metric microservices
# ==============================================================================
#
# Why a separate resource instead of `for_each` on `web_app`?
#
# Merging would change the resource state address, causing OpenTofu to destroy 
# and recreate the repository rather than renaming it. This is dangerous for
# production data. Keeping it separate prevents accidental state corruption.
locals {
  metric_services = ["cpu-service", "memory-service", "disk-service", "rest-service", "history-service"]
}

resource "aws_ecr_repository" "metric_services" {
  for_each = toset(local.metric_services)

  name                 = "${var.project_name}-${each.key}"
  force_delete         = true
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-${each.key}"
    Environment = var.env
    Component   = "registry"
  }
}

resource "aws_ecr_lifecycle_policy" "metric_services" {
  for_each = aws_ecr_repository.metric_services

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after 1 day (prunes intermediate multi-stage build layers)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the latest 10 tagged images for rollback capabilities"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

# --- Outputs ---
output "ecr_repository_url" {
  value       = aws_ecr_repository.web_app.repository_url
  description = "AWS ECR Repository URL for Web Application Image"
}

output "ecr_metric_service_urls" {
  value       = { for k, v in aws_ecr_repository.metric_services : k => v.repository_url }
  description = "ECR repository URLs for metric microservices"
}
