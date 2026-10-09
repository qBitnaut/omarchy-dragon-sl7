pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

import "components"
import "../lib/Format.js" as Format
import "../lib/Projection.js" as Projection

// Details tab: usage since the last full charge, drain by state, charging, the power
// mode the system side applied, and the SoC rails (relative figures from qcom_pld_power).
Item {
    id: root

    required property var popup
    property bool active: false

    readonly property var service: popup.service
    property var details: null

    function fetch() {
        if (!root.active || !root.service) return
        root.service.fetchDetails(function(ok, data) { if (ok && data) root.details = data })
    }

    onActiveChanged: if (active) fetch()

    Timer {
        interval: 30000
        running: root.active
        repeat: true
        onTriggered: root.fetch()
    }

    readonly property var d: details ? details : ({})
    readonly property var s: popup.s

    function has(v) { return v !== null && v !== undefined }
    function perHour(v) { return root.has(v) ? (Format.fixed(v, 2) + " %/h") : "" }

    readonly property string sinceFullText: {
        var sf = root.d.since_full
        if (!sf) return ""
        return Projection.sinceFullLabel(sf)
    }
    readonly property string splitText: {
        var sf = root.d.since_full
        if (!sf) return ""
        return Projection.durationLabel(sf.awake_s) + " awake · " + Projection.durationLabel(sf.asleep_s) + " asleep"
    }
    readonly property string cpuText: {
        var pm = root.d.powermode
        if (!pm || !pm.cpu) return ""
        return Format.fixed(pm.cpu.cap_khz / 1e6, 2) + " GHz of " + Format.fixed(pm.cpu.max_khz / 1e6, 2) + " GHz"
    }
    readonly property string modeText: {
        var pm = root.d.powermode
        if (!pm || !pm.mode) return ""
        var text = String(pm.mode) + (pm.profile ? (" · " + pm.profile) : "")
        return pm.level && pm.level !== pm.mode ? (text + " → " + pm.level) : text
    }

    implicitHeight: content.implicitHeight

    Column {
        id: content
        width: parent.width
        spacing: Style.space(6)

        SectionHeader {
            width: parent.width
            text: "Since full"
            foreground: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Usage"
            value: root.sinceFullText
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Awake · asleep"
            value: root.splitText
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "On battery for"
            value: root.has(root.d.on_battery_s) ? Projection.durationLabel(root.d.on_battery_s) : ""
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Time left if asleep"
            value: root.has(root.d.asleep_left_s) ? (Projection.sleepLeftLabel(root.d.asleep_left_s) + " at " + Format.fixed(root.d.sleep_w, 2, " W")) : ""
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }

        DetailRow {
            width: parent.width
            label: "Average draw today"
            value: root.has(root.d.today_avg_w) ? Format.fixed(root.d.today_avg_w, 1, " W") : ""
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }

        Item { width: 1; height: Style.space(6) }
        SectionHeader {
            width: parent.width
            text: "Drain, last 24 h on battery"
            foreground: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Screen on"
            value: root.perHour(root.d.drain_screen_on_pct_h)
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Screen off"
            value: root.perHour(root.d.drain_screen_off_pct_h)
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Suspended"
            value: root.perHour(root.d.drain_suspended_pct_h)
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }

        Item { width: 1; height: Style.space(6) }
        SectionHeader {
            width: parent.width
            text: "Charging"
            foreground: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Rate"
            value: root.has(root.d.charge_w)
                ? (Format.fixed(root.d.charge_w, 1, " W") + (root.has(root.d.charge_pct_h) ? (" · " + Format.fixed(root.d.charge_pct_h, 0) + " %/h") : ""))
                : ""
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }

        Item { width: 1; height: Style.space(6) }
        SectionHeader {
            width: parent.width
            text: "Power mode"
            foreground: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "Applied by omarchy-sl7-powermode"
            value: root.modeText
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        DetailRow {
            width: parent.width
            label: "CPU frequency cap"
            value: root.cpuText
            foreground: root.popup.fg
            muted: root.popup.muted
            fontFamily: root.popup.fontFamily
        }

        Item { width: 1; height: Style.space(6); visible: !!root.d.rails }
        SectionHeader {
            visible: !!root.d.rails
            width: parent.width
            text: "SoC rails"
            trailing: "relative, qcom_pld_power"
            foreground: root.popup.muted
            fontFamily: root.popup.fontFamily
        }
        Repeater {
            model: root.d.rails ? root.d.rails : []

            DetailRow {
                required property var modelData
                width: content.width
                label: modelData.label
                value: Format.fixed(modelData.w, 2, " W")
                foreground: root.popup.fg
                muted: root.popup.muted
                fontFamily: root.popup.fontFamily
            }
        }
    }
}
