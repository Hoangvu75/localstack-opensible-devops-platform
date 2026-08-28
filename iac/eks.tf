# ==============================================================================
# EKS Cluster + Node Group
# ==============================================================================

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-${var.env}"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # EKS authenticates via IAM, NOT certificates in kubeconfig.
  # If an IAM identity lacks cluster access, kubectl commands fail with:
  # "error: You must be logged in to the server (Unauthorized)"
  #
  # API_AND_CONFIG_MAP preserves both Access Entries (modern, Terraform-managed) and
  # the aws-auth ConfigMap (legacy).
  dynamic "access_config" {
    for_each = var.is_local ? [] : [1]
    content {
      authentication_mode                         = "API_AND_CONFIG_MAP"
      bootstrap_cluster_creator_admin_permissions = true
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.env}"
    Environment = var.env
    Component   = "kubernetes"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
}

# --- Node Group (Worker Nodes) ---
resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-workers"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  instance_types = [var.eks_node_instance_type]

  scaling_config {
    desired_size = var.eks_node_desired
    max_size     = var.eks_node_max
    min_size     = var.eks_node_min
  }

  tags = {
    Name        = "${var.project_name}-workers"
    Environment = var.env
    Component   = "kubernetes"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
  ]
}

# ==============================================================================
# Cluster Access for Ansible Worker
# ==============================================================================
#
# `bootstrap_cluster_creator_admin_permissions` grants access only to the identity
# that ran `tofu apply`. If the Ansible worker assumes a separate role, grant access
# by specifying `eks_admin_principal_arn` in terraform.tfvars.
resource "aws_eks_access_entry" "ansible_worker" {
  count = (!var.is_local && var.eks_admin_principal_arn != "") ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.eks_admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ansible_worker" {
  count = (!var.is_local && var.eks_admin_principal_arn != "") ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.eks_admin_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.ansible_worker]
}

# --- Outputs ---
output "eks_cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "EKS Cluster Name"
}

output "eks_cluster_endpoint" {
  value       = aws_eks_cluster.main.endpoint
  description = "EKS API Server Endpoint"
}

output "eks_cluster_version" {
  value       = aws_eks_cluster.main.version
  description = "Kubernetes version"
}
