# Serverless Ingestion Engine Architecture

Technical architecture specification for the Serverless Ingestion Engine, detailing system topology, component interactions, failure resilience, observability loops, and network design.

---

## 1. System Blueprint

The engine follows an asynchronous, event-driven decoupled architecture with codified observability:

![Serverless Ingestion Engine Architecture](../architecture.png)

---

## 2. Ingestion & Extractor Subsystem

The extractor runs as an ephemeral ECS Fargate container on Alpine Linux (51.7 MB compressed) with a read-only root filesystem:

- **Scheduled Trigger:** EventBridge invokes the task twice weekly in Production (Tuesdays and Fridays at 02:16 UTC).
- **Feed Registry:** Reads `feeds.json` directly from the S3 configuration bucket.
- **Concurrency:** Ingests feeds concurrently with per-host timeouts to isolate slow upstream hosts.

### Zero-NAT Gateway Egress Topology

To avoid AWS NAT Gateway fixed hourly charges while securing the network:

- **Public Subnet Launch:** The ECS task launches with `assign_public_ip = true`.
- **Egress-Only Security Group:** Ingress is completely empty (`ingress = []`). Unsolicited inbound traffic is dropped at the AWS hypervisor.
- **Stateful Return Traffic:** Security groups track outbound connections statefully, allowing responses for outbound HTTPS (443) and DNS (53) calls.

---

## 3. Messaging, Buffering & Resilience

### Asynchronous Fan-Out & Buffering

- **Decoupled Publishing:** Extractor publishes article events to SNS and exits immediately.
- **Backpressure Absorption:** SQS standard queue absorbs ingestion bursts and downstream rate limits.
- **Visibility Timeout:** Configured to 180s (6x the Lambda 30s timeout) to ensure in-flight batches have sufficient processing margin.

### Poison-Pill Quarantine (DLQ)

- **Retry Limit:** SQS tracks attempts per message (`ApproximateReceiveCount`).
- **Dead-Letter Routing:** After 3 consecutive failed deliveries, messages move to the DLQ.
- **Retention:** The DLQ retains quarantined messages for 14 days for inspection without blocking valid messages.

---

## 4. Deduplication & Idempotent Dispatch

### Check-First Deduplication Pattern

SQS provides at-least-once delivery. The Lambda dispatcher guarantees idempotent delivery via a check-first pattern:

1. **Deterministic Keying:** Each article URL is hashed with SHA-256 into a 64-character hexadecimal digest.
2. **Pre-Dispatch Evaluation:** Lambda reads DynamoDB (`GetItem`) before contacting Discord. If the hash exists, the article is logged as a duplicate and dismissed.
3. **Atomic Commit Post-Delivery:** The hash is committed to DynamoDB (`PutItem`) only after the Discord webhook returns an HTTP 2xx or 204 response.
4. **Failure Safety:** If Discord returns a 429 (rate limit) or 5xx (server error), the hash is not written, ensuring SQS will safely redeliver the message on the next attempt.

### Partial Batch Failure Handling

Lambda processes messages in batches of up to 10:

- The event source mapping has `ReportBatchItemFailures` enabled.
- If message 3 in a 10-message batch fails, Lambda reports only message 3's identifier in `batchItemFailures`.
- Messages 1, 2, and 4 through 10 are deleted from the queue, preventing duplicate notifications.

---

## 5. Infrastructure as Code & State Management

Infrastructure is managed with OpenTofu in modular components:

| Module | Core Resources | Responsibility |
| :--- | :--- | :--- |
| `infra/storage/` | DynamoDB Table, S3 Config Bucket | State storage and feed registry |
| `infra/messaging/` | SNS Topic, SQS Queue, SQS DLQ | Decoupled buffering and routing |
| `infra/extractor/` | ECS Cluster, Task Definition, Security Group, EventBridge | Ingestion compute and scheduling |
| `infra/dispatcher/` | Lambda Function, SQS Event Mapping, IAM Execution Role | Processing and delivery |
| `infra/observability/` | CloudWatch Metric Alarms, EventBridge Rule, SNS Alert Topic | SLI/SLO monitoring and alerting |

- **Partitioned Backend:** Uses a partial S3 backend with DynamoDB locking. State keys are partitioned per environment (`state/dev/terraform.tfstate` and `state/prod/terraform.tfstate`).
- **Dynamic Namespacing:** All resources use `local.namespaced_project_name` (`serverless-ingestion-engine-${var.environment}`) to prevent collisions.
- **Schedule Toggling:** Cron scheduling is enabled only in Production (`is_schedule_enabled = var.environment == "prod"`).

---

## 6. Cloud Verification & Test Harness Engineering

Integration testing runs against real AWS Dev infrastructure via `scripts/verify_dev_pipeline.py`, eliminating the fidelity gap of local emulation.

Pull requests labeled `dev-test` deploy to Dev and assert four system invariants:

1. **Container Exit Status:** Asserts that the Fargate extractor exits with return code 0.
2. **End-to-End Pipeline Completion:** Asserts that parsed articles traverse ECS -> SNS -> SQS -> Lambda and commit records into DynamoDB within the 120-second deadline.
3. **Zero Poison-Pill Quarantine:** Asserts that the Dead-Letter Queue contains zero failed messages.
4. **Single-Article Dev Safeguard:** The extractor respects `MAX_ARTICLES=1` in `dev` to prevent channel flooding while verifying the Discord visual layout.
