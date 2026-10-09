import QtQuick
import qs.Commons

import "../../lib/Spark.js" as Spark

// DotChart: an omarchy-words-style dot matrix. Each column is one resampled data
// point, lit bottom-up to the value's level; unlit dots stay as a faint track so the
// chart's footprint reads even when the data is flat. A null point (no reading, e.g.
// comm lost) leaves its column as track only.
//
//   values: var            (number|null)[], oldest first
//   minValue, maxValue: real   axis range; when maxValue <= minValue the chart
//                               autoscales to the data
//   rows: int              dots per column (default 6)
//   dotSize: real          dot diameter in px (default Style.space(3))
//   dotGap: real           minimum gap between dots in px (default Style.space(2))
//   color: color           lit dots
//   bodyOpacity: real      opacity of lit dots below each column's top dot; 1 draws
//                          solid columns, lower values read as a dotted line with a
//                          soft fill under it (default 0.45)
//   trackColor: color      unlit dots
//   marks: var             optional bool[] (same length as values); a marked column
//                          is drawn in markColor instead of color (on-battery bands)
//   markColor: color
//   futureFrom: int        first projected column (-1: none). Projected columns draw their
//                          lit dots hollow and faint in futureColor, and a vertical "now"
//                          divider (dividerColor, dividerWidth) is drawn between
//                          futureFrom - 1 and futureFrom
//   gapMarks: var          optional bool[]; a marked column is a gap (asleep) and its
//                          track is drawn in gapColor
//   gapColor, dividerColor, futureColor: color; dividerWidth: real
//   readonly columns: int  how many columns fit the current width -- request that many
//                          history points so no resampling is needed
//
// Width is whatever the parent gives it; the dot pitch stretches so the first and
// last columns sit exactly on the left and right edges. implicitHeight is the dot
// grid's height, so the chart never adds stray space below itself.
Canvas {
    id: root

    property var values: []
    property real minValue: 0
    property real maxValue: 0
    property int rows: 6
    property real dotSize: Style.space(3)
    property real dotGap: Style.space(2)
    property color color: Color.accent
    property real bodyOpacity: 0.45
    property color trackColor: Util.alpha(Color.foreground, 0.08)
    property var marks: []
    property color markColor: Color.urgent
    property int futureFrom: -1
    property var gapMarks: []
    property color gapColor: Util.alpha(Color.foreground, 0.2)
    property color dividerColor: Util.alpha(Color.foreground, 0.35)
    property real dividerWidth: 1
    property color futureColor: Util.alpha(Color.foreground, 0.45)

    readonly property int columns: Spark.columnsFor(width, dotSize, dotGap)
    readonly property real rowPitch: dotSize + dotGap

    implicitWidth: Style.space(200)
    implicitHeight: Math.ceil(rows * dotSize + (rows - 1) * dotGap)

    onValuesChanged: requestPaint()
    onMarksChanged: requestPaint()
    onMinValueChanged: requestPaint()
    onMaxValueChanged: requestPaint()
    onRowsChanged: requestPaint()
    onColorChanged: requestPaint()
    onBodyOpacityChanged: requestPaint()
    onTrackColorChanged: requestPaint()
    onMarkColorChanged: requestPaint()
    onFutureFromChanged: requestPaint()
    onGapMarksChanged: requestPaint()
    onGapColorChanged: requestPaint()
    onDividerColorChanged: requestPaint()
    onDividerWidthChanged: requestPaint()
    onFutureColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var cols = root.columns
        var data = Spark.resample(root.values, cols)
        var marked = Spark.resample((root.marks || []).map(function(m) { return m ? 1 : 0 }), cols)
        var lo = root.minValue
        var hi = root.maxValue
        if (hi <= lo) {
            var s = Spark.autoScale(data)
            lo = s.min
            hi = s.max
        }
        var gapped = Spark.resample((root.gapMarks || []).map(function(m) { return m ? 1 : 0 }), cols)
        var lit = Spark.levels(data, lo, hi, root.rows)
        var stepX = cols > 1 ? (root.width - root.dotSize) / (cols - 1) : 0
        var r = root.dotSize / 2
        var fut = root.futureFrom >= 0 ? root.futureFrom : cols + 1

        for (var c = 0; c < cols; c++) {
            var cx = r + c * stepX
            var level = lit[c]
            var hot = (marked[c] || 0) > 0
            var gap = (gapped[c] || 0) > 0.5
            var future = c >= fut
            for (var row = 0; row < root.rows; row++) {
                // row 0 is the bottom dot
                var cy = root.height - r - row * root.rowPitch
                var on = level >= 0 && row < level
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                if (on && future) {
                    // Projection: a faint light-grey fill and a hollow ring, so the
                    // forecast never reads as measured data.
                    ctx.fillStyle = root.futureColor
                    ctx.globalAlpha = 0.12
                    ctx.fill()
                    ctx.beginPath()
                    ctx.arc(cx, cy, Math.max(0.5, r - 0.5), 0, 2 * Math.PI)
                    ctx.strokeStyle = root.futureColor
                    ctx.lineWidth = 1
                    ctx.globalAlpha = 0.35
                    ctx.stroke()
                } else {
                    ctx.fillStyle = on ? (hot ? root.markColor : root.color) : (gap ? root.gapColor : root.trackColor)
                    ctx.globalAlpha = on && row < level - 1 ? root.bodyOpacity : 1
                    ctx.fill()
                }
            }
        }

        if (fut > 0 && fut < cols) {
            // A filled bar rather than a stroke, so its width is exact at any scale.
            var w = Math.max(1, root.dividerWidth)
            var x = Math.round(r + (fut - 0.5) * stepX - w / 2)
            ctx.globalAlpha = 1
            ctx.fillStyle = root.dividerColor
            ctx.fillRect(x, 0, w, root.height)
        }
    }
}
