#!/usr/bin/env node
// Execute the production WebKit reader with synthetic responses. No network or credentials.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../Sources/Switchboard/ClaudeBillingSession.swift', import.meta.url), 'utf8');
const matches = [...source.matchAll(/private static let billingScript = #"""\r?\n([\s\S]*?)\r?\n\s*"""#/g)];
assert.equal(matches.length, 1, 'Expected one production billingScript in ClaudeBillingSession.swift');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const billingReader = new AsyncFunction(
  'expectedAccount', 'expectedOrganization', 'fetch', 'setTimeout', 'clearTimeout', 'AbortController', matches[0][1],
);

const account = 'synthetic-account';
const organization = 'synthetic-org';
const sensitive = 'synthetic-sensitive-value-never-export';
const bootstrapPath = '/api/bootstrap?statsig_hashing_algorithm=djb2&growthbook_format=sdk&include_system_prompts=false';
const billingPath = id => `/api/organizations/${encodeURIComponent(id)}/subscription_details`;
const resetPath = id => `/api/organizations/${encodeURIComponent(id)}/usage?cedar_ember=1&skip_spend=1`;
const allowedFields = ['next_charge_at', 'next_charge_date', 'plan_ending_at', 'plan_ending_before',
  'status', 'payment_paused_until', 'gift_details'];
const bootstrap = (overrides = {}) => ({ account: { uuid: account, memberships: [
  { organization: { uuid: 'another-organization' } },
  { organization: { uuid: organization } },
], ...overrides }, session: sensitive });
const response = (body, status = 200) => ({ body, status });

async function execute(steps, expectedOrganization = organization) {
  if (steps.length === 2 && steps[1].status === 200 && steps[1].body && typeof steps[1].body === 'object' && !steps[1].jsonError) {
    steps = [...steps, response({cedar_ember: {eligible: true, grants: []}})];
  }
  const calls = [];
  const timers = [];
  const controllers = [];
  let jsonReads = 0;
  let unexpectedFetch = false;
  class MockAbortController {
    constructor() {
      this.signal = { aborted: false };
      controllers.push(this);
    }
    abort() { this.signal.aborted = true; }
  }
  const fetch = async (path, options) => {
    const step = steps[calls.length];
    calls.push({ path, options });
    if (!step) {
      unexpectedFetch = true;
      throw new Error('Unexpected synthetic fetch');
    }
    if (step.abort) {
      timers[0].callback();
      throw new Error(`Aborted request: ${sensitive}`);
    }
    if (step.fetchError) throw new Error(step.fetchError);
    return {
      ok: step.status >= 200 && step.status < 300,
      status: step.status,
      json: async () => {
        jsonReads += 1;
        if (step.jsonError) throw new SyntaxError(step.jsonError);
        return structuredClone(step.body);
      },
    };
  };
  const setTimeout = (callback, delay) => {
    const timer = { callback, delay, cleared: false };
    timers.push(timer);
    return timer;
  };
  const clearTimeout = timer => { timer.cleared = true; };
  const raw = await billingReader(account, expectedOrganization, fetch, setTimeout, clearTimeout, MockAbortController);
  assert.equal(unexpectedFetch, false, 'Reader made an unexpected request');
  assert.equal(calls.length, steps.length, 'Reader did not make the expected requests');
  assert.equal(controllers.length, 1);
  assert.equal(timers.length, 1);
  assert.equal(timers[0].delay, 10_000, 'Reader must retain a bounded request timeout');
  assert.equal(timers[0].cleared, true, 'Reader must clear its timer on every return path');
  for (const [index, call] of calls.entries()) {
    assert.equal(call.path, index === 0 ? bootstrapPath : index === 1 ? billingPath(expectedOrganization) : resetPath(expectedOrganization));
    assert.equal(call.options.credentials, 'include');
    assert.equal(call.options.redirect, 'error', 'Authenticated requests must not follow redirects');
    assert.equal(call.options.cache, 'no-store');
    assert.equal(call.options.signal, controllers[0].signal);
    assert.equal(call.options.method ?? 'GET', 'GET');
    assert.equal(call.options.body, undefined);
    assert.deepEqual(call.options.headers, { Accept: 'application/json' });
  }
  assert.equal(typeof raw, 'string');
  assert.equal(raw.includes(sensitive), false, 'Reader exported a private fixture value');
  const envelope = JSON.parse(raw);
  if ('error' in envelope) {
    assert.deepEqual(Object.keys(envelope), ['error']);
    assert.ok(['wrongAccount', 'signedOut', 'unavailable'].includes(envelope.error));
  } else {
    assert.deepEqual(Object.keys(envelope).sort(), ['accountUUID', 'details', 'organizationUUID', 'resetDetails']);
    assert.equal(envelope.accountUUID, account);
    assert.equal(envelope.organizationUUID, expectedOrganization);
    assert.ok(Object.keys(envelope.details).every(key => allowedFields.includes(key)));
    if (envelope.details.gift_details) {
      assert.ok(Object.keys(envelope.details.gift_details).every(key => key === 'paid_through'));
    }
  }
  return { envelope, calls, jsonReads, aborted: controllers[0].signal.aborted };
}

const cases = [];
const test = (name, run) => cases.push({ name, run });
const expectError = async (steps, error, jsonReads) => {
  const result = await execute(steps);
  assert.deepEqual(result.envelope, { error });
  if (jsonReads !== undefined) assert.equal(result.jsonReads, jsonReads);
};

test('reads full reset grants without exporting profile or usage data', async () => {
  const grant = {id:'launch-reset',resets_left:1,clears:['five_hour','seven_day'],
    starts_at:'2026-09-22T16:00:00Z',ends_at:'2026-10-22T16:00:00Z',paused:false,usable_now:true};
  const result = await execute([response(bootstrap()),response({status:'active'}),
    response({cedar_ember:{eligible:true,grants:[{...grant,event_props:sensitive}],event_props:sensitive},spend:sensitive})]);
  assert.deepEqual(result.envelope.resetDetails,{eligible:true,grants:[grant]});
});
for (const status of [401,403,429,500]) {
  test(`reset HTTP ${status} preserves billing without inventing zero resets`,async()=>{
    const result=await execute([response(bootstrap()),response({status:'active'}),response({error:sensitive},status)]);
    assert.deepEqual(result.envelope.details,{status:'active'});
    assert.equal(result.envelope.resetDetails,null);
  });
}
test('missing reset block remains unavailable',async()=>{
  const result=await execute([response(bootstrap()),response({status:'active'}),response({five_hour:null})]);
  assert.equal(result.envelope.resetDetails,null);
});

test('uses the matching non-first organization and exports only display metadata', async () => {
  const id = 'synthetic-org /?%';
  const details = {
    next_charge_at: '2026-09-28T09:00:00Z', next_charge_date: '2026-09-28',
    plan_ending_at: '2027-01-28T09:00:00Z', plan_ending_before: '2027-01-28',
    status: 'active', payment_paused_until: 1_800_000_000,
    gift_details: { paid_through: '2027-01-27', sender_email: sensitive, redemption_code: sensitive },
    customer_id: sensitive, payment_method: { details: sensitive }, access_token: sensitive,
  };
  const result = await execute([
    response(bootstrap({ memberships: [
      { organization: { uuid: 'another-organization' } },
      { organization: { uuid: id } },
    ] })), response(details),
  ], id);
  assert.deepEqual(result.envelope.details, {
    next_charge_at: details.next_charge_at, next_charge_date: details.next_charge_date,
    plan_ending_at: details.plan_ending_at, plan_ending_before: details.plan_ending_before,
    status: 'active', payment_paused_until: 1_800_000_000,
    gift_details: { paid_through: '2027-01-27' },
  });
  assert.equal(result.jsonReads, 3);
  assert.equal(result.aborted, false);
});

test('does not invent missing dates', async () => {
  const result = await execute([response(bootstrap()), response({ status: 'canceled', extra: sensitive })]);
  assert.deepEqual(result.envelope.details, { status: 'canceled' });
});
test('keeps null dates and gift coverage as null', async () => {
  const details = Object.fromEntries(allowedFields.map(key => [key, null]));
  const result = await execute([response(bootstrap()), response({ ...details, extra: sensitive })]);
  assert.deepEqual(result.envelope.details, details);
});
test('does not export gift metadata when paid_through is missing', async () => {
  const result = await execute([response(bootstrap()), response({ status: 'active', gift_details: { sender: sensitive } })]);
  assert.deepEqual(result.envelope.details, { status: 'active', gift_details: {} });
});

for (const [name, overrides] of [
  ['wrong account', { uuid: 'another-account' }],
  ['wrong organization', { memberships: [{ organization: { uuid: 'another-organization' } }] }],
  ['missing memberships', { memberships: undefined }],
  ['non-array memberships', { memberships: { uuid: organization } }],
  ['empty memberships', { memberships: [] }],
]) {
  test(`${name} never requests billing`, () => expectError([response(bootstrap(overrides))], 'wrongAccount', 1));
}
test('missing account never requests billing', () => expectError([response({ session: sensitive })], 'signedOut', 1));
test('missing account UUID never requests billing', () => expectError([response(bootstrap({ uuid: undefined }))], 'signedOut', 1));
test('malformed membership never requests billing', () => expectError([response(bootstrap({ memberships: [null] }))], 'unavailable', 1));

for (const stage of ['bootstrap', 'billing']) {
  const prefix = stage === 'billing' ? [response(bootstrap())] : [];
  for (const status of [401, 403, 500, 301, 302, 307, 308]) {
    test(`${stage} HTTP ${status} is sanitized without parsing its body`, () => expectError(
      [...prefix, response({ error: sensitive }, status)],
      status === 401 || status === 403 ? 'signedOut' : 'unavailable', prefix.length,
    ));
  }
  test(`${stage} invalid JSON is sanitized`, () => expectError(
    [...prefix, { status: 200, jsonError: sensitive }], 'unavailable', prefix.length + 1,
  ));
  test(`${stage} rejected fetch is sanitized`, () => expectError(
    [...prefix, { fetchError: `Redirect or network failure: ${sensitive}` }], 'unavailable', prefix.length,
  ));
  test(`${stage} timeout aborts the shared signal and is sanitized`, async () => {
    const result = await execute([...prefix, { abort: true }]);
    assert.equal(result.aborted, true);
    assert.deepEqual(result.envelope, { error: 'unavailable' });
  });
}
test('null bootstrap response is sanitized', () => expectError([response(null)], 'unavailable', 1));
for (const [name, body] of [['string', sensitive], ['number', 42], ['boolean', false], ['array', []]]) {
  test(`${name} bootstrap response cannot request billing`, () => expectError([response(body)], 'signedOut', 1));
}
for (const [name, body] of [['null', null], ['string', sensitive], ['number', 42], ['boolean', false]]) {
  test(`${name} billing response is sanitized`, () => expectError([response(bootstrap()), response(body)], 'unavailable', 2));
}

// Even accidental access to global fetch must fail locally. The reader only receives our mock.
const originalFetch = globalThis.fetch;
let globalFetchCalls = 0;
globalThis.fetch = async () => {
  globalFetchCalls += 1;
  throw new Error('Network access is disabled in billing-reader tests');
};
try {
  for (const { name, run } of cases) {
    try { await run(); }
    catch (error) { throw new Error(`Billing reader case failed: ${name}`, { cause: error }); }
  }
  assert.equal(globalFetchCalls, 0, 'Production reader bypassed its injected fetch');
  console.log(`Billing reader: ${cases.length} offline cases passed; no network or credentials accessed.`);
} finally {
  globalThis.fetch = originalFetch;
}
