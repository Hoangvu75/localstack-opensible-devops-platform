# ==============================================================================
# ACM — TLS certificate for CloudFront custom domain
# ==============================================================================
#
# Rationale: CloudFront REJECTS custom `aliases` without an ACM certificate matching
# that domain. The distribution previously declared `aliases = ["www.<zone>"]` with
# `cloudfront_default_certificate = true` — which works on LocalStack (unverified)
# but fails immediately on real AWS.
#
# Disabled when running locally (`count = 0`): LocalStack does not perform DNS validation,
# causing resources to hang indefinitely in PENDING_VALIDATION.
#
# ------------------------------------------------------------------------------
# Three resources, one closed loop:
#
#   1. aws_acm_certificate            → request certificate; ACM returns DNS validation record
#   2. aws_route53_record             → create DNS validation record in hosted zone
#   3. aws_acm_certificate_validation → wait until ACM verifies DNS record and issues certificate
#
# Step 3 creates no actual cloud resource; it is a wait barrier.
#
# ------------------------------------------------------------------------------
# External Prerequisite:
#
# DNS validation succeeds only when domain nameservers point to this hosted zone.
# Run `tofu output route53_nameservers` and update your domain registrar BEFORE applying.
# ==============================================================================

resource "aws_acm_certificate" "cdn" {
  count = var.is_local ? 0 : 1

  # Must use the us-east-1 provider — see notes in iac/providers.tf.
  provider = aws.us_east_1

  domain_name       = "www.${var.dns_zone_name}"
  validation_method = "DNS"

  # Active CloudFront certificates cannot be deleted. Create replacement first when updating.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-cdn-cert"
    Environment = var.env
  }
}

# DNS validation record. `allow_overwrite` prevents failures if records from older certificates exist.
resource "aws_route53_record" "cert_validation" {
  count = var.is_local ? 0 : 1

  zone_id         = aws_route53_zone.main.zone_id
  name            = tolist(aws_acm_certificate.cdn[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.cdn[0].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.cdn[0].domain_validation_options)[0].resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cdn" {
  count    = var.is_local ? 0 : 1
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cdn[0].arn
  validation_record_fqdns = [aws_route53_record.cert_validation[0].fqdn]

  timeouts {
    create = "10m"
  }
}

output "cdn_certificate_arn" {
  # one() returns null when the list is empty (e.g. running on LocalStack).
  value       = one(aws_acm_certificate_validation.cdn[*].certificate_arn)
  description = "ACM certificate ARN used by CloudFront (null on LocalStack)"
}
