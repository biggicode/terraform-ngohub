# VIC: login with NGO Hub (OIDC client, VIC issues 01-05), staging only: see local.vic_ngohub_login.
# With the switch off the VIC task definition, its secret and the Amplify branch are unchanged.

locals {
  vic_ngohub_environment = [
    for item in [
      { name = "NGOHUB_ISSUER", value = "https://${local.ngohub.oidc.domain}" },
      { name = "NGOHUB_CLIENT_ID", value = var.vic_ngohub_client_id },
      { name = "NGOHUB_REDIRECT_URI", value = "https://${local.vic.frontend.domain}/login/ngohub/callback" },
      # The NGO Hub logo is copied from its private bucket through a presigned URL (both host styles)
      {
        name = "NGOHUB_LOGO_HOSTS"
        value = join(",", [
          module.ngohub_s3_private.bucket_regional_domain_name,
          "${module.ngohub_s3_private.bucket}.s3.amazonaws.com",
        ])
      },
    ] : item if local.vic_ngohub_login
  ]

  vic_ngohub_secrets = [
    for item in [
      {
        name      = "NGOHUB_CLIENT_SECRET"
        valueFrom = "${aws_secretsmanager_secret.vic_auth.arn}:ngohub_oidc_client_secret::"
      },
    ] : item if local.vic_ngohub_login
  ]
}
