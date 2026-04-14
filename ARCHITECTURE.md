# Architecture — Dash0 ECS Observability

This document covers the architecture decisions behind the ECS demo, the sidecar vs. direct export trade-offs, collector image choices, cost analysis, and production graduation path.

## Table of Contents

- [The Two Patterns](#the-two-patterns)
- [Decision Framework](#decision-framework)
- [Collector Pipeline Deep Dive](#collector-pipeline-deep-dive)
- [Choosing a Collector Image](#choosing-a-collector-image)
- [Config Injection Methods](#config-injection-methods)
- [AWS Service Integrations (Optional)](#aws-service-integrations-optional)
- [Resource Overhead and Cost](#resource-overhead-and-cost)
- [Log Shipping Options](#log-shipping-options)
- [Production Graduation Path](#production-graduation-path)

---

## The Two Patterns

### Pattern 1: Direct OTLP Export

```
┌─────────────────────┐              ┌──────────┐
│  ECS Task           │              │          │
│  ┌───────────────┐  │  OTLP/gRPC  │  Dash0   │
│  │  App + OTel   │──┼─────────────→│          │
│  │  SDK          │  │              │          │
│  └───────────────┘  │              └──────────┘
└─────────────────────┘
```

The app's OTel SDK exports directly to Dash0's OTLP endpoint. Configuration is via environment variables in the task definition:

- `OTEL_EXPORTER_OTLP_ENDPOINT` = `https://ingress.<region>.aws.dash0.com:4317`
- `OTEL_EXPORTER_OTLP_HEADERS` = `Authorization=Bearer auth_xxx` (via Secrets Manager)
- `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, etc.

**Pros:**
- Zero additional infrastructure — one container per task
- Fast setup (~5 min)
- Easy to reason about

**Cons:**
- No automatic ECS metadata enrichment — `OTEL_RESOURCE_ATTRIBUTES` are static across all task instances
- No filtering, batching, or transformation outside the SDK
- Retry/buffering limited to SDK capabilities — threads can block under transient failures
- No PII redaction before data leaves the VPC
- At scale (50+ tasks), each opens its own HTTPS connection to Dash0

### Pattern 2: OTel Collector Sidecar

```
┌──────────────────────────────────────────────┐              ┌──────────┐
│  ECS Task                                    │              │          │
│  ┌──────────────┐    ┌────────────────────┐  │  OTLP/gRPC  │  Dash0   │
│  │  App + OTel  │───→│  OTel Collector    │──┼─────────────→│          │
│  │  SDK         │    │  resourcedetection │  │              │          │
│  └──────────────┘    │  batch, filter     │  │              └──────────┘
│    localhost:4317     └────────────────────┘  │
└──────────────────────────────────────────────┘
```

The app exports to `localhost:4317` (the collector sidecar within the same task). The collector processes, enriches, and forwards to Dash0.

**Pros:**
- Automatic ECS metadata enrichment — the `resourcedetection` processor queries the Task Metadata Endpoint (v4) and stamps every signal with cluster ARN, task ARN, AZ, container ID, etc. — dynamically per instance
- Full pipeline control — enrichment, filtering, batching, transformation, PII redaction, retry
- Single outbound connection per task — the collector manages auth, reducing per-container overhead
- Decouples app from backend — switch observability backends without redeploying the app

**Cons:**
- Additional memory and CPU per task (typically 128–512 MB / 0.25 vCPU)
- Increased Fargate cost (see [cost analysis](#resource-overhead-and-cost))
- More config to manage (collector YAML)
- Another moving part to monitor (health_check extension helps)
- Startup dependency (app depends on collector via ECS `dependsOn`)

---

## Decision Framework

| Scenario | Recommendation |
|---|---|
| Demo, POC, getting started | **Direct export.** Ship in 5 minutes, no extra infra, no extra cost. |
| Single service, low traffic (<100 rps) | **Direct export** is fine. Add sidecar later if needed. |
| Multiple services, production | **Sidecar collector.** You need metadata, filtering, and batching. |
| Regulated industry (fintech, health) | **Sidecar collector.** PII redaction before data leaves the VPC is likely a hard requirement. |
| High cardinality / high traffic (>1000 rps) | **Sidecar collector.** Batching and memory limiting prevent telemetry from becoming a scaling bottleneck. |
| Need log/trace correlation from container logs | **Sidecar collector.** Required to enrich and correlate logs not from the OTel SDK. |
| Already using FireLens or Fluent Bit | **Sidecar collector.** Pipe Fluent Bit output through the collector for OTLP conversion. |
| Cost-sensitive, large fleet (50+ tasks) | **Central collector** (shared ECS service behind ALB) instead of per-task sidecars. Reduces instances from N to 2–3 at the cost of an extra network hop. |
| Large fleet + needs per-task metadata | **Sidecar with tight sizing.** 128 MB / 0.25 vCPU per collector. Custom image via `ocb`. |

---

## Collector Pipeline Deep Dive

This demo's collector config ([collector/otel-collector-config.yaml](collector/otel-collector-config.yaml)) implements:

### Receivers

```yaml
receivers:
  otlp:
    protocols:
      grpc:                    # :4317
      http:                    # :4318
```

Accepts OTLP from the app over gRPC (primary) and HTTP (for Fluent Bit integration).

### Processors (in pipeline order)

**1. `memory_limiter` (always first)**

```yaml
memory_limiter:
  check_interval: 1s
  limit_mib: 150
  spike_limit_mib: 50
```

Back-pressure protection. When the collector approaches its memory limit, it starts dropping data rather than OOMing. This must be the first processor in the chain.

**2. `resourcedetection`**

```yaml
resourcedetection:
  detectors: [env, ecs, ec2]
  timeout: 5s
  override: false
```

Queries the ECS Task Metadata Endpoint (TMDE v4) at startup and stamps every span, log, and metric with:
- `aws.ecs.cluster.arn`, `aws.ecs.task.arn`, `aws.ecs.task.family`, `aws.ecs.task.revision`
- `aws.ecs.launchtype`, `aws.ecs.container.arn`
- `cloud.provider`, `cloud.platform`, `cloud.region`, `cloud.account.id`, `cloud.availability_zone`
- `container.name`, `container.id`

`override: false` preserves attributes the SDK already set.

**3. `filter/health`**

```yaml
filter/health:
  error_mode: ignore
  traces:
    span:
      - 'attributes["http.target"] == "/health"'
      - 'attributes["url.path"] == "/health"'
```

Drops health check spans to reduce noise and cost. Covers both old and new HTTP semantic conventions.

**4. `batch` (always last)**

```yaml
batch:
  send_batch_size: 512
  timeout: 5s
  send_batch_max_size: 1024
```

Buffers spans and flushes every 512 items or 5 seconds, whichever comes first. Reduces outbound API calls to Dash0.

### Exporters

- **`otlp/dash0`** — OTLP/gRPC to Dash0 with auth header and retry config
- **`debug`** — Dumps telemetry to stdout (visible in CloudWatch Logs). Remove for production.

### Extensions

- **`health_check`** on `:13133` — used by ECS health checks and `dependsOn`
- **`zpages`** on `:55679` — browser debug UI at `/debug/tracez`

---

## Choosing a Collector Image

| Image | Size | Key Processors | Best For |
|---|---|---|---|
| `otel/opentelemetry-collector-contrib` | ~250 MB | All — resourcedetection, filter, transform, k8sattributes, etc. | Demos, POCs, when you need contrib processors |
| `otel/opentelemetry-collector` | ~60 MB | Core only — batch, memory_limiter, attributes. **No resourcedetection.** | Minimal footprint, but no ECS enrichment |
| AWS ADOT (`public.ecr.aws/aws-observability/aws-otel-collector`) | ~150 MB | AWS-curated subset. Includes resourcedetection, batch, memory_limiter. Supports `AOT_CONFIG_CONTENT`. | AWS-native shops wanting AWS-supported images |
| Dash0 Collector (`ghcr.io/dash0hq/collector`) | ~120 MB | Curated for Dash0 — resourcedetection, batch, filter, transform | Dash0 customers (primarily K8s-focused today) |
| Custom (via `ocb`) | Variable | Exactly what you need | Production at scale — minimal size and attack surface |

**Recommendations:**
- **Demo/POC:** `otel/opentelemetry-collector-contrib` — has everything, well-documented
- **Production (AWS-native):** ADOT Collector — AWS-supported, on ECR (no Docker Hub rate limits)
- **Production (minimal):** Custom collector via `ocb` with only what you use

> **Why not the core collector?** It doesn't include `resourcedetection`, `filter`, or `transform`. Without resourcedetection you lose automatic ECS metadata enrichment — which is half the reason to run a sidecar.

---

## Config Injection Methods

| Method | How It Works | Change Workflow | Best For |
|---|---|---|---|
| **Environment variable** | Full YAML as env var. Collector reads via `--config=env:OTEL_COLLECTOR_CONFIG`. | Edit task def → register revision → rolling deploy | Demos, POCs (this demo uses this) |
| **`AOT_CONFIG_CONTENT`** | ADOT Collector's native env var. Same approach. | Same as above | AWS-native shops using ADOT |
| **SSM Parameter Store** | YAML in SSM. Startup script fetches at boot. | Update SSM → redeploy tasks | Production — versioning + audit trail |
| **Baked into image** | `COPY config.yaml /etc/otelcol/` at build time. | Edit → rebuild → push to ECR → rolling deploy | Production at scale — immutable config per tag |

---

## AWS Service Integrations (Optional)

The demo supports optional DynamoDB and S3 integrations, enabled via `ENABLE_AWS_SERVICES=true`. This produces deeper, more realistic traces that show AWS SDK auto-instrumentation in action.

### What gets created

| Resource | Type | Cost Model |
|---|---|---|
| DynamoDB table (`dash0demo-orders`) | On-demand (PAY_PER_REQUEST) | ~$0 for demo traffic |
| S3 bucket (`dash0demo-data-<account>-<region>`) | Standard | ~$0 for demo traffic |
| IAM task role (`dash0demo-task-role`) | N/A | Free |

### How it works

When enabled, the app container gets a **task role** (separate from the execution role) with scoped permissions for DynamoDB and S3. The OTel `@opentelemetry/auto-instrumentations-node` package automatically instruments all AWS SDK v3 HTTP calls — so each DynamoDB/S3 operation produces both:

1. A **manual span** from the app (e.g., `dynamodb-put-order`) with business attributes
2. An **auto-instrumented HTTP span** underneath showing the actual AWS API call

This creates rich trace waterfalls that demonstrate real-world distributed tracing patterns.

### Trace shape comparison

**Without AWS services** (`/api/order`):
```
root → validate-order → charge-payment
```

**With AWS services** (`/api/order`):
```
root
  → validate-order
  → charge-payment
  → dynamodb-put-order
      → HTTP POST dynamodb.<region>.amazonaws.com
  → dynamodb-get-order
      → HTTP POST dynamodb.<region>.amazonaws.com
  → s3-put-receipt
      → HTTP PUT <bucket>.s3.<region>.amazonaws.com
```

### Configuration

Set these in `.env` or as environment variables (env vars override `.env`):

| Env Var | Default | Description |
|---|---|---|
| `ENABLE_AWS_SERVICES` | `false` | Set to `true` to enable DynamoDB/S3 calls |
| `DYNAMO_TABLE` | `dash0demo-orders` | DynamoDB table name |
| `S3_BUCKET` | `dash0demo-data-<account>-<region>` | S3 bucket name |

---

## Resource Overhead and Cost

| Configuration | Task CPU | Task Memory | Collector Share | Monthly Cost (1 task, eu-west-1) |
|---|---|---|---|---|
| Direct export (no sidecar) | 512 (0.5 vCPU) | 1024 MB | 0% | ~$15 |
| Sidecar (demo sizing) | 1024 (1 vCPU) | 2048 MB | 25% CPU / 25% RAM | ~$30 |
| Sidecar (tight production) | 768 (0.75 vCPU) | 1536 MB | 17% CPU / 17% RAM | ~$22 |

*Costs are approximate, 24/7 on-demand pricing. Multiply by task count for fleet cost.*

**Cost framing:** The overhead is real but modest. For most services, the observability value — faster debugging, proactive alerting, SLO tracking — far outweighs the ~$7–15/month/task collector cost. Frame it as: "Would you rather pay $15/month extra per service, or spend 4 hours debugging a production incident blind?"

---

## Log Shipping Options

There are three ways to get ECS logs into Dash0:

### 1. Direct OTLP export from the app

The app's OTel SDK exports logs directly via OTLP. This is what this demo uses. Simplest option, works well for structured application logs.

### 2. FireLens + Fluent Bit sidecar

AWS-managed log routing. FireLens intercepts all container stdout/stderr and routes through Fluent Bit. Use the latest `aws-for-fluent-bit:stable` image with the `opentelemetry` output plugin to forward to the collector sidecar (or directly to Dash0).

Best for: capturing all container output including logs from libraries that don't use the OTel logging bridge.

### 3. CloudWatch Logs → Dash0 integration

Zero change to the ECS task. Enable the Dash0 CloudWatch-for-logs integration. Lowest effort but adds latency and loses some structured metadata.

Best for: quick wins when you can't modify the task definition.

---

## Production Graduation Path

```
Direct Export  ──→  Validate in Dash0  ──→  Add Sidecar Collector
```

1. **Start with direct export.** Set 5 env vars, deploy, confirm traces appear in Dash0. This validates your instrumentation works.

2. **Add the collector sidecar.** Use this demo's task definition as a template. You gain: automatic ECS metadata, filtering, batching, PII redaction, and retry buffering.

3. **Tighten for production.** Switch from `contrib` to ADOT or a custom `ocb` image. Move config to SSM Parameter Store. Right-size the collector (128 MB / 0.25 vCPU is often sufficient). Remove the `debug` exporter.

4. **Scale.** For large fleets (50+ tasks), evaluate a central collector behind an ALB to reduce total collector instances. Trade per-task metadata for cost savings.

---

## Teardown: AWS ENI Race Condition

When tearing down ECS infrastructure, there's a well-known AWS race condition: `describe-network-interfaces` reports 0 ENIs in the subnets, but AWS hasn't fully released the underlying dependencies from security groups and subnets. Single-shot deletes hit this window and fail.

The teardown script handles this with:

1. **SGs delete before subnets** — security groups have dependencies on ENIs; subnets depend on SGs being gone. Order matters.
2. **Retry with backoff** — up to 6 attempts with 15-second waits (90s total) for each resource group, instead of a single fire-and-fail.
3. **Idempotent retries** — if a resource was already deleted, the retry loop treats it as success and moves on.

---

## References

- [OTel Collector resourcedetection — ECS detector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourcedetectionprocessor/README.md)
- [Dash0: Resource Fragmentation Scenarios](https://dash0.com/docs/dash0/monitoring/resources/recognize-common-resource-fragmentation-scenarios)
- [Dash0: Batch Processor Guide](https://dash0.com/guides/opentelemetry-batch-processor)
- [Dash0: Resource Processor Guide](https://dash0.com/guides/opentelemetry-resource-processor)
- [OTel Collector Scaling Guide](https://opentelemetry.io/docs/collector/scaling/)
- [OTel Collector Resiliency](https://opentelemetry.io/docs/collector/resiliency/)
