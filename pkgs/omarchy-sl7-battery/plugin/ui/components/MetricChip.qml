import QtQuick
import qs.Commons

// MetricChip: a small selectable card naming one chart series -- its key colour and
// label, with a one-line summary of that series over the current window underneath
// ("190–310 W"). A row of these picks which series the stats chart shows; the header
// tiles already carry the live readings, so the chips summarise the window instead
// of repeating them.
//
//   label: string          metric name, rendered uppercase
//   value: string          the window summary ("190–310 W"), or "" while loading
//   keyColor: color        key swatch (the chart colour for this metric)
//   selected: bool         draws the kit's selected fill
//   foreground, muted, accent, fill: color
//   fontFamily: string
//   signal clicked()
//
// Keyboard: each chip is a Tab stop; Space/Enter select it. Draws a FocusRing.
Rectangle {
    id: root

    property string label: ""
    property string value: ""
    property color keyColor: Color.accent
    property bool selected: false
    property color foreground: Color.foreground
    property color muted: Color.muted
    property color accent: Color.accent
    property color fill: Util.alpha(foreground, 0.05)
    property string fontFamily: Style.font.family

    signal clicked()

    activeFocusOnTab: true
    Keys.onPressed: function(event) {
        if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
        root.clicked()
        event.accepted = true
    }

    radius: Style.cornerRadius
    border.width: 0
    implicitWidth: Style.space(80)
    implicitHeight: body.implicitHeight + Style.space(8) * 2
    color: selected ? Style.selectedFillFor(foreground, accent)
        : (mouse.containsMouse ? Style.hoverFillFor(foreground, accent) : fill)

    Behavior on color { ColorAnimation { duration: 120 } }

    Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(8)
        spacing: Style.space(3)

        Row {
            spacing: Style.space(5)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(6)
                height: width
                radius: width / 2
                color: root.keyColor
            }

            Text {
                textFormat: Text.PlainText
                text: root.label.toUpperCase()
                color: root.selected ? root.foreground : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
            }
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.value !== "" ? root.value : "—"
            color: root.selected ? root.foreground : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus()
            root.clicked()
        }
    }

    FocusRing {
        active: root.activeFocus
        accent: root.accent
        cornerRadius: root.radius
    }
}
