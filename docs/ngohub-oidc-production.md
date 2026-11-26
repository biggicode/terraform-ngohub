# NGO Hub own login + OIDC, VIC "Continuă cu NGO Hub", Cognito removal: production runbook (T4)

**Status: draft for Andrew's approval. Nothing here has been run.** Each phase is its own change window,
with its own go/no-go. O16 (removing the Cognito code from onghub) starts only after phase 5 is done.

Order (plan, section 2.7): VIC 2.0 in production → NGO Hub with own login and OIDC → VIC on NGO Hub OIDC →
NGO Hub's Cognito pool removed → VIC's Cognito pool and the leftovers removed.

Staging runbook: `docs/ngohub-oidc-staging.md`. Everything below assumes it ran end to end on staging,
T3 included, and staging stayed stable for at least two weeks.

## 0. Before any phase

- [ ] Andrew approved this runbook. Code4 knows the dates (NGO admins get a "new login" email).
- [ ] Production inventory, like T0 on staging, read-only: is `login_pre_authentication_check` set as a
      trigger on the NGO Hub pool (`describe-user-pool`)? Which clients the pool has
      (`list-user-pool-clients`): anything besides NGO Hub and `vic_ngohub_client` must be answered
      for before phase 4. RDS Postgres ≥ 13, Redis free memory, SES production quota and sending
      rate (one transition email per user), proxy hops between the ALB and the task (`TRUST_PROXY_HOPS`).
- [ ] `onghub/backend/scripts/auth-preflight.sql` run against a **copy** of production (a restored
      snapshot), every check zero rows. Fix case-duplicate emails in production before phase 2.
- [ ] Rehearsal on that copy: `auth:migrate -- --dry-run` in the production image, counts noted.
- [ ] The terraform change from section 1 merged, and its plan on production checked.

## 1. Terraform change for production (a separate PR, not on `feat/ngohub-oidc-staging`)

T1–T3 are hard-wired to staging (`!local.isProduction`). Production needs, reviewed on its own:

- `local.ngohub_own_auth = var.ngohub_own_auth_enabled` in both environments, still default `false`.
- The production NGO Hub image tag pinned in `locals.tf` (now `2.0.3`), changed only in phase 2.
- `OIDC_ALLOW_LOCALHOST_REDIRECTS = "false"` in production (staging keeps `true` for VIC developers).
- ECS Exec on the production NGO Hub service only for the phase 2 and 4 windows (`enable_execute_command`
  behind its own variable), switched off again afterwards.
- `AUTH_TOKEN_KEY_PREVIOUS` in the `ngohub_auth` secret, optional, for key rotation (section 8). Today
  terraform does not pass it.
- `ngohub_cognito_removed` allowed in production, plus a variable that turns off the pool's
  `deletion_protection` (`modules/cognito/main.tf:6`: production is `ACTIVE`). Both default off.

Acceptance: with every switch off, the production plan shows only the `moved` blocks from T3
(`module.ngohub_cognito` → `[0]`, `aws_cognito_user_pool_client.vic_ngohub_client` → `[0]`), no create,
change or destroy.

## 2. Phase 1 — VIC 2.0 (own login) in production

VIC's own release and runbook (VIC Auth Migration docs). Prerequisite, not part of this work: VIC
production moves from `1.1.0` to the 2.0 release (`locals.tf`, `local.vic.backend.image.tag`), its
users migrated to VIC's own login, mobile apps released. **Check:** VIC no longer calls Cognito in
production (no `cognito-idp` calls in CloudTrail for a week) before phase 5.

## 3. Phase 2 — NGO Hub with own login and as OIDC provider

1. Announce a short window. Manual RDS snapshot of production: **rollback point A**.
2. Pre-flight on the live database (bastion): `psql ... -f onghub/backend/scripts/auth-preflight.sql`,
   zero rows.
3. Secrets: `npm run oidc:generate-keys -- --env production --out ngohub-production.auto.tfvars`
   (mode 600). Keep the file only where the team keeps production secrets. **Production keys are never
   the staging keys.**
4. Image: the onghub release built from `main` with O1–O15: `<ngohub_tag>`.
5. ```sh
   terraform workspace select production
   terraform plan -var ngohub_own_auth_enabled=true -var-file=ngohub-production.auto.tfvars -out p2.plan
   ```
   Expected: the `ngohub_auth` secret, the NGO Hub task definition (image, auth and OIDC settings), the
   ALB rule and DNS for `id.<root>`, the Amplify `main` branch (`REACT_APP_OWN_AUTH`,
   `REACT_APP_OIDC_ISSUER`) and app headers. Cognito unchanged. Apply. Migrations run at boot.
6. Checks: `https://id.<root>/.well-known/openid-configuration` has that issuer; `/oidc/jwks` has the
   generated kid; `https://api.<root>/health` 200; Amplify `main` redeployed with the own-login SPA.
7. ECS Exec into the NGO Hub task:
   ```sh
   npm run auth:migrate -- --dry-run     # same counts as the rehearsal on the copy
   npm run auth:migrate                  # identities; transition emails held
   ```
   **Rollback point B** (before the emails leave).
8. Smoke test with the team's own accounts: login with link and with code, an invite, restricting a user,
   deleting one, `/new`, super-admin pages.
9. `npm run auth:migrate -- --release`. The queue limiter spaces the emails; watch SES bounces and
   complaints. `--status` until 0.

From step 9 on, users hold 30-day transition links: **do not rotate `AUTH_TOKEN_KEY` for 30 days.**

## 4. Phase 3 — VIC production on NGO Hub OIDC

1. Register VIC on production NGO Hub: super-admin panel (Edit application → "Autentificare cu NGO Hub
   (OIDC)") on the VIC application, or in the task:
   ```sh
   npm run oidc:register-client -- --client-id vic --first-party --application-id <VIC application id> \
     --scopes "openid email profile organization" \
     --redirect-uri https://vic.<root>/login/ngohub/callback
   ```
   No localhost redirect in production. The secret is shown once: straight into the production tfvars as
   `vic_ngohub_client_secret`.
2. `terraform plan -var ngohub_own_auth_enabled=true -var vic_ngohub_login_enabled=true ... -out p3.plan`.
   Expected: the VIC secret version (`ngohub_oidc_client_secret`), the VIC task definition (`NGOHUB_*`),
   the VIC Amplify branch (`VITE_NGOHUB_ENABLED=true`). Apply.
3. Scenarios with a test organization the team owns: existing VIC admin; NGO Hub admin of an
   organization VIC knows (joins; the other admins get "nu am fost noi"); employee (AUTH_017); new
   organization (prefilled form); VIC admin of another organization (AUTH_016); VIC logout, then a new
   code is asked for.
4. Link older organizations:
   ```sh
   # NGO Hub task: npm run oidc:export-orgs -- --out /tmp/ngohub-orgs.json   (copy to the VIC task)
   # VIC task:     npm run ngohub:link-orgs:prod -- --file /tmp/ngohub-orgs.json --report /tmp/report.json
   ```
   Review the report with Code4 (conflicts and candidates are never written; candidates are fixed by
   hand, question 15), then the same with `--apply`. Keep both reports.
5. ECS Exec off again (section 1).

## 5. Phase 4 — remove NGO Hub's Cognito pool (IRREVERSIBLE)

Not before: phase 3 has run for at least a month, the transition emails' 30 days are over, nobody uses the
old login (no Cognito sign-ins in the pool metrics), and Code4 agrees in writing.

1. Export the pool's users (paginate until no `PaginationToken`) and archive the file with a fresh RDS
   snapshot:
   `aws cognito-idp list-users --user-pool-id <production pool> --output json > ngohub-production-users.json`
2. Turn off deletion protection (the variable from section 1), plan, apply: only the pool's
   `deletion_protection` changes.
3. ```sh
   terraform plan -var ngohub_own_auth_enabled=true -var vic_ngohub_login_enabled=true \
     -var ngohub_cognito_removed=true ... -out p4.plan
   ```
   Expected, and nothing else: destroy `module.ngohub_cognito[0]` (pool, client, domain, Lambdas, IAM),
   `aws_cognito_user_pool_client.vic_ngohub_client[0]`; the NGO Hub task and Amplify branch lose
   `COGNITO_*` / `REACT_APP_COGNITO_*` / `REACT_APP_USER_POOL_*`; the NGO Hub IAM user loses its
   `cognito-idp` statement. Apply.
4. Then O16 in onghub (Cognito code, `cognito_id` column, Amplify leftovers), released like any change.

## 6. Phase 5 — VIC's Cognito and the leftovers

Only after phase 1's check (VIC calls no Cognito) and the VIC team's go:

1. Export VIC's pool users as in phase 4, turn off its deletion protection, destroy `module.vic_cognito`
   and the `cognito-idp` statement of the VIC IAM user (`service_vic.tf`, around line 500).
2. `aws_acm_certificate.global` (`acm.tf:31-60`) and its validation records: used only by the two Cognito
   custom domains (`service_ngohub.tf:12`, `service_vic.tf:11`), so they go in the same change.
3. `ngohub_hmac_api_key` and `ngohub_hmac_secret_key` (passed only to the Cognito modules), and
   `assets/cognito/*`.
4. **Keep** `ngohub_hmac_encryption_key` (`service_ngohub.tf:286`): the NGO Hub API still uses it, and VIC
   gets it too.

## 7. Rollback

| From | How | Loses |
| --- | --- | --- |
| Phase 2, before step 9 | `ngohub_own_auth_enabled=false`, image back to `2.0.3`, apply; restore snapshot A; `auth:migrate -- --drop` | nothing (no emails left) |
| Phase 2, after step 9 | same as above; tell users the emailed links no longer work | users' logins since step 9 |
| Phase 3 | `vic_ngohub_login_enabled=false`, apply (button gone, API answers AUTH_020); unlink with the report if needed | admins who joined through NGO Hub keep their VIC accounts |
| Phase 4 / 5 | none: Cognito pools cannot come back; restore only data from the export | — |

## 8. Key rotation (after go-live)

| Key | How | Effect |
| --- | --- | --- |
| `OIDC_JWKS` (ID token signing) | put the new JWK first, keep the old one; remove the old one after the longest ID token lifetime plus a day | none (clients read the JWKS) |
| `OIDC_COOKIE_KEYS` | new key first, old ones after it; drop the old ones after the session lifetime | none |
| `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEY` / `JWT_KEY_ID` | new pair and kid, apply | access tokens (15 min) are refused, the SPA refreshes; refresh tokens are not signed, sessions survive |
| `AUTH_TOKEN_KEY` | new key, old one in `AUTH_TOKEN_KEY_PREVIOUS` (section 1), apply; rotate each OIDC client secret (panel → rotate) to re-seal it, then drop the previous key | emailed links and codes still pending are refused (never in the 30 days after phase 2) |
| VIC's `vic_ngohub_client_secret` | panel → rotate on NGO Hub, new value in the tfvars, apply VIC at once | VIC logins with NGO Hub fail between the two steps (minutes) |

Generate new values with `npm run oidc:generate-keys` and take only the key being rotated.
