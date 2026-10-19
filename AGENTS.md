# AI Coding Agent Protocols & Operational Guidelines

This document provides autonomous coding agents, paired assistants, and software engineers with system context, architectural conventions, operational protocols, and testing guidelines for the Serverless Ingestion Engine repository.

---

## 1. System Overview & Architecture

The Serverless Ingestion Engine is an event-driven, multi-environment distributed ingestion and dispatch engine built with Python, OpenTofu, Amazon ECS Fargate, Amazon SNS, Amazon SQS, AWS Lambda, Amazon DynamoDB, and Discord Webhooks.

### Key Architectural Invariants

- **Multi-Environment Isolation (`dev` vs. `prod`):**
  - Dev and Prod run isolated AWS stacks namespaced by `${var.project_name}-${var.environment}`.
  - S3 backend state is partitioned into dedicated keys: `state/dev/terraform.tfstate` and `state/prod/terraform.tfstate`.
  - Dev runs strictly on-demand (EventBridge cron schedule disabled; `is_schedule_enabled = false`).
  - Prod runs scheduled cron ingestion twice weekly on Tuesdays and Fridays at 02:16 UTC (`cron(16 2 ? * TUE,FRI *)`).
- **Cost-Optimized Zero-NAT Egress:**
  - ECS Fargate extractor containers run in public subnets with `assign_public_ip = true` and an egress-only security group (`ingress = []`).
  - Outbound internet access operates via AWS Internet Gateway without incurring fixed hourly NAT Gateway fees.
- **Decoupled Buffer & Backpressure:**
  - Extractor publishes feed items to an SNS Topic, which fans out to an SQS standard queue.
  - Downstream rate limits (e.g., Discord API) are absorbed by SQS visibility timeouts (180s) and retry policies before dead-letter quarantine (DLQ) after 3 attempts.
- **Idempotency via Check-First Deduplication:**
  - Lambda computes a SHA-256 hash of the canonical article URL.
  - Checks DynamoDB before dispatching (`GetItem`).
  - Posts rich embed to Discord webhook.
  - Commits hash to DynamoDB (`PutItem`) only on HTTP 2xx/204 response.
- **Dev Article Capping:**
  - When running in `dev`, the extractor caps ingestion to 1 article (`MAX_ARTICLES=1`) to prevent channel spam while verifying webhook rendering.

---

## 2. Engineering Workflows & Make Targets

Always use `uv` and the provided `Makefile` targets. Do not install global Python packages.

| Target | Command | Purpose |
| :--- | :--- | :--- |
| `make lint` | `uv run ruff check . && uv run ruff format --check .` | Python linting and format inspection |
| `make format` | `uv run ruff format .` | Auto-format Python code |
| `make test` | `uv run pytest` | Run all unit tests with pytest |
| `make md-lint` | `npx markdownlint-cli "**/*.md"` | Markdown linting across repository |
| `make tofu-fmt` | `tofu fmt -recursive infra/` | Format OpenTofu configurations |
| `make tofu-validate` | `cd infra && tofu init -backend=false && tofu validate` | Validate OpenTofu root and modules |

---

## 3. Test Harness Engineering

The project implements automated cloud test harness engineering to verify end-to-end distributed system invariants in AWS Dev before promoting code to Production.

### Running the Cloud Test Harness

```bash
uv run python scripts/verify_dev_pipeline.py --environment dev --region ca-central-1
```

### Invariants Asserted by the Harness

1. **ECS Fargate Execution:** Triggers an ephemeral task run on the namespaced cluster and polls until exit. Asserts `task["containers"][0]["exitCode"] == 0`.
2. **DynamoDB Record Insertion:** Scans/queries the namespaced DynamoDB table within a 120-second timeout window to ensure at least one new article hash was written.
3. **Zero Dead-Letter Queue Depth:** Queries the SQS DLQ attributes and asserts `ApproximateNumberOfMessagesVisible == 0` and `ApproximateNumberOfMessagesNotVisible == 0`.
4. **Discord Webhook Notification:** Asserts that the isolated Dev channel receives the single rendered embed without error.

---

## 4. Ad-Hoc & Multi-Environment Operations

To trigger ingestion manually or validate network boundaries:

```bash
# Validate AWS Dev VPC, subnets, and ECS cluster without launching compute
./scripts/trigger_ingestion.sh --env dev --dry-run

# Run ephemeral Dev task and stream logs
./scripts/trigger_ingestion.sh --env dev

# Validate AWS Prod infrastructure
./scripts/trigger_ingestion.sh --env prod --dry-run
```

---

## 5. OpenTofu Initialization Protocols

The project uses OpenTofu partial backend configurations (`backend "s3" {}`).

**CRITICAL:** Never execute plain `tofu init` in CI or automation. It will block on interactive prompts.
Always specify non-interactive flags and the appropriate backend configuration:

```bash
# For Dev
tofu init -input=false -backend-config=environments/backend-dev.hcl

# For Prod
tofu init -input=false -backend-config=environments/backend-prod.hcl

# For Static Validation (no backend required)
tofu init -backend=false
tofu validate
```

---

## 6. CI/CD Triggers & Deployment Safety

- **PR Validation:**
  - `quality-and-tests`: Runs Python linting, unit tests, and Markdown linting.
  - `infra-security`: Runs `tofu fmt`, `tofu validate`, `tflint`, and `trivy` IaC security scans.
  - `container-security`: Builds Docker image and scans with `trivy`.
- **On-Demand Dev Cloud Verification (`dev-test`):**
  - Requires the `dev-test` label on the Pull Request.
  - Deploys the branch image to ECR `serverless-ingestion-engine-dev`.
  - Runs `tofu apply` against the Dev environment.
  - Executes `scripts/verify_dev_pipeline.py`.
- **Production Deployment (`cd.yaml`):**
  - Triggers only on push/merge to `main`.
  - Builds and pushes image to ECR `serverless-ingestion-engine`.
  - Runs `tofu apply` targeting Prod using `environments/backend-prod.hcl`.
- **Drift Detection (`drift-detection.yaml`):**
  - Executes weekly on Fridays at 04:00 UTC with `tofu plan -detailed-exitcode` against Prod state.

---

## 7. Agent Code Modification Guidelines

1. **Be Surgical:** Limit edits strictly to the requested lines or components. Avoid gratuitous refactoring.
2. **Preserve Comments & Docstrings:** Do not remove existing comments or docstrings unless directly superseded.
3. **Relative Links:** Use relative paths (e.g. `docs/architecture.md`) in documentation and responses. Never use absolute paths or `file://` schemes.
4. **Verify All Edits:** Always run `make lint`, `make test`, `make md-lint`, and `make tofu-validate` after modifying code or documentation.
