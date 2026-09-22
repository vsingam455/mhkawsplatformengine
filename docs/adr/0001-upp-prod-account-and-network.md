# UPP production environment on AWS (greenfield prod account)

## Context

UPP (`MHK-TECH-INC/UPP`, FastAPI + React, privacy-compliance website scanner) is the first product
to go to production. Today it runs in the shared account `700294801275` in the **default VPC** with
every subnet public: one Fargate task with a **public IP**, the **default security group open to the
world on 80/8000/8080**, CloudFront reaching it over **plain HTTP through `<ip>.nip.io`**, **no task
role** (static IAM user keys and 30 other secrets are plaintext in the task definition, readable by
anyone with `ecs:DescribeTaskDefinition`), no WAF on the prod distribution, CloudTrail / GuardDuty /
Security Hub / Config all off, and nine IAM users with ~11-month-old access keys. Staging shares the
same cluster, VPC and security group. SOS-ESD and the UPP git scanner use the identical pattern, so
the design must be reusable for them.

Decisions taken with the user (2026-09-21/22):

- **New dedicated production AWS account** under an AWS Organization (account boundary is the main
  guardrail).
- **Phase 1 = "secure first, split later"**: one API task, minimal code changes; the network is built
  ready for a later API/worker split. The app cannot run as 2+ replicas yet (in-memory scan registry,
  local `output/`, in-process APScheduler, SSE queue).
- **Keep Supabase for v1** (dedicated prod project, keys in Secrets Manager) — the one documented
  exception to "AWS managed identity everywhere". RDS + Cognito revisited later.
- **Domain: subdomain of `mhktechinc.com`**; company DNS is on Wix, so delegate only
  `upp.mhktechinc.com` to Route 53 in the prod account.
- **CloudFormation**, following the existing `infra/` convention (foundation stacks deployed by a
  platform admin with the AWS CLI, app stacks by the pipeline; stack names `mhk-<env>-<service>`,
  tags `environment/service/commit`).
- Not overkill: no Network Firewall, no Transit Gateway, no multi-region, no Control Tower.

## Reasoning (for the team review)

**Why a separate production account.** Today prod, staging, every developer's IAM user and the SDLC
agents share one account and one default VPC. An account boundary is the only control that stops a
staging mistake, a leaked developer key or an over-permissive agent role from touching production,
and it costs nothing. Retrofitting it later means re-creating every resource anyway, so it is done
first. The org also gives us one place to enforce rules (SCPs) that nobody in the account can undo.

**Why "secure first, split later" for UPP.** The scan engine keeps its state in the API process
(in-memory registry, local `output/`, in-process scheduler, SSE queues). Running two copies today
would double-fire scheduled scans and break pause/stop/download for half the requests. Making it
horizontally scalable is a multi-week refactor of Kishore's code. The security problems (public IP,
plaintext secrets, no audit trail, no SSRF guard) are the urgent part and need only small code
changes, so Phase 1 fixes those and builds the network so the worker split drops in without
re-doing anything. The cost of Phase 1's limitation: a deploy interrupts running scans for ~2 min,
and one AZ failure is an outage until ECS restarts the task in the other AZ.

**Why keep Supabase for now.** Every database call goes through the Supabase REST client and every
login through Supabase Auth, with row-level security already written in `supabase_setup.sql`.
Moving to RDS + Cognito means rewriting the data layer, the auth flows, pgvector and migrating
users, which would push the launch out by weeks and touch the riskiest code. It is the one place
that cannot use AWS managed identity; the service key lives in Secrets Manager and the exception is
recorded in the ADR so it is revisited deliberately, not forgotten.

**Why ALB + CloudFront + WAF instead of the current CloudFront → `nip.io` → task IP.** The current
path is unencrypted between CloudFront and the task, depends on a third-party DNS service, and
leaves port 8000 open to the whole internet, so anyone who finds the IP bypasses CloudFront and any
WAF. With the task in a private subnet, the only way in is CloudFront → ALB over TLS, WAF rules and
rate limits actually apply (the app has no rate limiting of its own), and the ALB health check lets
ECS replace a broken task automatically.

**Why NAT + broad egress rather than an allowlist.** UPP's job is to crawl arbitrary customer
websites, so outbound 80/443 to the internet has to stay open. The compensating control is the SSRF
guard in the application (reject private, loopback and link-local targets, re-check after
redirects) plus VPC endpoints so AWS API traffic never leaves the VPC. AWS Network Firewall would add
~$300/month for little extra here and is deliberately left out.

**Why managed identity (task role + OIDC) is non-negotiable.** The task definition currently
carries an IAM user's access key in plaintext along with the Supabase service key, OpenAI and Chroma
keys and the admin password. A task role gives the container short-lived credentials automatically;
GitHub OIDC does the same for the pipeline. After cut-over the nine long-lived IAM user keys in the
old account are rotated or deleted (follow-up issue #3).

**Why SSRF is a launch blocker, not a nice-to-have.** Once the task has a role, a scan pointed at
`http://169.254.170.2/v2/credentials/...` returns that role's credentials to the user — and the
crawler would screenshot the response, store it in S3 and stream it to the browser. There is no
guard anywhere in the code today. This becomes *more* dangerous, not less, when we do the right
thing with identity, so the two changes ship together.

**Why CloudFormation and not console clicks.** Same tool as the existing `infra/` work, reviewable
in a PR, repeatable for SOS-ESD, HR Portal and the git scanner (which use the same public-IP
pattern), and drift-detectable. The console is still where you watch it happen and where the
handful of one-time steps (create org/account, root MFA, Bedrock model access, Wix NS record) are
done.

**What is deliberately left out** (and why): Network Firewall, Transit Gateway, multi-region,
Control Tower / full landing zone, RDS/ElastiCache, blue-green CodeDeploy. Each adds cost or
operational weight without addressing a problem we have at this scale. The network reserves subnets
and the design reserves names so each can be added without rework.

**What is asked of the team.**
- Kishore: the eight UPP code changes (credential chain, `/healthz`, SSRF guard, CORS, non-root
  Dockerfile, OIDC deploy workflow, S3/CloudFront frontend deploy, scan ownership checks).
- Rajesh / Vamshi: approve the new account and the $275/month baseline; own the org root
  credentials.
- Whoever administers Wix DNS and Supabase: one NS record; one new Supabase project.

## Target architecture (Phase 1)

```
Users ──HTTPS──▶ CloudFront (WAF: AWS managed rules + rate limit)
                   ├─ app.upp.mhktechinc.com  ─▶ S3 static site (OAC)          [React build]
                   └─ api.upp.mhktechinc.com  ─▶ ALB (HTTPS, ACM, idle 3600s for SSE)
                                                   └─ ECS Fargate  upp-api  (private subnet, no public IP)
                                                        4 vCPU / 8 GB, 1 task, circuit breaker
                                                        task role: S3 (bucket-scoped), Bedrock (model ARNs),
                                                                   SES (identity-scoped), KMS decrypt
                                                        secrets: Secrets Manager (Supabase, OpenAI, Chroma, admin token)
                                                        egress ─▶ NAT GW ─▶ internet (crawler needs 80/443 to any site)
                                                        egress ─▶ VPC endpoints: S3 (gateway), ECR api/dkr, logs,
                                                                  secretsmanager, bedrock-runtime, ses
Outside AWS: Supabase (Postgres+Auth), Chroma Cloud, OpenAI
```

VPC `10.20.0.0/16`, 2 AZs: public `/24` ×2 (ALB, NAT), private-app `/24` ×2 (ECS), private-data
`/24` ×2 reserved for a later RDS/ElastiCache. One NAT gateway to start (documented single-AZ
egress risk; add the second when the worker service arrives). Security groups: `alb-sg` (443 from
CloudFront prefix list only), `api-sg` (8000 from `alb-sg` only; egress 443/80 any + VPC endpoints),
`endpoints-sg` (443 from `api-sg`). No default-SG usage. VPC flow logs to CloudWatch (30 d).

## Repository layout (in `~/mhkawsplatformengine/infra/`, branch off `infra/github-oidc`)

Foundation (admin-deployed, in this order):

1. `org/organization.md` — runbook, not a template: create Organization (all features), OU `Workloads`,
   account `mhk-prod` (email alias `aws-prod@mhktechinc.com`), enable CloudTrail org trail, GuardDuty
   and Security Hub delegated to the management account. Console-only steps are listed explicitly.
2. `org/scp-prod.json` — SCPs on the `Workloads` OU: deny leaving org, deny disabling
   CloudTrail/GuardDuty/Config, deny `iam:CreateUser`/`iam:CreateAccessKey`, restrict regions to
   `us-east-1` (+ `us-east-1` global services), deny making S3 public.
3. `prod/00-account-baseline.yml` (`mhk-prod-baseline`): CloudTrail (if not org trail), Config
   recorder + a handful of managed rules (encrypted volumes, S3 public, SG open ports, root MFA),
   IAM Access Analyzer, account-level S3 Block Public Access, EBS/ default encryption, ECR scan-on-push
   setting, AWS Budget (alarm at $300/mo), SNS `ops-alerts` topic with the user's email.
4. `prod/10-network.yml` (`mhk-prod-network`): VPC, subnets, IGW, NAT, route tables, endpoints,
   flow logs, the three security groups. Exports every ID.
5. `prod/20-edge.yml` (`mhk-prod-edge`): Route 53 hosted zone `upp.mhktechinc.com` (outputs the NS
   set for the Wix delegation), ACM certs (us-east-1 covers both CloudFront and the ALB), WAFv2
   web ACL (CloudFront scope) with `AWSManagedRulesCommonRuleSet`, `KnownBadInputs`,
   `AmazonIpReputationList`, and a rate rule of 1000 req / 5 min per IP.
6. `prod/30-github-oidc.yml` (`mhk-prod-github-oidc`): copy of the existing `github-oidc.yml` reduced
   to prod: OIDC provider, `gha-deploy-prod` (trust `repo:MHK-TECH-INC/UPP:environment:prod`),
   `mhk-cfn-exec` **with the permissions boundary the README already demands** (`mhk-prod-boundary`
   managed policy: no IAM user/key creation, no org/CloudTrail/Config changes, actions limited to
   the services this platform uses), ECR push allowed for the deploy role.
7. `prod/40-shared-services.yml` (`mhk-prod-shared`): KMS CMK (`alias/mhk-prod`), S3 buckets
   `mhk-prod-upp-artifacts`, `mhk-prod-upp-web`, `mhk-prod-logs` (SSE-KMS, versioning, TLS-only,
   lifecycle → IA 90 d), ECR repo `upp/api` (scan on push, keep last 10 images), ECS cluster
   `mhk-prod` with Container Insights, CloudWatch log group `/mhk/prod/upp-api` (retention 30 d, KMS),
   SES domain identity for `upp.mhktechinc.com` with DKIM records into the zone.
8. Secrets are created **by hand** with `aws secretsmanager create-secret` (values never in git or
   scripts), names `mhk/prod/upp/supabase`, `.../openai`, `.../chroma`, `.../admin`.

Application (pipeline-deployed from the UPP repo, one stack `mhk-prod-upp-api`):

- `UPP/infra/upp-api.yml` — single `Environment` parameter per the existing contract (`prod` only
  for now; the shared account keeps running dev/staging until they are migrated): task definition
  (image tag param, `secrets` block from Secrets Manager ARNs, non-root user, `healthCheck` on
  `/healthz`), execution role, task role (`s3:Get/Put/List` on the artifacts bucket + prefix,
  `bedrock:InvokeModel*` on Qwen3-235B, Nova Micro/Lite, Titan Embed v2 and their `us.` inference
  profiles, `ses:SendEmail` conditioned on the verified identity, `kms:Decrypt`), ALB + target group
  (health `/healthz`, deregistration delay 300 s), listener 443 → target, CloudFront distribution for
  the API (origin = ALB DNS over HTTPS, all methods, no caching, forwards `Authorization`), and the
  ECS service (desired 1, `maximumPercent` 200 / `minimumHealthyPercent` 0 so a deploy replaces the
  single task, circuit breaker + rollback, `assignPublicIp: DISABLED`, private subnets).
- Alarms in the same stack: ALB 5xx > 5 % (5 min), target unhealthy, task CPU/memory > 85 %, ECS
  running count < 1, Bedrock cost anomaly via the budget. All → `ops-alerts`.

## Code changes required in `MHK-TECH-INC/UPP` (small, Phase 1 only)

Reuse the existing SDLC agents to do these as stories with the `agent:dev` label once the repo is
onboarded; otherwise hand them to Kishore. Ordered by necessity:

1. **Default credential chain** — remove `aws_access_key_id=`/`aws_secret_access_key=` from
   `backend/s3.py:52`, `backend/bedrock_client.py:107`, `backend/ses_email.py:40` (task role
   takes over). Delete `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BEARER_TOKEN_BEDROCK` from
   `deploy.yml` `ENV_KEYS` and `.env.example`.
2. **Unauthenticated `GET /healthz`** next to the authenticated `/health` at `api.py:1492`; ALB and
   smoke test use it.
3. **SSRF guard** (required — a scan of `http://169.254.170.2/v2/credentials/...` would hand the
   task role to the user): validator on `ScanRequest.url` (`api.py:1263`) and a shared
   `is_public_target(url)` used by `crawler.py`, `privacy_extractor.py`, `compliance_session.py`,
   `test_agent/browser.py`: http/https only, resolve DNS, reject loopback, RFC1918, CGNAT, link-local
   (`169.254.0.0/16`, `fe80::/10`), `fc00::/7`, and re-check after redirects. Belt and braces:
   `api-sg` egress explicitly denies nothing (SGs can't), so also block `169.254.169.254` and
   `169.254.170.2` at the app level and route Chromium through the same guard via a request
   interceptor.
4. **`CORS_ORIGINS`** set to `https://app.upp.mhktechinc.com`, added to `ENV_KEYS`.
5. **Dockerfile**: `USER app` (non-root), pre-create `~/.mitmproxy`, pin base image digest.
6. **`deploy.yml`**: OIDC `role-to-assume: arn:aws:iam::<prod>:role/gha-deploy-prod`, push image,
   then `aws cloudformation deploy` of `infra/upp-api.yml` with `ImageTag=<sha>` (replaces the
   describe/register/update-service/`nip.io` dance). Keep `secrets` block; stop deleting it.
   Trigger: `workflow_dispatch` into GitHub environment `prod` gated on `PROMOTERS`, matching the
   platform's promotion rule.
7. **Frontend**: build in CI with `VITE_API_BASE_URL=https://api.upp.mhktechinc.com` and the prod
   Supabase anon key, `aws s3 sync` to `mhk-prod-upp-web`, CloudFront invalidation. Amplify app
   retired for prod. Remove the hardcoded Supabase anon key/URL from `docker-compose.yml`.
8. Ownership checks on `/api/status`, `/api/results`, `/api/download`, `/api/stream`,
   pause/resume/stop/cancel (any authenticated user can read another org's scan today). Not an
   infra item but a launch blocker; raise as a P1 story.

Deferred to Phase 2 (tracked, not built now): SQS + `upp-worker` service, shared state
(DynamoDB/Redis) for scan registry and SSE fan-out, EventBridge Scheduler replacing APScheduler,
incremental S3 artifact upload, log/PII scrubbing of `proxy_*.jsonl`, retiring the derived
`API_TOKEN`, second NAT gateway, RDS + Cognito evaluation.

## Execution order

1. **Console (user):** create Organization from `700294801275`, create `mhk-prod` account, enable
   MFA on its root, create IAM Identity Center (or one `admin` role assumed from the management
   account — no IAM users). Delegated to the user; I prepare the runbook and can verify each step.
2. `aws login` into the prod account (profile `mhk-prod`); deploy stacks 3 → 7 with
   `aws cloudformation deploy --profile mhk-prod`. Each deploy shown to the user for approval.
3. Wix: add NS record for `upp` → Route 53 name servers (user does it; I give exact values).
   ACM validation completes after delegation.
4. Enable Bedrock model access in the prod account for the four model families (console toggle,
   user).
5. Create the Supabase prod project, run `backend/supabase_setup.sql`, create the four secrets.
6. Verify SES production access in the new account (new accounts start sandboxed — request
   production access early, it takes up to 24 h).
7. Land the UPP code changes (PR reviewed by Kishore), onboard the repo to `prod` environment with
   `scripts/onboard-repo.sh`, set the GitHub variables (`AWS_ACCOUNT_ID`, region, bucket, domains).
8. First deploy via `workflow_dispatch`; cut over DNS for `app.` and `api.`; keep the old
   `nip.io` setup running one week, then delete it and **rotate/delete the IAM user keys** the old
   pipeline used (ties to follow-up issue #3).
9. Write `infra/README.md` prod section + an ADR (`docs/adr/0001-prod-account-and-network.md`) and
   add the board card "Migrate SOS-ESD and UPP git scanner to the prod pattern".

## Verification

- `aws sts get-caller-identity --profile mhk-prod` shows the new account; `aws iam list-users` is
  empty; `aws cloudtrail get-trail-status` logging; GuardDuty detector enabled; Security Hub
  foundational standard score visible.
- `aws ecs describe-tasks` shows no public IP and a `taskRoleArn`; `describe-task-definition` has
  zero `environment` entries containing keys and a populated `secrets` block.
- `curl https://api.upp.mhktechinc.com/healthz` → 200; `curl http://<alb-dns>/` → refused (443 only,
  CloudFront prefix list only); `nmap` from outside on 8000 → filtered.
- Scan of `http://169.254.170.2/` and `http://10.20.0.1/` → 400 rejected; scan of a real public site
  completes, report lands in `mhk-prod-upp-artifacts`, SES email delivered, SSE stream stays open
  > 10 min without ALB reset.
- WAF: 1200 requests in 5 min from one IP → 429/403 from CloudFront.
- Deploy a no-op image change via the workflow: circuit breaker keeps the old task if `/healthz`
  fails; successful deploy replaces it; CloudWatch alarms have data.
- `cfn-lint` + `cfn_nag`/`checkov` clean on every template; `aws cloudformation detect-stack-drift`
  clean after go-live.

## Estimated running cost (Phase 1, us-east-1)

NAT ~$35 + Fargate 4 vCPU/8 GB ~$145 + ALB ~$20 + VPC endpoints (5 interface) ~$36 + CloudFront/WAF
~$15 + GuardDuty/Config/CloudTrail ~$15 + S3/logs/KMS ~$10 ≈ **$275/month** before Bedrock/OpenAI
usage. Dropping the interface endpoints (NAT carries that traffic instead) saves ~$30 if needed.
