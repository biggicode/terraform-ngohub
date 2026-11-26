# Plans the whole configuration with mocked providers (no AWS access, no state) and checks what the
# NGO Hub own-auth / OIDC switches (T1, T2, T3) do. Run (terraform >= 1.11, e.g. in Docker):
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  override_during = plan

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        { domain_name = "ngohub.test", resource_record_name = "_a.ngohub.test", resource_record_type = "CNAME", resource_record_value = "_a.acm" },
      ]
    }
  }
  mock_resource "aws_sesv2_email_identity" {
    defaults = {
      arn                     = "arn:aws:ses:eu-west-1:123456789012:identity/ngohub.test"
      dkim_signing_attributes = [{ tokens = ["t1", "t2", "t3"] }]
    }
  }

  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"], zone_ids = ["euw1-az1", "euw1-az2", "euw1-az3"] }
  }
  mock_data "aws_ecr_repository" {
    defaults = { repository_url = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/repo" }
  }
  mock_resource "aws_sesv2_configuration_set" {
    defaults = { arn = "arn:aws:ses:eu-west-1:123456789012:configuration-set/main" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_region" {
    defaults = { name = "eu-west-1", region = "eu-west-1" }
  }
}

mock_provider "aws" {
  alias           = "acm"
  override_during = plan
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        { domain_name = "ngohub.test", resource_record_name = "_a.ngohub.test", resource_record_type = "CNAME", resource_record_value = "_a.acm" },
      ]
    }
  }
}

mock_provider "archive" {
  override_during = plan
}

override_resource {
  target          = aws_sesv2_email_identity.main
  override_during = plan
  values = {
    arn                     = "arn:aws:ses:eu-west-1:123456789012:identity/ngohub.test"
    email_identity          = "ngohub.test"
    dkim_signing_attributes = [{ tokens = ["t1", "t2", "t3"] }]
  }
}

override_data {
  target          = data.aws_iam_policy_document.ngohub_s3_private_policy
  override_during = plan
  values          = { json = "{}" }
}

override_data {
  target          = data.aws_iam_policy_document.ngohub_s3_public_policy
  override_during = plan
  values          = { json = "{}" }
}

override_data {
  target          = data.aws_iam_policy_document.vic_s3_private_policy
  override_during = plan
  values          = { json = "{}" }
}

override_data {
  target          = data.aws_iam_policy_document.vic_s3_public_policy
  override_during = plan
  values          = { json = "{}" }
}

variables {
  environment                          = "production"
  root_domain                          = "ngohub.test"
  bastion_public_key                   = "ssh-ed25519 AAAA test"
  ngohub_hmac_api_key                  = "x"
  ngohub_hmac_secret_key               = "x"
  ngohub_hmac_encryption_key           = "x"
  github_access_token                  = "x"
  expo_push_notifications_access_token = "x"
  vic_jwt_private_key                  = "x"
  vic_jwt_public_key                   = "x"
  vic_jwt_key_id                       = "x"
  vic_auth_token_key                   = "x"
  vic_google_client_ids                = "x"
  vic_google_web_client_id             = "x"
  vic_apple_services_id                = "x"
  vic_apple_team_id                    = "x"
  vic_apple_key_id                     = "x"
  vic_apple_private_key                = "x"

  # Every switch on: production must ignore them all.
  ngohub_own_auth_enabled  = true
  vic_ngohub_login_enabled = true
  ngohub_cognito_removed   = true
  ngohub_staging_image_tag = "9.9.9"
  ngohub_jwt_private_key   = "k"
  ngohub_jwt_public_key    = "k"
  ngohub_jwt_key_id        = "k"
  ngohub_auth_token_key    = "k"
  ngohub_oidc_jwks         = "k"
  ngohub_oidc_cookie_keys  = "k"
  vic_ngohub_client_secret = "s"
}

run "production_ignores_every_switch" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  assert {
    condition     = !local.ngohub_own_auth && !local.vic_ngohub_login && local.ngohub_cognito
    error_message = "a switch took effect in production"
  }
  assert {
    condition     = length(module.ngohub_cognito) == 1 && length(aws_cognito_user_pool_client.vic_ngohub_client) == 1
    error_message = "production must keep the Cognito pool and VIC's client on it"
  }
  assert {
    condition     = length(aws_secretsmanager_secret.ngohub_auth) == 0
    error_message = "no NGO Hub auth secret in production"
  }
  assert {
    condition     = local.ngohub.backend.image.tag == "2.0.3"
    error_message = "production keeps the pinned NGO Hub image"
  }
  assert {
    condition     = local.ngohub.frontend.branch == "main" && local.vic.frontend.branch == "main" && local.vic.backend.image.tag == "1.1.0"
    error_message = "production builds main and keeps VIC 1.1.0"
  }
  assert {
    condition     = local.ngohub_own_auth_environment == [] && local.ngohub_own_auth_secrets == [] && local.vic_ngohub_environment == [] && local.vic_ngohub_secrets == []
    error_message = "no own-auth or OIDC settings in production"
  }
  assert {
    condition     = length(local.ngohub_cognito_environment) == 3
    error_message = "production keeps the COGNITO_* settings"
  }
  assert {
    condition     = !can(jsondecode(aws_secretsmanager_secret_version.vic_auth.secret_string).ngohub_oidc_client_secret)
    error_message = "production's vic_auth secret must not get the NGO Hub key"
  }
}

run "staging_with_switches_off_is_unchanged" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  variables {
    environment              = "staging"
    ngohub_own_auth_enabled  = false
    vic_ngohub_login_enabled = false
    ngohub_cognito_removed   = false
    ngohub_staging_image_tag = "2.0.3"
  }

  assert {
    condition     = length(module.ngohub_cognito) == 1 && length(aws_secretsmanager_secret.ngohub_auth) == 0
    error_message = "staging changed with every switch off"
  }
  assert {
    condition     = local.ngohub_own_auth_environment == [] && local.vic_ngohub_environment == []
    error_message = "settings added with every switch off"
  }
  assert {
    condition     = local.ngohub.frontend.branch == "develop" && local.vic.frontend.branch == "develop" && local.vic.backend.image.tag == "2.0.0-rc.4"
    error_message = "staging builds develop and runs VIC 2.0.0-rc.4 by default"
  }
}

run "staging_feature_branches_before_merge" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  variables {
    environment                    = "staging"
    ngohub_cognito_removed         = false
    ngohub_staging_frontend_branch = "feat/ngohub-own-auth"
    vic_staging_frontend_branch    = "feat/ngohub-oidc"
    vic_staging_image_tag          = "ngohub-oidc-1"
  }

  assert {
    condition     = local.ngohub.frontend.branch == "feat/ngohub-own-auth" && local.vic.frontend.branch == "feat/ngohub-oidc" && local.vic.backend.image.tag == "ngohub-oidc-1"
    error_message = "staging takes the feature branches and image"
  }
}

run "staging_cognito_removal_needs_own_auth" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  variables {
    environment             = "staging"
    ngohub_own_auth_enabled = false
    ngohub_cognito_removed  = true
  }

  assert {
    condition     = length(module.ngohub_cognito) == 1
    error_message = "Cognito removed while NGO Hub still logs in through it"
  }
}

run "staging_own_auth_and_vic_login" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  variables {
    environment            = "staging"
    ngohub_cognito_removed = false
  }

  assert {
    condition     = length(aws_secretsmanager_secret.ngohub_auth) == 1 && length(local.ngohub_own_auth_secrets) == 5
    error_message = "the NGO Hub auth secret and its five keys"
  }
  assert {
    condition     = contains([for e in local.ngohub_own_auth_environment : e.name], "OIDC_ISSUER") && [for e in local.ngohub_own_auth_environment : e.value if e.name == "OIDC_ISSUER"][0] == "https://id-staging.ngohub.test"
    error_message = "the issuer is id-staging.<root>"
  }
  assert {
    condition     = local.ngohub.backend.image.tag == "9.9.9"
    error_message = "staging uses the configurable image tag"
  }
  assert {
    condition     = [for e in local.vic_ngohub_environment : e.value if e.name == "NGOHUB_REDIRECT_URI"][0] == "https://vic-staging.ngohub.test/login/ngohub/callback"
    error_message = "VIC's redirect URI"
  }
  assert {
    condition     = length(module.ngohub_cognito) == 1 && length(local.ngohub_cognito_environment) == 3
    error_message = "Cognito stays until T3"
  }
}

run "staging_cognito_removed" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  variables {
    environment = "staging"
  }

  assert {
    condition     = length(module.ngohub_cognito) == 0 && length(aws_cognito_user_pool_client.vic_ngohub_client) == 0
    error_message = "T3 removes the pool and VIC's old client"
  }
  assert {
    condition     = local.ngohub_cognito_environment == []
    error_message = "no COGNITO_* settings after T3"
  }
}

run "staging_own_auth_refuses_missing_keys" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  variables {
    environment             = "staging"
    ngohub_cognito_removed  = false
    ngohub_oidc_cookie_keys = ""
  }

  expect_failures = [aws_secretsmanager_secret_version.ngohub_auth]
}

run "staging_vic_login_refuses_missing_secret" {
  command = plan

  plan_options {
    # Only what the switches touch: SES DKIM, ACM validation and S3 policies cannot be planned on mocks.
    target = [
      module.ngohub_cognito, aws_cognito_user_pool_client.vic_ngohub_client,
      aws_secretsmanager_secret_version.ngohub_auth, aws_secretsmanager_secret_version.vic_auth,
      module.ngohub_frontend, module.vic_frontend, module.ngohub_iam_user, module.ngohub_backend, module.vic_backend,
    ]
  }

  variables {
    environment              = "staging"
    ngohub_cognito_removed   = false
    vic_ngohub_client_secret = null
  }

  expect_failures = [aws_secretsmanager_secret_version.vic_auth]
}
