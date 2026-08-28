# ==============================================================================
# Dedicated ALB for SigNoz
# ==============================================================================
#
# Follows the same pattern as the ArgoCD ALB:
#
#   1. Single-page applications can face path-routing issues under subpaths.
#      With a dedicated hostname, SigNoz serves cleanly at root "/".
#
#   2. Production alignment: administrative and observability surfaces remain
#      isolated from user traffic.
#
# ------------------------------------------------------------------------------
# THREE ALBs, THREE NODEPORT PORTS — must match across three places:
#
#   30080  ingress-nginx     → alb.tf                → web app
#   30081  argocd-server     → alb-argocd.tf         → ArgoCD UI
#   30083  signoz            → this file             → SigNoz UI
#
# Modifying ports requires updating NodePort Services in gitops/platform/ and
# register-targets tasks in playbooks/3.deploy-k8s-infra.yml.
# ==============================================================================

resource "aws_lb" "signoz" {
  name = "${var.project_name}-signoz-alb"

  # Real AWS: Internal ALB (observability data contains pod logs; access via VPN/Direct Connect).
  # Local lab: Public ALB for browser access in LocalStack.
  internal = !var.is_local

  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]

  subnets = var.is_local ? [aws_subnet.public_a.id, aws_subnet.public_b.id] : [aws_subnet.private_a.id, aws_subnet.private_b.id]

  enable_deletion_protection = false

  tags = {
    Name        = "${var.project_name}-signoz-alb"
    Environment = var.env
    Component   = "observability"
  }
}

resource "aws_lb_target_group" "signoz" {
  name     = "${var.project_name}-signoz-tg"
  port     = 30083
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  target_type = var.is_local ? "ip" : "instance"

  health_check {
    # Aligns with StatefulSet signoz livenessProbe in chart v0.139.0.
    path              = "/api/v1/health"
    protocol          = "HTTP"
    matcher           = "200"
    interval          = 30
    timeout           = 5
    healthy_threshold = 2
    # 5 instead of 3: SigNoz startup requires ClickHouse readiness.
    unhealthy_threshold = 5
  }

  tags = {
    Name        = "${var.project_name}-signoz-tg"
    Environment = var.env
  }
}

resource "aws_lb_listener" "signoz_http" {
  load_balancer_arn = aws_lb.signoz.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.signoz.arn
  }
}

# Real AWS: ASG automatically registers/deregisters instances with this target group.
resource "aws_autoscaling_attachment" "signoz_asg_attachment" {
  count                  = var.is_local ? 0 : length(data.aws_autoscaling_groups.eks_asg[0].names)
  autoscaling_group_name = data.aws_autoscaling_groups.eks_asg[0].names[count.index]
  lb_target_group_arn    = aws_lb_target_group.signoz.arn
}

# --- Outputs ---
output "signoz_alb_dns_name" {
  value       = aws_lb.signoz.dns_name
  description = "DNS hostname of the dedicated SigNoz ALB"
}

output "signoz_tg_arn" {
  value       = aws_lb_target_group.signoz.arn
  description = "Target group ARN for SigNoz used by playbooks to register nodes"
}
