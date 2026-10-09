'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadLib } = require('./load-lib');

const P = loadLib('Projection.js');

const at = (d, h, m) => new Date(2026, 9, d, h, m).getTime(); // 2026-10-08 is a Thursday

test('blendRate: recent alone early, weighted with the awake average once there is coverage', () => {
  assert.equal(P.blendRate(null, null, 0), null);
  assert.equal(P.blendRate(5, null, 3600), 5);
  assert.equal(P.blendRate(5, 3, 200), 5);
  assert.equal(P.blendRate(5, 3, null), 5);
  assert.equal(P.blendRate(null, 3, 3600), 3);
  // 18 min of coverage: w = 0.3, no cap yet.
  assert.ok(Math.abs(P.blendRate(10, 4, 1080) - (0.3 * 4 + 0.7 * 10)) < 1e-9);
  // 2 h: w = 0.5 and the EWMA is capped at 2 x 4 = 8.
  assert.ok(Math.abs(P.blendRate(10, 4, 7200) - 6) < 1e-9);
  // With the median: recent = 0.75 * 5 + 0.25 * 8 (capped) = 5.75.
  assert.ok(Math.abs(P.blendRate(10, 4, 7200, 5) - (0.5 * 4 + 0.5 * 5.75)) < 1e-9);
});

test('estimate: a night asleep does not make the time left optimistic', () => {
  // 40 Wh left; awake draw 5 W for 2 h after a night at 0.3 W. The old wall-time average
  // was about 1 W; the awake-only average is 5 W, so about 8 h, not 16 h+.
  const s = { present: true, flow: 'discharging', charge: 80, energy_full_wh: 50, ewma_w: 5,
    avg_since_unplug_w: 1, since_unplug_s: 10 * 3600, avg_awake_w_since_unplug: 5, awake_s_since_unplug: 7200 };
  const e = P.estimate(s, at(8, 8, 0));
  assert.equal(e.ok, true);
  assert.ok(Math.abs(e.rateW - 5) < 1e-9);
  assert.ok(Math.abs(e.seconds - 8 * 3600) < 1e-6);
  // Little awake time (10 min): the average carries 30%.
  const early = P.estimate({ ...s, avg_awake_w_since_unplug: 1, awake_s_since_unplug: 600 }, at(8, 8, 0));
  assert.ok(Math.abs(early.rateW - (0.3 * 1 + 0.7 * 5)) < 1e-9);
});

// Chris's case: 27.57 Wh left, daemon restarted after a package update. Persisted accumulators:
// 3 h awake at 5 W, then a 10-minute 14 W burst; the daemon's EWMA is 10-14 W, the median of
// the last 30 awake minutes is 5 W.
test('estimate: a restart burst does not halve the time left', () => {
  const base = { present: true, flow: 'discharging', charge: 55, energy_full_wh: 50.12, power_w: 3.65,
    avg_since_unplug_w: 2, since_unplug_s: 54892, awake_s_since_unplug: 11400, avg_awake_w_since_unplug: 5.47, recent_w: 5 };
  const left = (s) => 27.57 / P.estimate(s, at(9, 14, 0)).rateW;
  for (const ewma of [10.1, 13.72]) {
    const h = left({ ...base, ewma_w: ewma });
    assert.ok(h > 4.5 && h < 5.5, 'ewma ' + ewma + ' -> ' + h + ' h');
  }
  const e = P.estimate({ ...base, ewma_w: 13.72 }, at(9, 14, 0));
  assert.equal(e.ok, true);
  // Daemon without recent_w (old build) but with the persisted average: the EWMA is capped at
  // twice the average, so about 3.4 h rather than ~2 h.
  const h = left({ ...base, recent_w: null, ewma_w: 13.72 });
  assert.ok(h > 3 && h < 4, String(h));
});

test('estimate: sustained heavier load moves the estimate toward it', () => {
  // 2 h at 5 W, then 30 min at 12 W: average 6.4 W over 2.5 h, median 12, EWMA ~11.4.
  const s = { present: true, flow: 'discharging', charge: 60, energy_full_wh: 50, ewma_w: 11.4,
    avg_awake_w_since_unplug: 6.4, awake_s_since_unplug: 9000, recent_w: 12, since_unplug_s: 9000 };
  const rate = P.estimate(s, at(9, 14, 0)).rateW;
  assert.ok(rate > 8.5 && rate < 10, String(rate));
  assert.ok((rate - 5) / (12 - 5) > 0.5);
  // Half-way through the burst (15 min at 12 W) the median has not flipped yet: it already moves.
  const mid = P.estimate({ ...s, ewma_w: 8.5, recent_w: 5, avg_awake_w_since_unplug: 5.7, awake_s_since_unplug: 8100 }, at(9, 14, 0)).rateW;
  assert.ok(mid > 5.5, String(mid));
});

test('estimate: learning while there is under five awake minutes', () => {
  const s = { present: true, flow: 'discharging', charge: 55, energy_full_wh: 50, ewma_w: 14, since_unplug_s: 5000,
    avg_awake_w_since_unplug: null, awake_s_since_unplug: 160 };
  const e = P.estimate(s, at(9, 14, 0));
  assert.equal(e.ok, false);
  assert.equal(P.wording(s, e, at(9, 14, 0)).detail, 'learning the rate');
  // The same after a restart with persisted accumulators shows a figure.
  assert.equal(P.estimate({ ...s, awake_s_since_unplug: 9000, avg_awake_w_since_unplug: 5 }, at(9, 14, 0)).ok, true);
});

test('sleepLeftLabel: days, hours, minutes, unknown', () => {
  assert.equal(P.sleepLeftLabel(5 * 86400), '≈ 5 days');
  assert.equal(P.sleepLeftLabel(18 * 3600), '≈ 18h');
  assert.equal(P.sleepLeftLabel(90), '≈ 2m');
  assert.equal(P.sleepLeftLabel(null), '');
  assert.equal(P.sleepLeftLabel(0), '');
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
  const base = { present: true, flow: 'discharging', charge: 50, energy_full_wh: 50, ewma_w: 5, avg_since_unplug_w: null, since_unplug_s: 120, awake_s_since_unplug: 120 };
  const now = at(8, 20, 0);
  const early = P.estimate(base, now);
  assert.equal(early.ok, false);
  assert.equal(early.label, '—');
  const ok = P.estimate({ ...base, since_unplug_s: 600, awake_s_since_unplug: 600 }, now);
  assert.equal(ok.mode, 'discharging');
  assert.equal(ok.seconds, 5 * 3600);
  assert.equal(ok.label, 'Tomorrow 1am');
  const idle = P.estimate({ ...base, since_unplug_s: 600, awake_s_since_unplug: 600, ewma_w: 0.1 }, now);
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

test('wording: discharging says time left until a time', () => {
  const now = at(8, 20, 0);
  const st = { present: true, flow: 'discharging', charge: 50, energy_full_wh: 50, ewma_w: 5, since_unplug_s: 600, awake_s_since_unplug: 600 };
  const w = P.wording(st, P.estimate(st, now), now);
  assert.equal(w.title, 'Time left');
  assert.equal(w.detail, 'until Tomorrow 1am');
  assert.equal(w.tooltip, '5h 0m left');
  assert.equal(w.caption, 'Projected empty by Tomorrow 1am');
  assert.equal(w.endLabel, 'Tomorrow 1am');
  const early = P.wording({ ...st, since_unplug_s: 60 }, P.estimate({ ...st, since_unplug_s: 60 }, now), now);
  assert.equal(early.detail, 'learning the rate');
  assert.equal(early.endLabel, 'now');
});

test('wording: charging reads "full at" today, "full by" later, and names the limit', () => {
  const now = at(8, 14, 0);
  const st = { present: true, flow: 'charging', charge: 50, energy_full_wh: 50, charge_w: 25, charge_limit: null };
  const w = P.wording(st, P.estimate(st, now), now);
  assert.equal(w.title, 'Time to full');
  assert.match(w.detail, /^full at \d{1,2}(:\d\d)?pm$/);
  assert.match(w.tooltip, /^full in /);
  assert.match(w.caption, /^Projected 100% at /);
  const night = at(8, 23, 0);
  const slow = { ...st, charge: 5, charge_w: 2 };
  const wl = P.wording(slow, P.estimate(slow, night), night);
  assert.match(wl.detail, /^full by (Tomorrow|Fri|Sat|Sun|Mon|Tue|Wed) /);
  const lim = { ...st, charge_limit: 80 };
  const wm = P.wording(lim, P.estimate(lim, now), now);
  assert.equal(wm.title, 'Time to 80%');
  assert.match(wm.detail, /^80% at /);
  assert.match(wm.tooltip, /^80% in /);
});

test('wording: plugged in and not charging has no time', () => {
  const now = at(8, 14, 0);
  const full = { present: true, flow: 'idle', charge: 100, full: true, energy_full_wh: 50 };
  const w = P.wording(full, P.estimate(full, now), now);
  assert.equal(w.detail, 'Fully charged');
  assert.equal(w.tooltip, 'fully charged');
  const hold = { present: true, flow: 'idle', charge: 80, full: false, charge_limit: 80, energy_full_wh: 50 };
  const h = P.wording(hold, P.estimate(hold, now), now);
  assert.equal(h.detail, 'holding at 80%');
  assert.equal(h.endLabel, 'now');
});
