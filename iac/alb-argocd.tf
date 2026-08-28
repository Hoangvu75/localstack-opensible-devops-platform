# ==============================================================================
# Dedicated ALB for ArgoCD
# ==============================================================================
#
# Rationale for a dedicated ALB instead of a subpath /argocd on the app ALB:
#
#   1. ArgoCD subpath limitations on v2.13.2 (details in gitops/bootstrap/argocd/server-params-cm.yaml).
#      With a dedicated hostname, ArgoCD serves cleanly at root "/".
#
#   2. Production alignment: administrative control planes should be separated from user workloads
#      to allow distinct network perimeters and access policies.
#
# LocalStack allocates hostnames matching `<name>.elb.localhost.localstack.cloud`.

resource "aws_lb" "argocd" {
  name = "${var.project_name}-argocd-alb"

  # Real AWS: Internal ALB (accessible via VPN/Direct Connect).
  # Local lab: Public ALB to permit direct browser access in LocalStack.
  internal = !var.is_local

  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]

  # Internal ALBs reside in private subnets; public ALBs reside in public subnets.
  subnets = var.is_local ? [aws_subnet.public_a.id, aws_subnet.public_b.id] : [aws_subnet.private_a.id, aws_subnet.private_b.id]

  enable_deletion_protection = false

  tags = {
    Name        = "${var.project_name}-argocd-alb"
    Environment = var.env
    Component   = "gitops"
  }
}

resource "aws_lb_target_group" "argocd" {
  name     = "${var.project_name}-argocd-tg"
  port     = 30081 # NodePort of argocd-server-nodeport, see gitops/bootstrap/argocd/nodeport-svc.yaml
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # LocalStack: "ip" target type for manual registration by playbooks.
  # Real AWS: "instance" target type managed via aws_autoscaling_attachment.
  target_type = var.is_local ? "ip" : "instance"

  health_check {
    # ArgoCD exposes /healthz and responds with "ok".
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "${var.project_name}-argocd-tg"
    Environment = var.env
  }
}

resource "aws_lb_listener" "argocd_http" {
  load_balancer_arn = aws_lb.argocd.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.argocd.arn
  }
}

# Real AWS: ASG automatically registers/deregisters instances with this target group.
resource "aws_autoscaling_attachment" "argocd_asg_attachment" {
  count                  = var.is_local ? 0 : length(data.aws_autoscaling_groups.eks_asg[0].names)
  autoscaling_group_name = data.aws_autoscaling_groups.eks_asg[0].names[count.index]
  lb_target_group_arn    = aws_lb_target_group.argocd.arn
}

# --- Outputs ---
output "argocd_alb_dns_name" {
  value       = aws_lb.argocd.dns_name
  description = "DNS hostname of the dedicated ArgoCD ALB"
}

output "argocd_tg_arn" {
  value       = aws_lb_target_group.argocd.arn
  description = "Target group ARN for ArgoCD used by playbooks to register nodes"
}
