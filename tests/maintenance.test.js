const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

// We test the maintenance business logic in isolation.
// The actual route handler in app.js wraps this logic with OTel spans.
// We extract and test the core decision-making separately.

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

function maintenanceHandler(unicornName, rideId, opts = {}) {
  const errorRate = parseFloat(opts.errorRate ?? 0.15);
  const slowRate = parseFloat(opts.slowRate ?? 0.20);
  const slowMs = parseInt(opts.slowMs ?? 2000, 10);
  const mileage = Math.floor(Math.random() * 50000);

  const isError = Math.random() < errorRate;
  const isSlow = !isError && Math.random() < slowRate;

  if (isError) {
    return {
      delay: 0,
      statusCode: 500,
      body: {
        status: 'error',
        mechanic: 'Latka Gravas',
        unicorn: unicornName || 'unknown',
        rideId: rideId || 'unknown',
        diagnosis: pick(LATKA_QUOTES.error),
        errorCode: 'PART_UNAVAILABLE',
      },
    };
  }

  const diagnosis = isSlow ? pick(LATKA_QUOTES.slow) : pick(LATKA_QUOTES.ok);
  return {
    delay: isSlow ? slowMs : Math.floor(20 + Math.random() * 30),
    statusCode: 200,
    body: {
      status: 'ok',
      mechanic: 'Latka Gravas',
      unicorn: unicornName || 'unknown',
      rideId: rideId || 'unknown',
      diagnosis,
      mileage,
      nextService: isSlow ? '200 miles' : '500 miles',
      ...(isSlow ? { serviceTime: 'extended' } : {}),
    },
  };
}

describe('ECS /maintenance endpoint', () => {
  it('returns 200 with Latka response on success', () => {
    const result = maintenanceHandler('Bucephalus', 'ride-123', { errorRate: 0, slowRate: 0 });
    assert.equal(result.statusCode, 200);
    assert.equal(result.body.status, 'ok');
    assert.equal(result.body.mechanic, 'Latka Gravas');
    assert.equal(result.body.unicorn, 'Bucephalus');
    assert.equal(result.body.rideId, 'ride-123');
    assert.ok(result.body.diagnosis.length > 0);
    assert.ok(typeof result.body.mileage === 'number');
    assert.equal(result.body.nextService, '500 miles');
    assert.equal(result.body.serviceTime, undefined);
  });

  it('returns 500 with error when errorRate is 1.0', () => {
    for (let i = 0; i < 20; i++) {
      const result = maintenanceHandler('Jack', 'ride-err', { errorRate: 1.0, slowRate: 0 });
      assert.equal(result.statusCode, 500);
      assert.equal(result.body.status, 'error');
      assert.equal(result.body.errorCode, 'PART_UNAVAILABLE');
      assert.ok(LATKA_QUOTES.error.includes(result.body.diagnosis));
    }
  });

  it('returns slow response with extended serviceTime when slowRate is 1.0', () => {
    const result = maintenanceHandler('Gin', 'ride-slow', { errorRate: 0, slowRate: 1.0, slowMs: 100 });
    assert.equal(result.statusCode, 200);
    assert.equal(result.body.serviceTime, 'extended');
    assert.equal(result.body.nextService, '200 miles');
    assert.equal(result.delay, 100);
    assert.ok(LATKA_QUOTES.slow.includes(result.body.diagnosis));
  });

  it('returns fast response with no chaos when rates are 0', () => {
    for (let i = 0; i < 20; i++) {
      const result = maintenanceHandler('Walker', 'ride-ok', { errorRate: 0, slowRate: 0 });
      assert.equal(result.statusCode, 200);
      assert.equal(result.body.status, 'ok');
      assert.ok(result.delay < 100);
    }
  });

  it('handles missing unicornName and rideId gracefully', () => {
    const result = maintenanceHandler(undefined, undefined, { errorRate: 0, slowRate: 0 });
    assert.equal(result.statusCode, 200);
    assert.equal(result.body.unicorn, 'unknown');
    assert.equal(result.body.rideId, 'unknown');
  });

  it('uses default chaos rates when not specified', () => {
    let errors = 0;
    let slows = 0;
    for (let i = 0; i < 200; i++) {
      const result = maintenanceHandler('Sparkleface', 'ride-default');
      if (result.statusCode === 500) errors++;
      else if (result.body.serviceTime === 'extended') slows++;
    }
    assert.ok(errors > 5, `Expected some errors, got ${errors}`);
    assert.ok(errors < 60, `Expected ~30 errors, got ${errors}`);
    assert.ok(slows > 5, `Expected some slow responses, got ${slows}`);
  });
});
