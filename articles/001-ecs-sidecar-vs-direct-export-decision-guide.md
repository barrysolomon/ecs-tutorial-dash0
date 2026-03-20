---
title: "ECS Observability: Sidecar vs. Direct Export — Decision Guide"
id: 001
author: Barry Solomon
created: 2026-03-19
updated: 2026-03-19
tags: [ecs, fargate, otel-collector, sidecar, architecture, aws, decision-guide]
audience: SA, SE, CSM
status: published
---

# ECS Observability: Sidecar vs. Direct Export — Decision Guide

## TL;DR

Direct OTLP export sends telemetry straight from the app SDK to Dash0 — zero infrastructure, 5-minute setup, perfect for getting started and demos. An OTel Collector sidecar sits between the app and Dash0 and adds automatic infrastructure metadata (task ARN, cluster, AZ), batching, filtering, PII redaction, retry buffering, and log enrichment. Start with direct export, graduate to a sidecar when moving to production with multiple services.

## Context

This comes up in every ECS prospect conversation. Customers migrating to ECS (especially from Elastic Beanstalk, EC2, or Lambda) want to know the simplest path to observability — but also need to understand the production-grade architecture. The typical SA recommendation is the sidecar approach; the Dash0 ECS demo uses direct export for simplicity. Both are valid. The question is: what does the sidecar actually *give* you?

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

**Cons:**
- No automatic ECS metadata enrichment — you manually set `OTEL_RESOURCE_ATTRIBUTES` in the task definition, but these are static across all instances.
- No filtering, batching, or transformation outside the SDK. Every container makes its own outbound HTTPS connections.
- Retry/buffering is limited to what the SDK provides — under transient failures, threads block waiting for retries.
- No PII redaction before data leaves the VPC — sensitive attributes must be scrubbed in application code.
- No log enrichment from infrastructure logs (CloudWatch, FireLens) — correlation between app logs and structured logs gets lost.
- At scale (50+ tasks), each task opens its own HTTPS connection to Dash0 — inefficient and harder to rate-limit.

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

**Pros:**
- Automatic ECS metadata enrichment — the `resourcedetection` processor queries the Task Metadata Endpoint and stamps every signal with cluster ARN, task ARN, AZ, container ID, etc. This happens dynamically per instance, not statically.
- Full pipeline control — enrichment, filtering, batching, transformation, PII redaction, and retry all in one place.
- Single outbound connection per task — the collector manages auth to Dash0, reducing per-container overhead.
- Decouples the app from Dash0's backend — app doesn't know about or depend on Dash0's endpoint; the collector can switch backends without redeploying.

**Cons:**
- **Additional memory and CPU per task.** The collector sidecar consumes real resources. In the demo we allocate 256 CPU units (0.25 vCPU) and 512 MB RAM. In production, typical sizing is 128–512 MB RAM / 0.25 vCPU, but high-throughput services may need more. This cost is **per task** — if you're running 50 tasks, that's 50 collector instances.
- **Increased Fargate cost.** Because Fargate bills on task-level CPU+memory, bumping from 512/1024 to 1024/2048 to accommodate the sidecar roughly doubles the compute cost per task. For a single service in a POC this might be $7–15/month, but for a production fleet of 50 tasks, this becomes $350–750/month.
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

## How Users Configure the Collector Pipeline

The collector's behavior is defined in a single YAML config file. This config specifies receivers (what the collector listens on), processors (what it does to the data), and exporters (where it sends the data). On ECS Fargate, there are four ways to get this config into the sidecar container — each with different trade-offs for ease of change vs. operational maturity:

| Method | How It Works | Change Workflow | Best For |
|--------|-------------|-----------------|----------|
| **Environment variable** | Full YAML injected as an env var in the task definition. Collector reads it via `--config=env:OTEL_COLLECTOR_CONFIG`. | Edit the task definition JSON → register new revision → update service (rolling deploy). | Demos, POCs, small teams. Simple but the YAML is embedded in infra code. |
| **`AOT_CONFIG_CONTENT`** (ADOT only) | Same as above but using the AWS ADOT Collector's native env var. | Same as above. | AWS-native shops already using ADOT. |
| **SSM Parameter Store** | Store the YAML in SSM. A startup script or entrypoint in a custom image fetches it at container boot. | Update the SSM parameter → redeploy tasks (or wait for next scale event). Config is decoupled from the task definition. | Production teams that want config separate from infra. Supports versioning and audit trail via SSM. |
| **Baked into a custom image** | Build a Dockerfile that copies the YAML into the collector image at build time (`COPY otel-config.yaml /etc/otelcol/config.yaml`). | Edit YAML → rebuild image → push to ECR → update task definition → rolling deploy. | Production at scale. Config is immutable per image tag — you know exactly what's running. Pairs well with `ocb` custom builds. |

## Resource Overhead: Real Numbers

| Configuration | Task CPU | Task Memory | Collector Share | Monthly Fargate Cost (1 task, eu-west-1) |
|---------------|----------|-------------|-----------------|------------------------------------------|
| Direct export (no sidecar) | 512 (0.5 vCPU) | 1024 MB | 0% | ~$15 |
| Sidecar (demo sizing) | 1024 (1 vCPU) | 2048 MB | 25% CPU / 25% RAM | ~$30 |
| Sidecar (tight production) | 768 (0.75 vCPU) | 1536 MB | 17% CPU / 17% RAM | ~$22 |

*Costs are approximate, 24/7 on-demand, single task. Multiply by task count for fleet cost.*

The overhead is real but modest. For most services, the observability value (faster debugging, proactive alerting, SLO tracking) far outweighs the ~$7–15/month/task collector cost. The conversation with cost-conscious customers should be: "Would you rather pay $15/month extra per service, or spend 4 hours debugging a production incident blind?"

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

## Cross-References

For instrumentation setup details, see **002 — Instrumenting Apps for OTel on ECS**

For step-by-step sidecar setup, see **003 — OTel Collector Sidecar Setup on ECS Fargate**

For collector configuration and customization, see **004 — OTel Collector Configuration Reference**

## Sources & References

- [OTel Collector resourcedetection processor — ECS detector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourcedetectionprocessor/README.md)
- [Dash0: Resource Fragmentation Scenarios](https://dash0.com/docs/dash0/monitoring/resources/recognize-common-resource-fragmentation-scenarios)
- [Dash0: Batch Processor Guide](https://dash0.com/guides/opentelemetry-batch-processor)
- [Dash0: Resource Processor Guide](https://dash0.com/guides/opentelemetry-resource-processor)
- [OTel Collector Scaling Guide](https://opentelemetry.io/docs/collector/scaling/)
- [OTel Collector Resiliency](https://opentelemetry.io/docs/collector/resiliency/)
- Internal: FireLens config discussion in `#sa-support` (Mar 18, 2026)
- Internal: Collector scaling guidance in `#dash0-vibeiq` (Mar 9, 2026)
