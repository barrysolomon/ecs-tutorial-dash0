# Dash0 ECS Observability Tutorial

A self-paced tutorial: instrument an ECS Fargate app with OpenTelemetry and send traces, logs, and metrics to Dash0 using an OTel Collector sidecar.

## Quick Start

```bash
./scripts/tutorial.sh
```

The tutorial walks you through everything interactively — verifies prerequisites, handles AWS login, asks for your Dash0 token, deploys, generates traffic, explains what to look for in Dash0, and cleans up.

## Prerequisites

- Docker running locally
- AWS CLI installed (`brew install awscli` or [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
- AWS credentials (the tutorial will help you log in if needed)
- A Dash0 auth token (`auth_xxxx` — from app.dash0.com → Settings → Auth Tokens)

## What You'll Learn

1. **Direct export vs. collector sidecar** — two patterns for getting telemetry to Dash0, and when to use each
2. **Auto-instrumentation** — how the OTel SDK traces HTTP/DB/queue operations with zero code changes
3. **Manual spans** — adding business context (order IDs, payment amounts) as custom spans
4. **Collector pipeline** — how resourcedetection, batching, and filtering work
5. **Dash0 exploration** — RED metrics, trace waterfalls, errors, correlated logs, ECS resource attributes

## Architecture

```
┌───────────────────────────────────────────────────────┐
│  ECS Fargate Task                                     │
│  ┌────────────────────────┐ ┌──────────────────────┐  │
│  │  app (Node.js)         │ │  otel-collector      │  │
│  │  OTel auto-instrumented│→│  resourcedetection   │──── OTLP gRPC ──→ Dash0
│  │  + manual spans        │ │  batch, filter       │  │
│  │  port 3000             │ │  port 4317 (grpc)    │  │
│  └────────────────────────┘ └──────────────────────┘  │
│          ↑                           ↑                │
│    ALB :80 → :3000            localhost:4317          │
└───────────────────────────────────────────────────────┘
```

The app sends OTLP to `localhost:4317` — it doesn't know about Dash0. The collector sidecar handles auth, enrichment (ECS metadata), batching, filtering, and export.

## Structure

```
ecs-demo/
├── app/
│   ├── app.js            # Node.js demo service (auto + manual instrumentation)
│   ├── package.json
│   └── Dockerfile
├── collector/
│   └── otel-collector-config.yaml   # Reference config (injected via env var at runtime)
├── scripts/
│   ├── tutorial.sh       # ← Start here. Interactive guided walkthrough.
│   ├── setup.sh          # Creates all AWS infra + deploys to ECS Fargate
│   ├── teardown.sh       # Deletes everything
│   └── fire.sh           # Traffic generator
└── articles/
    └── 001-ecs-sidecar-vs-direct-export.md   # Deep-dive: sidecar vs direct, collector images, IaC examples
```

## Manual Mode (Advanced)

If you prefer to run the scripts directly instead of the tutorial:

```bash
# 1. Set env vars
export DASH0_AUTH_TOKEN=auth_xxxxxxxxxxxxxxxxxxxx
export AWS_REGION=eu-west-1
export DASH0_ENDPOINT=ingress.eu-west-1.aws.dash0.com:4317

# 2. Deploy (~5 min)
./scripts/setup.sh

# 3. Trigger telemetry
curl http://<ALB_DNS>/api/order     # happy path trace
curl http://<ALB_DNS>/api/slow      # latency spike
curl http://<ALB_DNS>/api/error     # error span
curl http://<ALB_DNS>/api/burst     # 10 parallel child spans
curl http://<ALB_DNS>/api/fetch     # outbound HTTP
./scripts/fire.sh http://<ALB_DNS>  # 30 mixed requests

# 4. View in Dash0
#    app.dash0.com → Services → dash0-demo

# 5. Teardown
./scripts/teardown.sh
```

Endpoint by region:
| Region     | DASH0_ENDPOINT                          |
|------------|------------------------------------------|
| EU West    | ingress.eu-west-1.aws.dash0.com:4317         |
| US West    | ingress.us-west-2.aws.dash0.com:4317         |
| US East    | ingress.us-east-2.aws.dash0.com:4317         |

## App Endpoints

| Endpoint     | What it demonstrates                                      |
|--------------|-----------------------------------------------------------|
| `/api/order` | 3-span trace (root → validate → payment), structured logs |
| `/api/slow`  | 1.5–3s latency spike, shows up in P95/P99 in Dash0        |
| `/api/error` | Error span with recorded exception + ERROR log            |
| `/api/burst` | 10 parallel child spans — great waterfall demo            |
| `/api/fetch` | Outbound HTTP call to httpbin.org, trace propagation      |
| `/api/load`  | Fires a random endpoint — use in a loop for load          |

## Collector Pipeline

```
receivers          processors                          exporters
  otlp  ──→  memory_limiter (always first)               otlp/dash0
              → resourcedetection (ecs, ec2)               → Dash0
              → filter/health (drops /health spans)
              → batch (always last, 512 spans/5s)
```

The collector config is in `collector/otel-collector-config.yaml` for reference. At runtime it's injected as an environment variable in the ECS task definition — no custom collector image needed.

## Further Reading

See `articles/001-ecs-sidecar-vs-direct-export.md` for the full architecture guide covering:
- Sidecar vs. direct export trade-offs
- Auto-instrumentation for Node.js, Java, Python, .NET, Go
- Collector image choices (contrib, ADOT, custom)
- IaC examples (Terraform, CDK)
- Common customizations (PII redaction, tail sampling, multi-backend export)
- Troubleshooting guide
