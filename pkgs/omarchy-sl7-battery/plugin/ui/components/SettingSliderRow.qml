import QtQuick
import qs.Commons
import qs.Ui

// SettingSliderRow: a labelled numeric setting -- label and value readout on one line,
// the kit PanelSlider under it, and an optional live reading ("now 87%") on the right
// of the label line. With `checkable` a ToggleSwitch leads the row, for threshold
// triggers that can be switched off independently of their value.
// Stateless: bind `value`/`checked` to staged state; update them from the signals.
//
//   label: string          "Battery at or below"
//   value: real            current (staged) value
//   from, to: real         range
//   stepSize: real         snapping step; `moved` only ever reports snapped values
//   unit: string           readout suffix ("%", " min", " s")
//   valueText: string      optional readout override (default: value + unit)
//   nowText: string        optional muted live reading ("now 87%")
//   checkable: bool        show the leading switch
//   checked: bool          switch state; when false the slider is dimmed
//   enabled: bool          false dims the row and ignores input (read-only peers)
//   bar: QtObject          the host bar, forwarded to PanelSlider for its knob ring
//   foreground, muted, accent: color
//   fontFamily: string
//   signal moved(real value)   snapped value while dragging / wheeling
//   signal toggled()           the user asked to flip `checked`
//
// Keyboard: one Tab stop for the whole row. ←/→ (h/l) step the value, PgUp/PgDn move
// five steps, Home/End jump to the ends, Space flips the switch when `checkable`.
// Draws a FocusRing around the row.
Item {
    id: root

    property string label: ""
    property real value: 0
    property real from: 0
    property real to: 100
    property real stepSize: 1
    property string unit: ""
    property string valueText: ""
    property string nowText: ""
    property bool checkable: false
    property bool checked: true
    property QtObject bar: null
    property color foreground: Color.foreground
    property color muted: Color.muted
    property color accent: Color.accent
    property string fontFamily: Style.font.family

    signal moved(real value)
    signal toggled()

    function snap(v) {
        var s = root.stepSize > 0 ? root.stepSize : 1
        var snapped = root.from + Math.round((v - root.from) / s) * s
        return Math.max(root.from, Math.min(root.to, Number(snapped.toFixed(6))))
    }

    function nudge(steps) {
        if (!root.live) return
        var s = root.stepSize > 0 ? root.stepSize : 1
        var v = root.snap(root.value + steps * s)
        if (v !== root.value) root.moved(v)
    }

    readonly property bool live: root.enabled && (!root.checkable || root.checked)

    activeFocusOnTab: enabled
    Keys.onPressed: function(event) {
        if (!root.enabled) return
        var handled = true
        if (event.key === Qt.Key_Left || event.text === "h") root.nudge(-1)
        else if (event.key === Qt.Key_Right || event.text === "l") root.nudge(1)
        else if (event.key === Qt.Key_PageDown) root.nudge(-5)
        else if (event.key === Qt.Key_PageUp) root.nudge(5)
        else if (event.key === Qt.Key_Home) { if (root.live && root.value !== root.from) root.moved(root.from) }
        else if (event.key === Qt.Key_End) { if (root.live && root.value !== root.to) root.moved(root.to) }
        else if (event.key === Qt.Key_Space && root.checkable) root.toggled()
        else handled = false
        event.accepted = handled
    }

    opacity: enabled ? 1 : 0.5
    implicitWidth: Style.space(300)
    implicitHeight: head.height + Style.space(2) + slider.implicitHeight

    Item {
        id: head
        width: parent.width
        height: Math.max(labelText.implicitHeight, toggle.visible ? toggle.implicitHeight : 0)

        ToggleSwitch {
            id: toggle
            visible: root.checkable
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            checked: root.checked
            interactive: root.enabled
            cursorRing: false
            foreground: root.checked ? root.accent : root.foreground
            accent: root.accent
            trackHeight: Math.max(14, Math.round(Style.spacing.controlHeight * 0.5))
            onToggled: {
                root.forceActiveFocus()
                root.toggled()
            }
        }

        Text {
            id: labelText
            anchors.left: root.checkable ? toggle.right : parent.left
            anchors.leftMargin: root.checkable ? Style.space(8) : 0
            anchors.right: now.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.label
            color: root.checkable && !root.checked ? root.muted : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
        }

        Text {
            id: now
            anchors.right: readout.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: root.nowText !== ""
            text: root.nowText
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }

        Text {
            id: readout
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.valueText !== "" ? root.valueText : (root.value + root.unit)
            color: root.live ? root.foreground : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
        }
    }

    PanelSlider {
        id: slider
        anchors.top: head.bottom
        anchors.topMargin: Style.space(2)
        width: parent.width
        bar: root.bar
        value: root.value
        minimum: root.from
        maximum: root.to
        step: root.stepSize
        enabled: root.live
        opacity: root.live ? 1 : 0.45
        trackColor: Util.alpha(root.foreground, 0.1)
        fillColor: root.accent
        knobColor: root.foreground
        onMoved: function(v) {
            root.forceActiveFocus()
            var s = root.snap(v)
            if (s !== root.value) root.moved(s)
        }
        onReleased: function(v) {
            var s = root.snap(v)
            if (s !== root.value) root.moved(s)
        }
    }

    FocusRing {
        active: root.activeFocus
        accent: root.accent
        inset: Style.space(6)
    }
}
