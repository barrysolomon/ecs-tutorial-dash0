# Quick Start — Dash0 ECS Demo

Get from zero to distributed traces in Dash0 in under 10 minutes.

## 1. Prerequisites

- Docker running
- AWS CLI installed and configured (`aws sts get-caller-identity` should succeed)
- A Dash0 auth token (`auth_xxxx` from [app.dash0.com](https://app.dash0.com) → Settings → Auth Tokens)

## 2. Configure

Create a `.env` file in the project root (scripts load it automatically):

```bash
cat > .env <<'EOF'
DASH0_AUTH_TOKEN=auth_xxxxxxxxxxxxxxxxxxxx
AWS_REGION=eu-west-1
DASH0_ENDPOINT=ingress.eu-west-1.aws.dash0.com:4317
AWS_PROFILE=your-profile
ENABLE_AWS_SERVICES=true
EOF
```

Or export variables directly (these override `.env`):

```bash
export DASH0_AUTH_TOKEN=auth_xxxxxxxxxxxxxxxxxxxx
export AWS_REGION=eu-west-1
export DASH0_ENDPOINT=ingress.eu-west-1.aws.dash0.com:4317
```

### Endpoints by region

| Region | Endpoint |
|---|---|
| EU West (Ireland) | `ingress.eu-west-1.aws.dash0.com:4317` |
| US West (Oregon) | `ingress.us-west-2.aws.dash0.com:4317` |
| US East (Ohio) | `ingress.us-east-2.aws.dash0.com:4317` |

## 3. Deploy

```bash
./scripts/setup.sh
```

This creates a VPC, ECS cluster, ECR repository, ALB, and deploys the demo app with an OTel Collector sidecar. If `ENABLE_AWS_SERVICES=true` is set (in `.env` or environment), it also creates a DynamoDB table and S3 bucket for richer trace demos. Takes ~5 minutes.

The script prints the ALB DNS name when done — save it.

## 4. Generate Telemetry

```bash
# Single requests
curl http://<ALB_DNS>/api/order      # order flow (+ DynamoDB/S3 if AWS enabled)
curl http://<ALB_DNS>/api/inventory  # scan orders + S3 report (AWS-only)
curl http://<ALB_DNS>/api/slow       # latency spike (1.5–3s)
curl http://<ALB_DNS>/api/error      # error span + exception
curl http://<ALB_DNS>/api/burst      # 10 parallel child spans
curl http://<ALB_DNS>/api/fetch      # outbound HTTP with trace propagation

# Sustained load (30 mixed requests)
./scripts/fire.sh http://<ALB_DNS>
```

## 5. Explore in Dash0

1. Open [app.dash0.com](https://app.dash0.com) → your organisation
2. Go to **Services** — look for `dash0-demo`
3. Click into the service to see RED metrics (rate, errors, duration)
4. Open the **Traces** tab — click any trace to see the waterfall
5. From a trace, check **correlated logs** in the side panel
6. Try the **Logs** view — filter by service, search across attributes

### What to look for

| Endpoint | What you'll see in Dash0 |
|---|---|
| `/api/order` | Order waterfall: validate → payment (+ DynamoDB put/get → S3 put if AWS enabled) |
| `/api/inventory` | DynamoDB scan + S3 report write (AWS-only — graceful no-op when disabled) |
| `/api/slow` | P95/P99 latency spike in the duration histogram |
| `/api/error` | Error span with `otel.status = ERROR` + recorded exception |
| `/api/burst` | 10 parallel child spans fanning out from a single parent |
| `/api/fetch` | Outbound HTTP span to httpbin.org with trace context propagation |

## 6. Teardown

```bash
./scripts/teardown.sh
```

Deletes all AWS resources created by `setup.sh`, including DynamoDB table and S3 bucket if they were created.

## Next Steps

- Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand the sidecar vs. direct export trade-offs
- Explore the collector config in [collector/otel-collector-config.yaml](collector/otel-collector-config.yaml)
- Browse the app instrumentation in [app/app.js](app/app.js) to see manual span creation and log correlation
- Try the [interactive tutorial](./scripts/tutorial.sh) for a guided experience with explanations at each step
