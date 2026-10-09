.pragma library

// Dot-matrix chart maths and chart scales. Pure functions, no Quickshell APIs, so this
// is exercised with `node --test` (tests/js/). `ui/components/DotChart.qml` draws what
// these functions compute: the popup's charts are a grid of round dots (the
// omarchy-words look), one column per resampled data point, filled bottom-up to the
// value's level, with unfilled dots left as a faint track.

function _num(v) {
    if (v === null || v === undefined) return null
    var n = Number(v)
    return isNaN(n) ? null : n
}

// Resamples `values` (number|null)[] to exactly `columns` entries. Downsampling
// averages each bucket's non-null values (null when the whole bucket is null, so a
// comm-lost gap stays a gap); upsampling repeats the nearest source point.
function resample(values, columns) {
    values = values || []
    columns = Math.max(0, Math.floor(Number(columns) || 0))
    var out = []
    var n = values.length
    if (columns === 0) return out
    if (n === 0) {
        for (var e = 0; e < columns; e++) out.push(null)
        return out
    }
    for (var c = 0; c < columns; c++) {
        var start = Math.floor(c * n / columns)
        var end = Math.max(start + 1, Math.floor((c + 1) * n / columns))
        var sum = 0
        var count = 0
        for (var i = start; i < end && i < n; i++) {
            var v = _num(values[i])
            if (v === null) continue
            sum += v
            count++
        }
        out.push(count > 0 ? sum / count : null)
    }
    return out
}

// Filled-dot count per column for a chart `rows` dots tall: -1 for a null (no data),
// otherwise 1..rows. Any real reading lights at least the bottom dot, so "at the
// minimum" still reads differently from "no data".
function levels(values, min, max, rows) {
    values = values || []
    rows = Math.max(1, Math.floor(Number(rows) || 1))
    var out = []
    for (var i = 0; i < values.length; i++) {
        var v = _num(values[i])
        if (v === null) { out.push(-1); continue }
        var frac = max > min ? (v - min) / (max - min) : 1
        frac = Math.max(0, Math.min(1, frac))
        out.push(Math.max(1, Math.min(rows, Math.round(frac * rows))))
    }
    return out
}

// Last non-null value in a series, or null.
function latest(values) {
    values = values || []
    for (var i = values.length - 1; i >= 0; i--) {
        var v = _num(values[i])
        if (v !== null) return v
    }
    return null
}

// How many dot columns fit `width` px at `dotSize` + `gap` pitch (at least 1).
function columnsFor(width, dotSize, gap) {
    var w = Number(width) || 0
    var g = Number(gap) || 0
    var pitch = (Number(dotSize) || 1) + g
    return Math.max(1, Math.floor((w + g) / pitch))
}

// §7.5 "Voltage scale": [min(nominal-8, data min), max(nominal+3, data max)], so a
// +-1 V jitter around nominal doesn't fill the whole chart height.
function voltageScale(nominal, values) {
    var n = Number(nominal) || 0
    var dataMin = null
    var dataMax = null
    for (var i = 0; i < (values || []).length; i++) {
        var num = _num(values[i])
        if (num === null) continue
        if (dataMin === null || num < dataMin) dataMin = num
        if (dataMax === null || num > dataMax) dataMax = num
    }
    var lo = n - 8
    var hi = n + 3
    if (dataMin !== null) lo = Math.min(lo, dataMin)
    if (dataMax !== null) hi = Math.max(hi, dataMax)
    if (hi <= lo) hi = lo + 1
    return { min: lo, max: hi }
}

// The data's own min and max (nulls skipped), or null for an empty series. This is
// what the stats chips summarise; the scales below widen it for drawing.
function extent(values) {
    var lo = null
    var hi = null
    for (var i = 0; i < (values || []).length; i++) {
        var num = _num(values[i])
        if (num === null) continue
        if (lo === null || num < lo) lo = num
        if (hi === null || num > hi) hi = num
    }
    return lo === null ? null : { min: lo, max: hi }
}

// A plain min/max scale for gauges with no fixed nominal to anchor against. Degenerate
// series widen by 1 either side so max > min.
function autoScale(values) {
    var lo = null
    var hi = null
    for (var i = 0; i < (values || []).length; i++) {
        var num = _num(values[i])
        if (num === null) continue
        if (lo === null || num < lo) lo = num
        if (hi === null || num > hi) hi = num
    }
    if (lo === null) return { min: 0, max: 1 }
    if (hi === lo) return { min: lo - 1, max: hi + 1 }
    return { min: lo, max: hi }
}

// Load and runtime read best anchored at zero: a 260-280 W wobble drawn on a 260-280
// axis looks like a crisis.
function zeroScale(values) {
    var s = autoScale(values)
    return { min: Math.min(0, s.min), max: Math.max(s.max, 1) }
}
