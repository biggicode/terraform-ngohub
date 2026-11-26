#!/usr/bin/env bash
# T0: read-only inventory of NGO Hub STAGING before own login + OIDC (plan section 8.3, questions 7, 8, 14).
# Every AWS call here only reads (describe/list/get). Run with staging credentials, then send the output back.
#
#   AWS_PROFILE=<staging profile> bash scripts/t0-inventory.sh > t0-staging.txt 2>&1
#
# The database part (6.2 inventory + the email pre-flight) needs psql through the bastion; it prints the
# queries to run if DATABASE_URL is not set. Nothing is written anywhere.
set -uo pipefail

ENV=staging   # deliberately fixed: this script is for staging only
NS="ngohub-${ENV}"
VIC_NS="vic-${ENV}"
REGION="${AWS_REGION:-eu-west-1}"
aws() { command aws --region "$REGION" --output json "$@"; }
section() { printf '\n===== %s =====\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
need aws
need jq

section "who am I (must be the staging account)"
aws sts get-caller-identity | jq '{Account, Arn}'

section "Q7/Q8: Cognito pools named ${NS} / ${VIC_NS}: Lambda triggers, clients"
for pool_name in "$NS" "$VIC_NS"; do
  id=$(aws cognito-idp list-user-pools --max-results 60 | jq -r --arg n "$pool_name" '.UserPools[] | select(.Name==$n) | .Id')
  if [ -z "$id" ]; then echo "$pool_name: no pool"; continue; fi
  echo "$pool_name ($id)"
  aws cognito-idp describe-user-pool --user-pool-id "$id" \
    | jq '.UserPool | {LambdaConfig, DeletionProtection, EstimatedNumberOfUsers, Domain, CustomDomain}'
  echo "clients (anything besides NGO Hub and VIC was created outside terraform):"
  aws cognito-idp list-user-pool-clients --user-pool-id "$id" --max-results 60 | jq -r '.UserPoolClients[] | "  \(.ClientName)  \(.ClientId)"'
done

section "proxy hops: ALB ${NS}-lb, and any CloudFront in front of the api/app/id hosts (TRUST_PROXY_HOPS)"
aws elbv2 describe-load-balancers --names "${NS}-lb" | jq '.LoadBalancers[] | {DNSName, Scheme, Type}'
aws cloudfront list-distributions \
  | jq '[.DistributionList.Items[]? | {Id, Aliases: .Aliases.Items, Origins: [.Origins.Items[].DomainName]}]'
echo "Route 53 records for the NGO Hub hosts:"
zone=$(aws route53 list-hosted-zones | jq -r '.HostedZones[0].Id')
aws route53 list-resource-record-sets --hosted-zone-id "$zone" \
  | jq -r '.ResourceRecordSets[] | select(.Name|test("^(app|api|auth|id|vic|api-vic)-staging\\.")) | "  \(.Name) \(.Type) \(.AliasTarget.DNSName // (.ResourceRecords // [] | map(.Value) | join(",")))"'

section "Amplify: the NGO Hub and VIC staging apps, their domains and branches"
aws amplify list-apps | jq -r '.apps[] | select(.name|test("staging")) | "\(.appId) \(.name) \(.defaultDomain)"' | while read -r app name domain; do
  echo "$name ($app) $domain"
  aws amplify list-domain-associations --app-id "$app" | jq -r '.domainAssociations[] | "  domain \(.domainName): \([.subDomains[].subDomainSetting | "\(.prefix)->\(.branchName)"] | join(", "))"'
  aws amplify list-branches --app-id "$app" | jq -r '.branches[] | "  branch \(.branchName) basicAuth=\(.enableBasicAuth)"'
done

section "RDS ${NS}: engine version (needs Postgres >= 13)"
aws rds describe-db-instances --db-instance-identifier "$NS" \
  | jq '.DBInstances[] | {Engine, EngineVersion, DBInstanceClass, AllocatedStorage}'

section "Q14: Redis ${NS}: node type (memory) and the current used memory (CloudWatch, last hour)"
aws elasticache describe-cache-clusters --cache-cluster-id "$NS" \
  | jq '.CacheClusters[] | {CacheNodeType, EngineVersion, NumCacheNodes}'
now=$(date -u +%Y-%m-%dT%H:%M:%SZ); hour_ago=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
aws cloudwatch get-metric-statistics --namespace AWS/ElastiCache --metric-name DatabaseMemoryUsagePercentage \
  --dimensions Name=CacheClusterId,Value="$NS" --start-time "$hour_ago" --end-time "$now" --period 3600 --statistics Maximum \
  | jq '.Datapoints'

section "Q14: SES sending quota and status"
aws sesv2 get-account | jq '{SendQuota, ProductionAccessEnabled, SendingEnabled}'

section "ECR: the onghub backend tags (the image the own-auth branch builds lands here)"
aws ecr describe-images --repository-name onghub-backend --max-items 15 2>/dev/null \
  | jq -r '[.imageDetails[] | {tags: .imageTags, pushed: .imagePushedAt}] | sort_by(.pushed) | reverse | .[] | "  \(.pushed) \(.tags)"' \
  || echo "  (repository name differs: aws ecr describe-repositories | jq -r '.repositories[].repositoryName')"

section "ECS: the NGO Hub service and its current image"
aws ecs list-services --cluster "$NS" | jq -r '.serviceArns[]' | grep -i ngohub | while read -r svc; do
  td=$(aws ecs describe-services --cluster "$NS" --services "$svc" | jq -r '.services[0].taskDefinition')
  aws ecs describe-task-definition --task-definition "$td" | jq -r '.taskDefinition.containerDefinitions[] | "  \(.name) \(.image)"'
done

section "database (6.2 inventory + email pre-flight), read-only"
SQL=$(cat <<'SQL'
-- other apps with a Cognito client (TEO?), plan 6.2
SELECT id, name, type, status, cognito_client_id, login_link FROM application WHERE cognito_client_id IS NOT NULL;
-- HMAC key holders that disappear with hasAccess, plan 6.2
SELECT issued_by, created_on FROM public_keys;
-- users by role/status, for the transition emails
SELECT role, status, count(*) FROM "user" WHERE deleted_on IS NULL GROUP BY 1, 2 ORDER BY 1, 2;
-- case duplicates: auth:migrate refuses them (full checks: onghub/backend/scripts/auth-preflight.sql)
SELECT lower(email), count(*) FROM "user" WHERE deleted_on IS NULL GROUP BY 1 HAVING count(*) > 1;
SELECT version();
SQL
)
if [ -n "${DATABASE_URL:-}" ]; then
  command -v psql >/dev/null && psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c 'SET default_transaction_read_only = on;' -c "$SQL" \
    || echo "psql not found"
else
  echo "DATABASE_URL not set: run these through the bastion (read-only):"
  echo "$SQL"
fi
