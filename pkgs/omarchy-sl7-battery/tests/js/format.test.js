'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadLib } = require('./load-lib');

const Format = loadLib('Format.js');

test('batteryGlyph picks the alert glyph below 10%', () => {
  assert.equal(Format.batteryGlyph(0, false), String.fromCodePoint(0xF0083));
  assert.equal(Format.batteryGlyph(5, false), String.fromCodePoint(0xF0083));
  assert.equal(Format.batteryGlyph(NaN, false), String.fromCodePoint(0xF0083));
});

test('batteryGlyph rounds to the nearest 10% bucket while on mains (not charging)', () => {
  assert.equal(Format.batteryGlyph(100, false), String.fromCodePoint(0xF0079));
  assert.equal(Format.batteryGlyph(87, false), String.fromCodePoint(0xF0082)); // rounds to 90
  assert.equal(Format.batteryGlyph(14, false), String.fromCodePoint(0xF007A)); // rounds to 10
});

test('batteryGlyph uses the charging table when charging is true', () => {
  assert.equal(Format.batteryGlyph(100, true), String.fromCodePoint(0xF0085));
  assert.equal(Format.batteryGlyph(50, true), String.fromCodePoint(0xF089D));
});

test('glyph returns the known codepoints and empty string for unknown names', () => {
  assert.equal(Format.glyph('power_plug'), String.fromCodePoint(0xF06A5));
  assert.equal(Format.glyph('power_plug_off'), String.fromCodePoint(0xF06A6));
  assert.equal(Format.glyph('nonexistent'), '');
});

test('durationShort formats hours, minutes and seconds', () => {
  assert.equal(Format.durationShort(30), '30s');
  assert.equal(Format.durationShort(90), '1m');
  assert.equal(Format.durationShort(3661), '1h 1m');
  assert.equal(Format.durationShort(1548), '25m');
});

test('countdownClock formats mm:ss with a zero-padded seconds field', () => {
  assert.equal(Format.countdownClock(45), '0:45');
  assert.equal(Format.countdownClock(125), '2:05');
  assert.equal(Format.countdownClock(0), '0:00');
});

test('fixed rounds float noise and renders a missing reading as an em dash', () => {
  assert.equal(Format.fixed(27.399999618530273, 1, ' V'), '27.4 V');
  assert.equal(Format.fixed(null, 1, ' V'), '—');
  assert.equal(Format.fixed('abc', 0), '—');
  assert.equal(Format.fixed(3, 0), '3');
});

test('money adds the currency and thousands separators', () => {
  assert.equal(Format.money(1204.5, '$'), '$1,204.50');
  assert.equal(Format.money(0.29), '$0.29');
  assert.equal(Format.money(null, '€'), '—');
});
