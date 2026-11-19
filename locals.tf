locals {
  isProduction = var.environment == "production"

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
        tag  = "2.0.3"
      }
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
        # VIC 2.0 (own authentication): staging runs the image built from vic `develop`
        tag = local.isProduction ? "1.1.0" : "develop"
        # Staging pins the `develop` image by digest: the tag moves on every vic push, which
        # Terraform cannot see. To deploy a new build, put its digest here (from the vic
        # "Build Docker image" run: `containerimage.digest`).
        # sha256:d820… = vic develop 2852e56d (19 Nov 2026, PR #716)
        digest = local.isProduction ? null : "sha256:d82037b58dc00b3383b6d4ad6dc0469ca211a6e7f98757e51c7be925091af94b"
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
