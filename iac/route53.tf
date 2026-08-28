# ==============================================================================
# Route 53 - DNS
# ==============================================================================

resource "aws_route53_zone" "main" {
  name = var.dns_zone_name

  tags = {
    Name        = "${var.project_name}-zone"
    Environment = var.env
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${var.dns_zone_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

# --- Outputs ---
output "route53_nameservers" {
  value       = aws_route53_zone.main.name_servers
  description = "Name servers for the Route 53 zone"
}

output "website_url" {
  # LocalStack routes all services via the gateway port using the Host header, making the port
  # part of the local URL. On AWS with ACM certificates, traffic uses standard HTTPS.
  value       = var.is_local ? "http://${aws_route53_record.www.name}:4566" : "https://${aws_route53_record.www.name}"
  description = "The final URL to access the website"
}
