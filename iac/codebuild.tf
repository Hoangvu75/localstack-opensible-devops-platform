# ==============================================================================
# AWS CodeBuild - CI/CD Pipeline
# ==============================================================================

# IAM Role cho CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "${var.project_name}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

# Policy cho CodeBuild (S3, ECR, EKS)
resource "aws_iam_role_policy" "codebuild_policy" {
  name = "${var.project_name}-codebuild-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetObjectVersion"
        ]
        Resource = [
          aws_s3_bucket.cicd_artifacts.arn,
          "${aws_s3_bucket.cicd_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      # NO EKS permissions here, by design.
      #
      # Prior to GitOps migration, buildspec executed `kubectl apply`, requiring CodeBuild
      # to have `eks:DescribeCluster` and an entry in aws-auth. With GitOps, CI stops after
      # pushing images and updating kustomization.yaml; ArgoCD INSIDE the cluster handles deployments.
      #
      # CodeBuild fetches the GitHub PAT directly from Secrets Manager instead of receiving it via env vars.
      # The IAM role scopes permissions to the project's secret prefix (local.secrets_arn_pattern).
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = local.secrets_arn_pattern
      }
    ]
  })
}

# CodeBuild Project
resource "aws_codebuild_project" "app_build" {
  name          = "${var.project_name}-build"
  description   = "Builds the Next.js app and deploys to EKS"
  build_timeout = "30"
  service_role  = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
  }

  source {
    type     = "S3"
    location = "${aws_s3_bucket.cicd_artifacts.id}/source.zip"

    # Inline the buildspec instead of pointing at a path inside the source zip.
    # The CodeBuild agent used by LocalStack recurses forever when it has to resolve a
    # buildspec *path* (resolveBuildspec -> stack overflow -> build container exits 2),
    # so we hand it the content directly. Inline buildspecs are valid on real AWS too.
    # NOTE: editing buildspec.yml now requires re-running playbooks/2.deploy-cloud-infra.yml.
    buildspec = file("${path.module}/../buildspec.yml")
  }

  tags = {
    Environment = var.env
  }
}

output "codebuild_project_name" {
  value       = aws_codebuild_project.app_build.name
  description = "The name of the CodeBuild project"
}
