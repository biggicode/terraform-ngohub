# NGO Hub own login + OIDC, and VIC "Continuă cu NGO Hub": staging rollout

Staging only. Production is a separate runbook (T4, `docs/ngohub-oidc-production.md`) and nothing here changes it: every resource and
setting below is behind `ngohub_own_auth_enabled` / `vic_ngohub_login_enabled`, which are ignored when
`environment = "production"`. Before each apply, check that the plan touches only staging resources.

Code: onghub `feat/ngohub-own-auth` (O0–O15), vic `feat/ngohub-oidc` (VIC 01–07), this repo
`feat/ngohub-oidc-staging` (T1, T2). Plan: `plan-cu-decizii.md` (Andrew, 25 November 2026).

## 0. Before

- [ ] T0 inventory done (Cognito pre-auth trigger, other pool clients, RDS Postgres ≥ 13, Redis memory,
      SES quota, proxy hops). If anything sits between the ALB and the task, set `TRUST_PROXY_HOPS`.
- [ ] The code staging runs, either way:
  - **Before merging (recommended first):** the feature branches pushed to code4romania/onghub and
    code4romania/vic (Amplify builds only from those repos). Backend images built from them and pushed by
    hand to ECR, since `build-image.yml` only builds `main`, `develop` and `v*` tags:
    ```sh
    # onghub/backend at feat/ngohub-own-auth (same for vic/backend at feat/ngohub-oidc)
    docker build --platform linux/amd64 -t <ecr repo>:<tag> . && docker push <ecr repo>:<tag>
    ```
    Then plan every step below with `-var ngohub_staging_image_tag=<ngohub_tag>`,
    `-var vic_staging_image_tag=<vic_tag>`, `-var ngohub_staging_frontend_branch=feat/ngohub-own-auth`,
    `-var vic_staging_frontend_branch=feat/ngohub-oidc`. Changing a frontend branch **replaces** the
    Amplify branch (`develop` is deleted there and recreated when the variable goes back; its settings
    come from terraform, its build history is lost), and the staging site is down until the first build
    finishes.
  - **After merging:** `develop` brought up to `main`, `feat/ngohub-own-auth` and `feat/ngohub-oidc`
    merged into their `develop`, images built by CI (`<ngohub_tag>`, VIC `v2.0.0-rc.N` = `<vic_tag>`),
    the frontend variables left at `develop`.
- [ ] The NGO Hub frontend Amplify builds must contain the own-login SPA before step 3.

## 1. Snapshot and pre-flight

1. Manual RDS snapshot of the staging database (the rollback point).
2. Through the bastion: `psql ... -d ngohub -f onghub/backend/scripts/auth-preflight.sql`. Every check
   must return zero rows (the email migration refuses case duplicates).

## 2. Secrets

```sh
cd onghub/backend && npm run build
npm run oidc:generate-keys -- --env staging --out ngohub-staging.auto.tfvars   # mode 600, never in git or chat
```

Keep the file where the team keeps terraform secrets (it holds the JWT and OIDC signing keys).

## 3. NGO Hub with own login and as OIDC provider (T1)

```sh
terraform workspace select staging
terraform plan \
  -var ngohub_own_auth_enabled=true \
  -var ngohub_staging_image_tag=<ngohub_tag> \
  -var-file=ngohub-staging.auto.tfvars -out t1.plan
```

Expected changes, staging only: the `ngohub_auth` secret and its version, the NGO Hub task definition
(new image, auth and OIDC settings, ECS Exec), the service, the ALB rule and DNS records for
`id-staging.<root>`, the Amplify NGO Hub branch (`REACT_APP_OWN_AUTH`, `REACT_APP_OIDC_ISSUER`) and app
(security headers). Then `terraform apply t1.plan`. Migrations run at boot (`migrationsRun: true`).

Checks: `https://id-staging.<root>/.well-known/openid-configuration` answers with that issuer;
`/oidc/jwks` shows one key with the generated kid; `https://api-staging.<root>/health` is 200.

## 4. Move the users to the own login

ECS Exec into the NGO Hub task (`aws ecs execute-command --cluster ... --task ... --interactive --command sh`):

```sh
npm run auth:migrate -- --dry-run     # counts, duplicates
npm run auth:migrate                  # identities + held transition emails
npm run auth:migrate -- --status      # how many emails are held
# smoke test (below), then:
npm run auth:migrate -- --release     # send the held emails
```

Restricted users (and users of restricted NGOs) get an identity but no transition email; the report counts
them as `restricted`.

Smoke test: login with link and with code, an invite, restricting a user, deleting one, `/new`.
Decision 3: staging has test data, no `MAIL_ALLOWLIST` needed (set `ngohub_mail_allowlist` otherwise).

## 5. Register VIC as a client

Either the super-admin panel (Edit application → "Autentificare cu NGO Hub (OIDC)") on the VIC
application, or in the task (`--application-id` links the client to the VIC application, whose name and
logo the login page shows; without it the page says "vic"):

```sh
npm run oidc:register-client -- --client-id vic --first-party --application-id <VIC application id> \
  --scopes "openid email profile organization" \
  --redirect-uri https://vic-staging.<root>/login/ngohub/callback \
  --redirect-uri http://localhost:5173/login/ngohub/callback
```

The secret is shown once: put it straight into the staging tfvars as `vic_ngohub_client_secret`.

## 6. VIC with "Continuă cu NGO Hub" (T2)

Set VIC's staging image with `-var vic_staging_image_tag=<vic_tag>`, then:

```sh
terraform plan \
  -var ngohub_own_auth_enabled=true -var ngohub_staging_image_tag=<ngohub_tag> \
  -var vic_ngohub_login_enabled=true -var vic_staging_image_tag=<vic_tag> \
  -var-file=ngohub-staging.auto.tfvars -out t2.plan
```

Expected changes: the VIC secret version (new key `ngohub_oidc_client_secret`), the VIC task definition
(`NGOHUB_*`), the VIC Amplify branch (`VITE_NGOHUB_ENABLED=true`). Apply.

The five VIC scenarios (plan, section 7, phase 5): existing admin (by `sub` and by email); NGO Hub admin of
an organization VIC knows (joins, the other admins get "nu am fost noi"); employee (refused, AUTH_017);
admin of a new organization (prefilled form); VIC login of another organization (AUTH_016). Also: logout
in VIC, then "Continuă cu NGO Hub" asks for a new code.

## 7. Link VIC's older organizations

```sh
# NGO Hub task:  npm run oidc:export-orgs -- --out /tmp/ngohub-orgs.json   (copy it to the VIC task)
# VIC task:      npm run ngohub:link-orgs:prod -- --file /tmp/ngohub-orgs.json --report /tmp/report.json
# review the report (conflicts and candidates are never written), then the same with --apply
```

## 8. Remove NGO Hub's Cognito on staging (T3) — IRREVERSIBLE

Only after steps 3–7 work and nobody on staging needs the old login.

1. Export the pool's users and keep the file with the snapshot:
   `aws cognito-idp list-users --user-pool-id <staging pool> --output json > ngohub-staging-users.json`
   (paginate until there is no `PaginationToken`).
2. ```sh
   terraform plan -var ngohub_own_auth_enabled=true -var ngohub_cognito_removed=true \
     -var ngohub_staging_image_tag=<ngohub_tag> -var vic_ngohub_login_enabled=true \
     -var-file=ngohub-staging.auto.tfvars -out t3.plan
   ```
   Expected: destroy `module.ngohub_cognito[0]` (pool, client, domain, lambdas, IAM) and
   `aws_cognito_user_pool_client.vic_ngohub_client[0]`; the NGO Hub task and Amplify branch lose the
   `COGNITO_*` / `REACT_APP_COGNITO_*` / `REACT_APP_USER_POOL_*` settings; the NGO Hub IAM user loses its
   `cognito-idp` statement. Nothing else. On staging the pool has no deletion protection.
3. The first plan on **production** after this change must show only `moved` for
   `module.ngohub_cognito` → `module.ngohub_cognito[0]` and the VIC client, no destroy.

## Local rehearsal (26 November 2026)

Steps 1, 2, 4, 5 and 7, plus the step 6 scenarios, run locally against the real onghub image
(`feat/ngohub-own-auth`, linux/amd64) on a copy of the data, with the commands above run inside the
container. Results: pre-flight catches a case duplicate; the image applies its migrations at boot;
`auth:migrate` dry run writes nothing, a second run creates nothing, `--release` sends the held emails;
code login, refresh, logout; VIC login through the container's issuer: an admin of a linked organization
joins it (the other admins get the email), an employee gets AUTH_017, a mixed-case NGO Hub email still
finds the VIC admin, `prompt=login` refuses an older NGO Hub login (FRESH_LOGIN_REQUIRED);
`ngohub:link-orgs` matches `RO11111111` to `11111111`, and a second `--apply` changes nothing.
Then the same VIC steps with the VIC image too (`feat/ngohub-oidc`, linux/amd64, as in step 0's
pre-merge route): it passes VIC's production environment check with the settings terraform gives the task
(`AWS_S3_BUCKET_NAME`, `AWS_S3_BUCKET_NAME_PUBLIC`, `MAIL_FROM`), logs an NGO Hub admin in through the NGO
Hub image, refuses an employee (AUTH_017), and `ngohub:link-orgs:prod` runs inside it.
Not covered: terraform plan/apply, ALB/DNS/Amplify, SES, step 8.

## Rollback

- VIC: `vic_ngohub_login_enabled=false` and apply (the button disappears, the API answers AUTH_020).
- NGO Hub before step 4: `ngohub_own_auth_enabled=false`, image tag back to `2.0.3`, apply.
- NGO Hub after step 4: also restore the snapshot from step 1 and empty the held transition queue
  (`npm run auth:migrate -- --drop`, before `--release`).
- After step 8 (T3) there is no way back to Cognito on staging.
