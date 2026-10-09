'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadLib } = require('./load-lib');

const Spark = loadLib('Spark.js');

test('resample returns exactly `columns` entries', () => {
  assert.equal(Spark.resample([1, 2, 3, 4, 5, 6, 7, 8], 4).length, 4);
  assert.equal(Spark.resample([1, 2], 5).length, 5);
  assert.deepEqual(Spark.resample([], 3), [null, null, null]);
  assert.deepEqual(Spark.resample([1, 2], 0), []);
});

test('resample averages each bucket when downsampling', () => {
  assert.deepEqual(Spark.resample([1, 3, 5, 7], 2), [2, 6]);
});

test('resample keeps an all-null bucket as a gap and ignores nulls otherwise', () => {
  assert.deepEqual(Spark.resample([null, null, 4, null], 2), [null, 4]);
});

test('resample repeats the nearest point when upsampling', () => {
  assert.deepEqual(Spark.resample([10, 20], 4), [10, 10, 20, 20]);
});

test('levels maps null to -1 and a real minimum to one lit dot', () => {
  assert.deepEqual(Spark.levels([null, 0, 100], 0, 100, 6), [-1, 1, 6]);
});

test('levels rounds to the nearest row and clamps out-of-range values', () => {
  assert.deepEqual(Spark.levels([50, -20, 250], 0, 100, 4), [2, 1, 4]);
});

test('levels on a degenerate scale lights the full column', () => {
  assert.deepEqual(Spark.levels([5], 5, 5, 3), [3]);
});

test('latest returns the last non-null value', () => {
  assert.equal(Spark.latest([1, 2, null]), 2);
  assert.equal(Spark.latest([null, null]), null);
});

test('columnsFor fits whole dots including the trailing gap', () => {
  // 10 dots of 3 px with 2 px gaps: 10 * 3 + 9 * 2 = 48 px
  assert.equal(Spark.columnsFor(48, 3, 2), 10);
  assert.equal(Spark.columnsFor(47, 3, 2), 9);
  assert.equal(Spark.columnsFor(0, 3, 2), 1);
});

test('zeroScale anchors the axis at zero', () => {
  assert.deepEqual(Spark.zeroScale([260, 280]), { min: 0, max: 280 });
  assert.deepEqual(Spark.zeroScale([null]), { min: 0, max: 1 });
});

test('voltageScale widens to the nominal +-8/+3 band when data is tight around nominal', () => {
  const scale = Spark.voltageScale(120, [119, 120, 121]);
  assert.equal(scale.min, 112); // 120 - 8
  assert.equal(scale.max, 123); // 120 + 3
});

test('voltageScale widens further when data exceeds the nominal band', () => {
  const scale = Spark.voltageScale(120, [95, 140]);
  assert.equal(scale.min, 95);
  assert.equal(scale.max, 140);
});

test('voltageScale ignores nulls when computing the data extremes', () => {
  const scale = Spark.voltageScale(120, [null, 119, null, 121]);
  assert.equal(scale.min, 112);
  assert.equal(scale.max, 123);
});

test('autoScale returns a degenerate-safe 0..1 range for an all-null series', () => {
  const scale = Spark.autoScale([null, null]);
  assert.equal(scale.min, 0);
  assert.equal(scale.max, 1);
});

test('autoScale widens a single repeated value so max > min', () => {
  const scale = Spark.autoScale([50, 50, 50]);
  assert.equal(scale.min, 49);
  assert.equal(scale.max, 51);
});

test('autoScale spans the real min/max of the data', () => {
  const scale = Spark.autoScale([10, 40, 25, null, 5]);
  assert.equal(scale.min, 5);
  assert.equal(scale.max, 40);
});

test('extent reports the data min/max, skipping nulls, and null for an empty series', () => {
  assert.deepEqual(Spark.extent([3, null, 1, 7, '5']), { min: 1, max: 7 });
  assert.deepEqual(Spark.extent([4]), { min: 4, max: 4 });
  assert.equal(Spark.extent([]), null);
  assert.equal(Spark.extent([null, null]), null);
});
