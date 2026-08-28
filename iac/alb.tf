# ==============================================================================
# ALB - Application Load Balancer
# ==============================================================================

resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Security Group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP traffic from everywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS traffic from everywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-alb-sg"
    Environment = var.env
  }
}

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  enable_deletion_protection = false

  tags = {
    Name        = "${var.project_name}-alb"
    Environment = var.env
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "${var.project_name}-tg-ip"
  port     = 30080 # NodePort of ingress-nginx controller, not the app directly
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # LocalStack: "ip" + playbook manually registers k3d node IPs (no real ASG).
  # Real AWS:   "instance" allows aws_autoscaling_attachment to automatically register
  #             and deregister nodes based on ASG lifecycle.
  target_type = var.is_local ? "ip" : "instance"

  health_check {
    # Dedicated endpoint rather than "/": home page issues do not take targets out of service.
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "${var.project_name}-tg"
    Environment = var.env
  }
}

output "alb_tg_arn" {
  value       = aws_lb_target_group.app_tg.arn
  description = "The ARN of the ALB Target Group"
}

# --- Real AWS ASG Attachment ---
data "aws_autoscaling_groups" "eks_asg" {
  count = var.is_local ? 0 : 1

  filter {
    name   = "tag:eks:cluster-name"
    values = [aws_eks_cluster.main.name]
  }
}

resource "aws_autoscaling_attachment" "eks_asg_attachment" {
  count                  = var.is_local ? 0 : length(data.aws_autoscaling_groups.eks_asg[0].names)
  autoscaling_group_name = data.aws_autoscaling_groups.eks_asg[0].names[count.index]
  lb_target_group_arn    = aws_lb_target_group.app_tg.arn
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# --- Outputs ---
output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "The DNS name of the ALB"
}
