import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

import "lib/Protocol.js" as Protocol

// One instance per shell, shared by every bar/monitor. Holds the single socket
// connection to sl7-batteryd and the last-seen status and config, so every Panel.qml
// instance just reads properties here instead of dialing out itself.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    // Injected by the shell: not settings.
    property var shell: null
    property var manifest: null

    readonly property string socketPath: Quickshell.env("SL7_BATTERYD_SOCKET")
        || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/sl7-batteryd.sock")

    // ---- connection state ----------------------------------------------------
    readonly property var activeSocket: socketLoader.item
    readonly property bool connected: !!(activeSocket && activeSocket.connected)
    property bool daemonDown: true
    property int reconnectAttempt: 0

    // ---- daemon state ----------------------------------------------------------
    // A fresh object per push so QML bindings on `status.*` re-evaluate.
    property var status: null
    property var config: null
    property int configRev: -1
    property var capabilities: ({})

    signal statusUpdated()
    signal configUpdated()

    // ---- request/response plumbing ---------------------------------------------
    property var pending: ({})

    function request(cmd, args, cb) {
        var socket = activeSocket
        if (!socket || !socket.connected) {
            if (typeof cb === "function") cb(false, null, "sl7-batteryd is not connected")
            return 0
        }
        var id = Protocol.nextId()
        var next = ({})
        for (var k in pending) next[k] = pending[k]
        next[String(id)] = { cb: typeof cb === "function" ? cb : null, sentAt: Date.now(), cmd: cmd }
        pending = next
        socket.write(Protocol.encodeLine(Protocol.buildRequest(cmd, args, id)))
        socket.flush()
        return id
    }

    function fetchHistory(window, metrics, points, cb) {
        return request("history.get", { window: window, metrics: metrics, points: points || 80 }, cb)
    }
    function fetchDetails(cb) {
        var midnight = new Date()
        midnight.setHours(0, 0, 0, 0)
        return request("details.get", { since: Math.floor(midnight.getTime() / 1000) }, cb)
    }
    function fetchSleeps(limit, cb) {
        return request("sleeps.get", { limit: limit || 10 }, cb)
    }
    function setConfig(patch, cb) {
        return request("config.set", { base_rev: root.configRev, patch: patch }, function(ok, data, err) {
            if (ok && data) root.applyConfigData(data)
            else if (!ok) root.refreshConfig(null)
            if (typeof cb === "function") cb(ok, data, err)
        })
    }
    function setProfile(profile, cb) {
        return request("profile.set", { profile: profile }, cb)
    }
    function refreshConfig(cb) {
        return request("config.get", null, function(ok, data, err) {
            if (ok) root.applyConfigData(data)
            if (typeof cb === "function") cb(ok, data, err)
        })
    }

    // Pending-request timeout sweep. Only runs while something is outstanding.
    Timer {
        interval: 1000
        repeat: true
        running: Object.keys(root.pending).length > 0
        onTriggered: {
            var now = Date.now()
            var next = ({})
            var changed = false
            for (var id in root.pending) {
                var entry = root.pending[id]
                if (now - entry.sentAt > 8000) {
                    changed = true
                    if (entry.cb) entry.cb(false, null, "timeout")
                } else {
                    next[id] = entry
                }
            }
            if (changed) root.pending = next
        }
    }

    function applyConfigData(data) {
        if (!data) return
        root.config = data.config || null
        root.configRev = data.rev !== undefined ? data.rev : root.configRev
        if (data.capabilities !== undefined) root.capabilities = data.capabilities || {}
        root.configUpdated()
    }

    function handleLine(line) {
        var msg = Protocol.parseLine(line)
        if (!msg) return
        staleGuard.restart()

        if (Protocol.isHello(msg)) {
            Protocol.resetIds()
            root.configRev = msg.config_rev || -1
            root.reconnectAttempt = 0
            root.daemonDown = false
            request("subscribe", { topics: ["status", "config"] }, null)
            refreshConfig(null)
            return
        }

        if (Protocol.isResponse(msg)) {
            var id = String(msg.id)
            var entry = root.pending[id]
            if (entry === undefined) return
            var next = ({})
            for (var k in root.pending) if (k !== id) next[k] = root.pending[k]
            root.pending = next
            if (entry.cb) {
                if (msg.ok) entry.cb(true, msg.data, "")
                else entry.cb(false, msg.error || null, Protocol.errorText(msg.error))
            }
            return
        }

        if (Protocol.isPush(msg)) {
            if (msg.topic === "status") {
                root.status = msg.data
                root.statusUpdated()
            } else if (msg.topic === "config") {
                root.applyConfigData(msg.data)
            }
        }
    }

    // ---- socket lifecycle (ytmusic's Loader/reconnect pattern) -------------------
    Component {
        id: socketComponent
        Socket {
            id: socket
            path: root.socketPath
            connected: false
            parser: SplitParser {
                splitMarker: "\n"
                onRead: function(line) { root.handleLine(line) }
            }
            Component.onCompleted: connected = true
            onConnectionStateChanged: {
                if (!connected) root.status = null
            }
            onError: function() {
                connected = false
            }
        }
    }

    Loader {
        id: socketLoader
        active: false
        sourceComponent: socketComponent
    }

    // 180 ms + 120 ms per attempt, capped at 1.5 s, then 5 s after 20 attempts.
    Timer {
        id: reconnectTimer
        interval: root.reconnectAttempt < 20 ? Math.min(1500, 180 + root.reconnectAttempt * 120) : 5000
        repeat: true
        triggeredOnStart: true
        running: !root.connected
        onTriggered: {
            root.reconnectAttempt = root.reconnectAttempt + 1
            if (socketLoader.active) {
                socketLoader.active = false
                return
            }
            socketLoader.active = true
        }
    }

    // daemonDown flips true 3 s after disconnecting, so a restart does not flicker the bar.
    Timer {
        id: daemonDownTimer
        interval: 3000
        running: !root.connected
        onTriggered: root.daemonDown = true
    }
    onConnectedChanged: {
        if (connected) daemonDownTimer.stop()
        else daemonDownTimer.restart()
    }

    // The daemon pushes a status every 20 s while awake. Connected but silent for 70 s
    // (a suspend can swallow a push) -> reconnect.
    Timer {
        id: staleGuard
        interval: 70000
        running: root.connected
        onTriggered: {
            if (socketLoader.active) socketLoader.active = false
            reconnectTimer.restart()
        }
    }

    IpcHandler {
        target: "qbit.sl7battery.service"

        function status(): string {
            if (!root.status) return JSON.stringify({ connected: root.connected, daemonDown: root.daemonDown })
            var s = root.status
            return JSON.stringify({
                connected: root.connected,
                charge: s.charge,
                flow: s.flow,
                profile: s.profile,
                power_w: s.power_w,
                auto: s.auto,
            })
        }
    }
}
