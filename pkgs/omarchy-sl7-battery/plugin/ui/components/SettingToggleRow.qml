import QtQuick
import qs.Commons
import qs.Ui

// SettingToggleRow: a settings row with a label (and optional description) on the
// left and the kit ToggleSwitch on the right. The whole row is the click target.
// Stateless: bind `checked` to your staged value and flip it in `onToggled`.
//
// The switch is tinted `accent` while on, so the on state reads at a glance instead
// of relying on the kit's 18% foreground track alone.
//
//   label: string          row title ("Auto-shutdown")
//   description: string    optional muted line under the title
//   checked: bool
//   enabled: bool          false dims the row and ignores clicks (read-only peers)
//   trailingText: string   optional muted note left of the switch ("now off")
//   foreground, muted, accent: color
//   fontFamily: string
//   signal toggled()       the user asked to flip `checked`
//
// Keyboard: one Tab stop; Space/Enter toggle. Draws a FocusRing around the row.
Item {
    id: root

    property string label: ""
    property string description: ""
    property bool checked: false
    property string trailingText: ""
    property color foreground: Color.foreground
    property color muted: Color.muted
    property color accent: Color.accent
    property string fontFamily: Style.font.family

    signal toggled()

    activeFocusOnTab: enabled
    Keys.onPressed: function(event) {
        if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
        root.toggled()
        event.accepted = true
    }

    opacity: enabled ? 1 : 0.5
    implicitWidth: Style.space(300)
    implicitHeight: Math.max(texts.implicitHeight, toggle.implicitHeight)

    Column {
        id: texts
        anchors.left: parent.left
        anchors.right: note.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            visible: root.description !== ""
            text: root.description
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
    }

    Text {
        id: note
        anchors.right: toggle.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        visible: root.trailingText !== ""
        text: root.trailingText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
    }

    ToggleSwitch {
        id: toggle
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: root.checked
        interactive: false
        foreground: root.checked ? root.accent : root.foreground
        accent: root.accent
        trackHeight: Math.max(14, Math.round(Style.spacing.controlHeight * 0.5))
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus()
            root.toggled()
        }
    }

    FocusRing {
        active: root.activeFocus
        accent: root.accent
        inset: Style.space(6)
    }
}
