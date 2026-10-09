import QtQuick
import qs.Commons
import qs.Ui

import "../../lib/Theme.js" as Theme

// ActionButton: a command button with a clear hierarchy -- `primary` is a solid accent
// fill ("Test (dry run)", "Apply"), `secondary` a quiet tinted fill ("Revert"),
// `danger` a solid urgent fill ("Deep self-test"). With `confirmText` set, the first
// press arms the button (label swaps to confirmText for 3 s) and only a second press
// inside that window emits `triggered`.
//
// Unavailable buttons keep their identity without the solid fill: a primary becomes
// a faint accent tint with an accent label, a secondary the quiet fill with a muted
// label. Both stay legible (no opacity fade) and keep hover for the reason tooltip.
//
//   text: string
//   iconText: string       optional Nerd Font glyph before the label
//   kind: string           "primary" | "secondary" | "danger"
//   confirmText: string    non-empty enables two-step confirm ("Confirm deep test")
//   busy: bool             shows "..." after the label and ignores presses
//   available: bool        false dims and ignores presses but keeps hover, so
//                          `tooltipText` can say why (prefer it over `enabled`)
//   tooltipText: string    shown on hover
//   foreground, muted, accent, urgent, background: color
//   fontFamily: string
//   signal triggered()     the (confirmed) press
//
// Keyboard: Tab focus (only while available), Space/Enter press. Draws a FocusRing.
Rectangle {
    id: root

    property string text: ""
    property string iconText: ""
    property string kind: "primary"
    property string confirmText: ""
    property bool busy: false
    property bool available: true
    property string tooltipText: ""
    property color foreground: Color.foreground
    property color muted: Qt.darker(foreground, 1.4)
    property color accent: Color.accent
    property color urgent: Color.urgent
    property color background: Color.popups.background
    property string fontFamily: Style.font.family

    signal triggered()

    property bool armed: false

    readonly property bool solid: kind !== "secondary"
    readonly property color base: kind === "danger" ? urgent : (kind === "primary" ? accent : foreground)
    readonly property real tintAlpha: 0.12
    readonly property color labelColor: {
        if (!available) return solid ? Theme.legibleOn(base, tintAlpha, background, foreground) : muted
        return solid ? background : foreground
    }

    function press() {
        if (!root.available || root.busy) return
        if (root.confirmText !== "" && !root.armed) {
            root.armed = true
            disarm.restart()
            return
        }
        root.armed = false
        disarm.stop()
        root.triggered()
    }

    activeFocusOnTab: available && !busy
    Keys.onPressed: function(event) {
        if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
        root.press()
        event.accepted = true
    }

    implicitWidth: content.implicitWidth + Style.spacing.controlPaddingX * 2 + Style.space(8)
    implicitHeight: content.implicitHeight + Style.spacing.controlPaddingY * 2 + Style.space(2)
    radius: Style.cornerRadius
    color: {
        if (!available) return solid ? Util.alpha(base, tintAlpha) : Util.alpha(foreground, 0.05)
        if (!solid) return Util.alpha(foreground, mouse.pressed ? 0.16 : (mouse.containsMouse ? 0.11 : 0.07))
        if (mouse.pressed) return Qt.darker(base, 1.18)
        if (mouse.containsMouse) return Qt.lighter(base, 1.08)
        return base
    }

    Behavior on color { ColorAnimation { duration: 120 } }

    Timer {
        id: disarm
        interval: 3000
        onTriggered: root.armed = false
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: Style.spacing.controlGap

        Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: root.iconText !== ""
            text: root.iconText
            color: root.labelColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: (root.armed ? root.confirmText : root.text) + (root.busy ? "..." : "")
            color: root.labelColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.available && !root.busy ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            if (root.available && !root.busy) root.forceActiveFocus()
            root.press()
        }

        PanelToolTip {
            visible: root.tooltipText !== "" && mouse.containsMouse
            text: root.tooltipText
            fontFamily: root.fontFamily
        }
    }

    FocusRing {
        active: root.activeFocus
        accent: root.accent
        cornerRadius: root.radius
    }

    onAvailableChanged: if (!available) armed = false
}
