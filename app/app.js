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

// ── RabbitMQ (optional — enabled via ENABLE_MQ=true) ────────────────────────
const MQ_ENABLED  = (process.env.ENABLE_MQ || '').toLowerCase() === 'true';
const MQ_ENDPOINT = process.env.MQ_ENDPOINT || '';
const MQ_USERNAME = process.env.MQ_USERNAME || 'wildrydes';
const MQ_PASSWORD = process.env.MQ_PASSWORD || '';
const MQ_EXCHANGE = 'wildrydes.events';

// In-memory stores for ratings and chat (ephemeral — fine for demo)
const recentRides = new Map();   // rideId → rideDetail
const ratings     = new Map();   // rideId → { score, comment, unicornName, city, timestamp }
const chatMessages = new Map();  // rideId → [{ from, message, timestamp }]

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

// ── Latka's Maintenance Database (RDS PostgreSQL) ─────────────────────────
const DB_ENABLED = !!(process.env.DATABASE_URL || process.env.DB_HOST);
let dbPool = null;

if (DB_ENABLED) {
  const { Pool } = require('pg');
  const dbConfig = process.env.DATABASE_URL
    ? { connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } }
    : {
        host: process.env.DB_HOST,
        port: parseInt(process.env.DB_PORT || '5432', 10),
        database: process.env.DB_NAME || 'latkas_garage',
        user: process.env.DB_USER || 'latka',
        password: process.env.DB_PASSWORD || '',
        ssl: { rejectUnauthorized: false },
      };
  dbPool = new Pool({ ...dbConfig, max: 5, idleTimeoutMillis: 30000 });
  console.log(`Maintenance DB ENABLED — ${dbConfig.host || 'via DATABASE_URL'}`);
} else {
  console.log('Maintenance DB DISABLED — set DB_HOST to enable RDS record-keeping');
}

async function initMaintenanceSchema() {
  if (!dbPool) return;
  try {
    await dbPool.query(`
      CREATE TABLE IF NOT EXISTS maintenance_records (
        id SERIAL PRIMARY KEY,
        ride_id VARCHAR(64) NOT NULL,
        unicorn_name VARCHAR(64) NOT NULL,
        mechanic VARCHAR(64) DEFAULT 'Latka Gravas',
        mileage INTEGER,
        status VARCHAR(20) NOT NULL DEFAULT 'pending',
        diagnosis TEXT,
        service_time VARCHAR(20),
        dispatch_issues TEXT,
        louie_override BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMPTZ DEFAULT NOW()
      );
      CREATE TABLE IF NOT EXISTS parts_used (
        id SERIAL PRIMARY KEY,
        record_id INTEGER REFERENCES maintenance_records(id),
        part_name VARCHAR(128) NOT NULL,
        part_number VARCHAR(32),
        quantity INTEGER DEFAULT 1,
        condition VARCHAR(32) DEFAULT 'new',
        notes TEXT
      );
      CREATE TABLE IF NOT EXISTS mechanic_comments (
        id SERIAL PRIMARY KEY,
        record_id INTEGER REFERENCES maintenance_records(id),
        mechanic VARCHAR(64) DEFAULT 'Latka Gravas',
        comment TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW()
      );
      CREATE INDEX IF NOT EXISTS idx_maintenance_unicorn ON maintenance_records(unicorn_name);
      CREATE INDEX IF NOT EXISTS idx_maintenance_ride ON maintenance_records(ride_id);
    `);
    console.log('Maintenance DB schema initialized');
  } catch (err) {
    console.error('Failed to initialize maintenance DB schema:', err.message);
  }
}

const GARAGE_PARTS = [
  { part_name: 'Shimmer Capacitor', part_number: 'SC-4401', condition: 'refurbished' },
  { part_name: 'Rainbow Refractor', part_number: 'RR-7720', condition: 'new' },
  { part_name: 'Sparkle Fluid Filter', part_number: 'SFF-100', condition: 'new' },
  { part_name: 'Horn Alignment Gauge', part_number: 'HAG-03', condition: 'calibrated' },
  { part_name: 'Hoof Grip Pad (set of 4)', part_number: 'HGP-4S', condition: 'new' },
  { part_name: 'Mane Detangler Nozzle', part_number: 'MDN-22', condition: 'used' },
  { part_name: 'Tail Light Crystal', part_number: 'TLC-88', condition: 'polished' },
  { part_name: 'Glitter Injection Valve', part_number: 'GIV-55', condition: 'new' },
  { part_name: 'Cloud Traction Module', part_number: 'CTM-12', condition: 'refurbished' },
  { part_name: 'Ibbida Valve', part_number: 'IV-0001', condition: 'rare import' },
];

const LATKA_COMMENTS_OK = [
  'Everything check out. Veddy nice unicorn. I give A+.',
  'Oil good, sparkle fluid good, hooves good. Ready for next ride!',
  'I run full diagnostic. All systems nominal. Is beautiful machine.',
  'Mileage is getting up there but this unicorn still veddy strong.',
  'I tighten the rainbow refractor and top off sparkle fluid. Good to go!',
];
const LATKA_COMMENTS_WARN = [
  'Horn alignment little bit off. I fix but keep eye on it.',
  'Sparkle fluid running low. Louie should order more but he cheap.',
  'I notice small crack in cloud traction module. Not urgent but schedule follow-up.',
  'Mane detangler needs replacement soon. Maybe 200 more miles.',
];
const LATKA_COMMENTS_ERROR = [
  'This unicorn should NOT be on road. I file formal complaint with management.',
  'Louie will hear about this. I document everything. EVERYTHING.',
  'Major safety issue. I refuse to sign off on this. Latka has standards.',
];

// ── Latka's Maintenance Shop (configurable chaos) ──────────────────────────
const LATKA_ERROR_RATE = parseFloat(process.env.LATKA_ERROR_RATE ?? '0.15');
const LATKA_SLOW_RATE  = parseFloat(process.env.LATKA_SLOW_RATE ?? '0.20');
const LATKA_SLOW_MS    = parseInt(process.env.LATKA_SLOW_MS ?? '2000', 10);

const LATKA_QUOTES = {
  ok: [
    'I check the horn, adjust the sparkle. Is okay now. Tenk you veddy much.',
    'Everything running smooth like butter. Latka approve. Ibi da!',
    'I give full inspection. This unicorn, top condition. Number one. Tenk you veddy much.',
    'Nik nik... I mean, the engine. The engine is veddy good. All clean.',
    'In my country we have saying: happy unicorn, happy rider. This one? Veddy happy.',
  ],
  slow: [
    'Hmm, this one make funny noise. I look more careful... Ah, is just the glitter filter. I clean, is fine now. Tenk you veddy much.',
    'I must do deep diagnostic. Take little bit longer... okay, found it. Small crack in rainbow refractor. 110 kebble to fix. I fix.',
    'This unicorn need extra attention. In my country, we take our time with these things. Is not like America where everything rush rush rush.',
    'I run full sparkle diagnostic... Okay, is all good now. Just needed tune-up. You know, back home this would cost 270 lithnich. Here? Free. America!',
  ],
  error: [
    'Is broken. Part on backorder from old country. I call my cousin, he maybe have one.',
    'Oh no. The shimmer capacitor is kaput. I never see this before. Veddy bad.',
    'I try fix but this beyond Latka skill. Need specialist. Maybe unicorn doctor. I must protest! No! No! No!',
    'In my country we have word for this: gibbelfritz. Means "the machine is angry and will not forgive." Veddy serious.',
    'Is no good. I look everywhere. The ibbida valve is completely... how you say... dead. Like my dreams of becoming American mechanic of the year.',
  ],
};

function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

// ── Louie-specific diagnoses (deterministic when dispatchContext present) ───
const LOUIE_DIAGNOSIS = {
  skippedInspection: 'Somebody skip the pre-ride inspection. I wonder who... LOUIE!',
  tireCondition: 'Louie send this unicorn out with bald hooves AGAIN?! I tell him last week! Aye yi yi...',
  oilChangeMiles: (n) => `${n.toLocaleString()} miles since oil change?! In my country, Louie would be in big trouble. BIG trouble.`,
  ridesToday: (n) => `This unicorn do ${n} rides today! Is not machine, is living creature! Louie have no heart.`,
  sparkleFluid: 'Who put discount sparkle fluid in here? Horn is flickering! Veddy dangerous! LOUIE!',
};

function buildLouieDiagnosis(dispatchContext) {
  const issues = Object.keys(dispatchContext).filter(k => k !== 'louie_says');
  const parts = issues.map(key => {
    const template = LOUIE_DIAGNOSIS[key];
    if (typeof template === 'function') return template(dispatchContext[key]);
    return template;
  });
  if (parts.length >= 2) {
    return parts.join(' AND ') + ' I must protest! No! No! No!';
  }
  return parts[0] || '';
}

function buildLouieError(dispatchContext) {
  const firstKey = Object.keys(dispatchContext).filter(k => k !== 'louie_says')[0];
  const issueText = {
    skippedInspection: 'skip inspection',
    tireCondition: 'use bald hooves',
    oilChangeMiles: 'ignore oil change',
    ridesToday: 'overwork the unicorn',
    sparkleFluid: 'use discount sparkle fluid',
  }[firstKey] || 'cut corners';
  return `Is broken BECAUSE Louie ${issueText}. The shimmer capacitor is kaput. I tell him this would happen! Nobody listen to Latka. Tenk you veddy much.`;
}

// ── HTTP server ────────────────────────────────────────────────────────────
const http  = require('http');
const https = require('https');

const tracer = trace.getTracer('dash0-demo');

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', d => body += d);
    req.on('end', () => { try { resolve(JSON.parse(body || '{}')); } catch (e) { resolve({}); } });
    req.on('error', reject);
  });
}

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

  // ── Recent rides received from RabbitMQ ───────────────────────────────────
  'GET /api/rides/recent': async (req, res) => {
    const rides = Array.from(recentRides.values()).slice(-50).reverse();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ rides, count: rides.length }));
  },

  // ── Submit a rating for a ride ──────────────────────────────────────────
  'POST /api/ratings': async (req, res) => {
    const body = await readBody(req);
    const { rideId, score, comment, unicornName, city } = body;
    if (!rideId || !score) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'rideId and score are required' }));
      return;
    }
    await tracer.startActiveSpan('submit-rating', async span => {
      span.setAttribute('ride.id', rideId);
      span.setAttribute('rating.score', score);
      span.setAttribute('rating.unicorn', unicornName || 'unknown');
      const rating = {
        rideId, score: Math.min(5, Math.max(1, score)),
        comment: comment || '', unicornName: unicornName || 'unknown',
        city: city || 'unknown', timestamp: new Date().toISOString(),
      };
      ratings.set(rideId, rating);
      log('INFO', 'Rating submitted', { rideId, score, unicornName });
      span.end();
    });
    res.writeHead(201, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'saved', rideId }));
  },

  // ── Get ratings (optionally filtered by unicorn) ─────────────────────────
  'GET /api/ratings': async (req, res) => {
    const url = new URL(req.url, `http://localhost`);
    const unicorn = url.searchParams.get('unicorn');
    let all = Array.from(ratings.values());
    if (unicorn) all = all.filter(r => r.unicornName === unicorn);
    // Calculate averages per unicorn
    const byUnicorn = {};
    all.forEach(r => {
      if (!byUnicorn[r.unicornName]) byUnicorn[r.unicornName] = { total: 0, count: 0 };
      byUnicorn[r.unicornName].total += r.score;
      byUnicorn[r.unicornName].count += 1;
    });
    const averages = Object.entries(byUnicorn).map(([name, v]) => ({
      unicorn: name, average: (v.total / v.count).toFixed(1), count: v.count,
    }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ratings: all, averages, count: all.length }));
  },

  // ── Send a chat message ─────────────────────────────────────────────────
  'POST /api/chat': async (req, res) => {
    const body = await readBody(req);
    const { rideId, user, message } = body;
    if (!rideId || !message) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'rideId and message are required' }));
      return;
    }
    await tracer.startActiveSpan('send-chat-message', async span => {
      span.setAttribute('ride.id', rideId);
      span.setAttribute('chat.user', user || 'anonymous');
      if (!chatMessages.has(rideId)) chatMessages.set(rideId, []);
      const msgs = chatMessages.get(rideId);
      msgs.push({ from: user || 'anonymous', message, timestamp: new Date().toISOString() });
      // Auto-reply from support after a short delay
      const ride = recentRides.get(rideId);
      const unicornName = ride?.Unicorn?.Name || 'your unicorn';
      setTimeout(() => {
        msgs.push({
          from: 'support',
          message: `Thanks for riding with ${unicornName}! How was your experience?`,
          timestamp: new Date().toISOString(),
        });
      }, 1500);
      log('INFO', 'Chat message sent', { rideId, user });
      span.end();
    });
    res.writeHead(201, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'sent', rideId }));
  },

  // ── Get chat messages for a ride ────────────────────────────────────────
  'GET /api/chat': async (req, res) => {
    const url = new URL(req.url, `http://localhost`);
    const rideId = url.searchParams.get('rideId');
    if (!rideId) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'rideId query param is required' }));
      return;
    }
    const msgs = chatMessages.get(rideId) || [];
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ messages: msgs, count: msgs.length }));
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

  // ── Latka's Unicorn Maintenance Shop ─────────────────────────────────────
  'POST /maintenance': async (req, res) => {
    const body = await readBody(req);
    const unicornName = body.unicornName || 'unknown';
    const rideId = body.rideId || 'unknown';
    const dispatchContext = body.dispatchContext || null;

    await tracer.startActiveSpan('maintenance-check', async span => {
      span.setAttribute('maintenance.mechanic', 'Latka Gravas');
      span.setAttribute('maintenance.unicorn', unicornName);
      span.setAttribute('maintenance.type', 'post-ride-check');
      span.setAttribute('ride.id', rideId);

      const mileage = Math.floor(Math.random() * 50000);
      span.setAttribute('maintenance.mileage', mileage);

      if (dispatchContext) {
        const issues = Object.keys(dispatchContext).filter(k => k !== 'louie_says');
        span.setAttribute('dispatch.corner_cutting', true);
        span.setAttribute('dispatch.issues', issues.join(','));
        if (dispatchContext.louie_says) span.setAttribute('dispatch.louie_says', dispatchContext.louie_says[0] || '');
      }

      const isError = Math.random() < LATKA_ERROR_RATE;
      const isSlow = !isError && Math.random() < LATKA_SLOW_RATE;

      if (isError) {
        const diagnosis = dispatchContext ? buildLouieError(dispatchContext) : pick(LATKA_QUOTES.error);
        span.setAttribute('maintenance.diagnosis', diagnosis);
        span.setAttribute('maintenance.error_code', 'PART_UNAVAILABLE');
        span.setStatus({ code: SpanStatusCode.ERROR, message: diagnosis });

        // Record the rejection in the database
        let recordId = null;
        if (dbPool) {
          try {
            const issues = dispatchContext ? Object.keys(dispatchContext).filter(k => k !== 'louie_says').join(',') : null;
            const result = await dbPool.query(
              `INSERT INTO maintenance_records (ride_id, unicorn_name, mileage, status, diagnosis, dispatch_issues, louie_override)
               VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
              [rideId, unicornName, mileage, 'rejected', diagnosis, issues, !!(dispatchContext)]
            );
            recordId = result.rows[0].id;
            await dbPool.query(
              `INSERT INTO mechanic_comments (record_id, mechanic, comment) VALUES ($1, $2, $3)`,
              [recordId, 'Latka Gravas', pick(LATKA_COMMENTS_ERROR)]
            );
          } catch (err) {
            log('WARN', 'Failed to record rejection', { error: err.message });
          }
        }

        // Latka tries to order the missing part from the supplier
        const neededPart = pick(GARAGE_PARTS);
        let supplierResult = null;
        await tracer.startActiveSpan('order-replacement-part', async partSpan => {
          partSpan.setAttribute('parts.supplier', 'Unicorn Parts Warehouse');
          partSpan.setAttribute('parts.part_name', neededPart.part_name);
          partSpan.setAttribute('parts.part_number', neededPart.part_number);
          partSpan.setAttribute('maintenance.unicorn', unicornName);
          try {
            const supplierResp = await httpGet(`https://dummyjson.com/products/search?q=${encodeURIComponent(neededPart.part_name.split(' ')[0])}&limit=3`);
            const catalog = JSON.parse(supplierResp.body);
            partSpan.setAttribute('parts.supplier_status', supplierResp.status);
            partSpan.setAttribute('parts.results_found', catalog.total || 0);
            if (catalog.total === 0 || supplierResp.status !== 200) {
              partSpan.setAttribute('parts.available', false);
              partSpan.setStatus({ code: SpanStatusCode.ERROR, message: `${neededPart.part_name} not available from supplier` });
              supplierResult = { available: false, part: neededPart.part_name };
            } else {
              partSpan.setAttribute('parts.available', true);
              partSpan.setAttribute('parts.estimated_delivery', '3-5 business days');
              supplierResult = { available: true, part: neededPart.part_name, delivery: '3-5 business days' };
            }
          } catch (err) {
            partSpan.setAttribute('parts.available', false);
            partSpan.setStatus({ code: SpanStatusCode.ERROR, message: `Supplier unreachable: ${err.message}` });
            supplierResult = { available: false, part: neededPart.part_name, error: err.message };
            log('WARN', 'Parts supplier unreachable', { error: err.message, part: neededPart.part_name });
          }
          partSpan.end();
        });

        log('ERROR', 'Maintenance check failed', { unicorn: unicornName, rideId, diagnosis, recordId, partOrder: supplierResult });
        span.end();
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          status: 'error', mechanic: 'Latka Gravas', unicorn: unicornName,
          rideId, diagnosis, errorCode: 'PART_UNAVAILABLE',
          partOrder: supplierResult,
          ...(recordId ? { recordId } : {}),
        }));
        return;
      }

      // Simulate diagnostic work
      await tracer.startActiveSpan('unicorn-diagnostics', async diagSpan => {
        diagSpan.setAttribute('maintenance.unicorn', unicornName);
        diagSpan.setAttribute('maintenance.mileage', mileage);

        const delay = isSlow ? LATKA_SLOW_MS : Math.floor(20 + Math.random() * 30);
        await sleep(delay);

        if (isSlow) {
          diagSpan.setAttribute('maintenance.service_time', 'extended');
          span.setAttribute('maintenance.service_time', 'extended');
        }
        diagSpan.end();
      });

      const diagnosis = dispatchContext
        ? buildLouieDiagnosis(dispatchContext)
        : (isSlow ? pick(LATKA_QUOTES.slow) : pick(LATKA_QUOTES.ok));
      span.setAttribute('maintenance.diagnosis', diagnosis);

      // Write maintenance record to PostgreSQL (auto-instrumented → pg.query spans)
      let recordId = null;
      if (dbPool) {
        await tracer.startActiveSpan('write-maintenance-record', async dbSpan => {
          dbSpan.setAttribute('db.system', 'postgresql');
          dbSpan.setAttribute('maintenance.unicorn', unicornName);
          dbSpan.setAttribute('ride.id', rideId);
          try {
            const serviceTime = isSlow ? 'extended' : 'standard';
            const issues = dispatchContext ? Object.keys(dispatchContext).filter(k => k !== 'louie_says').join(',') : null;
            const result = await dbPool.query(
              `INSERT INTO maintenance_records (ride_id, unicorn_name, mileage, status, diagnosis, service_time, dispatch_issues, louie_override)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
              [rideId, unicornName, mileage, 'approved', diagnosis, serviceTime, issues, !!(dispatchContext)]
            );
            recordId = result.rows[0].id;
            dbSpan.setAttribute('db.record_id', recordId);

            // Log parts used during service
            const numParts = Math.floor(Math.random() * 3) + (isSlow ? 2 : 1);
            const shuffled = [...GARAGE_PARTS].sort(() => Math.random() - 0.5);
            const partsUsed = shuffled.slice(0, numParts);
            for (const part of partsUsed) {
              await dbPool.query(
                `INSERT INTO parts_used (record_id, part_name, part_number, quantity, condition, notes)
                 VALUES ($1, $2, $3, $4, $5, $6)`,
                [recordId, part.part_name, part.part_number, 1, part.condition,
                 isSlow ? 'Required extra attention' : null]
              );
            }
            dbSpan.setAttribute('maintenance.parts_count', numParts);

            // Add mechanic comment
            const comment = dispatchContext
              ? pick(LATKA_COMMENTS_WARN)
              : (isSlow ? pick(LATKA_COMMENTS_WARN) : pick(LATKA_COMMENTS_OK));
            await dbPool.query(
              `INSERT INTO mechanic_comments (record_id, mechanic, comment)
               VALUES ($1, $2, $3)`,
              [recordId, 'Latka Gravas', comment]
            );
            dbSpan.setAttribute('maintenance.comment', comment);

            log('INFO', 'Maintenance record saved', { recordId, unicorn: unicornName, rideId, parts: numParts });
          } catch (err) {
            dbSpan.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
            log('ERROR', 'Failed to save maintenance record', { error: err.message, unicorn: unicornName });
          }
          dbSpan.end();
        });
      }

      log('INFO', 'Maintenance check complete', { unicorn: unicornName, rideId, diagnosis, isSlow, recordId });

      span.end();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: 'ok', mechanic: 'Latka Gravas', unicorn: unicornName,
        rideId, diagnosis, mileage, nextService: isSlow ? '200 miles' : '500 miles',
        ...(isSlow ? { serviceTime: 'extended' } : {}),
        ...(recordId ? { recordId } : {}),
      }));
    });
  },
};

// ── CORS headers ────────────────────────────────────────────────────────────
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, traceparent, tracestate',
};

// ── Route table ────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }
  // Add CORS to all responses
  Object.entries(CORS_HEADERS).forEach(([k, v]) => res.setHeader(k, v));

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

// ── RabbitMQ consumer ───────────────────────────────────────────────────────
let mqConnection = null;

async function startMQConsumer() {
  if (!MQ_ENABLED || !MQ_ENDPOINT) return;
  const amqp = require('amqplib');
  const url = MQ_ENDPOINT.replace('amqps://', `amqps://${MQ_USERNAME}:${encodeURIComponent(MQ_PASSWORD)}@`);

  try {
    mqConnection = await amqp.connect(url);
    const ch = await mqConnection.createChannel();
    await ch.assertExchange(MQ_EXCHANGE, 'topic', { durable: true });
    await ch.assertQueue('ride-completed', { durable: true });
    await ch.assertQueue('chat-messages', { durable: true });
    await ch.bindQueue('ride-completed', MQ_EXCHANGE, 'ride.completed');
    await ch.bindQueue('chat-messages', MQ_EXCHANGE, 'chat.message');
    ch.prefetch(1);

    ch.consume('ride-completed', (msg) => {
      if (!msg) return;
      tracer.startActiveSpan('process-ride-completed', span => {
        try {
          const ride = JSON.parse(msg.content.toString());
          const detail = ride.RideDetail || {};
          recentRides.set(ride.RideId, detail);
          span.setAttribute('ride.id', ride.RideId);
          span.setAttribute('ride.unicorn', detail.Unicorn?.Name || 'unknown');
          span.setAttribute('ride.city', detail.PickupLocation?.City || 'unknown');
          span.setAttribute('messaging.system', 'rabbitmq');
          span.setAttribute('messaging.operation', 'process');
          log('INFO', 'Ride received from RabbitMQ', {
            rideId: ride.RideId,
            unicorn: detail.Unicorn?.Name,
            city: detail.PickupLocation?.City,
          });
        } catch (err) {
          log('ERROR', 'Failed to process ride message', { error: err.message });
        }
        span.end();
        ch.ack(msg);
      });
    });

    ch.consume('chat-messages', (msg) => {
      if (!msg) return;
      try {
        const data = JSON.parse(msg.content.toString());
        if (data.rideId && data.message) {
          if (!chatMessages.has(data.rideId)) chatMessages.set(data.rideId, []);
          chatMessages.get(data.rideId).push({
            from: data.user || 'anonymous',
            message: data.message,
            timestamp: new Date().toISOString(),
          });
        }
      } catch (err) {
        log('ERROR', 'Failed to process chat message', { error: err.message });
      }
      ch.ack(msg);
    });

    mqConnection.on('close', () => { mqConnection = null; log('WARN', 'RabbitMQ connection closed'); });
    mqConnection.on('error', (err) => { mqConnection = null; log('ERROR', 'RabbitMQ error', { error: err.message }); });

    log('INFO', 'RabbitMQ consumer started', { exchange: MQ_EXCHANGE, queues: ['ride-completed', 'chat-messages'] });
  } catch (err) {
    log('ERROR', 'Failed to connect to RabbitMQ', { error: err.message, endpoint: MQ_ENDPOINT });
  }
}

const PORT = process.env.PORT || 3000;
server.listen(PORT, async () => {
  log('INFO', `Dash0 demo app listening`, { port: PORT });
  await initMaintenanceSchema();
  console.log(`
  Endpoints:
    GET  /health          — health check (no trace)
    GET  /api/order       — order flow (+ DynamoDB/S3 if AWS enabled)
    GET  /api/inventory   — scan orders + S3 report (AWS-only)
    GET  /api/slow        — slow query (latency spike)
    GET  /api/error       — error span + ERROR log
    GET  /api/fetch       — outbound HTTP call (multi-service trace)
    GET  /api/burst       — 10 parallel child spans (waterfall demo)
    GET  /api/load        — fires random traffic (use in a loop)
    GET  /api/rides/recent — recent rides from RabbitMQ
    POST /api/ratings     — submit a ride rating
    GET  /api/ratings     — get ratings (optional ?unicorn=Name)
    POST /api/chat        — send a chat message
    GET  /api/chat        — get chat history (?rideId=xxx)
  AWS services: ${AWS_ENABLED ? 'ENABLED' : 'DISABLED'}
  RabbitMQ:     ${MQ_ENABLED ? 'ENABLED' : 'DISABLED'}
  `);
  // Start MQ consumer after server is listening
  startMQConsumer();
});

process.on('SIGTERM', async () => {
  log('INFO', 'SIGTERM received, shutting down');
  if (mqConnection) { try { await mqConnection.close(); } catch (_) {} }
  await sdk.shutdown();
  process.exit(0);
});
