import QtQuick
import qs.Commons

// SectionHeader: the small uppercase label that opens a popup section, with an
// optional trailing note on the same baseline (a count, a range, "step 45 s").
//
//   text: string           section label; rendered uppercase
//   trailing: string       optional right-aligned note (not uppercased)
//   foreground: color      label colour (a muted tone)
//   trailingColor: color   note colour
//   fontFamily: string
Item {
    id: root

    property string text: ""
    property string trailing: ""
    property color foreground: Color.muted
    property color trailingColor: foreground
    property string fontFamily: Style.font.family

    implicitWidth: label.implicitWidth + note.implicitWidth + Style.space(12)
    implicitHeight: Math.max(label.implicitHeight, note.implicitHeight)

    Text {
        id: label
        anchors.left: parent.left
        anchors.right: note.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: root.text.toUpperCase()
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
    }

    Text {
        id: note
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        visible: root.trailing !== ""
        text: root.trailing
        color: root.trailingColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
    }
}
