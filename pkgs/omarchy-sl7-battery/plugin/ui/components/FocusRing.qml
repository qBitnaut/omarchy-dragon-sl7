import QtQuick
import qs.Commons

// FocusRing: the one keyboard-focus indicator every control in the popup draws -- a
// thin accent outline just outside the control's edge. It sits outside so the ring
// never changes a control's size or fill, and it is the same shape on a button, a
// chip, a picker track or a whole settings row, so Tab focus reads identically
// wherever it lands. Declare it as the control's last child.
//
//   active: bool           show the ring (default: the parent's activeFocus)
//   accent: color
//   inset: real            how far outside the parent's edge (default Style.space(3))
//   cornerRadius: real     the parent's own radius; the ring adds `inset` to it
Rectangle {
    id: root

    property bool active: parent ? parent.activeFocus : false
    property color accent: Color.accent
    property real inset: Style.space(3)
    property real cornerRadius: Style.cornerRadius

    anchors.fill: parent
    anchors.margins: -inset
    visible: active
    z: 10
    color: "transparent"
    radius: cornerRadius > 0 ? cornerRadius + inset : 0
    border.width: Math.max(1, Style.space(1))
    border.color: accent
}
