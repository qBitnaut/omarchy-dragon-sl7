.pragma library

// Pure display formatting: durations, glyph choice. kWh/money/relative-time
// formatting join this in M2 alongside the stats and energy tabs.

// Nerd Font (Material Design set) codepoints, cross-checked against the upstream
// nerd-fonts glyphnames.json and confirmed present in the installed JetBrainsMono
// Nerd Font (fc-match monospace -> JetBrainsMono Nerd Font). All of them sit in the
// Supplementary Private Use Area-A (U+F0000-FFFFD), so String.fromCodePoint is
// required -- these are outside the BMP and need a surrogate pair.
var CODEPOINT = {
    power_plug: 0xF06A5,       // 󰚥 -- the glyph Chris's "󰚥 37W" example uses
    power_plug_off: 0xF06A6,   // 󰚦
    battery_alert: 0xF0083,    // 󰂃
    timer_sand: 0xF051F,       // 󰔟
    cancel: 0xF073A,           // 󰜺 -- marks an option this machine can't offer
}

var BATTERY_PLAIN = {
    100: 0xF0079, 90: 0xF0082, 80: 0xF0081, 70: 0xF0080, 60: 0xF007F,
    50: 0xF007E, 40: 0xF007D, 30: 0xF007C, 20: 0xF007B, 10: 0xF007A,
}

var BATTERY_CHARGING = {
    100: 0xF0085, 90: 0xF008B, 80: 0xF008A, 70: 0xF089E, 60: 0xF0089,
    50: 0xF089D, 40: 0xF0088, 30: 0xF0087, 20: 0xF0086, 10: 0xF089C,
}

function _bucket10(pct) {
    var p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)))
    var b = Math.round(p / 10) * 10
    return Math.max(10, Math.min(100, b))
}

// `pct` 0..100, `charging` bool. Falls back to the alert glyph below 10% or on a
// missing/NaN reading.
function batteryGlyph(pct, charging) {
    var p = Number(pct)
    if (isNaN(p) || p < 10) return String.fromCodePoint(CODEPOINT.battery_alert)
    var bucket = _bucket10(p)
    var table = charging ? BATTERY_CHARGING : BATTERY_PLAIN
    var cp = table[bucket] || CODEPOINT.battery_alert
    return String.fromCodePoint(cp)
}

function glyph(name) {
    var cp = CODEPOINT[name]
    return cp ? String.fromCodePoint(cp) : ""
}

// Seconds to "Xh Ym" / "Xm" / "Xs", for the runtime/on-battery lines in the
// tooltip and header.
function durationShort(totalSeconds) {
    var s = Math.max(0, Math.round(Number(totalSeconds) || 0))
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m"
    return s + "s"
}

// mm:ss, for a live countdown (M3, but the formatter is cheap to have now).
function countdownClock(totalSeconds) {
    var s = Math.max(0, Math.round(Number(totalSeconds) || 0))
    var m = Math.floor(s / 60)
    var r = s % 60
    return m + ":" + (r < 10 ? "0" : "") + r
}

// A number with `digits` decimals and an optional suffix, or an em dash for a missing
// reading. Fixes float noise such as 27.399999618530273 -> "27.4".
function fixed(v, digits, suffix) {
    if (v === null || v === undefined || v === "") return "—"
    var n = Number(v)
    if (isNaN(n)) return "—"
    return n.toFixed(Math.max(0, digits || 0)) + (suffix || "")
}

// Money with its currency symbol and thousands separators: "$1,204.50".
function money(v, currency) {
    var n = Number(v)
    if (v === null || v === undefined || isNaN(n)) return "—"
    var parts = Math.abs(n).toFixed(2).split(".")
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    return (n < 0 ? "-" : "") + (currency || "$") + parts.join(".")
}
