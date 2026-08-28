# ==============================================================================
# CloudFront - CDN
# ==============================================================================

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.project_name} CloudFront Distribution"
  default_root_object = ""

  # Alternate domain name the distribution answers to. Route53 aliases www.<zone> here, and
  # without this CloudFront has no idea it owns that name — on real AWS it rejects the Host
  # outright. Referenced through var.dns_zone_name (not the route53 resource) to avoid a
  # dependency cycle, since aws_route53_record.www points back at this distribution.
  # On real AWS, this alias requires an ACM certificate matching the domain — see iac/acm.tf.
  aliases = ["www.${var.dns_zone_name}"]

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "ALB-${aws_lb.main.name}"

    custom_origin_config {
      # LocalStack does not give the ALB a real port-80 listener — every service answers on
      # the gateway port and is routed by Host header. Pointing the origin at 80 locally
      # means CloudFront connects to nothing and returns an empty response.
      http_port              = var.is_local ? 4566 : 80
      https_port             = var.is_local ? 4566 : 443
      origin_protocol_policy = "http-only" # Routing to ALB over HTTP
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ALB-${aws_lb.main.name}"

    forwarded_values {
      query_string = true
      headers      = ["*"]

      cookies {
        forward = "all"
      }
    }

    # Force HTTPS when certificates are valid. In local dev, keep "allow-all" because LocalStack
    # serves plain HTTP on the gateway port.
    viewer_protocol_policy = var.is_local ? "allow-all" : "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # LocalStack uses default CloudFront cert. Real AWS uses ACM cert validated in iac/acm.tf.
  # one() returns null when list is empty to prevent index errors when count = 0.
  viewer_certificate {
    cloudfront_default_certificate = var.is_local
    acm_certificate_arn            = one(aws_acm_certificate_validation.cdn[*].certificate_arn)
    ssl_support_method             = var.is_local ? null : "sni-only"
    minimum_protocol_version       = var.is_local ? null : "TLSv1.2_2021"
  }

  tags = {
    Name        = "${var.project_name}-cloudfront"
    Environment = var.env
  }
}

# --- Outputs ---
output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.cdn.domain_name
  description = "The domain name of the CloudFront distribution"
}
