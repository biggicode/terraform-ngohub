locals {
  isProduction = var.environment == "production"

  # NGO Hub own login + OIDC provider (T1). Staging only, and only once switched on: the onghub image and
  # the Amplify branch must already contain the feature. Off = exactly the current setup.
  ngohub_own_auth = !local.isProduction && var.ngohub_own_auth_enabled

  namespace  = "ngohub-${var.environment}"
  env_suffix = local.isProduction ? "" : "-${var.environment}"

  availability_zone = data.aws_availability_zones.current.names[1]

  db = {
    instance_class = "db.t4g.micro"
  }

  mail_domain = var.email_domain != null ? var.email_domain : var.root_domain
  mail_from   = "NGO Hub <no-reply@${local.mail_domain}>"

  ngohub = {
    namespace = "ngohub-${var.environment}"

    auth = {
      domain = "auth${local.env_suffix}.${var.root_domain}"
    }

    backend = {
      domain = "api${local.env_suffix}.${var.root_domain}"
      image = {
        repo = data.aws_ecr_repository.ngohub_backend.repository_url
        tag  = local.isProduction ? "2.0.3" : var.ngohub_staging_image_tag
      }
    }

    # The OIDC issuer (decision 1: id.<root> in production, id-staging.<root> on staging). Served by the
    # NGO Hub backend; the provider routes only answer for this host (OIDC_ISSUER_HOST).
    oidc = {
      domain = "id${local.env_suffix}.${var.root_domain}"
    }

    frontend = {
      domain = "app${local.env_suffix}.${var.root_domain}"
    }
  }

  vic = {
    namespace = "vic-${var.environment}"

    auth = {
      domain = "auth-vic${local.env_suffix}.${var.root_domain}"
    }

    backend = {
      domain = "api-vic${local.env_suffix}.${var.root_domain}"
      image = {
        repo = data.aws_ecr_repository.vic_backend.repository_url
        # VIC 2.0 (own authentication): staging runs a vic release tag (v2.0.0-rc.N on develop)
        tag = local.isProduction ? "1.1.0" : "2.0.0-rc.4"
      }
    }

    frontend = {
      domain = "vic${local.env_suffix}.${var.root_domain}"
    }
  }

  centrucivic = {
    frontend = {
      domain = local.isProduction ? "www.centrucivic.ro" : "centrucivic${local.env_suffix}.${var.root_domain}"
    }
  }

  practice4good = {
    frontend = {
      domain = local.isProduction ? "www.practice4good.ro" : "practice4good${local.env_suffix}.${var.root_domain}"
    }
  }
}
