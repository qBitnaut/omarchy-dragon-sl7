.pragma library

// colors.toml parsing and the semantic token map (architecture.md §7.6). Pure
// functions: `parseColorsToml` takes the file's text, `tokenColor` resolves one
// semantic token given the parsed palette plus the `Color` singleton's base tokens.

// Matches lines like `red = "#e06c75"`. Quoted hex only, same as every Omarchy
// theme's colors.toml.
var LINE_RE = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/

function parseColorsToml(text) {
    var out = {}
    if (!text) return out
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
        var m = LINE_RE.exec(lines[i])
        if (m) out[m[1]] = m[2]
    }
    return out
}

// ---- colour maths ---------------------------------------------------------------
// Accepts "#rrggbb", "#rgb", Qt's "#aarrggbb" string form, or a Qt color object
// ({ r, g, b } in 0..1). Returns [r, g, b] in 0..1, or null.
function _rgb(c) {
    if (c === null || c === undefined) return null
    if (typeof c === "object" && typeof c.r === "number") return [c.r, c.g, c.b]
    var s = String(c).replace(/^\s+|\s+$/g, "")
    if (s.charAt(0) !== "#") return null
    var h = s.slice(1)
    if (h.length === 8) h = h.slice(2)
    if (h.length === 3) h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2)
    if (h.length !== 6 || !/^[0-9a-fA-F]{6}$/.test(h)) return null
    var n = parseInt(h, 16)
    return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255]
}

function _hex(rgb) {
    var out = "#"
    for (var i = 0; i < 3; i++) {
        var v = Math.round(Math.max(0, Math.min(1, rgb[i])) * 255).toString(16)
        out += v.length < 2 ? "0" + v : v
    }
    return out
}

function _luminance(rgb) {
    var lin = []
    for (var i = 0; i < 3; i++) {
        var c = rgb[i]
        lin.push(c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4))
    }
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
}

// WCAG contrast ratio between two colours (1 when either can't be parsed).
function contrast(a, b) {
    var ra = _rgb(a)
    var rb = _rgb(b)
    if (!ra || !rb) return 1
    var la = _luminance(ra)
    var lb = _luminance(rb)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

// `t` of colour `a` blended with (1 - t) of colour `b`, as "#rrggbb".
function mix(a, b, t) {
    var ra = _rgb(a)
    var rb = _rgb(b)
    if (!ra) return b
    if (!rb) return a
    t = Math.max(0, Math.min(1, Number(t) || 0))
    return _hex([ra[0] * t + rb[0] * (1 - t), ra[1] * t + rb[1] * (1 - t), ra[2] * t + rb[2] * (1 - t)])
}

// The secondary-text colour for a foreground on a background: the foreground
// pulled toward the background as far as it can go while keeping `minContrast`
// (4:1 by default -- captions in this popup are 10 px bold, so they need it).
// Theme `muted` keys are not used for text: on most Omarchy themes they sit at
// about 2:1 against the popup ground, which is why the M2 captions were hard to
// read. Falls back to the foreground itself when the pair can't be parsed.
function mutedFor(fg, bg, minContrast) {
    var need = Number(minContrast) > 0 ? Number(minContrast) : 4.5
    var f = _rgb(fg)
    var b = _rgb(bg)
    if (!f || !b) return fg
    for (var t = 0.62; t < 1; t += 0.04) {
        var m = mix(fg, bg, t)
        if (contrast(m, bg) >= need) return m
    }
    return _hex(f)
}

// A text colour for `tone` written on its own tint -- `tone` at `alpha` over `bg`,
// the way the status pill and an unavailable primary button are drawn. Returns
// `tone` itself when it already clears `minContrast` (4:1 by default) against that
// tint, otherwise `tone` pulled toward `fg` just far enough to clear it. Light themes
// need this: a mid-green on a faint green wash over a near-white ground sits at
// about 2.5:1, while the same pair on a dark ground is 7:1.
function legibleOn(tone, alpha, bg, fg, minContrast) {
    var need = Number(minContrast) > 0 ? Number(minContrast) : 4
    var c = _rgb(tone)
    var b = _rgb(bg)
    var f = _rgb(fg)
    if (!c || !b) return tone
    var ground = mix(tone, bg, Math.max(0, Math.min(1, Number(alpha) || 0)))
    if (contrast(tone, ground) >= need || !f) return _hex(c)
    for (var t = 0.9; t > 0; t -= 0.1) {
        var m = mix(tone, fg, t)
        if (contrast(m, ground) >= need) return m
    }
    return _hex(f)
}

// `base` is an object with the `Color` singleton's always-present tokens:
// { foreground, background, accent, urgent, muted, popupsBackground, popupsText,
//   popupsBorder }. `palette` is parseColorsToml's output (may be missing keys,
// e.g. before the FileView has loaded). Falls back to `Color.foreground` for any
// series/semantic token colors.toml doesn't have, per §7.6. `dim` is derived from
// the popup's own text/ground pair (see mutedFor), not the theme's `muted` key.
function tokenColor(token, palette, base) {
    palette = palette || {}
    base = base || {}
    var fallback = base.foreground || "#ffffff"

    switch (token) {
        case "bg": return base.popupsBackground || base.background || fallback
        case "fg": return base.popupsText || base.foreground || fallback
        case "border": return base.popupsBorder || base.muted || fallback
        case "dim": return mutedFor(tokenColor("fg", palette, base), tokenColor("bg", palette, base))
        case "accent": return base.accent || fallback
        case "ok": return palette.green || fallback
        case "warn": return palette.yellow || fallback
        case "crit": return palette.red || base.urgent || fallback
        case "info": return palette.cyan || fallback
        case "output_v": return palette.blue || fallback
        case "runtime": return palette.magenta || fallback
        case "battery_v": return palette.bright_black || base.muted || fallback
        case "energy": return palette.orange || fallback
        default: return fallback
    }
}
