import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "lib/Format.js" as Format
import "lib/Projection.js" as Projection
import "lib/Theme.js" as Theme
import "ui" as PopupUi

// Bar widget + popup host: the battery glyph, percentage and tooltip in the bar, and the
// KeyboardPanel that hosts ui/PopupContent.qml. Replaces Omarchy's omarchy.power widget.
Panel {
    id: root
    moduleName: "qbit.sl7battery"
    // `omarchy-shell qbit.sl7battery toggle` (the Panel base registers the handler).
    ipcTarget: "qbit.sl7battery"

    readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

    // Manifest defaults, applied by hand since Omarchy does not render `schema`.
    readonly property bool showPercentage: setting("showPercentage", true) === true

    readonly property var status: service ? service.status : null
    readonly property bool daemonDown: !service || service.daemonDown
    readonly property bool present: !!(status && status.present !== false)
    readonly property int charge: (status && status.charge !== null && status.charge !== undefined) ? status.charge : -1
    readonly property bool discharging: !!(status && status.flow === "discharging")
    readonly property bool charging: !!(status && status.flow === "charging")
    readonly property bool saverForced: !!(status && status.auto && status.auto.forced)
    readonly property bool criticalBattery: discharging && charge >= 0 && charge <= 10
    readonly property int saverThreshold: (status && status.auto && status.auto.enabled && status.auto.threshold !== null && status.auto.threshold !== undefined) ? status.auto.threshold : 30
    readonly property bool belowSaver: discharging && charge >= 0 && charge <= saverThreshold

    // ---- theme colours ------------------------------------------------------
    property var themeColors: ({})

    function themeBase() {
        var popups = Color.popups || ({})
        return {
            foreground: Color.foreground,
            background: Color.background,
            accent: Color.accent,
            urgent: Color.urgent,
            muted: Color.muted,
            popupsBackground: popups.background || Color.background,
            popupsText: popups.text || Color.foreground,
            popupsBorder: popups.border || Color.muted,
        }
    }

    function tokenColor(token) {
        return Theme.tokenColor(token, root.themeColors, root.themeBase())
    }

    FileView {
        id: colorsFile
        path: Color.currentThemePath + "/colors.toml"
        watchChanges: true
        printErrors: false
        onLoaded: root.themeColors = Theme.parseColorsToml(text())
        onFileChanged: reload()
        onLoadFailed: root.themeColors = ({})
    }

    Connections {
        target: Color
        function onAccentChanged() { colorsFile.reload() }
        function onForegroundChanged() { colorsFile.reload() }
        function onBackgroundChanged() { colorsFile.reload() }
    }

    // ---- bar state ------------------------------------------------------------
    readonly property string glyphChar: {
        if (root.daemonDown || !root.present || root.charge < 0) return Format.glyph("power_plug_off")
        return Format.batteryGlyph(root.charge, root.charging)
    }

    readonly property string colorToken: {
        if (root.daemonDown) return "dim"
        if (root.criticalBattery) return "crit"
        if (root.saverForced || root.belowSaver) return "warn"
        return "fg"
    }

    readonly property string barText: {
        if (root.daemonDown || !root.present || root.charge < 0 || !root.showPercentage) return ""
        return root.charge + "%"
    }

    readonly property var estimate: Projection.estimate(root.status, Date.now())

    readonly property string tooltipBody: {
        if (root.daemonDown) return "Battery · sl7-batteryd is not running"
        if (!root.present) return "Battery · none found"
        var s = root.status
        var lines = []
        var state = root.discharging ? "on battery" : (root.charging ? "charging" : (s.ac ? "plugged in" : "idle"))
        lines.push("Battery · " + state)
        var mid = []
        if (root.charge >= 0) mid.push(root.charge + "%")
        var wd = Projection.wording(s, root.estimate, Date.now())
        if (wd.tooltip !== "") mid.push(wd.tooltip)
        if (s.power_w !== null && s.power_w !== undefined) mid.push(Format.fixed(s.power_w, 1, " W"))
        lines.push(mid.join(" · "))
        if (s.profile) lines.push("Profile: " + s.profile + (root.saverForced ? " (auto)" : ""))
        var sf = Projection.sinceFullLabel(s.since_full)
        if (sf !== "" && !s.ac) lines.push(sf)
        return lines.join("\n")
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function togglePercentage() {
        root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
        if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.glyphChar + (root.barText ? (" " + root.barText) : "")
        // Widen the icon slot when there is label text next to the glyph.
        slotSize: Style.bar.iconSlot * (root.barText ? 2.6 : 1)
        foreground: root.tokenColor(root.colorToken)
        tooltipText: root.tooltipBody
        onPressed: function(b) {
            if (b === Qt.RightButton) root.togglePercentage()
            else root.toggle()
        }
    }

    // Theme token map for the popup, rebuilt whenever the Color singleton or colors.toml
    // changes, so an Omarchy theme switch restyles an open popup live.
    readonly property var themeTokens: {
        var keys = ["fg", "bg", "border", "dim", "accent", "ok", "warn", "crit", "info", "output_v", "runtime", "battery_v", "energy"]
        var out = {}
        for (var i = 0; i < keys.length; i++) out[keys[i]] = root.tokenColor(keys[i])
        return out
    }

    // Tab / Shift+Tab walk the active tab's controls in layout order through Qt's own
    // focus chain; controls handle their own keys and anything they do not accept falls
    // through to the PanelKeyCatcher, so Esc and the 1-3 tab keys work from anywhere.
    function moveFocus(dir) {
        var win = keyCatcher.Window.window
        var cur = win && win.activeFocusItem ? win.activeFocusItem : keyCatcher
        var next = cur.nextItemInFocusChain(dir > 0)
        if (!next || next === cur) return
        next.forceActiveFocus(Qt.TabFocusReason)
        root.reveal(next)
    }

    // Scroll a focused control into view; only matters once the screen has capped the
    // card and the Flickable is actually scrolling.
    function reveal(item) {
        if (!item || !scroller.interactive) return
        var p = item.mapToItem(popup, 0, 0)
        var margin = Style.space(8)
        var top = p.y - margin
        var bottom = p.y + item.height + margin
        if (top < scroller.contentY) scroller.contentY = Math.max(0, top)
        else if (bottom > scroller.contentY + scroller.height)
            scroller.contentY = Math.min(scroller.contentHeight - scroller.height, bottom - scroller.height)
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(popup.implicitWidth + 2 * panel.padding
            + Border.left(panel.borderSpec) + Border.right(panel.borderSpec))
        contentHeight: panel.fittedContentHeight(popup.implicitHeight)

        // The header is fixed and the card's top edge stays anchored to the bar; only the
        // tab body's height changes, and the card eases to it.
        Behavior on contentHeight {
            enabled: root.opened
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTextKey: function(t) { popup.handleTextKey(t) }
            onMoveRequested: function(dx, dy) { popup.handleMove(dx, dy) }
            onTabRequested: function(dir) { root.moveFocus(dir) }

            Flickable {
                id: scroller
                anchors.fill: parent
                contentWidth: width
                contentHeight: popup.implicitHeight
                clip: contentHeight > height
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds

                PopupUi.PopupContent {
                    id: popup
                    width: scroller.width
                    height: implicitHeight
                    service: root.service
                    theme: root.themeTokens
                    bar: root.bar
                    opened: root.opened
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                }
            }
        }
    }
}
