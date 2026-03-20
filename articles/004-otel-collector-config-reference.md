---
title: "OTel Collector Configuration Reference for ECS + Dash0"
id: 004
author: Barry Solomon
created: 2026-03-19
updated: 2026-03-19
tags: [otel-collector, config, yaml, processors, exporters, resourcedetection, batch, filter, ecs]
audience: SA, SE, DevOps, Platform Engineer
status: published
---

# OTel Collector Configuration Reference for ECS + Dash0

## TL;DR

The collector config is a single YAML file with receivers, processors, exporters, and a service section that wires them into pipelines. Processor order matters — `memory_limiter` first, `batch` last. This reference covers every processor you'll need for ECS + Dash0, plus common customizations.

## YAML Structure Overview

Every OTel Collector config has the same top-level shape:

```yaml
extensions:      # optional — add health checks, profiling, etc.
receivers:       # what the collector listens on (OTLP gRPC/HTTP, typically localhost:4317)
processors:      # what it does to the data (enrich, filter, batch, redact — in order)
exporters:       # where it sends the data (Dash0 OTLP endpoint + auth)
service:
  extensions:    # enable extensions here
  pipelines:     # wires receivers → processors → exporters per signal type
    traces:  { receivers: [otlp], processors: [memory_limiter, resourcedetection, filter/health, batch], exporters: [otlp/dash0] }
    logs:    { receivers: [otlp], processors: [memory_limiter, resourcedetection, batch], exporters: [otlp/dash0] }
    metrics: { receivers: [otlp], processors: [memory_limiter, resourcedetection, batch], exporters: [otlp/dash0] }
  telemetry:
    logs:
      level: warn                   # collector's own logging — keep quiet unless debugging
```

**Critical rules:**
- Processors execute **in the order listed** in the pipeline array.
- `memory_limiter` should always be **first** (protects against OOM before other processors consume memory).
- `batch` should always be **last** (batches the final processed data for efficient export).
- Environment variables in YAML (e.g., `${DASH0_OTLP_ENDPOINT}`) are resolved by the collector at runtime — set them in the ECS task definition or Secrets Manager.

---

## Minimum Production-Ready Config

Copy this to get started with ECS + Dash0:

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
  memory_limiter:
    check_interval: 1s
    limit_mib: 150
    spike_limit_mib: 50

  resourcedetection:
    detectors: [env, ecs, ec2]
    timeout: 5s
    override: false

  filter/health:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["url.path"] == "/health"'

  batch:
    send_batch_size: 512
    timeout: 5s
    send_batch_max_size: 1024

exporters:
  otlp/dash0:
    endpoint: ${DASH0_OTLP_ENDPOINT}
    headers:
      Authorization: "Bearer ${DASH0_AUTH_TOKEN}"
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
      level: warn
```

---

## What the Sidecar Actually Gives You

### 1. Automatic ECS Infrastructure Metadata

The `resourcedetection` processor with the `ecs` detector queries the ECS Task Metadata Endpoint (TMDE v3/v4) and stamps every span, log, and metric with runtime identifiers.

**Attributes automatically added:**

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

Without a collector, you only get what you manually set in `OTEL_RESOURCE_ATTRIBUTES` — which is static. The collector gets the actual runtime identifiers dynamically. When you scale to multiple tasks, this is how you tell them apart in Dash0.

**Processor config:**

```yaml
processors:
  resourcedetection:
    detectors: [env, ecs, ec2]      # env: reads OTEL_RESOURCE_ATTRIBUTES
    timeout: 5s                     # ecs: queries Task Metadata Endpoint
    override: false                 # ec2: adds cloud.account.id, AZ, etc.
                                    # override: false = don't overwrite what SDK set
```

### 2. Batching

The `batch` processor groups spans/logs before export. Reduces outbound HTTPS calls, lowers network overhead, and is gentler on Dash0's ingest API.

Without batching, the SDK sends each span/log individually (or in small internal batches). At scale — say 50 ECS tasks each doing hundreds of requests/second — this multiplies into thousands of outbound calls. The collector consolidates them.

**Processor config:**

```yaml
processors:
  batch:
    send_batch_size: 512            # flush when this many items collected
    timeout: 5s                     # or after this duration, whichever first
    send_batch_max_size: 1024       # never exceed this size per batch
```

### 3. Memory Limiter (Back-Pressure Protection)

If the app suddenly floods telemetry (retry storm, traffic spike, log explosion), the `memory_limiter` processor drops data gracefully instead of OOM-killing the collector.

This is especially relevant for high-throughput services. Without it, a telemetry spike can crash the export pipeline — which for direct export means the app process itself is holding onto data during failures.

**Processor config:**

```yaml
processors:
  memory_limiter:
    check_interval: 1s              # how often to check memory usage
    limit_mib: 100                  # hard limit — starts dropping data
    spike_limit_mib: 30             # soft limit — starts refusing data before hitting hard limit
```

**Sizing:** For a 512 MB container, use `limit_mib: 400, spike_limit_mib: 100`. For 256 MB, use `limit_mib: 150, spike_limit_mib: 50`.

### 4. Filtering (Cost and Noise Control)

Drop telemetry you don't want in Dash0 before it leaves your VPC. Health check spans every 15 seconds from an ALB are a classic example — they add noise and cost but zero debugging value.

**Processor config:**

```yaml
processors:
  filter/health:
    error_mode: ignore              # don't error if no match
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["url.path"] == "/health"'
        - 'attributes["http.target"] == "/ready"'
        - 'attributes["http.target"] == "/metrics"'
        - 'name == "fs.readFile"'   # drop filesystem spans
```

Wire it into the pipeline: `processors: [memory_limiter, resourcedetection, filter/health, batch]`

### 5. Attribute Transformation and PII Redaction

The `transform` and `attributes` processors let you rename, delete, or hash attributes before they leave your VPC.

For regulated industries (fintech, healthcare, crypto payments) this is often a hard requirement — sensitive data must not leave the VPC in plaintext. With direct export, you'd need to do this in app code.

**Processor config:**

```yaml
processors:
  attributes/redact:
    actions:
      - key: db.statement
        action: hash                # hash SQL queries so they're groupable but not readable
      - key: user.email
        action: delete              # strip PII
      - key: http.request.header.authorization
        action: delete              # never export auth headers
      - key: customer.credit_card
        action: delete              # strip payment card data
```

Wire it into the traces pipeline: `processors: [memory_limiter, resourcedetection, attributes/redact, filter/health, batch]`

### 6. Log Enrichment and Routing

When logs come through FireLens (fluent-bit) or awslogs, the raw log body is a nested JSON blob. Without a collector to parse and promote fields, Dash0 sees a flat `body` string and attribution gets lost.

The collector can:
- Extract `trace_id`, `span_id` from structured log bodies into proper attributes (enabling log/trace correlation)
- Add `service.name` and resource attributes to logs that don't have them (e.g., infrastructure logs)
- Route different log levels to different pipelines (e.g., ERROR logs get exported, DEBUG logs get dropped)

**Example — extract trace_id from a log body:**

```yaml
processors:
  parse_json/logs:
    parse_from: body
    parse_to: attributes
  resource_log_processor:
    attributes:
      - key: service.name
        value: my-service
        action: upsert
```

### 7. Retry Buffering

The collector's exporter handles retries with configurable backoff. If Dash0's endpoint is briefly unreachable, the collector buffers in memory (or optionally to disk). With direct export, the SDK does retrying — tying up app threads during transient failures.

**Exporter config (included in "Minimum Production-Ready Config" above):**

```yaml
exporters:
  otlp/dash0:
    endpoint: ${DASH0_OTLP_ENDPOINT}
    headers:
      Authorization: "Bearer ${DASH0_AUTH_TOKEN}"
    retry_on_failure:
      enabled: true
      initial_interval: 5s          # wait 5s before first retry
      max_interval: 30s             # cap backoff at 30s
      max_elapsed_time: 300s        # give up after 5 minutes
```

---

## Common Customizations

### Add PII Redaction

1. Define the processor:
   ```yaml
   processors:
     attributes/redact:
       actions:
         - key: db.statement
           action: hash
         - key: user.email
           action: delete
   ```

2. Wire it into the traces pipeline:
   ```yaml
   service:
     pipelines:
       traces:
         processors: [memory_limiter, resourcedetection, attributes/redact, filter/health, batch]
   ```

3. Redeploy (update env var or rebuild custom image, then update the ECS service).

### Filter More Span Types

Extend the `filter/health` processor or create a new one:

```yaml
processors:
  filter/noise:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["http.target"] == "/ready"'
        - 'attributes["http.target"] == "/metrics"'
        - 'name == "fs.readFile"'
        - 'attributes["span.kind"] == "INTERNAL"'
```

### Add Custom Resource Attributes (team, cost center)

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

Then wire it into all pipelines: `processors: [memory_limiter, resourcedetection, resource/tags, batch]`

### Export to Multiple Backends (Dash0 + CloudWatch + X-Ray)

```yaml
exporters:
  otlp/dash0:
    endpoint: ${DASH0_OTLP_ENDPOINT}
    headers:
      Authorization: "Bearer ${DASH0_AUTH_TOKEN}"
  awsxray:                          # requires ADOT or contrib image
    region: eu-west-1
  awsemf:                           # for CloudWatch metrics
    region: eu-west-1

service:
  pipelines:
    traces:
      exporters: [otlp/dash0, awsxray]     # fan-out to both
    metrics:
      exporters: [otlp/dash0, awsemf]      # fan-out to both
```

### Tail Sampling (Only Export Interesting Traces)

Tail sampling buffers complete traces in memory, then decides whether to export based on policies. Useful for cost reduction when trace volume is high and you only care about errors/slow requests.

```yaml
processors:
  tail_sampling:
    decision_wait: 10s              # wait up to 10s for trace completion
    policies:
      - name: errors-always
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-always
        type: latency
        latency: { threshold_ms: 1000 }
      - name: sample-rest
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }   # sample 10% of others
```

**Warning:** Tail sampling requires holding complete traces in memory. This increases collector memory usage significantly — often 2–3x. Only use when you have a clear cost-reduction need and understand the memory implications.

---

## Config Delivery Methods

| Method | How It Works | Change Workflow | Best For |
|--------|-------------|-----------------|----------|
| **Environment variable** | Full YAML injected as an env var in the task definition. Collector reads it via `--config=env:OTEL_COLLECTOR_CONFIG`. | Edit the task definition JSON → register new revision → update service (rolling deploy). | Demos, POCs, small teams. Simple but the YAML is embedded in infra code. |
| **`AOT_CONFIG_CONTENT`** (ADOT only) | Same as above but using the AWS ADOT Collector's native env var. | Same as above. | AWS-native shops already using ADOT. |
| **SSM Parameter Store** | Store the YAML in SSM. A startup script or entrypoint in a custom image fetches it at container boot. | Update the SSM parameter → redeploy tasks (or wait for next scale event). Config is decoupled from the task definition. | Production teams that want config separate from infra. Supports versioning and audit trail via SSM. |
| **Baked into a custom image** | Build a Dockerfile that copies the YAML into the collector image at build time (`COPY otel-config.yaml /etc/otelcol/config.yaml`). | Edit YAML → rebuild image → push to ECR → update task definition → rolling deploy. | Production at scale. Config is immutable per image tag — you know exactly what's running. Pairs well with `ocb` custom builds. |

---

## Observing the Collector Itself

A key challenge: **the invisible failure scenario**. The app sees no errors, the health check passes, but exports are silently failing. Detect this through collector observability:

### zpages Extension

Provides an HTTP diagnostic UI at a specified port. Shows live collector state, pipeline status, and recent exports.

**Config:**

```yaml
extensions:
  zpages:
    endpoint: 0.0.0.0:55679         # diagnostic UI on this port

service:
  extensions: [health_check, zpages]
```

**Access on ECS Fargate:**
- Add port 55679 to the collector container's port mappings.
- In CloudWatch Container Insights or ECS console, see the collector's private IP.
- From a bastion or another task in the same VPC: `curl http://<collector-ip>:55679/debug/servicez`

**What it shows:**
- Active receivers, processors, exporters
- Queue depths
- Number of spans/logs/metrics in flight
- Export success/failure rates (real-time)

### Debug Exporter

Dumps telemetry to stdout (which flows to CloudWatch Logs). Verbosity levels control output volume.

**Config:**

```yaml
exporters:
  logging/debug:
    loglevel: debug

service:
  pipelines:
    traces:
      exporters: [otlp/dash0, logging/debug]   # export to both Dash0 and debug logs
```

**Verbosity levels:** `info` (minimal), `debug` (full attributes), `trace` (with raw proto). Use `debug` for development, `info` for production. The debug exporter dumps ~1 KB per span to CloudWatch Logs — at scale this becomes expensive.

### Prometheus Internal Metrics

The collector exposes internal metrics on port 8888 (default). Scrape these to detect export failures:

**Key metrics:**

```
otelcol_exporter_sent_spans         # spans successfully exported
otelcol_exporter_send_failed_spans   # export failures (THIS ONE MATTERS)
otelcol_receiver_accepted_spans      # spans received from app
otelcol_exporter_queue_size          # number of items waiting in export queue
otelcol_processor_batch_batch_send_size_count  # histogram of batch sizes
otelcol_processor_memory_limiter_refused_spans # data dropped due to memory pressure
```

**The invisible failure:** If `otelcol_receiver_accepted_spans` is high but `otelcol_exporter_sent_spans` is flat, data is being received but not exported. Check:
- Network connectivity from collector to Dash0
- Auth token in `DASH0_AUTH_TOKEN` secret
- Exporter configuration

**How to scrape on Fargate:**
- Expose port 8888 in the collector container definition.
- Use CloudWatch Container Insights to scrape metrics from the task.
- Or run a separate Prometheus instance in your VPC and scrape the collector tasks.

---

## OTelBin

Use [otelbin.io](https://otelbin.io) to validate configs before deploying. Paste your YAML and it will:
- Check syntax (YAML parsing)
- Verify all referenced processors/exporters exist in the image
- Warn about invalid processor chains
- Suggest improvements

This catches YAML typos and missing processors at dev time instead of at 3am in production.

---

## Cross-References

- **For deciding whether you need a sidecar**, see [001 — OTel Collector Sidecar vs. Direct OTLP Export on AWS ECS Fargate](001-ecs-sidecar-vs-direct-export.md)
- **For step-by-step ECS integration and IaC examples**, see [003 — OTel Collector Sidecar Setup on ECS Fargate](003-sidecar-setup-ecs.md) (coming soon)

---

## Sources & References

- [OTel Collector resourcedetection processor — ECS detector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourcedetectionprocessor/README.md)
- [OTel Collector Batch Processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md)
- [OTel Collector Attributes Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/attributesprocessor/README.md)
- [OTel Collector Filter Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/filterprocessor/README.md)
- [OTel Collector Tail Sampling Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md)
- [OTel Collector Memory Limiter Processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md)
- [OTel Collector Scaling Guide](https://opentelemetry.io/docs/collector/scaling/)
- [OTel Collector Resiliency](https://opentelemetry.io/docs/collector/resiliency/)
- [Dash0: Resource Fragmentation Scenarios](https://dash0.com/docs/dash0/monitoring/resources/recognize-common-resource-fragmentation-scenarios)
- [OTelBin — Config Validator](https://otelbin.io)
