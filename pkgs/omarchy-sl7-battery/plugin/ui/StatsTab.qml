pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

import "components"
import "../lib/Spark.js" as Spark
import "../lib/Format.js" as Format
import "../lib/Projection.js" as Projection

// Stats tab: a window selector (6h, 24h, 7d, 30d), chips that pick the series (charge,
// draw, temperature, screen-on) and one 16-row dot chart. The charge chart runs on a fixed
// 0-100 axis, marks the stretches on AC, shows sleep gaps as dim track, and continues past
// "now" with a hollow, faint projection to empty (or to full while charging).
Item {
    id: root

    required property var popup
    // True while this tab is showing in an open popup; fetches only happen then.
    property bool active: false

    readonly property var service: popup.service

    readonly property var windows: ["6h", "24h", "7d", "30d"]
    readonly property var windowSeconds: ({ "6h": 21600, "24h": 86400, "7d": 604800, "30d": 2592000 })
    property string windowName: "6h"
    property int metricIndex: 0
    property var series: ({})
    property int stepS: 0
    property bool daemonOld: false

    readonly property int points: Math.max(8, Math.min(720, chart.columns))

    function values(metric) {
        var s = root.series[metric]
        return s && s.avg ? s.avg : []
    }

    function fetchHistory() {
        if (!root.active || !root.service) return
        var metrics = ["charge", "draw_w", "charge_w", "temp_c", "screen_on", "on_ac", "asleep"]
        root.service.fetchHistory(root.windowName, metrics, root.points, function(ok, data, err) {
            if (!ok) {
                if (String(err).indexOf("unknown_command") >= 0) root.daemonOld = true
                return
            }
            root.daemonOld = false
            root.stepS = data.step_s || 0
            var map = {}
            for (var i = 0; i < (data.series || []).length; i++) map[data.series[i].metric] = data.series[i]
            root.series = map
        })
    }

    onActiveChanged: if (active) fetchHistory()
    onWindowNameChanged: fetchHistory()
    onPointsChanged: Qt.callLater(root.fetchHistory)

    Timer {
        interval: 60000
        running: root.active
        repeat: true
        onTriggered: root.fetchHistory()
    }

    // Left/right change the window, up/down the series.
    function handleMove(dx, dy) {
        if (dx !== 0) {
            var i = root.windows.indexOf(root.windowName)
            root.windowName = root.windows[Math.max(0, Math.min(root.windows.length - 1, i + dx))]
            return true
        }
        if (dy !== 0) {
            root.metricIndex = (root.metricIndex + dy + root.metrics.length) % root.metrics.length
            return true
        }
        return false
    }

    // ---- derived data ----------------------------------------------------------
    readonly property var chargePct: values("charge")
    readonly property var drawW: values("draw_w")
    readonly property var tempC: values("temp_c")
    readonly property var screenOn: values("screen_on")
    readonly property var onAc: values("on_ac")
    readonly property var asleep: values("asleep")

    function rangeText(vals, digits, suffix) {
        var e = Spark.extent(vals)
        if (!e) return ""
        return Format.fixed(e.min, digits) + "–" + Format.fixed(e.max, digits, suffix)
    }

    function meanText(vals) {
        var sum = 0
        var n = 0
        for (var i = 0; i < vals.length; i++) {
            if (vals[i] === null || vals[i] === undefined) continue
            sum += Number(vals[i])
            n++
        }
        return n > 0 ? Math.round(sum / n * 100) + "% on" : ""
    }

    function boolList(vals, threshold) {
        var out = []
        for (var i = 0; i < vals.length; i++) out.push(vals[i] !== null && vals[i] !== undefined && vals[i] > threshold)
        return out
    }

    readonly property var draw: Spark.zeroScale(root.drawW)
    readonly property var temp: Spark.autoScale(root.tempC)

    readonly property var metrics: [
        { label: "Charge", summary: root.rangeText(root.chargePct, 0, "%"), values: root.chargePct,
          scale: { min: 0, max: 100 }, maxText: "100", minText: "0", color: root.popup.accent },
        { label: "Draw", summary: root.rangeText(root.drawW, 1, " W"), values: root.drawW,
          scale: root.draw, maxText: Format.fixed(root.draw.max, 0), minText: "0", color: root.popup.theme.runtime },
        { label: "Temp", summary: root.rangeText(root.tempC, 0, "°C"), values: root.tempC,
          scale: root.temp, maxText: Format.fixed(root.temp.max, 0), minText: Format.fixed(root.temp.min, 0), color: root.popup.theme.energy },
        { label: "Screen-on", summary: root.meanText(root.screenOn), values: root.screenOn,
          scale: { min: 0, max: 1 }, maxText: "100%", minText: "0", color: root.popup.theme.info }
    ]
    readonly property var metric: metrics[metricIndex]

    // The projection only belongs on the charge chart.
    readonly property bool projecting: root.metricIndex === 0 && root.popup.estimate.ok
    readonly property var lay: root.projecting
        ? Projection.layout(root.points, root.windowSeconds[root.windowName], root.popup.estimate.seconds)
        : ({ pastCols: root.points, futureCols: 0, stepS: 0 })

    function withFuture(past, future) {
        return past.concat(future)
    }

    // What the chart draws: the history resampled to the past columns, then the projection.
    readonly property var chartValues: {
        var past = Spark.resample(root.metric.values, root.lay.pastCols)
        if (!root.projecting || root.lay.futureCols <= 0) return past
        var charge = root.popup.charge
        return root.withFuture(past, Projection.futureValues(root.popup.estimate, charge, root.lay.stepS, root.lay.futureCols))
    }
    readonly property var acMarks: {
        var past = Spark.resample(root.boolList(root.onAc, 0.5).map(function(b) { return b ? 1 : 0 }), root.lay.pastCols)
            .map(function(v) { return v !== null && v > 0.5 })
        var pad = []
        for (var i = 0; i < root.lay.futureCols; i++) pad.push(false)
        return root.metricIndex === 0 ? past.concat(pad) : []
    }
    readonly property var gapMarks: {
        var past = Spark.resample(root.asleep, root.lay.pastCols).map(function(v) { return v !== null && v > 0.5 })
        var pad = []
        for (var i = 0; i < root.lay.futureCols; i++) pad.push(false)
        return past.concat(pad)
    }
    readonly property int acStretches: {
        var n = 0
        var prev = false
        for (var i = 0; i < root.acMarks.length; i++) {
            if (root.acMarks[i] && !prev) n++
            prev = root.acMarks[i]
        }
        return n
    }

    readonly property string endLabel: root.projecting ? root.popup.estimate.label : "now"
    readonly property string projectionCaption: {
        if (!root.projecting) return ""
        var est = root.popup.estimate
        var rate = est.rateW !== null && est.rateW !== undefined ? (" at " + Format.fixed(est.rateW, 1) + " W") : ""
        if (est.mode === "charging") return "Projected " + est.target + "% by " + est.label + rate
        return "Projected empty by " + est.label + rate
    }

    implicitHeight: content.implicitHeight

    Column {
        id: content
        width: parent.width
        spacing: Style.space(14)

        Item {
            visible: !root.daemonOld
            width: parent.width
            height: windowPicker.height

            SegmentedPicker {
                id: windowPicker
                anchors.left: parent.left
                stretch: false
                options: root.windows
                value: root.windowName
                foreground: root.popup.fg
                muted: root.popup.muted
                accent: root.popup.accent
                trackColor: root.popup.fillColor
                fontFamily: root.popup.fontFamily
                fontSize: Style.font.caption
                onChanged: function(v) { root.windowName = v }
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.stepS > 0 ? ("1 dot = " + Format.durationShort(root.stepS)) : ""
                color: root.popup.muted
                font.family: root.popup.fontFamily
                font.pixelSize: Style.font.caption
            }
        }

        // Shown instead of the chart when the daemon predates history.get.
        Rectangle {
            visible: root.daemonOld
            width: parent.width
            height: notice.implicitHeight + Style.space(12) * 2
            radius: Style.cornerRadius
            color: Util.alpha(root.popup.theme.warn, 0.1)

            Text {
                id: notice
                anchors.fill: parent
                anchors.margins: Style.space(12)
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
                text: "History needs a newer sl7-batteryd. Update the omarchy-sl7-battery package."
                color: root.popup.fg
                font.family: root.popup.fontFamily
                font.pixelSize: Style.font.bodySmall
            }
        }

        Column {
            width: parent.width
            spacing: Style.space(12)
            // Hidden with opacity/height rather than `visible` so the chart keeps its width
            // (and the fetch its point count) while the notice shows.
            opacity: root.daemonOld ? 0 : 1
            height: root.daemonOld ? 0 : implicitHeight

            Row {
                id: chips
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                    model: root.metrics

                    MetricChip {
                        required property var modelData
                        required property int index
                        width: (chips.width - chips.spacing * (root.metrics.length - 1)) / root.metrics.length
                        label: modelData.label
                        value: modelData.summary
                        keyColor: modelData.color
                        selected: root.metricIndex === index
                        foreground: root.popup.fg
                        muted: root.popup.muted
                        accent: root.popup.accent
                        fill: root.popup.fillColor
                        fontFamily: root.popup.fontFamily
                        onClicked: root.metricIndex = index
                    }
                }
            }

            ChartPanel {
                id: chart
                width: parent.width
                values: root.chartValues
                minValue: root.metric.scale.min
                maxValue: root.metric.scale.max
                maxText: root.metric.maxText
                minText: root.metric.minText
                startText: root.windowName + " ago"
                endText: root.endLabel
                noteText: root.acStretches > 0 ? (root.acStretches + " on AC") : ""
                rows: 16
                marks: root.acMarks
                gapMarks: root.gapMarks
                futureFrom: root.projecting && root.lay.futureCols > 0 ? root.lay.pastCols : -1
                futureColor: root.popup.muted
                dividerColor: root.popup.accent
                dividerWidth: Style.space(3)
                color: root.metric.color
                markColor: root.popup.theme.ok
                foreground: root.popup.fg
                muted: root.popup.muted
                trackColor: root.popup.trackColor
                fontFamily: root.popup.fontFamily
            }

            Text {
                visible: root.projectionCaption !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: root.projectionCaption
                color: root.popup.muted
                font.family: root.popup.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }
}
