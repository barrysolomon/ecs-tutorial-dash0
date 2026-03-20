// ─────────────────────────────────────────────────────────────────────────────
// Dash0 Demo App — triggers traces, logs, errors, and downstream spans
// ─────────────────────────────────────────────────────────────────────────────
const { NodeSDK }                   = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter }         = require('@opentelemetry/exporter-trace-otlp-grpc');
const { OTLPLogExporter }           = require('@opentelemetry/exporter-logs-otlp-grpc');
const { SimpleLogRecordProcessor }  = require('@opentelemetry/sdk-logs');
const { Resource }                  = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');
const { trace, context, SpanStatusCode } = require('@opentelemetry/api');

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]:    process.env.OTEL_SERVICE_NAME    || 'dash0-demo',
    [SemanticResourceAttributes.SERVICE_VERSION]: '1.0.0',
    'deployment.environment': process.env.DEPLOYMENT_ENV || 'demo',
  }),
  traceExporter: new OTLPTraceExporter(),
  logRecordProcessor: new SimpleLogRecordProcessor(new OTLPLogExporter()),
  instrumentations: [getNodeAutoInstrumentations({
    '@opentelemetry/instrumentation-fs': { enabled: false },
  })],
});
sdk.start();

// ── Logger (injects trace context into every log line) ─────────────────────
const { logs }  = require('@opentelemetry/api-logs');
const logger    = logs.getLogger('dash0-demo');

function log(severity, msg, attrs = {}) {
  const span = trace.getActiveSpan();
  const extra = span ? {
    trace_id: span.spanContext().traceId,
    span_id:  span.spanContext().spanId,
  } : {};
  logger.emit({
    severityText: severity,
    body: msg,
    attributes: { ...extra, ...attrs },
  });
  console.log(JSON.stringify({ level: severity, msg, ...extra, ...attrs }));
}

// ── AWS services (optional — enabled via ENABLE_AWS_SERVICES=true) ──────────
const AWS_ENABLED = (process.env.ENABLE_AWS_SERVICES || '').toLowerCase() === 'true';
const AWS_REGION  = process.env.AWS_REGION || 'eu-west-1';
const DYNAMO_TABLE = process.env.DYNAMO_TABLE || 'dash0-demo-orders';
const S3_BUCKET    = process.env.S3_BUCKET    || 'dash0-demo-data';

let dynamoClient, s3Client;
if (AWS_ENABLED) {
  const { DynamoDBClient, PutItemCommand, GetItemCommand, QueryCommand } = require('@aws-sdk/client-dynamodb');
  const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
  dynamoClient = new DynamoDBClient({ region: AWS_REGION });
  s3Client     = new S3Client({ region: AWS_REGION });
  console.log(`AWS services ENABLED — DynamoDB: ${DYNAMO_TABLE}, S3: ${S3_BUCKET}`);
} else {
  console.log('AWS services DISABLED — set ENABLE_AWS_SERVICES=true to enable DynamoDB/S3');
}

// ── HTTP server ────────────────────────────────────────────────────────────
const http  = require('http');
const https = require('https');

const tracer = trace.getTracer('dash0-demo');

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function httpGet(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith('https') ? https : http;
    lib.get(url, res => {
      let body = '';
      res.on('data', d => body += d);
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}

const ROUTES = {

  // ── Basic health ──────────────────────────────────────────────────────────
  'GET /health': async (req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'dash0-demo', ts: new Date().toISOString() }));
  },

  // ── Order flow — with optional DynamoDB + S3 for deeper traces ───────────
  'GET /api/order': async (req, res) => {
    const orderId    = `ORD-${Math.floor(Math.random() * 90000) + 10000}`;
    const customerId = `CUST-${Math.floor(Math.random() * 100) + 1}`;
    const amount     = (Math.random() * 200 + 10).toFixed(2);
    const items      = Math.ceil(Math.random() * 5);
    log('INFO', 'Processing order', { orderId, customerId });

    await tracer.startActiveSpan('validate-order', async span => {
      span.setAttribute('order.id', orderId);
      span.setAttribute('order.items', items);
      await sleep(20 + Math.random() * 30);
      log('DEBUG', 'Order validated', { orderId });
      span.end();
    });

    await tracer.startActiveSpan('charge-payment', async span => {
      span.setAttribute('payment.method', 'card');
      span.setAttribute('payment.amount', amount);
      await sleep(40 + Math.random() * 60);
      log('INFO', 'Payment charged', { orderId });
      span.end();
    });

    // ── AWS enrichment (DynamoDB write + read, S3 receipt) ──────────────
    if (AWS_ENABLED) {
      const { PutItemCommand, GetItemCommand } = require('@aws-sdk/client-dynamodb');
      const { PutObjectCommand } = require('@aws-sdk/client-s3');

      const orderRecord = {
        orderId:    { S: orderId },
        customerId: { S: customerId },
        amount:     { N: amount },
        items:      { N: String(items) },
        status:     { S: 'confirmed' },
        createdAt:  { S: new Date().toISOString() },
      };

      await tracer.startActiveSpan('dynamodb-put-order', async span => {
        span.setAttribute('db.system', 'dynamodb');
        span.setAttribute('db.operation', 'PutItem');
        span.setAttribute('aws.dynamodb.table_names', DYNAMO_TABLE);
        span.setAttribute('order.id', orderId);
        await dynamoClient.send(new PutItemCommand({
          TableName: DYNAMO_TABLE,
          Item: orderRecord,
        }));
        log('INFO', 'Order persisted to DynamoDB', { orderId, table: DYNAMO_TABLE });
        span.end();
      });

      await tracer.startActiveSpan('dynamodb-get-order', async span => {
        span.setAttribute('db.system', 'dynamodb');
        span.setAttribute('db.operation', 'GetItem');
        span.setAttribute('aws.dynamodb.table_names', DYNAMO_TABLE);
        const result = await dynamoClient.send(new GetItemCommand({
          TableName: DYNAMO_TABLE,
          Key: { orderId: { S: orderId } },
        }));
        span.setAttribute('db.response.found', !!result.Item);
        log('DEBUG', 'Order read back from DynamoDB', { orderId, found: !!result.Item });
        span.end();
      });

      await tracer.startActiveSpan('s3-put-receipt', async span => {
        span.setAttribute('rpc.system', 'aws-api');
        span.setAttribute('rpc.service', 'S3');
        span.setAttribute('aws.s3.bucket', S3_BUCKET);
        const key = `receipts/${orderId}.json`;
        span.setAttribute('aws.s3.key', key);
        const receipt = JSON.stringify({
          orderId, customerId, amount, items,
          status: 'confirmed',
          timestamp: new Date().toISOString(),
        }, null, 2);
        await s3Client.send(new PutObjectCommand({
          Bucket: S3_BUCKET,
          Key: key,
          Body: receipt,
          ContentType: 'application/json',
        }));
        log('INFO', 'Receipt saved to S3', { orderId, bucket: S3_BUCKET, key });
        span.end();
      });
    }

    log('INFO', 'Order complete', { orderId });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ orderId, customerId, amount, items, status: 'confirmed', awsEnriched: AWS_ENABLED }));
  },

  // ── Inventory check — DynamoDB scan + S3 report (AWS-only endpoint) ──────
  'GET /api/inventory': async (req, res) => {
    if (!AWS_ENABLED) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ message: 'AWS services disabled — set ENABLE_AWS_SERVICES=true', items: [] }));
      return;
    }
    const { ScanCommand } = require('@aws-sdk/client-dynamodb');
    const { PutObjectCommand } = require('@aws-sdk/client-s3');

    let orders = [];
    await tracer.startActiveSpan('dynamodb-scan-orders', async span => {
      span.setAttribute('db.system', 'dynamodb');
      span.setAttribute('db.operation', 'Scan');
      span.setAttribute('aws.dynamodb.table_names', DYNAMO_TABLE);
      const result = await dynamoClient.send(new ScanCommand({
        TableName: DYNAMO_TABLE,
        Limit: 20,
      }));
      orders = (result.Items || []).map(item => ({
        orderId: item.orderId?.S,
        customerId: item.customerId?.S,
        amount: item.amount?.N,
        status: item.status?.S,
      }));
      span.setAttribute('db.response.count', orders.length);
      log('INFO', 'Inventory scan complete', { count: orders.length });
      span.end();
    });

    await tracer.startActiveSpan('s3-put-report', async span => {
      span.setAttribute('rpc.system', 'aws-api');
      span.setAttribute('rpc.service', 'S3');
      span.setAttribute('aws.s3.bucket', S3_BUCKET);
      const key = `reports/inventory-${Date.now()}.json`;
      span.setAttribute('aws.s3.key', key);
      await s3Client.send(new PutObjectCommand({
        Bucket: S3_BUCKET,
        Key: key,
        Body: JSON.stringify({ generatedAt: new Date().toISOString(), orders }, null, 2),
        ContentType: 'application/json',
      }));
      log('INFO', 'Inventory report saved to S3', { bucket: S3_BUCKET, key });
      span.end();
    });

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ orders, count: orders.length }));
  },

  // ── Slow request (shows latency in RED metrics) ───────────────────────────
  'GET /api/slow': async (req, res) => {
    const delay = 1500 + Math.random() * 1500;
    log('WARN', 'Slow operation starting', { expectedDelayMs: Math.round(delay) });
    await tracer.startActiveSpan('slow-db-query', async span => {
      span.setAttribute('db.system', 'postgresql');
      span.setAttribute('db.statement', 'SELECT * FROM large_table WHERE unindexed_col = $1');
      await sleep(delay);
      log('WARN', 'Slow db query completed', { durationMs: Math.round(delay) });
      span.end();
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ message: 'slow response', durationMs: Math.round(delay) }));
  },

  // ── Error path (error spans + ERROR logs) ────────────────────────────────
  'GET /api/error': async (req, res) => {
    log('INFO', 'Starting operation that will fail');
    await tracer.startActiveSpan('failing-operation', async span => {
      span.setAttribute('operation.type', 'downstream-call');
      try {
        await sleep(30);
        throw new Error('Upstream service returned 503: rate limit exceeded');
      } catch (err) {
        span.recordException(err);
        span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
        log('ERROR', 'Operation failed', {
          error: err.message,
          errorType: 'UpstreamError',
          retryable: true,
        });
        span.end();
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message, retryable: true }));
      }
    });
  },

  // ── Downstream HTTP call (multi-service trace) ────────────────────────────
  'GET /api/fetch': async (req, res) => {
    log('INFO', 'Fetching external data');
    let result;
    await tracer.startActiveSpan('external-api-call', async span => {
      span.setAttribute('http.url', 'https://httpbin.org/get');
      span.setAttribute('peer.service', 'httpbin');
      try {
        result = await httpGet('https://httpbin.org/get');
        span.setAttribute('http.response.status_code', result.status);
        log('INFO', 'External call succeeded', { statusCode: result.status });
      } catch (err) {
        span.recordException(err);
        span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
        log('ERROR', 'External call failed', { error: err.message });
        result = { status: 0, body: '{}' };
      }
      span.end();
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ upstream_status: result.status }));
  },

  // ── Burst — fires 10 sub-spans (good for waterfall demo) ──────────────────
  'GET /api/burst': async (req, res) => {
    const jobId = `JOB-${Date.now()}`;
    log('INFO', 'Starting batch job', { jobId, tasks: 10 });
    await tracer.startActiveSpan('batch-job', async parent => {
      parent.setAttribute('job.id', jobId);
      parent.setAttribute('job.tasks', 10);
      await Promise.all(Array.from({ length: 10 }, (_, i) =>
        tracer.startActiveSpan(`task-${i}`, { }, context.active(), async span => {
          span.setAttribute('task.index', i);
          span.setAttribute('task.type', i % 3 === 0 ? 'write' : 'read');
          await sleep(20 + Math.random() * 80);
          if (i === 7) {
            span.addEvent('cache-miss', { key: `item-${i}` });
            log('WARN', 'Cache miss on task', { taskIndex: i, jobId });
          }
          span.end();
        })
      ));
      log('INFO', 'Batch job complete', { jobId });
      parent.end();
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ jobId, tasks: 10, status: 'done' }));
  },

  // ── Load generator — call this to auto-fire mixed traffic ─────────────────
  'GET /api/load': async (req, res) => {
    const endpoints = ['/api/order', '/api/order', '/api/order', '/api/slow', '/api/error', '/api/burst'];
    const target    = endpoints[Math.floor(Math.random() * endpoints.length)];
    const port      = process.env.PORT || 3000;
    log('INFO', 'Load gen firing', { target });
    httpGet(`http://localhost:${port}${target}`).catch(() => {});
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ fired: target }));
  },
};

// ── Route table ────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const key = `${req.method} ${req.url.split('?')[0]}`;
  const handler = ROUTES[key];
  if (handler) {
    try { await handler(req, res); }
    catch (err) {
      log('ERROR', 'Unhandled exception', { error: err.message, path: req.url });
      res.writeHead(500);
      res.end(JSON.stringify({ error: 'internal server error' }));
    }
  } else {
    res.writeHead(404);
    res.end(JSON.stringify({ error: 'not found', path: req.url }));
  }
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  log('INFO', `Dash0 demo app listening`, { port: PORT });
  console.log(`
  Endpoints:
    GET /health         — health check (no trace)
    GET /api/order      — order flow (+ DynamoDB/S3 if AWS enabled)
    GET /api/inventory  — scan orders + S3 report (AWS-only)
    GET /api/slow       — slow query (latency spike)
    GET /api/error      — error span + ERROR log
    GET /api/fetch      — outbound HTTP call (multi-service trace)
    GET /api/burst      — 10 parallel child spans (waterfall demo)
    GET /api/load       — fires random traffic (use in a loop)
  AWS services: ${AWS_ENABLED ? 'ENABLED' : 'DISABLED'}
  `);
});

process.on('SIGTERM', async () => {
  log('INFO', 'SIGTERM received, shutting down');
  await sdk.shutdown();
  process.exit(0);
});
