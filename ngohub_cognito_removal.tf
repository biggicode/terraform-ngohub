# T3: NGO Hub's Cognito pool becomes conditional (local.ngohub_cognito). These blocks keep the existing
# resources at their new addresses, so production (and staging until the switch) plans "moved", never
# "destroy and create".

moved {
  from = module.ngohub_cognito
  to   = module.ngohub_cognito[0]
}

moved {
  from = aws_cognito_user_pool_client.vic_ngohub_client
  to   = aws_cognito_user_pool_client.vic_ngohub_client[0]
}

locals {
  ngohub_cognito_environment = [
    for item in [
      { name = "COGNITO_CLIENT_ID", value = one(module.ngohub_cognito[*].user_pool_client_id) },
      { name = "COGNITO_USER_POOL_ID", value = one(module.ngohub_cognito[*].user_pool_id) },
      { name = "COGNITO_REGION", value = var.region },
    ] : item if local.ngohub_cognito
  ]
}
