---
title: "Instrumenting Applications for OpenTelemetry on ECS"
id: 002
author: Barry Solomon
created: 2026-03-19
updated: 2026-03-19
tags: [ecs, otel, instrumentation, auto-instrumentation, node, java, python, dotnet, go]
audience: SA, SE, Developer
status: published
---

# Instrumenting Applications for OpenTelemetry on ECS

## TL;DR

Auto-instrumentation gets you traces for HTTP, DB, and queue operations with zero code changes — just add a dependency and set environment variables in the ECS task definition. Manual instrumentation adds business-specific spans. Start auto-only, add manual for critical paths.

## Context

This topic comes up after a customer has decided to adopt Dash0 and OpenTelemetry. Before the collector has anything to collect (and before you decide between sidecar or direct export), the app needs to produce telemetry. There are two approaches: auto-instrumentation and manual instrumentation. They aren't mutually exclusive — most production setups start with auto and add manual spans for business logic.

**Related articles:**
- For deciding between sidecar and direct export, see **001 — Decision Guide**
- For setting up the collector sidecar, see **003 — Sidecar Setup**

## Auto-Instrumentation

Auto-instrumentation injects tracing into known libraries (HTTP servers, DB clients, message queues) without changing application code. How you enable it depends on the language:

| Language | How to Enable | Where It's Configured | Zero Code Changes? |
|----------|--------------|----------------------|-------------------|
| **Node.js** | `NODE_OPTIONS='-r @opentelemetry/auto-instrumentations-node/register'` or `--require @opentelemetry/auto-instrumentations-node/register` | **Task definition** (env var) or **Dockerfile** (CMD/ENTRYPOINT). Either works. The OTel packages must be in `node_modules` (installed via `package.json` or a separate layer). | Yes — if you add the dependency and set the env var, no code changes needed. |
| **Java** | `-javaagent:/path/to/opentelemetry-javaagent.jar` | **Dockerfile** (add the agent JAR + set `JAVA_TOOL_OPTIONS` or modify the entrypoint). Can also be set via `JAVA_TOOL_OPTIONS` env var in the **task definition** if the JAR is already in the image. | Yes — the Java agent instruments at the bytecode level. No code changes. |
| **Python** | `opentelemetry-instrument python app.py` or `OTEL_PYTHON_CONFIGURATOR=auto` with the SDK installed | **Dockerfile** (change CMD to use `opentelemetry-instrument` wrapper). The env var approach also works from the **task definition** if the packages are installed. | Yes — wraps the Python process. No code changes. |
| **.NET** | `CORECLR_ENABLE_PROFILING=1` + `CORECLR_PROFILER` + `CORECLR_PROFILER_PATH` env vars, or `DOTNET_STARTUP_HOOKS` | **Task definition** (env vars) if the profiler DLLs are in the image. Typically configured in the **Dockerfile** alongside the profiler installation. | Yes — .NET auto-instrumentation uses CLR profiling APIs. No code changes. |
| **Go** | No runtime auto-instrumentation available. Must use compile-time instrumentation (`go.opentelemetry.io/contrib/instrumentation/...`) or eBPF-based (experimental). | **Code** — Go requires importing instrumentation libraries and wiring them in code. | No — Go doesn't have a runtime agent model. Manual instrumentation required. |

**The practical answer for most customers:** "Add the OTel auto-instrumentation package to your Docker image, set one or two environment variables in the task definition, and you get traces for all HTTP/gRPC/DB/queue operations with zero code changes. The environment variables can be set in the task definition — you don't have to touch the Dockerfile if the packages are already installed."

## What Auto-Instrumentation Captures

Out of the box, auto-instrumentation covers the framework and library level:

- **Inbound HTTP requests** — a root span per request with method, path, status code, duration
- **Outbound HTTP calls** — child spans for each fetch/axios/http call, with trace context propagation
- **Database queries** — spans for MongoDB, PostgreSQL, MySQL, Redis, etc. with the query (or hashed query) as an attribute
- **Message queues** — spans for Kafka, RabbitMQ, SQS publish/consume
- **gRPC** — spans for both client and server calls

What auto-instrumentation does **not** capture: your business logic. It won't know that a particular code path is "validate order" vs. "charge payment" — those are just generic HTTP handler spans. For that, you need manual instrumentation.

## Manual Instrumentation

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

## Recommendation for Customers

1. **Start with auto-instrumentation only.** Set the env vars, deploy, confirm traces appear in Dash0. This takes minutes.
2. **Add manual spans for critical business logic** once auto-instrumentation is validated. Focus on operations where you need custom attributes (order IDs, customer IDs, payment amounts) or where you want to break a single HTTP request into meaningful sub-operations.
3. **Log correlation comes for free** if the app's logger injects `trace_id` and `span_id` into structured log output. Most OTel SDK auto-instrumentation does this automatically for popular loggers.

## Task Definition Environment Variables for Auto-Instrumentation

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

## Log Correlation

OTel auto-instrumentation automatically injects `trace_id` and `span_id` into structured logs from popular logging libraries, enabling seamless correlation between traces and logs in Dash0.

**How it works by language:**

- **Node.js** — Pino, Winston, and Bunyan get automatic trace context injection when their OTel instrumentation packages are installed. Trace IDs appear as attributes in structured logs.
- **Java** — Logback and Log4j are instrumented automatically. The OTel SDK injects trace context into the MDC (Mapped Diagnostic Context), which loggers then format into output.
- **Python** — The standard `logging` module gets automatic trace context injection. Trace IDs become available in log records.
- **.NET** — The instrumentation for popular logging frameworks (Serilog, NLog) automatically injects `TraceId` and `SpanId` into log context.

**What this enables in Dash0:**

Once trace IDs and span IDs are in your logs, you can:
- Click from a trace span in Dash0 to see all correlated logs from that span
- Click from a log entry to see the full trace it was part of
- Filter logs by trace ID for fast incident investigation
- Join trace and log metadata in dashboards and queries

This correlation works even when logs come from different sources (application logs, infrastructure logs, container logs) as long as they include the trace ID. For container logs routed through FireLens or CloudWatch, a collector sidecar can enrich untraced logs with trace context if they happen during a traced request.

## Sources & References

- [OpenTelemetry Node.js Auto-Instrumentation](https://github.com/open-telemetry/opentelemetry-js-contrib/tree/main/packages/auto-instrumentations-node)
- [OpenTelemetry Java Agent](https://github.com/open-telemetry/opentelemetry-java-instrumentation)
- [OpenTelemetry Python Auto-Instrumentation](https://opentelemetry.io/docs/languages/python/automatic/)
- [OpenTelemetry .NET Auto-Instrumentation](https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation)
- [OpenTelemetry Go Instrumentation Libraries](https://github.com/open-telemetry/opentelemetry-go-contrib)
- [OTel Trace API (Manual Instrumentation)](https://opentelemetry.io/docs/specs/otel/trace/api/)
- [OTel Semantic Conventions for Databases](https://opentelemetry.io/docs/specs/semconv/database/)
