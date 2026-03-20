# Dash0 ECS Observability Demo

Instrument an ECS Fargate application with OpenTelemetry and send traces, logs, and metrics to [Dash0](https://dash0.com) — using an OTel Collector sidecar for production-grade observability.

> **Zero to traces in 10 minutes.** Run the interactive tutorial and see distributed traces, correlated logs, and RED metrics in Dash0 — all from an ECS Fargate task with no code changes to the demo app.

## Quick Start

```bash
./scripts/tutorial.sh
```

The tutorial handles everything interactively: prerequisite checks, AWS login, Dash0 token setup, deployment, traffic generation, and teardown.

For a minimal step-by-step without the interactive wrapper, see [QUICKSTART.md](QUICKSTART.md).

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker** | Running locally (used to build the app image) |
| **AWS CLI** | `brew install awscli` or [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| **AWS credentials** | The tutorial helps with login if needed |
| **Dash0 auth token** | `auth_xxxx` — from [app.dash0.com](https://app.dash0.com) → Settings → Auth Tokens |

## What You'll Learn

1. **Sidecar collector vs. direct export** — two patterns for shipping telemetry from ECS, when to use each, and how to graduate from one to the other
2. **Auto-instrumentation** — how the OTel SDK traces HTTP, DB, and queue operations with zero code changes
3. **Manual spans** — adding business context (order IDs, payment amounts) as custom spans and attributes
4. **AWS SDK tracing** — (optional) DynamoDB and S3 calls produce auto-instrumented AWS SDK spans for deeper trace waterfalls
5. **Collector pipeline** — how `resourcedetection`, batching, filtering, and memory limiting work together
6. **ECS metadata enrichment** — automatic stamping of cluster ARN, task ARN, AZ, container ID via the Task Metadata Endpoint
7. **Trace-log correlation** — every log line linked to its parent trace in Dash0
8. **Dash0 exploration** — RED metrics, trace waterfalls, error analysis, and correlated logs

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│  ECS Fargate Task                                         │
│                                                           │
│  ┌─────────────────────────┐  ┌────────────────────────┐  │
│  │  app (Node.js)          │  │  otel-collector        │  │
│  │                         │  │                        │  │
│  │  Auto-instrumented      │  │  resourcedetection     │  │
│  │  + manual spans         │→ │  memory_limiter        │──── OTLP/gRPC ──→ Dash0
│  │  + correlated logs      │  │  filter (health)       │  │
│  │                         │  │  batch                 │  │
│  │  port 3000              │  │  port 4317 (gRPC)      │  │
│  └─────────────────────────┘  └────────────────────────┘  │
│          ↑                            ↑                   │
│    ALB :80 → :3000             localhost:4317              │
└───────────────────────────────────────────────────────────┘
```

The app exports OTLP to `localhost:4317` — it has no knowledge of Dash0. The collector sidecar handles authentication, ECS metadata enrichment (task ARN, cluster, AZ), batching, health-check filtering, and export.

### Optional: AWS Service Integrations

When `ENABLE_AWS_SERVICES=true`, the app also calls DynamoDB and S3 — producing deeper, more realistic traces with auto-instrumented AWS SDK spans:

```
/api/order trace (with AWS enabled):
  validate-order
  charge-payment
  dynamodb-put-order    ← AWS SDK auto-instrumented (HTTP spans underneath)
  dynamodb-get-order    ← read-back verification
  s3-put-receipt        ← JSON receipt to S3

/api/inventory trace:
  dynamodb-scan-orders  ← scan up to 20 orders
  s3-put-report         ← inventory report to S3
```

Setup creates a DynamoDB table (PAY_PER_REQUEST — only pay for what you use) and an S3 bucket. Teardown cleans up both.

For a deep dive on architecture decisions, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Project Structure

```
ecs-demo/
├── .env                                # Your config (tokens, region, AWS services toggle)
├── app/
│   ├── app.js                          # Node.js demo service (auto + manual instrumentation)
│   ├── package.json
│   └── Dockerfile
├── collector/
│   └── otel-collector-config.yaml      # Reference config (injected via env var at runtime)
├── scripts/
│   ├── tutorial.sh                     # ← Start here. Interactive guided walkthrough
│   ├── setup.sh                        # Creates all AWS infra + deploys to ECS Fargate
│   ├── teardown.sh                     # Deletes everything cleanly
│   └── fire.sh                         # Traffic generator for demo scenarios
├── QUICKSTART.md                       # Minimal step-by-step (no interactive wrapper)
├── ARCHITECTURE.md                     # Architecture deep dive + decision framework
└── README.md                           # ← You are here
```

## App Endpoints

| Endpoint | What It Demonstrates |
|---|---|
| `/api/order` | Order flow: validate → payment → DynamoDB write/read → S3 receipt (when AWS enabled) |
| `/api/inventory` | DynamoDB scan + S3 report (AWS-only — returns graceful no-op when disabled) |
| `/api/slow` | 1.5–3s latency spike — shows up in P95/P99 in Dash0 |
| `/api/error` | Error span with recorded exception + ERROR-level log |
| `/api/burst` | 10 parallel child spans — waterfall visualization demo |
| `/api/fetch` | Outbound HTTP call to httpbin.org with distributed trace propagation |
| `/api/load` | Fires a random endpoint — use in a loop for sustained load |

## Collector Pipeline

```
Receivers         Processors                              Exporters
─────────         ──────────                              ─────────
  otlp    ──→  memory_limiter  (back-pressure, always first)
              → resourcedetection  (ECS task ARN, cluster, AZ, container ID)
              → filter/health  (drops /health spans)
              → batch  (512 spans / 5s window, always last)
                                                    ──→  otlp/dash0 (Dash0)
                                                    ──→  debug (stdout → CloudWatch)
```

The collector config is in [collector/otel-collector-config.yaml](collector/otel-collector-config.yaml). At runtime it's injected as an environment variable in the ECS task definition — no custom collector image needed.

## Manual Mode

If you prefer to run scripts directly instead of the interactive tutorial:

```bash
# 1. Create a .env file (scripts load it automatically)
cat > .env <<'EOF'
DASH0_AUTH_TOKEN=auth_xxxxxxxxxxxxxxxxxxxx
AWS_REGION=eu-west-1
DASH0_ENDPOINT=ingress.eu-west-1.aws.dash0.com:4317
AWS_PROFILE=your-profile
ENABLE_AWS_SERVICES=true
EOF

# 2. Deploy (~5 min)
./scripts/setup.sh

# 3. Generate telemetry
curl http://<ALB_DNS>/api/order      # order flow (+ DynamoDB/S3 if enabled)
curl http://<ALB_DNS>/api/inventory  # scan orders + S3 report (AWS-only)
curl http://<ALB_DNS>/api/slow       # latency spike
curl http://<ALB_DNS>/api/error      # error span
curl http://<ALB_DNS>/api/burst      # 10 parallel child spans
curl http://<ALB_DNS>/api/fetch      # outbound HTTP
./scripts/fire.sh http://<ALB_DNS>   # 30 mixed requests

# 4. Explore in Dash0
#    app.dash0.com → Services → dash0-demo

# 5. Teardown (cleans up DynamoDB/S3 too if created)
./scripts/teardown.sh
```

All scripts (`setup.sh`, `teardown.sh`, `fire.sh`) auto-load `.env` from the project root. Command-line env vars override `.env` values.

### `.env` reference

| Variable | Required | Description |
|---|---|---|
| `DASH0_AUTH_TOKEN` | Yes | Dash0 auth token (`auth_xxxx`) |
| `AWS_REGION` | Yes | AWS region (e.g., `eu-west-1`, `us-west-2`) |
| `DASH0_ENDPOINT` | Yes | Dash0 OTLP endpoint (see table below) |
| `AWS_PROFILE` | No | AWS CLI profile to use |
| `ENABLE_AWS_SERVICES` | No | `true` to create DynamoDB + S3 for deeper traces (default: `false`) |

### Dash0 Endpoints by Region

| Region | Endpoint |
|---|---|
| EU West (Ireland) | `ingress.eu-west-1.aws.dash0.com:4317` |
| US West (Oregon) | `ingress.us-west-2.aws.dash0.com:4317` |
| US East (Ohio) | `ingress.us-east-2.aws.dash0.com:4317` |

## Sidecar vs. Direct Export

This demo uses the **collector sidecar** pattern. For getting started or simple POCs, you can also export directly from the app to Dash0 (no collector needed).

| | Direct Export | Collector Sidecar |
|---|---|---|
| **Setup time** | ~5 min | ~10 min |
| **Extra infra** | None | Sidecar container per task |
| **ECS metadata** | Static (manual env vars) | Automatic (task ARN, AZ, container ID) |
| **Filtering/batching** | SDK-only | Full pipeline control |
| **PII redaction** | In application code | In collector config |
| **Best for** | Demos, POCs, low-traffic services | Production, regulated industries, multi-service |

**Recommended path:** Start with direct export to validate your instrumentation, then add the collector sidecar when moving to production.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full decision framework, collector image comparison, and cost analysis.

## Demo Tips

- **Lead with simplicity.** Show "5 env vars and you're done" before introducing the collector sidecar as the production upgrade.
- **Show the metadata enrichment.** Point out automatic ECS resource attributes (cluster ARN, task ARN, AZ) that the `resourcedetection` processor adds — this is the key sidecar differentiator.
- **Trace → Log correlation.** Click a trace in Dash0, then show correlated logs in the side panel — this is the "aha" moment for ECS teams.
- **"Why not just CloudWatch?"** The collector gives a single pipeline for traces, logs, and metrics to one backend. CloudWatch + X-Ray = two systems, two UIs, manual correlation.

## Further Reading

- [QUICKSTART.md](QUICKSTART.md) — Minimal step-by-step setup
- [ARCHITECTURE.md](ARCHITECTURE.md) — Architecture deep dive, decision framework, collector images, cost analysis
- [Sidecar vs. Direct Export Guide](ecs_dash0-sidecar-vs-direct-export-guide.html) — Visual decision guide (HTML)
- [ECS Setup Tutorial](ecs_dash0_tutorial.html) — Detailed step-by-step with FireLens log routing (HTML)
- [OTel Collector resourcedetection — ECS detector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourcedetectionprocessor/README.md)
- [Dash0 Batch Processor Guide](https://dash0.com/guides/opentelemetry-batch-processor)

## License

MIT
