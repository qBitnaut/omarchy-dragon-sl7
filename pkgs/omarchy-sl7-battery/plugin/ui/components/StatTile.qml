import QtQuick
import qs.Commons

// StatTile: a quiet filled card holding one headline number -- label, value with a
// unit, an optional detail line and an optional progress meter along the bottom.
//
//   label: string          uppercase caption ("Charge")
//   value: string          headline ("100")
//   unit: string           unit beside the value ("%"), drawn smaller and muted
//   detail: string         optional caption under the value ("full")
//   progress: real         0..1 draws a meter; < 0 hides it (default -1)
//   marker: real           0..1 cuts a notch into the meter at that point (the
//                          low-battery threshold, say); < 0 for none (default -1)
//   accent: color          meter fill and, when `tinted`, the value colour
//   tinted: bool           colour the value with `accent` (status emphasis)
//   compact: bool          smaller headline, for secondary rows of tiles
//   foreground, muted, fill, background: color   (`background` paints the notch)
//   fontFamily: string
Rectangle {
    id: root

    property string label: ""
    property string value: ""
    property string unit: ""
    property string detail: ""
    property real progress: -1
    property real marker: -1
    property color accent: Color.accent
    property bool tinted: false
    property bool compact: false
    property color foreground: Color.foreground
    property color muted: Color.muted
    property color fill: Util.alpha(foreground, 0.05)
    property color background: Color.popups.background
    property string fontFamily: Style.font.family

    radius: Style.cornerRadius
    color: root.fill
    implicitWidth: Style.space(140)
    implicitHeight: body.implicitHeight + (compact ? Style.space(8) : Style.space(10)) * 2

    Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: root.compact ? Style.space(8) : Style.space(10)
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(3)

        Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.label.toUpperCase()
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
        }

        Row {
            spacing: Style.space(3)

            Text {
                id: valueText
                textFormat: Text.PlainText
                text: root.value
                color: root.tinted ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.compact ? Style.font.heading : Style.font.display
                font.bold: true
            }

            Text {
                anchors.baseline: valueText.baseline
                textFormat: Text.PlainText
                visible: root.unit !== ""
                text: root.unit
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: root.compact ? Style.font.caption : Style.font.subtitle
            }
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            visible: root.detail !== ""
            text: root.detail
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }

        Item {
            width: parent.width
            height: Style.space(3) + Style.space(3)
            visible: root.progress >= 0

            Rectangle {
                id: meter
                anchors.bottom: parent.bottom
                width: parent.width
                height: Style.space(3)
                radius: height / 2
                color: Util.alpha(root.foreground, 0.08)

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, root.progress))
                    height: parent.height
                    radius: parent.radius
                    color: root.accent
                }

                // A notch cut in the popup ground, the kit slider's tick idiom.
                Rectangle {
                    visible: root.marker >= 0 && root.marker <= 1
                    width: Math.max(1, Style.space(2))
                    height: parent.height + Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    x: Math.max(0, Math.min(parent.width - width, parent.width * root.marker - width / 2))
                    color: root.background
                }
            }
        }
    }
}
