# NGO Hub own login and OIDC provider (onghub O1-O15), staging only: see local.ngohub_own_auth.
# With the switch off nothing here exists and the NGO Hub task definition is unchanged.

locals {
  ngohub_own_auth_environment = [
    for item in [
      { name = "JWT_KEY_ID", value = coalesce(var.ngohub_jwt_key_id, "unset") },
      { name = "JWT_ACCESS_TTL_SECONDS", value = "900" },
      { name = "REFRESH_TTL_DAYS_WEB", value = "7" },
      { name = "WEB_APP_URL", value = "https://${local.ngohub.frontend.domain}" },
      { name = "CORS_ORIGINS", value = "https://${local.ngohub.frontend.domain}" },
      { name = "AWS_REGION", value = var.region },
      { name = "REDIS_KEY_PREFIX", value = "ngohub:" },
      { name = "BULL_PREFIX", value = "ngohub" },
      { name = "OIDC_ISSUER", value = "https://${local.ngohub.oidc.domain}" },
      { name = "OIDC_ISSUER_HOST", value = local.ngohub.oidc.domain },
      { name = "OIDC_INTERACTION_URL", value = "https://${local.ngohub.frontend.domain}/interaction" },
      # VIC's local development client (http://localhost:5173) is registered on staging only
      { name = "OIDC_ALLOW_LOCALHOST_REDIRECTS", value = "true" },
      { name = "MAIL_ALLOWLIST", value = var.ngohub_mail_allowlist },
    ] : item if local.ngohub_own_auth
  ]

  ngohub_own_auth_secrets = [
    for key in ["jwt_private_key", "jwt_public_key", "auth_token_key", "oidc_jwks", "oidc_cookie_keys"] : {
      name      = upper(key)
      valueFrom = "${one(aws_secretsmanager_secret.ngohub_auth[*].arn)}:${key}::"
    } if local.ngohub_own_auth
  ]

  ngohub_spa_security_headers = <<-EOT
    customHeaders:
      - pattern: '**/*'
        headers:
          - key: Content-Security-Policy
            value: "frame-ancestors 'none'"
          - key: Referrer-Policy
            value: strict-origin-when-cross-origin
          - key: X-Content-Type-Options
            value: nosniff
  EOT
}

# One JSON secret, read by key in the task definition (like vic_auth).
resource "aws_secretsmanager_secret" "ngohub_auth" {
  count = local.ngohub_own_auth ? 1 : 0
  name  = "${local.ngohub.namespace}-auth-${random_string.secrets_suffix.result}"
}

resource "aws_secretsmanager_secret_version" "ngohub_auth" {
  count     = local.ngohub_own_auth ? 1 : 0
  secret_id = aws_secretsmanager_secret.ngohub_auth[0].id
  secret_string = jsonencode({
    jwt_private_key  = var.ngohub_jwt_private_key
    jwt_public_key   = var.ngohub_jwt_public_key
    auth_token_key   = var.ngohub_auth_token_key
    oidc_jwks        = var.ngohub_oidc_jwks
    oidc_cookie_keys = var.ngohub_oidc_cookie_keys
  })

  lifecycle {
    # An empty key would start the task with own auth half configured.
    precondition {
      condition = alltrue([
        for value in [
          var.ngohub_jwt_private_key, var.ngohub_jwt_public_key, var.ngohub_jwt_key_id,
          var.ngohub_auth_token_key, var.ngohub_oidc_jwks, var.ngohub_oidc_cookie_keys,
        ] : value != null && value != ""
      ])
      error_message = "ngohub_own_auth_enabled needs ngohub_jwt_private_key, ngohub_jwt_public_key, ngohub_jwt_key_id, ngohub_auth_token_key, ngohub_oidc_jwks and ngohub_oidc_cookie_keys."
    }
  }
}
