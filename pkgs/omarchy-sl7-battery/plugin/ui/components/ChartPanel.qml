import QtQuick
import qs.Commons

// ChartPanel: a DotChart with omarchy-words-style axis notes -- the axis maximum and
// minimum in a narrow column on the left, and the time span under the chart
// ("1h ago" ... "now"), with an optional legend note before the end label
// ("● 1 on battery · 3m") keyed in the chart's mark colour.
//
//   values, minValue, maxValue, rows, marks, bodyOpacity, color, markColor,
//   trackColor, futureFrom, gapMarks, gapColor, dividerColor, dividerWidth,
//   futureColor: forwarded to DotChart
//   maxText, minText: string     y-axis notes (top / bottom of the chart)
//   startText, endText: string   x-axis notes (left / right under the chart)
//   noteText: string             optional legend note, right-aligned before endText
//   foreground, muted: color
//   fontFamily: string
//   readonly columns: int        DotChart.columns, for sizing the history fetch
Item {
    id: root

    property var values: []
    property real minValue: 0
    property real maxValue: 0
    property int rows: 12
    property var marks: []
    property real bodyOpacity: 0.45
    property color color: Color.accent
    property color markColor: Color.urgent
    property color foreground: Color.foreground
    property color muted: Color.muted
    property color trackColor: Util.alpha(foreground, 0.08)
    property string maxText: ""
    property string minText: ""
    property string startText: ""
    property string endText: ""
    property string noteText: ""
    property int futureFrom: -1
    property var gapMarks: []
    property color gapColor: Util.alpha(foreground, 0.2)
    property color dividerColor: Util.alpha(foreground, 0.35)
    property real dividerWidth: 1
    property color futureColor: Util.alpha(foreground, 0.45)
    property string fontFamily: Style.font.family

    readonly property int columns: chart.columns

    implicitWidth: Style.space(300)
    implicitHeight: chart.implicitHeight + Style.space(4) + startLabel.implicitHeight

    TextMetrics {
        id: axisMetrics
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        text: root.maxText.length >= root.minText.length ? root.maxText : root.minText
    }

    Item {
        id: axis
        width: Math.ceil(axisMetrics.advanceWidth)
        height: chart.height

        Text {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: -Math.round(implicitHeight / 4)
            textFormat: Text.PlainText
            text: root.maxText
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }

        Text {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.bottomMargin: -Math.round(implicitHeight / 4)
            textFormat: Text.PlainText
            text: root.minText
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
    }

    DotChart {
        id: chart
        anchors.left: axis.right
        anchors.leftMargin: axis.width > 0 ? Style.space(8) : 0
        anchors.right: parent.right
        height: implicitHeight
        values: root.values
        minValue: root.minValue
        maxValue: root.maxValue
        rows: root.rows
        marks: root.marks
        bodyOpacity: root.bodyOpacity
        color: root.color
        markColor: root.markColor
        trackColor: root.trackColor
        futureFrom: root.futureFrom
        gapMarks: root.gapMarks
        gapColor: root.gapColor
        dividerColor: root.dividerColor
        dividerWidth: root.dividerWidth
        futureColor: root.futureColor
    }

    Text {
        id: startLabel
        anchors.left: chart.left
        anchors.top: chart.bottom
        anchors.topMargin: Style.space(4)
        textFormat: Text.PlainText
        text: root.startText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
    }

    Row {
        id: note
        visible: root.noteText !== ""
        anchors.right: endLabel.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: endLabel.verticalCenter
        spacing: Style.space(5)

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            color: root.markColor
        }

        Text {
            textFormat: Text.PlainText
            text: root.noteText
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
    }

    Text {
        id: endLabel
        anchors.right: chart.right
        anchors.top: chart.bottom
        anchors.topMargin: Style.space(4)
        textFormat: Text.PlainText
        text: root.endText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
    }
}
