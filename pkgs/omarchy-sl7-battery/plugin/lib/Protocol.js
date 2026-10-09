.pragma library

// Socket protocol helpers (architecture.md §6.1): request ids, envelope build/parse,
// and a short human-readable error string. Pure functions only -- no Quickshell APIs
// -- so this can be exercised with `node --test` (tests/js/).

var _nextId = 1

// Monotonically increasing request id for this connection. Reset by the caller
// (Service.qml) on every fresh socket, since the daemon doesn't care about gaps.
function nextId() {
    return _nextId++
}

function resetIds() {
    _nextId = 1
}

// Build one request envelope. `args` may be omitted (undefined/null).
function buildRequest(cmd, args, id) {
    var req = { v: 1, id: id, cmd: cmd }
    if (args !== undefined && args !== null) req.args = args
    return req
}

function encodeLine(obj) {
    return JSON.stringify(obj) + "\n"
}

// Parse one received line. Returns null (not throws) on malformed JSON, so the
// caller can just drop the line.
function parseLine(line) {
    if (!line) return null
    try {
        return JSON.parse(line)
    } catch (e) {
        return null
    }
}

function isHello(msg) {
    return !!msg && msg.type === "hello"
}

function isResponse(msg) {
    return !!msg && msg.type === "response"
}

function isPush(msg) {
    return !!msg && msg.type === "push"
}

// "code: message", or just "code" when there's no message. "" for a falsy error.
function errorText(err) {
    if (!err) return ""
    var code = err.code || "error"
    var msg = err.message || ""
    return msg ? (code + ": " + msg) : code
}

// Truthy iff `msg` is a successful response envelope.
function isOk(msg) {
    return isResponse(msg) && msg.ok === true
}
