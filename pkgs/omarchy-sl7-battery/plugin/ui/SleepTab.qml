pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

import "components"
import "../lib/Format.js" as Format
import "../lib/Projection.js" as Projection

// Sleep tab: last night's summary ("-6% over 8h 12m · 0.37 W avg · woke 3x") and the
// recent sleeps from the daemon's suspend log (logind PrepareForSleep).
Item {
    id: root

    required property var popup
    property bool active: false

    readonly property var service: popup.service
    property var items: []
    property bool loaded: false

    function fetch() {
        if (!root.active || !root.service) return
        root.service.fetchSleeps(12, function(ok, data) {
            if (!ok || !data) return
            root.items = data.items || []
            root.loaded = true
        })
    }

    onActiveChanged: if (active) fetch()

    Timer {
        interval: 120000
        running: root.active
        repeat: true
        onTriggered: root.fetch()
    }

    // The longest sleep of at least an hour that ended in the last 30 hours.
    readonly property var night: {
        var best = null
        var cutoff = Date.now() / 1000 - 30 * 3600
        for (var i = 0; i < root.items.length; i++) {
            var it = root.items[i]
            if (it.end < cutoff || it.duration_s < 3600) continue
            if (best === null || it.duration_s > best.duration_s) best = it
        }
        return best
    }

    function drainText(it) {
        if (it.drain_pct === null || it.drain_pct === undefined) return "—"
        var d = Math.round(it.drain_pct)
        return (d > 0 ? "−" : (d < 0 ? "+" : "")) + Math.abs(d) + "%"
    }

    function whenText(it) {
        var a = new Date(it.start * 1000)
        var b = new Date(it.end * 1000)
        return Qt.formatDateTime(a, "ddd h:mmap") + " → " + Qt.formatDateTime(b, "h:mmap")
    }

    function nightSummary(it) {
        var bits = [drainText(it) + " over " + Projection.durationLabel(it.duration_s)]
        if (it.avg_w !== null && it.avg_w !== undefined) bits.push(Format.fixed(it.avg_w, 2) + " W avg")
        if (it.wake_irqs !== null && it.wake_irqs !== undefined) bits.push("woke " + it.wake_irqs + "×")
        return bits.join(" · ")
    }

    implicitHeight: content.implicitHeight

    Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        SectionHeader {
            width: parent.width
            text: "Last night"
            trailing: root.night ? Qt.formatDateTime(new Date(root.night.start * 1000), "ddd d MMM") : ""
            foreground: root.popup.muted
            fontFamily: root.popup.fontFamily
        }

        Rectangle {
            width: parent.width
            height: nightText.implicitHeight + Style.space(12) * 2
            radius: Style.cornerRadius
            color: root.popup.fillColor

            Text {
                id: nightText
                anchors.fill: parent
                anchors.margins: Style.space(12)
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.night ? root.nightSummary(root.night)
                    : (root.loaded ? "No long sleep recorded yet." : "Loading…")
                color: root.popup.fg
                font.family: root.popup.fontFamily
                font.pixelSize: Style.font.body
                font.bold: root.night !== null
            }
        }

        SectionHeader {
            width: parent.width
            text: "Recent sleeps"
            trailing: root.items.length > 0 ? String(root.items.length) : ""
            foreground: root.popup.muted
            fontFamily: root.popup.fontFamily
        }

        Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
                model: root.items

                Item {
                    id: row
                    required property var modelData
                    width: parent.width
                    height: Math.max(whenLabel.implicitHeight, statLabel.implicitHeight) + Style.space(4)

                    Text {
                        id: whenLabel
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: root.whenText(row.modelData)
                        color: root.popup.fg
                        font.family: root.popup.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                        id: statLabel
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: Projection.durationLabel(row.modelData.duration_s)
                            + "  " + root.drainText(row.modelData)
                            + (row.modelData.avg_w !== null && row.modelData.avg_w !== undefined ? ("  " + Format.fixed(row.modelData.avg_w, 2) + " W") : "")
                            + (row.modelData.wake_irqs ? ("  " + row.modelData.wake_irqs + "×") : "")
                        color: root.popup.muted
                        font.family: root.popup.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                }
            }

            Text {
                visible: root.loaded && root.items.length === 0
                width: parent.width
                textFormat: Text.PlainText
                text: "Suspends are recorded from now on."
                color: root.popup.muted
                font.family: root.popup.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
        }
    }
}
