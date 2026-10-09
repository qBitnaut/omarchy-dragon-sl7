.pragma library

// Battery projection and time labels. Pure functions, no Quickshell APIs, exercised with
// `node --test` (tests/js/projection.test.js). The popup feeds in the daemon's status
// object and gets back the time left, the end label ("Tonight 10:40pm") and the future
// dot columns of the charge chart.

var MIN_RATE_W = 0.3
var MIN_DATA_S = 300
var TAPER_FROM = 80

function _num(v) {
    if (v === null || v === undefined) return null
    var n = Number(v)
    return isNaN(n) ? null : n
}

// Discharge rate in watts: the daemon's EWMA of the draw blended 70/30 with the average
// draw over AWAKE time since unplug (suspend is excluded, so a night asleep does not make
// the estimate optimistic). With less than 15 minutes of awake data the EWMA alone.
function blendRate(ewma, avgAwakeW, awakeS) {
    var e = _num(ewma)
    var a = _num(avgAwakeW)
    var awake = _num(awakeS)
    if (e === null && a === null) return null
    if (e === null) return a
    if (a === null || awake === null || awake < 900) return e
    return 0.7 * e + 0.3 * a
}

// "≈ 5 days" / "≈ 18h" for the time left if the machine slept from now on, or "" when
// unknown.
function sleepLeftLabel(seconds) {
    var s = _num(seconds)
    if (s === null || s <= 0) return ""
    var h = s / 3600
    if (h >= 48) return "≈ " + Math.round(h / 24) + " days"
    if (h >= 1) return "≈ " + Math.round(h) + "h"
    return "≈ " + Math.max(1, Math.round(s / 60)) + "m"
}

// Energy left in Wh.
function remainingWh(chargePct, energyFullWh) {
    var c = _num(chargePct)
    var f = _num(energyFullWh)
    if (c === null || f === null) return null
    return Math.max(0, c) / 100 * f
}

// Seconds until empty at a constant draw, or null when the rate is too low to say.
function secondsToEmpty(chargePct, energyFullWh, rateW) {
    var wh = remainingWh(chargePct, energyFullWh)
    var r = _num(rateW)
    if (wh === null || r === null || r < MIN_RATE_W) return null
    return wh / r * 3600
}

// Charging slows above TAPER_FROM: the rate falls linearly to 20% of the full-speed
// rate at 100%.
function chargeRateAt(pct, fullRateW) {
    if (pct <= TAPER_FROM) return fullRateW
    var f = 1 - 0.8 * Math.min(1, (pct - TAPER_FROM) / (100 - TAPER_FROM))
    return fullRateW * f
}

// Table of [seconds since now, percent] points, one per percent, charging from `pct` to
// `target`. Null when it cannot be computed.
function chargeTable(pct, target, energyFullWh, chargeW) {
    var p = _num(pct)
    var t = _num(target)
    var f = _num(energyFullWh)
    var w = _num(chargeW)
    if (p === null || t === null || f === null || w === null || w < MIN_RATE_W || f <= 0) return null
    if (p >= t) return null
    var table = [[0, p]]
    var secs = 0
    var cur = p
    while (cur < t - 1e-9) {
        var step = Math.min(1, t - cur)
        var mid = cur + step / 2
        var rate = chargeRateAt(mid, w)
        secs += step / 100 * f / rate * 3600
        cur += step
        table.push([secs, cur])
    }
    return table
}

// Percent at `t` seconds from a monotonic table, clamped to its ends.
function tableAt(table, t) {
    if (!table || table.length === 0) return null
    if (t <= table[0][0]) return table[0][1]
    var last = table[table.length - 1]
    if (t >= last[0]) return last[1]
    for (var i = 1; i < table.length; i++) {
        if (t <= table[i][0]) {
            var a = table[i - 1]
            var b = table[i]
            var span = b[0] - a[0]
            return span > 0 ? a[1] + (b[1] - a[1]) * (t - a[0]) / span : b[1]
        }
    }
    return last[1]
}

// The estimate shown in the tile and at the end of the projection.
//   status: the daemon's status object; nowMs: Date.now()
// Returns { mode: "discharging"|"charging"|"none", ok, rateW, seconds, endMs, label,
//           target, table }. `ok` is false when there is no trustworthy figure (rate
// below 0.3 W or less than five minutes of data); label is then "—".
function estimate(status, nowMs) {
    var none = { mode: "none", ok: false, rateW: null, seconds: null, endMs: null, label: "—", target: null, table: null }
    if (!status || status.present === false) return none
    var charge = _num(status.charge)
    var full = _num(status.energy_full_wh)
    if (charge === null || full === null) return none
    if (status.flow === "discharging") {
        var rate = blendRate(status.ewma_w, status.avg_awake_w_since_unplug, status.awake_s_since_unplug)
        var since = _num(status.since_unplug_s)
        var enough = since === null ? false : since >= MIN_DATA_S
        var secs = enough ? secondsToEmpty(charge, full, rate) : null
        var r = { mode: "discharging", ok: secs !== null, rateW: rate, seconds: secs, endMs: null, label: "—", target: 0, table: null }
        if (secs !== null) {
            r.endMs = nowMs + secs * 1000
            r.label = timeLabel(r.endMs, nowMs)
        }
        return r
    }
    if (status.flow === "charging") {
        var limit = _num(status.charge_limit)
        var target = limit !== null && limit > 0 && limit < 100 ? limit : 100
        var table = chargeTable(charge, target, full, status.charge_w)
        var c = { mode: "charging", ok: table !== null, rateW: _num(status.charge_w), seconds: null, endMs: null, label: "—", target: target, table: table }
        if (table) {
            c.seconds = table[table.length - 1][0]
            c.endMs = nowMs + c.seconds * 1000
            c.label = timeLabel(c.endMs, nowMs)
        }
        return c
    }
    return none
}

// Mode-aware wording for the estimate, so every surface says the same thing.
//   status: the daemon's status object; est: estimate(status, nowMs)
// Returns { title, detail, tooltip, caption, endLabel }:
//   discharging  "Time left"            "until Tonight 10:40pm"      "3h 10m left"
//   charging     "Time to full" / "Time to 80%" (charge limit)
//                                       "full at 3:40pm" (today) / "full by Tomorrow 12pm"
//   not charging "Battery"              "Fully charged" / "holding at 80%", no time
// `detail`/`tooltip` fall back to "learning the rate" / "" while there is no estimate.
function wording(status, est, nowMs) {
    var w = { title: "Time left", detail: "", tooltip: "", caption: "", endLabel: "now" }
    if (!status || status.present === false) return w
    var limit = _num(status.charge_limit)
    var hasLimit = limit !== null && limit > 0 && limit < 100
    var charge = _num(status.charge)
    if (status.flow === "discharging") {
        if (est && est.ok) {
            w.detail = "until " + est.label
            w.tooltip = durationLabel(est.seconds) + " left"
            w.caption = "Projected empty by " + est.label
            w.endLabel = est.label
        } else {
            w.detail = "learning the rate"
        }
        return w
    }
    if (status.flow === "charging") {
        var goal = hasLimit ? limit + "%" : "full"
        w.title = hasLimit ? "Time to " + limit + "%" : "Time to full"
        if (est && est.ok) {
            var n = _num(nowMs)
            var target = new Date(roundTarget(est.endMs, n === null ? est.endMs : n))
            var sameDay = n !== null && Math.round((_dayStart(target) - _dayStart(new Date(n))) / 86400000) <= 0
            var when = sameDay ? "at " + _clock(target) : "by " + est.label
            w.detail = goal + " " + when
            w.tooltip = goal + " in " + durationLabel(est.seconds)
            w.caption = "Projected " + (est.target || 100) + "% " + when
            w.endLabel = est.label
        } else {
            w.detail = "learning the rate"
        }
        return w
    }
    w.title = "Battery"
    if (status.full === true || (charge !== null && charge >= 99)) w.detail = "Fully charged"
    else if (hasLimit && charge !== null) w.detail = "holding at " + Math.round(charge) + "%"
    w.tooltip = w.detail.toLowerCase()
    return w
}

// Percent at `t` seconds from now along the estimate, or null.
function pctAt(est, charge, t) {
    if (!est || !est.ok) return null
    if (est.mode === "discharging") {
        if (t >= est.seconds) return 0
        return Math.max(0, charge * (1 - t / est.seconds))
    }
    return tableAt(est.table, t)
}

// Splits `columns` chart columns between the past window and the projection. The step is
// the same on both sides, so a column always spans `windowS / pastCols` seconds. The past
// keeps at least 40% of the width; a projection longer than fits is cut off at the edge.
function layout(columns, windowS, projectionS) {
    var n = Math.max(2, Math.floor(Number(columns) || 0))
    var w = Number(windowS) || 0
    var h = Number(projectionS)
    if (!(h > 0) || !(w > 0)) return { pastCols: n, futureCols: 0, stepS: w > 0 ? w / n : 0 }
    var past = Math.round(n * w / (w + h))
    past = Math.max(Math.ceil(n * 0.4), Math.min(n - 3, past))
    return { pastCols: past, futureCols: n - past, stepS: w / past }
}

// Values for the future columns (one per column after "now"): the projected percent at
// the middle of each column; after the projection ends, 0 when emptying and the target
// when charging.
function futureValues(est, charge, stepS, futureCols) {
    var out = []
    if (!est || !est.ok) return out
    for (var i = 1; i <= futureCols; i++) {
        var v = pctAt(est, charge, i * stepS)
        out.push(v === null ? null : v)
    }
    return out
}

// ---- time labels -------------------------------------------------------------------

function _clock(d) {
    var h = d.getHours()
    var m = d.getMinutes()
    var suffix = h >= 12 ? "pm" : "am"
    var h12 = h % 12 === 0 ? 12 : h % 12
    return h12 + (m === 0 ? "" : ":" + (m < 10 ? "0" : "") + m) + suffix
}

var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

function _dayStart(d) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

// Rounds to 10 minutes within three hours, 15 minutes beyond.
function roundTarget(targetMs, nowMs) {
    var unit = (targetMs - nowMs) > 3 * 3600 * 1000 ? 15 * 60000 : 10 * 60000
    return Math.round(targetMs / unit) * unit
}

// "Tonight 10pm" (target at or after 18:00), "This afternoon 3pm" (12:00-18:00),
// "Today 11am", "Tomorrow 2am", then "Fri 9am".
function timeLabel(targetMs, nowMs) {
    var t = _num(targetMs)
    var n = _num(nowMs)
    if (t === null || n === null) return "—"
    var d = new Date(roundTarget(t, n))
    var today = _dayStart(new Date(n))
    var dayDiff = Math.round((_dayStart(d) - today) / 86400000)
    var clock = _clock(d)
    if (dayDiff <= 0) {
        var h = d.getHours()
        if (h >= 18) return "Tonight " + clock
        if (h >= 12) return "This afternoon " + clock
        return "Today " + clock
    }
    if (dayDiff === 1) return "Tomorrow " + clock
    return DAYS[d.getDay()] + " " + clock
}

// "2h 15m" / "45m" / "—"
function durationLabel(seconds) {
    var s = _num(seconds)
    if (s === null || s < 0) return "—"
    var m = Math.round(s / 60)
    var h = Math.floor(m / 60)
    var rest = m % 60
    if (h > 0) return h + "h " + rest + "m"
    return m + "m"
}

// "14h 20m since full · 62% used", or "" when there is nothing to say.
function sinceFullLabel(sf) {
    if (!sf) return ""
    var secs = _num(sf.secs)
    if (secs === null) return ""
    var used = _num(sf.used_pct)
    return durationLabel(secs) + " since full" + (used !== null ? " · " + Math.round(used) + "% used" : "")
}
