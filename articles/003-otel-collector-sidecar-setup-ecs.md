---
title: "OTel Collector Sidecar Setup on ECS Fargate — Step by Step"
id: 003
author: Barry Solomon
created: 2026-03-19
updated: 2026-03-19
tags: [ecs, fargate, otel-collector, sidecar, setup, aws, secrets-manager, task-definition]
audience: SA, SE, DevOps, Platform Engineer
status: published
---

# OTel Collector Sidecar Setup on ECS Fargate — Step by Step

## TL;DR

Add a collector sidecar to your ECS task in 6 steps: store the auth token in Secrets Manager, write a collector config, modify the task definition (bump resources, add the sidecar container, point the app at localhost:4317), register and deploy, then verify in Dash0.

**Related articles:**
- For deciding whether you need a sidecar, see **001 — Decision Guide**
- For app instrumentation, see **002 — Instrumenting Apps**
- For collector config customization (PII redaction, filtering, multi-backend, sampling), see **004 — Configuration Reference**

## Prerequisites

- AWS CLI configured and authenticated
- An existing ECS task definition (or you're creating one)
- A Dash0 auth token (`auth_xxxx`) — get this from Dash0 → Organization Settings → Auth Tokens
- Your Dash0 OTLP endpoint (e.g., `api.eu-west-1.aws.dash0.com:4317`)

## Step 1: Store the Dash0 Auth Token in Secrets Manager

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

## Step 2: Write the Collector Config

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

## Step 3: Add the Sidecar to Your ECS Task Definition

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
  ],
  "dependsOn": [
    { "containerName": "otel-collector", "condition": "HEALTHY" }
  ]
}
```

Note what's removed compared to direct export: no `OTEL_EXPORTER_OTLP_HEADERS` (no auth needed for localhost), no static `cloud.provider=aws,cloud.platform=aws_ecs` in resource attributes (the collector injects these dynamically).

The `dependsOn` ensures the app doesn't start until the collector is healthy — otherwise the app's first spans would fail to export.

**C. Add the collector sidecar container.** There are two sub-options here depending on how you inject the config:

### Option 1: Config via environment variable (simplest)

Used in demos and quick starts:

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

The YAML needs to be escaped as a single-line JSON string in the `value` field. In production, most IaC tools (Terraform, CDK, Pulumi) handle this escaping natively — see step 5.

### Option 2: Config baked into a custom image (production-grade)

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
  ],
  "portMappings": [
    { "containerPort": 4317, "protocol": "tcp" },
    { "containerPort": 4318, "protocol": "tcp" },
    { "containerPort": 13133, "protocol": "tcp" }
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

**When to choose which:** Use option 1 for demos and quick starts. Use option 2 when you want immutable, versioned config — you know exactly what's running because it's tied to the image tag.

## Step 4: Register the Task Definition and Deploy

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

## Step 5: IaC Examples

### Terraform

Most common for ECS customers:

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

### AWS CDK (TypeScript)

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

## Step 6: Verify It's Working

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

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| App container stuck in PENDING | Collector not healthy → `dependsOn` blocks app start | Check collector logs in CloudWatch. Common: YAML parse error, wrong image (core vs contrib), auth failure to Dash0. |
| Traces appear in Dash0 but no `aws.ecs.*` attributes | `resourcedetection` not in the pipeline, or `ecs` not in `detectors` list | Verify the pipeline includes `resourcedetection` and the processor config includes `detectors: [ecs]`. |
| `aws.ecs.*` attributes present but `cloud.availability_zone` missing | `ec2` detector not enabled | Add `ec2` to the detectors list: `detectors: [env, ecs, ec2]`. The AZ comes from the EC2 metadata API. |
| `/health` spans still showing in Dash0 | Filter attribute name mismatch | OTel HTTP semantic conventions changed from `http.target` to `url.path` in newer SDK versions. Add both to the filter. |
| Collector OOM-killed | `memory_limiter` not configured or limits too high | Add or lower `limit_mib`. For 512 MB container, use `limit_mib: 400, spike_limit_mib: 100`. |
| `400 Bad Request` from Dash0 exporter | Malformed spans or wrong endpoint | Check the collector logs for the full error. Common: using HTTP endpoint with gRPC exporter, or wrong port. Dash0 gRPC is port 4317. |
| Collector starts but no data flows | App still pointing at Dash0 directly instead of localhost | Check the app's `OTEL_EXPORTER_OTLP_ENDPOINT` — must be `http://localhost:4317`, not the Dash0 endpoint. |

## Sources & References

- [OTel Collector resourcedetection processor — ECS detector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourcedetectionprocessor/README.md)
- [Dash0: Resource Fragmentation Scenarios](https://dash0.com/docs/dash0/monitoring/resources/recognize-common-resource-fragmentation-scenarios)
- [Dash0: Batch Processor Guide](https://dash0.com/guides/opentelemetry-batch-processor)
- [Dash0: Resource Processor Guide](https://dash0.com/guides/opentelemetry-resource-processor)
- [OTel Collector Scaling Guide](https://opentelemetry.io/docs/collector/scaling/)
- [OTel Collector Resiliency](https://opentelemetry.io/docs/collector/resiliency/)
