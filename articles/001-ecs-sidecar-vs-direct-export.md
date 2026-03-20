---
title: "OTel Collector Sidecar vs. Direct OTLP Export on AWS ECS Fargate"
id: 001
author: Barry Solomon
created: 2026-03-19
updated: 2026-03-19
tags: [ecs, fargate, otel-collector, sidecar, architecture, aws]
audience: SA, SE, CSM
status: published
---

# OTel Collector Sidecar vs. Direct OTLP Export on AWS ECS Fargate

## TL;DR

Direct OTLP export sends telemetry straight from the app SDK to Dash0 — zero infrastructure, 5-minute setup, perfect for getting started and demos. An OTel Collector sidecar sits between the app and Dash0 and adds automatic infrastructure metadata (task ARN, cluster, AZ), batching, filtering, PII redaction, retry buffering, and log enrichment. Start with direct export, graduate to a sidecar when moving to production with multiple services.

## Context

This comes up in every ECS prospect conversation. Customers migrating to ECS (especially from Elastic Beanstalk, EC2, or Lambda) want to know the simplest path to observability — but also need to understand the production-grade architecture. The typical SA recommendation is the sidecar approach; the Dash0 ECS demo uses direct export for simplicity. Both are valid. The question is: what does the sidecar actually *give* you?

## Instrumenting the Application

Before the collector has anything to collect, the app needs to produce telemetry. There are two approaches: auto-instrumentation and manual instrumentation. They aren't mutually exclusive — most production setups start with auto and add manual spans for business logic.

### Auto-Instrumentation

Auto-instrumentation injects tracing into known libraries (HTTP servers, DB clients, message queues) without changing application code. How you enable it depends on the language:

| Language | How to Enable | Where It's Configured | Zero Code Changes? |
|----------|--------------|----------------------|-------------------|
| **Node.js** | `NODE_OPTIONS='-r @opentelemetry/auto-instrumentations-node/register'` or `--require @opentelemetry/auto-instrumentations-node/register` | **Task definition** (env var) or **Dockerfile** (CMD/ENTRYPOINT). Either works. The OTel packages must be in `node_modules` (installed via `package.json` or a separate layer). | Yes — if you add the dependency and set the env var, no code changes needed. |
| **Java** | `-javaagent:/path/to/opentelemetry-javaagent.jar` | **Dockerfile** (add the agent JAR + set `JAVA_TOOL_OPTIONS` or modify the entrypoint). Can also be set via `JAVA_TOOL_OPTIONS` env var in the **task definition** if the JAR is already in the image. | Yes — the Java agent instruments at the bytecode level. No code changes. |
| **Python** | `opentelemetry-instrument python app.py` or `OTEL_PYTHON_CONFIGURATOR=auto` with the SDK installed | **Dockerfile** (change CMD to use `opentelemetry-instrument` wrapper). The env var approach also works from the **task definition** if the packages are installed. | Yes — wraps the Python process. No code changes. |
| **.NET** | `CORECLR_ENABLE_PROFILING=1` + `CORECLR_PROFILER` + `CORECLR_PROFILER_PATH` env vars, or `DOTNET_STARTUP_HOOKS` | **Task definition** (env vars) if the profiler DLLs are in the image. Typically configured in the **Dockerfile** alongside the profiler installation. | Yes — .NET auto-instrumentation uses CLR profiling APIs. No code changes. |
| **Go** | No runtime auto-instrumentation available. Must use compile-time instrumentation (`go.opentelemetry.io/contrib/instrumentation/...`) or eBPF-based (experimental). | **Code** — Go requires importing instrumentation libraries and wiring them in code. | No — Go doesn't have a runtime agent model. Manual instrumentation required. |

**The practical answer for most customers:** "Add the OTel auto-instrumentation package to your Docker image, set one or two environment variables in the task definition, and you get traces for all HTTP/gRPC/DB/queue operations with zero code changes. The environment variables can be set in the task definition — you don't have to touch the Dockerfile if the packages are already installed."

### What Auto-Instrumentation Captures

Out of the box, auto-instrumentation covers the framework and library level:

- **Inbound HTTP requests** — a root span per request with method, path, status code, duration
- **Outbound HTTP calls** — child spans for each fetch/axios/http call, with trace context propagation
- **Database queries** — spans for MongoDB, PostgreSQL, MySQL, Redis, etc. with the query (or hashed query) as an attribute
- **Message queues** — spans for Kafka, RabbitMQ, SQS publish/consume
- **gRPC** — spans for both client and server calls

What auto-instrumentation does **not** capture: your business logic. It won't know that a particular code path is "validate order" vs. "charge payment" — those are just generic HTTP handler spans. For that, you need manual instrumentation.

### Manual Instrumentation

Manual instrumentation adds custom spans and attributes for business-specific operations. This is code-level work — the developer adds it inside the application.

**Node.js example** (from the Dash0 demo app):

```javascript
const { trace } = require('@opentelemetry/api');
const tracer = trace.getTracer('my-service');

// Wrap a business operation in a custom span
await tracer.startActiveSpan('validate-order', async (span) => {
  span.setAttribute('order.id', orderId);
  span.setAttribute('order.items', itemCount);
  // ... business logic ...
  span.end();
});
```

**Java example:**

```java
Tracer tracer = GlobalOpenTelemetry.getTracer("my-service");
Span span = tracer.spanBuilder("validate-order").startSpan();
try (Scope scope = span.makeCurrent()) {
    span.setAttribute("order.id", orderId);
    // ... business logic ...
} finally {
    span.end();
}
```

Manual spans nest inside auto-instrumentation spans automatically — the OTel SDK tracks the active span context. So a custom "validate-order" span appears as a child of the auto-generated HTTP request span in the trace waterfall.

### Recommendation for Customers

1. **Start with auto-instrumentation only.** Set the env vars, deploy, confirm traces appear in Dash0. This takes minutes.
2. **Add manual spans for critical business logic** once auto-instrumentation is validated. Focus on operations where you need custom attributes (order IDs, customer IDs, payment amounts) or where you want to break a single HTTP request into meaningful sub-operations.
3. **Log correlation comes for free** if the app's logger injects `trace_id` and `span_id` into structured log output. Most OTel SDK auto-instrumentation does this automatically for popular loggers (Pino, Winston, Bunyan for Node; Logback, Log4j for Java; standard logging for Python).

### Task Definition Environment Variables for Auto-Instrumentation

These env vars configure the OTel SDK's behavior. They're set on the **app container**, not the collector:

```json
{
  "name": "app",
  "environment": [
    { "name": "OTEL_SERVICE_NAME",              "value": "my-service" },
    { "name": "OTEL_EXPORTER_OTLP_ENDPOINT",    "value": "http://localhost:4317" },
    { "name": "OTEL_EXPORTER_OTLP_PROTOCOL",    "value": "grpc" },
    { "name": "OTEL_TRACES_EXPORTER",           "value": "otlp" },
    { "name": "OTEL_LOGS_EXPORTER",             "value": "otlp" },
    { "name": "OTEL_METRICS_EXPORTER",          "value": "otlp" },
    { "name": "OTEL_PROPAGATORS",               "value": "tracecontext,baggage" },
    { "name": "OTEL_RESOURCE_ATTRIBUTES",        "value": "deployment.environment=production" },
    { "name": "NODE_OPTIONS",                    "value": "-r @opentelemetry/auto-instrumentations-node/register" }
  ]
}
```

The last line (`NODE_OPTIONS`) is the Node.js auto-instrumentation trigger. For Java, you'd instead set `JAVA_TOOL_OPTIONS=-javaagent:/opt/opentelemetry-javaagent.jar`. For Python, change the container `command` to use `opentelemetry-instrument`. Everything else above is language-agnostic.

If the app targets the sidecar collector at `http://localhost:4317`, no auth headers are needed on the app container — the collector handles auth to Dash0.

## The Two Patterns

### Pattern 1: Direct OTLP Export (No Collector)

```
┌─────────────────────────────┐
│  ECS Task                   │
│  ┌───────────────────────┐  │
│  │  App Container         │  │
│  │  (OTel SDK inside)     │──────── OTLP gRPC ──────► Dash0
│  │                        │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

The app's OTel SDK exports directly to Dash0's OTLP endpoint. Configuration is entirely via environment variables in the ECS task definition:

- `OTEL_EXPORTER_OTLP_ENDPOINT` = `https://api.<region>.aws.dash0.com:4317`
- `OTEL_EXPORTER_OTLP_HEADERS` = `Authorization=Bearer auth_xxx` (via Secrets Manager)
- `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, etc.

**Pros:** Zero additional infrastructure. One container per task. Fast to set up. Easy to reason about.

**Cons:** No automatic ECS metadata enrichment. No filtering, batching, or transformation outside the SDK. Retry/buffering is limited to what the SDK provides. Every container makes its own outbound HTTPS connections.

### Pattern 2: OTel Collector Sidecar

```
┌──────────────────────────────────────────┐
│  ECS Task                                │
│  ┌──────────────────┐  ┌──────────────┐  │
│  │  App Container    │  │  Collector   │  │
│  │  (OTel SDK)       │──│  Sidecar     │──────► Dash0
│  │                   │  │              │  │
│  └──────────────────┘  └──────────────┘  │
└──────────────────────────────────────────┘
        localhost:4317          OTLP gRPC
```

The app's OTel SDK exports to `localhost:4317` (the collector sidecar within the same task). The collector processes and forwards to Dash0.

**Pros:** Full pipeline control — enrichment, filtering, batching, transformation, redaction, retry. Automatic ECS metadata stamped on every signal. Single outbound connection per task (collector manages it). Decouples app from backend.

**How users configure the collector pipeline:** The collector's behavior is defined in a single YAML config file. This config specifies receivers (what the collector listens on), processors (what it does to the data), and exporters (where it sends the data). On ECS Fargate, there are four ways to get this config into the sidecar container — each with different trade-offs for ease of change vs. operational maturity:

| Method | How It Works | Change Workflow | Best For |
|--------|-------------|-----------------|----------|
| **Environment variable** | Full YAML injected as an env var in the task definition. Collector reads it via `--config=env:OTEL_COLLECTOR_CONFIG`. | Edit the task definition JSON → register new revision → update service (rolling deploy). | Demos, POCs, small teams. Simple but the YAML is embedded in infra code. |
| **`AOT_CONFIG_CONTENT`** (ADOT only) | Same as above but using the AWS ADOT Collector's native env var. | Same as above. | AWS-native shops already using ADOT. |
| **SSM Parameter Store** | Store the YAML in SSM. A startup script or entrypoint in a custom image fetches it at container boot. | Update the SSM parameter → redeploy tasks (or wait for next scale event). Config is decoupled from the task definition. | Production teams that want config separate from infra. Supports versioning and audit trail via SSM. |
| **Baked into a custom image** | Build a Dockerfile that copies the YAML into the collector image at build time (`COPY otel-config.yaml /etc/otelcol/config.yaml`). | Edit YAML → rebuild image → push to ECR → update task definition → rolling deploy. | Production at scale. Config is immutable per image tag — you know exactly what's running. Pairs well with `ocb` custom builds. |

**What's in the YAML — the three-section structure:**

```yaml
receivers:       # What the collector listens on (OTLP gRPC/HTTP, typically localhost:4317)
processors:      # What it does to the data (enrich, filter, batch, redact — in order)
exporters:       # Where it sends the data (Dash0 OTLP endpoint + auth)
service:
  pipelines:     # Wires receivers → processors → exporters per signal type
    traces:  { receivers: [otlp], processors: [memory_limiter, resourcedetection, filter/health, batch], exporters: [otlp/dash0] }
    logs:    { receivers: [otlp], processors: [memory_limiter, resourcedetection, batch], exporters: [otlp/dash0] }
    metrics: { receivers: [otlp], processors: [memory_limiter, resourcedetection, batch], exporters: [otlp/dash0] }
```

Processors execute **in the order listed** in the pipeline — this matters. `memory_limiter` should always be first (so it can drop data before other processors consume memory), and `batch` should always be last (so it batches the final processed data).

To add or change processing behavior, you edit this YAML. For example, to redact SQL queries, add an `attributes` processor and insert it into the pipeline:

```yaml
processors:
  attributes/redact:
    actions:
      - key: db.statement
        action: hash
```

Then wire it into the traces pipeline: `processors: [memory_limiter, resourcedetection, attributes/redact, filter/health, batch]`

The collector validates the config at startup — if the YAML is malformed or references a processor that doesn't exist in the image, it fails fast with a clear error in the container logs. Use [OTelBin](https://otelbin.io) to validate configs before deploying.

**Cons:**
- **Additional memory and CPU per task.** The collector sidecar consumes real resources. In the demo we allocate 256 CPU units (0.25 vCPU) and 512 MB RAM. In production, typical sizing is 128–512 MB RAM / 0.25 vCPU, but high-throughput services may need more. This cost is **per task** — if you're running 50 tasks, that's 50 collector instances. At scale, consider whether a central collector (shared ECS service behind an ALB) makes more sense than per-task sidecars.
- **Increased Fargate cost.** Because Fargate bills on task-level CPU+memory, bumping from 512/1024 to 1024/2048 to accommodate the sidecar roughly doubles the compute cost per task. For a demo or POC this is negligible, but for production fleet sizing it's a real line item.
- **More config to manage.** The collector YAML is another artifact to version, deploy, and debug. Config errors (bad YAML, wrong processor order, typo in endpoint) won't surface until runtime.
- **Another moving part to monitor.** The collector itself can fail, OOM, or drop data under pressure. You need to monitor it — the `health_check` extension helps, but it's still one more thing.
- **Startup dependency.** The app container depends on the collector being healthy before it starts (via ECS `dependsOn`). If the collector fails to start, the app won't start either. This is usually the right behavior, but adds a failure mode.

## Choosing a Collector Image

Not all collector images are the same. The choice affects what processors are available, image size, and support posture.

| Image | Size | Key Processors | Best For |
|-------|------|----------------|----------|
| `otel/opentelemetry-collector-contrib` | ~250 MB | All of them — resourcedetection, filter, transform, k8sattributes, etc. | Demos, POCs, and when you need specific contrib processors. Kitchen sink. |
| `otel/opentelemetry-collector` | ~60 MB | Core only — batch, memory_limiter, attributes. No resourcedetection, no filter. | Minimal footprint, but lacks ECS enrichment. Not useful for this use case. |
| AWS ADOT Collector (`public.ecr.aws/aws-observability/aws-otel-collector`) | ~150 MB | AWS-curated subset of contrib. Includes resourcedetection (ECS/EC2), batch, memory_limiter. Supports `AOT_CONFIG_CONTENT` env var for config injection. | AWS-native shops that want AWS-supported images. Good ECS support out of the box. |
| Dash0 OTel Collector (`ghcr.io/dash0hq/collector`) | ~120 MB | Curated for Dash0 — includes resourcedetection, batch, filter, transform, memory_limiter. Pre-configured for Dash0 endpoints. | Dash0 customers who want a smaller image with only what's needed. Check availability for ECS (primarily K8s-focused today). |
| Custom-built (via `ocb` — OTel Collector Builder) | Variable | Exactly what you need, nothing more. | Production at scale where image size and attack surface matter. Build time investment upfront. |

**Recommendation by scenario:**

- **Demo / POC:** Use `otel/opentelemetry-collector-contrib`. It has everything, config is well-documented, and image pull time doesn't matter for a demo.
- **Production (AWS-native):** Consider the ADOT Collector. AWS supports it, it's on ECR (no Docker Hub rate limits), and `AOT_CONFIG_CONTENT` makes config injection cleaner than the `--config=env:` approach.
- **Production (minimal footprint):** Build a custom collector with `ocb` containing only the receivers, processors, and exporters you actually use. Smallest image, smallest attack surface, fastest startup.
- **If the customer asks "why not just use the core collector?"** — because the core image doesn't include `resourcedetection`, `filter`, or `transform`. Those are all in the contrib or ADOT images. Without resourcedetection, you lose the automatic ECS metadata enrichment — which is half the reason to run a sidecar in the first place.

### Resource Overhead: Real Numbers

| Configuration | Task CPU | Task Memory | Collector Share | Monthly Fargate Cost (1 task, eu-west-1) |
|---------------|----------|-------------|-----------------|------------------------------------------|
| Direct export (no sidecar) | 512 (0.5 vCPU) | 1024 MB | 0% | ~$15 |
| Sidecar (demo sizing) | 1024 (1 vCPU) | 2048 MB | 25% CPU / 25% RAM | ~$30 |
| Sidecar (tight production) | 768 (0.75 vCPU) | 1536 MB | 17% CPU / 17% RAM | ~$22 |

*Costs are approximate, 24/7 on-demand, single task. Multiply by task count for fleet cost.*

The overhead is real but modest. For most services, the observability value (faster debugging, proactive alerting, SLO tracking) far outweighs the ~$7–15/month/task collector cost. The conversation with cost-conscious customers should be: "Would you rather pay $15/month extra per service, or spend 4 hours debugging a production incident blind?"

## Setup Guide: Adding an OTel Collector Sidecar to an ECS Fargate Task

This walks through the end-to-end setup. It assumes you already have an ECS task definition with an app container that's instrumented with the OTel SDK. You're adding the collector sidecar alongside it.

### Prerequisites

- AWS CLI configured and authenticated
- An existing ECS task definition (or you're creating one)
- A Dash0 auth token (`auth_xxxx`) — get this from Dash0 → Organization Settings → Auth Tokens
- Your Dash0 OTLP endpoint (e.g., `api.eu-west-1.aws.dash0.com:4317`)

### Step 1: Store the Dash0 Auth Token in Secrets Manager

Don't put the auth token in plaintext in your task definition. Use AWS Secrets Manager:

```bash
aws secretsmanager create-secret \
    --name "dash0/auth-token" \
    --description "Dash0 OTLP ingest auth token" \
    --secret-string "auth_xxxxxxxxxxxxxxxxxxxx" \
    --region eu-west-1
```

Note the ARN it returns — you'll reference this in the task definition. The ECS execution role needs `secretsmanager:GetSecretValue` permission on this ARN.

To update an existing secret:

```bash
aws secretsmanager put-secret-value \
    --secret-id "dash0/auth-token" \
    --secret-string "auth_xxxxxxxxxxxxxxxxxxxx" \
    --region eu-west-1
```

### Step 2: Write the Collector Config

Create a YAML config file. This is the minimum production-ready config for ECS + Dash0:

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133        # collector health endpoint

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317     # app sends telemetry here
      http:
        endpoint: 0.0.0.0:4318     # optional HTTP receiver

processors:
  # Order matters — listed here in the order they should appear in pipelines

  memory_limiter:                   # ALWAYS first — protects against OOM
    check_interval: 1s
    limit_mib: 150                  # hard limit — starts dropping data
    spike_limit_mib: 50             # soft limit — starts refusing data

  resourcedetection:                # auto-stamps ECS metadata on every signal
    detectors: [env, ecs, ec2]      # env reads OTEL_RESOURCE_ATTRIBUTES,
    timeout: 5s                     # ecs queries Task Metadata Endpoint,
    override: false                 # ec2 adds cloud.account.id, AZ, etc.
                                    # override: false = don't overwrite what the SDK set

  filter/health:                    # drop ALB health check noise
    error_mode: ignore              # don't error if no match
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["url.path"] == "/health"'

  batch:                            # ALWAYS last — batches the final processed data
    send_batch_size: 512
    timeout: 5s
    send_batch_max_size: 1024

exporters:
  otlp/dash0:
    endpoint: ${DASH0_OTLP_ENDPOINT}          # injected via env var at runtime
    headers:
      Authorization: "Bearer ${DASH0_AUTH_TOKEN}"  # injected via Secrets Manager
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, filter/health, batch]
      exporters: [otlp/dash0]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlp/dash0]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlp/dash0]
  telemetry:
    logs:
      level: warn                   # collector's own logging — keep quiet unless debugging
```

**Key points about this config:**

- `${DASH0_OTLP_ENDPOINT}` and `${DASH0_AUTH_TOKEN}` are **not** bash variables — the collector resolves them from environment variables at runtime. You set these in the task definition (step 3).
- Processor order in the pipeline array is the execution order. `memory_limiter` first, `batch` last. Everything else in between.
- `override: false` on `resourcedetection` means if your app SDK already sets `service.name`, the collector won't overwrite it. It only *adds* attributes that aren't already present.
- `filter/health` only applies to traces — you generally want health check logs to still flow through for debugging startup issues.

### Step 3: Add the Sidecar to Your ECS Task Definition

You need to modify three things in your task definition:

**A. Bump task-level resources** to accommodate the sidecar:

```json
{
  "cpu": "1024",     // was "512" — add headroom for the collector
  "memory": "2048"   // was "1024"
}
```

**B. Change your app container's OTLP endpoint** from Dash0's endpoint to the local collector:

```json
{
  "name": "app",
  "environment": [
    { "name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": "http://localhost:4317" },
    { "name": "OTEL_EXPORTER_OTLP_PROTOCOL", "value": "grpc" },
    { "name": "OTEL_RESOURCE_ATTRIBUTES",     "value": "deployment.environment=demo" }
    // No auth headers needed — the collector handles auth to Dash0
    // No cloud.provider/cloud.platform — the collector adds these automatically
  ],
  "dependsOn": [
    { "containerName": "otel-collector", "condition": "HEALTHY" }
  ]
  // ... rest of app container definition unchanged
}
```

Note what's removed compared to direct export: no `OTEL_EXPORTER_OTLP_HEADERS` (no auth needed for localhost), no static `cloud.provider=aws,cloud.platform=aws_ecs` in resource attributes (the collector injects these dynamically).

The `dependsOn` ensures the app doesn't start until the collector is healthy — otherwise the app's first spans would fail to export.

**C. Add the collector sidecar container.** There are two sub-options here depending on how you inject the config:

**Option 1: Config via environment variable** (simplest — used in the Dash0 demo):

```json
{
  "name": "otel-collector",
  "image": "otel/opentelemetry-collector-contrib:0.120.0",
  "essential": true,
  "command": ["--config=env:OTEL_COLLECTOR_CONFIG"],
  "portMappings": [
    { "containerPort": 4317, "protocol": "tcp" },
    { "containerPort": 4318, "protocol": "tcp" },
    { "containerPort": 13133, "protocol": "tcp" }
  ],
  "environment": [
    {
      "name": "OTEL_COLLECTOR_CONFIG",
      "value": "extensions:\n  health_check:\n    endpoint: 0.0.0.0:13133\nreceivers:\n  otlp:\n    protocols:\n      grpc:\n        endpoint: 0.0.0.0:4317\n      http:\n        endpoint: 0.0.0.0:4318\n..."
    },
    { "name": "DASH0_OTLP_ENDPOINT", "value": "api.eu-west-1.aws.dash0.com:4317" }
  ],
  "secrets": [
    {
      "name": "DASH0_AUTH_TOKEN",
      "valueFrom": "arn:aws:secretsmanager:eu-west-1:123456789:secret:dash0/auth-token-AbCdEf"
    }
  ],
  "cpu": 256,
  "memory": 512,
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/ecs/your-service",
      "awslogs-region": "eu-west-1",
      "awslogs-stream-prefix": "collector"
    }
  },
  "healthCheck": {
    "command": ["CMD-SHELL", "wget -q --spider http://localhost:13133/ || exit 1"],
    "interval": 10,
    "timeout": 5,
    "retries": 3,
    "startPeriod": 10
  }
}
```

The YAML needs to be escaped as a single-line JSON string in the `value` field. In the demo's `setup.sh`, this is handled automatically by piping the heredoc through `python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'`. For production, most IaC tools (Terraform, CDK, Pulumi) handle this escaping natively — see step 5.

**Option 2: Config baked into a custom image** (production-grade):

Create a Dockerfile:

```dockerfile
FROM otel/opentelemetry-collector-contrib:0.120.0
COPY otel-collector-config.yaml /etc/otelcol-contrib/config.yaml
```

Build and push:

```bash
docker build -t your-ecr-repo/otel-collector:v1 .
docker push your-ecr-repo/otel-collector:v1
```

Then the container definition is simpler — no `command` override, no config in env vars:

```json
{
  "name": "otel-collector",
  "image": "123456789.dkr.ecr.eu-west-1.amazonaws.com/otel-collector:v1",
  "essential": true,
  "environment": [
    { "name": "DASH0_OTLP_ENDPOINT", "value": "api.eu-west-1.aws.dash0.com:4317" }
  ],
  "secrets": [
    {
      "name": "DASH0_AUTH_TOKEN",
      "valueFrom": "arn:aws:secretsmanager:eu-west-1:123456789:secret:dash0/auth-token-AbCdEf"
    }
  ]
  // ... same ports, healthCheck, logConfiguration as above
}
```

**When to choose which:** Use option 1 for demos and quick starts. Use option 2 when you want immutable, versioned config — you know exactly what's running because it's tied to the image tag.

### Step 4: Register the Task Definition and Deploy

```bash
# Register the updated task definition
aws ecs register-task-definition \
    --cli-input-json file://task-definition.json \
    --region eu-west-1

# Update the service to use the new task definition (rolling deploy)
aws ecs update-service \
    --cluster your-cluster \
    --service your-service \
    --task-definition your-service \
    --region eu-west-1

# Wait for the new task to reach steady state
aws ecs wait services-stable \
    --cluster your-cluster \
    --services your-service \
    --region eu-west-1
```

### Step 5: IaC Examples

**Terraform** (most common for ECS customers):

```hcl
# In your task definition's container_definitions JSON
container_definitions = jsonencode([
  {
    name  = "app"
    image = "your-app:latest"
    environment = [
      { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
      { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "grpc" },
    ]
    dependsOn = [{ containerName = "otel-collector", condition = "HEALTHY" }]
    # ... rest of app config
  },
  {
    name    = "otel-collector"
    image   = "otel/opentelemetry-collector-contrib:0.120.0"
    command = ["--config=env:OTEL_COLLECTOR_CONFIG"]
    environment = [
      { name = "OTEL_COLLECTOR_CONFIG", value = file("otel-collector-config.yaml") },
      { name = "DASH0_OTLP_ENDPOINT",  value = var.dash0_endpoint },
    ]
    secrets = [{ name = "DASH0_AUTH_TOKEN", valueFrom = aws_secretsmanager_secret.dash0.arn }]
    # ... ports, healthCheck, logConfiguration
  }
])
```

Note: Terraform's `file()` function reads the YAML as a string and `jsonencode` handles the JSON escaping — no manual escaping needed.

**AWS CDK (TypeScript):**

```typescript
const collectorConfig = fs.readFileSync('otel-collector-config.yaml', 'utf-8');

taskDefinition.addContainer('otel-collector', {
  image: ecs.ContainerImage.fromRegistry('otel/opentelemetry-collector-contrib:0.120.0'),
  command: ['--config=env:OTEL_COLLECTOR_CONFIG'],
  environment: {
    OTEL_COLLECTOR_CONFIG: collectorConfig,
    DASH0_OTLP_ENDPOINT: 'api.eu-west-1.aws.dash0.com:4317',
  },
  secrets: {
    DASH0_AUTH_TOKEN: ecs.Secret.fromSecretsManager(dash0Secret),
  },
  cpu: 256,
  memoryLimitMiB: 512,
  healthCheck: {
    command: ['CMD-SHELL', 'wget -q --spider http://localhost:13133/ || exit 1'],
    interval: cdk.Duration.seconds(10),
    startPeriod: cdk.Duration.seconds(10),
  },
  logging: new ecs.AwsLogDriver({ streamPrefix: 'collector' }),
});
```

### Step 6: Verify It's Working

After deployment:

1. **Check the collector started.** In CloudWatch Logs, look at the `collector` log stream. On success you'll see the collector's startup banner with the pipeline config. On failure, you'll see a YAML parse error or a missing processor error — both are clear and actionable.

2. **Send a test request.** Hit your service's endpoint and check Dash0 for traces.

3. **Verify resource attributes.** In Dash0, open a trace and inspect the resource attributes. You should see:
   - `aws.ecs.cluster.arn` — the cluster ARN (injected by the collector)
   - `aws.ecs.task.arn` — the specific running task (injected by the collector)
   - `cloud.availability_zone` — the AZ (injected by the collector)
   - `service.name` — your app's name (set by the SDK, preserved by the collector)

   If you see `cloud.provider` and `cloud.platform` but **not** `aws.ecs.cluster.arn`, the `resourcedetection` processor's `ecs` detector isn't reaching the Task Metadata Endpoint. Ensure the task is running on Fargate (TMDE v4) and the collector has network access within the task.

4. **Verify health check filtering.** If your ALB has a health check, you should **not** see `/health` spans in Dash0. If you do, the filter processor isn't matching — check the attribute name (`http.target` vs `url.path` depends on OTel SDK version and HTTP semantic conventions version).

### Common Customizations

Once the basic sidecar is running, these are the most frequent things customers want to add:

**Add a new processor (e.g., PII redaction):**

1. Add the processor definition to the YAML:
   ```yaml
   processors:
     attributes/redact:
       actions:
         - key: db.statement
           action: hash
         - key: user.email
           action: delete
   ```
2. Wire it into the pipeline(s) — insert it between `resourcedetection` and `filter/health`:
   ```yaml
   traces:
     processors: [memory_limiter, resourcedetection, attributes/redact, filter/health, batch]
   ```
3. Redeploy (update env var or rebuild custom image, then update the ECS service).

**Filter more span types:**

```yaml
processors:
  filter/noise:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["http.target"] == "/ready"'
        - 'attributes["http.target"] == "/metrics"'
        - 'name == "fs.readFile"'              # drop filesystem spans
```

**Add custom resource attributes (e.g., team, cost center):**

```yaml
processors:
  resource/tags:
    attributes:
      - key: team
        value: payments
        action: upsert
      - key: cost_center
        value: CC-1234
        action: upsert
```

**Export to multiple backends (e.g., Dash0 + CloudWatch):**

```yaml
exporters:
  otlp/dash0:
    endpoint: ${DASH0_OTLP_ENDPOINT}
    headers:
      Authorization: "Bearer ${DASH0_AUTH_TOKEN}"
  awsxray:                          # requires ADOT or contrib image
    region: eu-west-1

service:
  pipelines:
    traces:
      exporters: [otlp/dash0, awsxray]   # fan-out to both
```

**Tail sampling (only export interesting traces):**

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: errors-always
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-always
        type: latency
        latency: { threshold_ms: 1000 }
      - name: sample-rest
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }
```

Note: tail sampling requires holding complete traces in memory. This increases collector memory usage significantly. Only use when you have a clear cost-reduction need and understand the memory implications.

### Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| App container stuck in PENDING | Collector not healthy → `dependsOn` blocks app start | Check collector logs in CloudWatch. Common: YAML parse error, wrong image (core vs contrib), auth failure to Dash0. |
| Traces appear in Dash0 but no `aws.ecs.*` attributes | `resourcedetection` not in the pipeline, or `ecs` not in `detectors` list | Verify the pipeline includes `resourcedetection` and the processor config includes `detectors: [ecs]`. |
| `aws.ecs.*` attributes present but `cloud.availability_zone` missing | `ec2` detector not enabled | Add `ec2` to the detectors list: `detectors: [env, ecs, ec2]`. The AZ comes from the EC2 metadata API. |
| `/health` spans still showing in Dash0 | Filter attribute name mismatch | OTel HTTP semantic conventions changed from `http.target` to `url.path` in newer SDK versions. Add both to the filter. |
| Collector OOM-killed | `memory_limiter` not configured or limits too high | Add or lower `limit_mib`. For 512 MB container, use `limit_mib: 400, spike_limit_mib: 100`. |
| `400 Bad Request` from Dash0 exporter | Malformed spans or wrong endpoint | Check the collector logs for the full error. Common: using HTTP endpoint with gRPC exporter, or wrong port. Dash0 gRPC is port 4317. |
| Collector starts but no data flows | App still pointing at Dash0 directly instead of localhost | Check the app's `OTEL_EXPORTER_OTLP_ENDPOINT` — must be `http://localhost:4317`, not the Dash0 endpoint. |

## What the Sidecar Actually Gives You

### 1. Automatic ECS Infrastructure Metadata

The `resourcedetection` processor with the `ecs` detector queries the ECS Task Metadata Endpoint (TMDE v3/v4) and stamps every span, log, and metric with:

| Attribute | Example Value | Why It Matters |
|-----------|--------------|----------------|
| `aws.ecs.cluster.arn` | `arn:aws:ecs:ap-southeast-1:123:cluster/prod` | Identify which cluster |
| `aws.ecs.task.arn` | `arn:aws:ecs:...:task/abc123` | Identify the specific task instance |
| `aws.ecs.task.family` | `payments-service` | Task definition family |
| `aws.ecs.task.revision` | `14` | Which version of the task def |
| `aws.ecs.launchtype` | `FARGATE` | Launch type |
| `aws.ecs.container.arn` | `arn:aws:ecs:...:container/xyz` | Container-level granularity |
| `cloud.provider` | `aws` | Cloud provider |
| `cloud.platform` | `aws_ecs` | Platform |
| `cloud.region` | `ap-southeast-1` | Region |
| `cloud.account.id` | `123456789012` | AWS account |
| `cloud.availability_zone` | `ap-southeast-1a` | AZ (useful for failure correlation) |
| `container.name` | `app` | Container name within the task |
| `container.id` | `d4e5f6...` | Container ID |

Without a collector, you only get what you manually set in `OTEL_RESOURCE_ATTRIBUTES` — which is static. The collector gets the *actual* runtime identifiers dynamically. When you scale to multiple tasks, this is how you tell them apart in Dash0.

**Collector config for this:**

```yaml
processors:
  resourcedetection:
    detectors: [ecs, ec2]
    timeout: 5s
    override: false   # don't overwrite attributes the SDK already set
```

### 2. Batching

The `batch` processor groups spans/logs before export. Reduces outbound HTTPS calls, lowers network overhead, and is gentler on Dash0's ingest API.

```yaml
processors:
  batch:
    send_batch_size: 512
    timeout: 5s
    send_batch_max_size: 1024
```

Without batching, the SDK sends each span/log individually (or in small internal batches). At scale — say 50 ECS tasks each doing hundreds of requests/second — this multiplies into thousands of outbound calls. The collector consolidates them.

### 3. Memory Limiter (Back-Pressure Protection)

If the app suddenly floods telemetry (retry storm, traffic spike, log explosion), the `memory_limiter` processor drops data gracefully instead of OOM-killing the collector.

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 100
    spike_limit_mib: 30
```

This is especially relevant for high-throughput services. Without it, a telemetry spike can crash the export pipeline — which for direct export means the *app process itself* is holding onto data during failures.

### 4. Filtering (Cost and Noise Control)

Drop telemetry you don't want in Dash0 before it leaves your VPC:

```yaml
processors:
  filter:
    traces:
      span:
        - 'attributes["http.route"] == "/health"'
        - 'attributes["http.route"] == "/ready"'
```

Health check spans every 15 seconds from an ALB are a classic example — they add noise and cost but zero debugging value. Filter them at the collector, not in Dash0.

### 5. Attribute Transformation and PII Redaction

The `transform` and `attributes` processors let you rename, delete, or hash attributes before they leave your VPC.

```yaml
processors:
  attributes:
    actions:
      - key: db.statement
        action: hash       # hash SQL queries so they're groupable but not readable
      - key: user.email
        action: delete     # strip PII
      - key: http.request.header.authorization
        action: delete     # never export auth headers
```

For regulated industries (fintech, healthcare, crypto payments) this is often a hard requirement — sensitive data must not leave the VPC in plaintext. With direct export, you'd need to do this in app code.

### 6. Log Enrichment and Routing

When logs come through FireLens (fluent-bit) or awslogs, the raw log body is a nested JSON blob. Without a collector to parse and promote fields, Dash0 sees a flat `body` string and attribution gets lost.

The collector can:
- Extract `trace_id`, `span_id` from structured log bodies into proper attributes (enabling log/trace correlation)
- Add `service.name` and resource attributes to logs that don't have them (e.g., infrastructure logs)
- Route different log levels to different pipelines (e.g., ERROR logs get exported, DEBUG logs get dropped)

### 7. Retry Buffering

The collector's exporter handles retries with configurable backoff. If Dash0's endpoint is briefly unreachable, the collector buffers in memory (or optionally to disk). With direct export, the SDK does retrying — tying up app threads during transient failures.

```yaml
exporters:
  otlp:
    endpoint: api.eu-west-1.aws.dash0.com:4317
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
```

## Decision Framework

| Scenario | Recommendation |
|----------|---------------|
| Demo, POC, getting started | **Direct export.** Ship in 5 minutes, no extra infra, no extra cost. |
| Single service, low traffic (<100 rps) | **Direct export** is fine. Add sidecar later if needed. |
| Multiple services, production | **Sidecar collector.** You need the metadata, filtering, and batching. Budget ~$7–15/month/task for the overhead. |
| Regulated industry (fintech, health) | **Sidecar collector.** PII redaction before data leaves the VPC is likely a hard requirement. The overhead cost is negligible vs. compliance risk. |
| High cardinality / high traffic (>1000 rps) | **Sidecar collector.** Batching and memory limiting prevent telemetry from becoming a scaling bottleneck. May need to bump collector memory allocation beyond 512 MB. |
| Need log/trace correlation from container logs | **Sidecar collector.** Needed to enrich and correlate logs that don't come from the OTel SDK directly. |
| Already using FireLens or fluent-bit | **Sidecar collector.** Pipe fluent-bit output through the collector for OTLP conversion and enrichment. |
| Cost-sensitive, large fleet (50+ tasks) | **Consider a central collector** (shared ECS service behind an ALB) instead of per-task sidecars. Reduces total collector instances from N to 2–3, at the cost of an extra network hop and more complex scaling. |
| Large fleet + needs per-task metadata | **Sidecar with tight sizing.** Use 128 MB / 0.25 vCPU per collector. Build a custom image with `ocb` to minimize startup time and memory footprint. |

**The graduation path:** Start with direct export → validate traces and logs appear in Dash0 → add a sidecar collector when moving to production. This avoids premature complexity while giving a clear upgrade path.

## Demo Tips

- **For a quick demo**, use direct export (the `ecs-demo` kit does this). It deploys in 4 minutes and shows traces + logs immediately.
- **To show the sidecar value**, point out the static `OTEL_RESOURCE_ATTRIBUTES` in the task definition and say: "Right now we're hardcoding `cloud.provider=aws`. With a collector sidecar, the `resourcedetection` processor fills in the cluster ARN, task ARN, AZ, and container ID automatically — per running instance."
- **For customers who ask "why not just CloudWatch?"** — the collector gives them a single pipeline for traces, logs, and metrics to one backend. CloudWatch + X-Ray = two systems, two UIs, manual correlation.
- **Don't lead with the sidecar** in early conversations. It adds perceived complexity. Lead with "5 env vars, done." Then introduce the collector as the production upgrade.

## Three Options for ECS Log Shipping

1. **Direct OTLP export from the app** — the app's OTel SDK exports logs directly. Simplest. Good for getting started.
2. **FireLens + fluent-bit sidecar** — AWS-managed log routing. Use the latest fluent-bit image (not the AWS-provided one, which lacks OTLP export). Tested and deployed successfully in customer engagements.
3. **CloudWatch logs → Dash0 integration** — zero change to the ECS task. Just enable the Dash0 CloudWatch-for-logs integration. Lowest effort but adds latency and loses some structured metadata.

## Sources & References

- [OTel Collector resourcedetection processor — ECS detector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourcedetectionprocessor/README.md)
- [Dash0: Resource Fragmentation Scenarios](https://dash0.com/docs/dash0/monitoring/resources/recognize-common-resource-fragmentation-scenarios)
- [Dash0: Batch Processor Guide](https://dash0.com/guides/opentelemetry-batch-processor)
- [Dash0: Resource Processor Guide](https://dash0.com/guides/opentelemetry-resource-processor)
- [OTel Collector Scaling Guide](https://opentelemetry.io/docs/collector/scaling/)
- [OTel Collector Resiliency](https://opentelemetry.io/docs/collector/resiliency/)
- Internal: FireLens config discussion in `#sa-support` (Mar 18, 2026)
- Internal: Collector scaling guidance in `#dash0-vibeiq` (Mar 9, 2026)
