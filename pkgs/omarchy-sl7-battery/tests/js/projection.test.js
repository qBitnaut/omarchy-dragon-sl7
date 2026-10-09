'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadLib } = require('./load-lib');

const P = loadLib('Projection.js');

const at = (d, h, m) => new Date(2026, 9, d, h, m).getTime(); // 2026-10-08 is a Thursday

test('blendRate: ewma alone early, blended once there is history', () => {
  assert.equal(P.blendRate(null, null, 0), null);
  assert.equal(P.blendRate(5, null, 3600), 5);
  assert.equal(P.blendRate(5, 3, 600), 5);
  assert.equal(P.blendRate(null, 3, 3600), 3);
  assert.ok(Math.abs(P.blendRate(10, 4, 7200) - 8.2) < 1e-9);
});

test('secondsToEmpty: constant draw, refuses tiny rates', () => {
  assert.equal(P.secondsToEmpty(50, 50, 5), 5 * 3600);
  assert.equal(P.secondsToEmpty(50, 50, 0.29), null);
  assert.equal(P.secondsToEmpty(null, 50, 5), null);
});

test('timeLabel: tonight, afternoon, today, tomorrow, weekday', () => {
  assert.equal(P.timeLabel(at(8, 22, 40), at(8, 20, 0)), 'Tonight 10:40pm');
  assert.equal(P.timeLabel(at(8, 22, 0), at(8, 20, 0)), 'Tonight 10pm');
  assert.equal(P.timeLabel(at(8, 15, 3), at(8, 13, 0)), 'This afternoon 3pm');
  assert.equal(P.timeLabel(at(8, 11, 4), at(8, 8, 0)), 'Today 11am');
  assert.equal(P.timeLabel(at(9, 2, 7), at(8, 23, 30)), 'Tomorrow 2:10am');
  assert.equal(P.timeLabel(at(10, 9, 0), at(8, 20, 0)), 'Sat 9am');
});

test('timeLabel: rounding past midnight moves to tomorrow; noon and midnight read 12', () => {
  assert.equal(P.timeLabel(at(8, 23, 57), at(8, 23, 30)), 'Tomorrow 12am');
  assert.equal(P.timeLabel(at(8, 12, 0), at(8, 11, 0)), 'This afternoon 12pm');
  assert.equal(P.timeLabel(null, at(8, 11, 0)), '—');
});

test('roundTarget: 10 minutes near, 15 minutes far', () => {
  assert.equal(P.roundTarget(at(8, 12, 7), at(8, 11, 0)), at(8, 12, 10));
  assert.equal(P.roundTarget(at(8, 16, 8), at(8, 11, 0)), at(8, 16, 15));
});

test('estimate: discharging needs five minutes of data and a real rate', () => {
  const base = { present: true, flow: 'discharging', charge: 50, energy_full_wh: 50, ewma_w: 5, avg_since_unplug_w: null, since_unplug_s: 120 };
  const now = at(8, 20, 0);
  const early = P.estimate(base, now);
  assert.equal(early.ok, false);
  assert.equal(early.label, '—');
  const ok = P.estimate({ ...base, since_unplug_s: 600 }, now);
  assert.equal(ok.mode, 'discharging');
  assert.equal(ok.seconds, 5 * 3600);
  assert.equal(ok.label, 'Tomorrow 1am');
  const idle = P.estimate({ ...base, since_unplug_s: 600, ewma_w: 0.1 }, now);
  assert.equal(idle.ok, false);
});

test('estimate: charging tapers above 80%, stops at the charge limit', () => {
  const now = at(8, 9, 0);
  const s = { present: true, flow: 'charging', charge: 50, energy_full_wh: 50, charge_w: 25, charge_limit: null };
  const full = P.estimate(s, now);
  assert.equal(full.mode, 'charging');
  assert.ok(full.seconds > 3600 && full.seconds < 3600 * 1.6, String(full.seconds));
  const limited = P.estimate({ ...s, charge_limit: 80 }, now);
  assert.equal(limited.target, 80);
  assert.ok(Math.abs(limited.seconds - 2160) < 1e-6);
  assert.equal(P.estimate({ ...s, charge: 100 }, now).ok, false);
  assert.equal(P.estimate({ ...s, charge_w: 0.1 }, now).ok, false);
});

test('estimate: idle or missing status gives nothing', () => {
  assert.equal(P.estimate(null, 0).mode, 'none');
  assert.equal(P.estimate({ present: false }, 0).mode, 'none');
  assert.equal(P.estimate({ present: true, flow: 'idle', charge: 100, energy_full_wh: 50 }, 0).label, '—');
});

test('pctAt and futureValues follow the projection to its end', () => {
  const est = { mode: 'discharging', ok: true, seconds: 36000 };
  assert.equal(P.pctAt(est, 60, 0), 60);
  assert.equal(P.pctAt(est, 60, 18000), 30);
  assert.equal(P.pctAt(est, 60, 40000), 0);
  const v = P.futureValues(est, 60, 12000, 4);
  assert.deepEqual(v.map(Math.round), [40, 20, 0, 0]);
  assert.deepEqual(P.futureValues({ ok: false }, 60, 1000, 3), []);
});

test('layout: same step both sides, past keeps at least 40%', () => {
  const l = P.layout(60, 21600, 21600);
  assert.equal(l.pastCols, 30);
  assert.equal(l.futureCols, 30);
  assert.equal(l.stepS, 720);
  const far = P.layout(60, 21600, 21600 * 20);
  assert.equal(far.pastCols, 24);
  assert.equal(far.futureCols, 36);
  const none = P.layout(60, 21600, 0);
  assert.equal(none.futureCols, 0);
  assert.equal(none.pastCols, 60);
  const near = P.layout(60, 21600, 60);
  assert.equal(near.futureCols, 3);
});

test('charging table is monotonic and reaches the target', () => {
  const t = P.chargeTable(20, 100, 50, 30);
  for (let i = 1; i < t.length; i++) {
    assert.ok(t[i][0] > t[i - 1][0] && t[i][1] > t[i - 1][1]);
  }
  assert.equal(t[t.length - 1][1], 100);
  assert.equal(P.tableAt(t, 0), 20);
  assert.equal(P.tableAt(t, 1e9), 100);
});

test('durationLabel and sinceFullLabel', () => {
  assert.equal(P.durationLabel(14 * 3600 + 20 * 60), '14h 20m');
  assert.equal(P.durationLabel(45 * 60), '45m');
  assert.equal(P.durationLabel(null), '—');
  assert.equal(P.sinceFullLabel({ secs: 14 * 3600 + 20 * 60, used_pct: 61.6 }), '14h 20m since full · 62% used');
  assert.equal(P.sinceFullLabel(null), '');
  assert.equal(P.sinceFullLabel({ secs: 600 }), '10m since full');
});
