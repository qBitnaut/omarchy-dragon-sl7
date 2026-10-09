'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadLib } = require('./load-lib');

const Protocol = loadLib('Protocol.js');

test('nextId increments and resetIds restarts at 1', () => {
  Protocol.resetIds();
  assert.equal(Protocol.nextId(), 1);
  assert.equal(Protocol.nextId(), 2);
  Protocol.resetIds();
  assert.equal(Protocol.nextId(), 1);
});

test('buildRequest omits args when not given', () => {
  const req = Protocol.buildRequest('ping', undefined, 1);
  assert.deepEqual(req, { v: 1, id: 1, cmd: 'ping' });
});

test('buildRequest includes args when given', () => {
  const req = Protocol.buildRequest('subscribe', { topics: ['status'], rate: 'fast' }, 2);
  assert.deepEqual(req, { v: 1, id: 2, cmd: 'subscribe', args: { topics: ['status'], rate: 'fast' } });
});

test('parseLine returns null for malformed JSON instead of throwing', () => {
  assert.equal(Protocol.parseLine('not json'), null);
  assert.equal(Protocol.parseLine(''), null);
  assert.equal(Protocol.parseLine(null), null);
});

test('parseLine parses a valid envelope', () => {
  const msg = Protocol.parseLine('{"v":1,"type":"hello","daemon":"cyberpowerd"}');
  assert.equal(msg.type, 'hello');
});

test('isHello/isResponse/isPush classify envelopes', () => {
  assert.equal(Protocol.isHello({ type: 'hello' }), true);
  assert.equal(Protocol.isResponse({ type: 'response' }), true);
  assert.equal(Protocol.isPush({ type: 'push' }), true);
  assert.equal(Protocol.isHello({ type: 'push' }), false);
  assert.equal(Protocol.isHello(null), false);
});

test('isOk requires a response envelope with ok true', () => {
  assert.equal(Protocol.isOk({ type: 'response', ok: true }), true);
  assert.equal(Protocol.isOk({ type: 'response', ok: false }), false);
  assert.equal(Protocol.isOk({ type: 'push', ok: true }), false);
});

test('errorText formats code and message, or just code', () => {
  assert.equal(Protocol.errorText({ code: 'conflict', message: 'stale rev' }), 'conflict: stale rev');
  assert.equal(Protocol.errorText({ code: 'forbidden' }), 'forbidden');
  assert.equal(Protocol.errorText(null), '');
});
