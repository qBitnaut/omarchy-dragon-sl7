import QtQuick
import qs.Commons

// DetailRow: one label and value on a line, the label muted on the left and the value on
// the right. An empty value shows an em dash.
//
//   label, value: string
//   foreground, muted: color
//   fontFamily: string
Item {
    id: root

    property string label: ""
    property string value: ""
    property color foreground: Color.foreground
    property color muted: Color.muted
    property string fontFamily: Style.font.family

    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight) + Style.space(2)

    Text {
        id: labelText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.label
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
    }

    Text {
        id: valueText
        anchors.right: parent.right
        anchors.left: labelText.right
        anchors.leftMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        textFormat: Text.PlainText
        text: root.value !== "" ? root.value : "—"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
    }
}
