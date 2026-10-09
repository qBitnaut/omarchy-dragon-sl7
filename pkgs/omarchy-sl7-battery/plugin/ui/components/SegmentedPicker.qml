pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

import "../../lib/Format.js" as Format

// SegmentedPicker: pick one of N, as a row of kit Buttons sitting on a shared track.
// Used for the history window, the event filter, the tab strip, and (M3) the
// shutdown action picker and UPS beeper/sensitivity choices.
//
//   options: var           string[] (label == value) or
//                          [{ value, label, enabled?, reason? }]; a disabled option
//                          is drawn in `muted` with a 󰜺 mark, ignores clicks and
//                          shows `reason` as a tooltip
//   value: string          the selected option's value
//   enabled: bool          false dims the whole picker and ignores clicks (read-only)
//   stretch: bool          true: segments share the full width equally (tabs, action
//                          picker); false: segments hug their labels (window selector)
//   foreground, muted, accent, trackColor: color
//   fontFamily: string
//   fontSize: real
//   signal changed(string value)   emitted on a click of a different, enabled option
//
// Keyboard: the picker is one Tab stop; ←/→ (or h/l) move to the previous/next
// enabled option and emit `changed`. Draws a FocusRing around the track.
Rectangle {
    id: root

    property var options: []
    property string value: ""
    property bool stretch: true
    property color foreground: Color.foreground
    property color muted: Qt.darker(foreground, 1.4)
    property color accent: Color.accent
    property color trackColor: Util.alpha(foreground, 0.05)
    property string fontFamily: Style.font.family
    property real fontSize: Style.font.bodySmall

    signal changed(string value)

    function optionValue(o) { return (o && typeof o === "object") ? String(o.value) : String(o) }
    function optionLabel(o) { return (o && typeof o === "object" && o.label !== undefined) ? String(o.label) : String(o) }
    function optionEnabled(o) { return !(o && typeof o === "object" && o.enabled === false) }
    function optionReason(o) { return (o && typeof o === "object" && o.reason) ? String(o.reason) : "" }

    // Select the next enabled option `dir` steps away from the current one, wrapping.
    function move(dir) {
        var n = root.options.length
        if (n === 0 || !root.enabled) return
        var i = -1
        for (var k = 0; k < n; k++) if (optionValue(root.options[k]) === root.value) { i = k; break }
        var from = i >= 0 ? i : (dir > 0 ? -1 : n)
        for (var s = 1; s <= n; s++) {
            var j = (((from + dir * s) % n) + n) % n
            if (!optionEnabled(root.options[j])) continue
            var v = optionValue(root.options[j])
            if (v !== root.value) root.changed(v)
            return
        }
    }

    activeFocusOnTab: enabled
    Keys.onPressed: function(event) {
        var dir = 0
        if (event.key === Qt.Key_Left || event.text === "h") dir = -1
        else if (event.key === Qt.Key_Right || event.text === "l") dir = 1
        if (dir === 0) return
        root.move(dir)
        event.accepted = true
    }

    readonly property int inset: Style.space(2)

    color: trackColor
    radius: Style.cornerRadius
    opacity: enabled ? 1 : 0.55
    implicitWidth: row.implicitWidth + inset * 2
    implicitHeight: row.implicitHeight + inset * 2

    Row {
        id: row
        x: root.inset
        y: root.inset
        spacing: root.inset

        Repeater {
            model: root.options

            Button {
                id: seg
                required property var modelData
                readonly property bool optionOn: root.optionEnabled(modelData)
                width: root.stretch
                    ? (root.width - root.inset * 2 - row.spacing * Math.max(0, root.options.length - 1)) / Math.max(1, root.options.length)
                    : implicitWidth
                text: root.optionLabel(modelData)
                iconText: optionOn ? "" : Format.glyph("cancel")
                iconSize: root.fontSize
                selected: root.optionValue(modelData) === root.value
                // Stays enabled when only the option is off, so its `reason` tooltip
                // can still show on hover; the click is ignored below.
                enabled: root.enabled
                foreground: optionOn ? root.foreground : root.muted
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontSize
                verticalPadding: Style.space(4)
                horizontalPadding: Style.space(10)
                tooltipText: optionOn ? "" : root.optionReason(modelData)
                onClicked: {
                    if (!seg.optionOn) return
                    root.forceActiveFocus()
                    var v = root.optionValue(seg.modelData)
                    if (v !== root.value) root.changed(v)
                }
            }
        }
    }

    FocusRing {
        active: root.activeFocus
        accent: root.accent
        cornerRadius: root.radius
    }
}
