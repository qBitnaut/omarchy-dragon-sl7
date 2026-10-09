pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

import "components"
import "../lib/Format.js" as Format
import "../lib/Projection.js" as Projection
import "../lib/Theme.js" as Theme

// The popup body: a fixed header (status line and pills, three headline tiles, the
// readings, the power profile picker and the auto power saver), then a tab strip and the
// active tab (StatsTab, SleepTab, DetailsTab).
//
// Sizing contract with Panel.qml: this item is laid out by the card (anchors.fill), so
// every row spans `width`. The card is in turn sized from this item's implicit size.
//
// Colours: `theme` is Panel.qml's token map (Color singleton + colors.toml). Tiles, chips
// and pickers are separated by fill (`fillColor`), never by their own borders.
Item {
    id: root

    required property var service
    required property var theme
    // The host bar; forwarded to kit controls that take one (PanelSlider).
    property QtObject bar: null
    property string fontFamily: Style.font.family
    // Whether the popup is showing. Tabs only fetch history while true.
    property bool opened: false

    // ---- theme -------------------------------------------------------------
    readonly property color fg: theme.fg
    readonly property color muted: theme.dim
    readonly property color accent: theme.accent
    readonly property color fillColor: Util.alpha(fg, 0.05)
    readonly property color trackColor: Util.alpha(fg, 0.08)

    // ---- live state ----------------------------------------------------------
    readonly property bool daemonDown: !service || service.daemonDown
    readonly property var status: service ? service.status : null
    readonly property bool present: !!(status && status.present !== false)
    readonly property bool live: !daemonDown && !!status && present
    readonly property var s: status ? status : ({})
    readonly property var autoInfo: s.auto ? s.auto : ({})
    readonly property bool discharging: s.flow === "discharging"
    readonly property bool charging: s.flow === "charging"
    readonly property int charge: s.charge !== null && s.charge !== undefined ? s.charge : -1
    readonly property bool lowBattery: discharging && charge >= 0 && charge <= 10
    // Warn colours only from the auto power-saver threshold down (default 30%), so a
    // healthy battery on discharge does not look like a problem.
    readonly property int saverThreshold: autoInfo.enabled && has(autoInfo.threshold) ? autoInfo.threshold : 30
    readonly property bool belowSaver: discharging && charge >= 0 && charge <= saverThreshold
    readonly property var estimate: Projection.estimate(status, nowMs)
    property real nowMs: Date.now()

    // Refresh "now" so labels and the projection stay current while the popup is open.
    Timer {
        interval: 30000
        running: root.opened
        repeat: true
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    readonly property color stateColor: {
        if (daemonDown || !present) return muted
        if (lowBattery) return theme.crit
        if (belowSaver) return theme.warn
        if (discharging) return fg
        if (charging) return Qt.tint(theme.ok, Qt.rgba(1, 1, 1, 0.5 * shimmer))
        return theme.ok
    }

    // Charging shimmer for the Charge tile, matching the bar widget; only while the
    // popup is open and the battery is charging.
    property real shimmer: 0
    SequentialAnimation on shimmer {
        running: root.opened && root.charging && root.live
        loops: Animation.Infinite
        onRunningChanged: if (!running) root.shimmer = 0
        NumberAnimation { from: 0; to: 1; duration: 1400; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1; to: 0; duration: 1400; easing.type: Easing.InOutSine }
    }

    function has(v) { return v !== null && v !== undefined }

    readonly property real thresholdMarker: autoInfo.enabled && has(autoInfo.threshold) ? autoInfo.threshold / 100 : -1

    function profileLabel(name) {
        if (name === "power-saver") return "Power saver"
        if (name === "balanced") return "Balanced"
        if (name === "performance") return "Performance"
        return name ? String(name) : "—"
    }

    // ---- tabs ----------------------------------------------------------------
    // 0 stats, 1 sleep, 2 details.
    property int activeTab: 0
    // A control keeps keyboard focus only inside its own tab; switching tabs hands focus
    // back here so the next Tab press starts at the top of the new tab.
    onActiveTabChanged: root.forceActiveFocus()
    readonly property var tabOptions: [
        { value: "0", label: "Stats" },
        { value: "1", label: "Sleep" },
        { value: "2", label: "Details" }
    ]
    readonly property var tabs: [statsTab, sleepTab, detailsTab]
    readonly property var currentTab: tabs[activeTab]

    implicitWidth: Style.space(460)
    implicitHeight: layout.implicitHeight

    Column {
        id: layout
        width: parent.width
        spacing: Style.space(14)

        // ---- status line ----------------------------------------------------
        Item {
            width: parent.width
            height: Math.max(statusLeft.height, statusRight.height)

            Row {
                id: statusLeft
                anchors.left: parent.left
                anchors.right: statusRight.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(12)

                Text {
                    id: stateGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: {
                        if (!root.live || root.charge < 0) return Format.glyph("power_plug_off")
                        return Format.batteryGlyph(root.charge, root.charging)
                    }
                    color: root.stateColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - stateGlyph.width - parent.spacing
                    spacing: Style.space(2)

                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: {
                            if (root.daemonDown) return "sl7-batteryd is not running"
                            if (!root.present) return "No battery found"
                            if (root.discharging) return "On battery"
                            if (root.charging) return "Charging"
                            return "Plugged in"
                        }
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.heading
                        font.bold: true
                    }

                    // The pulse on usage: how long since the battery was last full and how
                    // much of it has gone (14h 20m since full · 62% used).
                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: {
                            if (root.daemonDown) return "WAITING FOR THE DAEMON"
                            if (!root.live) return ""
                            var sf = root.s.since_full
                            if (sf && !sf.on_ac) return Projection.sinceFullLabel(sf).toUpperCase()
                            if (root.charging) {
                                var lim = root.has(root.s.charge_limit) ? (" · LIMIT " + root.s.charge_limit + "%") : ""
                                return "CHARGING" + lim
                            }
                            if (root.s.full) return "FULLY CHARGED"
                            if (sf) return Projection.sinceFullLabel(sf).toUpperCase()
                            return ""
                        }
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 1.2
                    }
                }
            }

            Column {
                id: statusRight
                visible: root.live
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(5)

                // Power profile pill.
                Rectangle {
                    anchors.right: parent.right
                    width: profileText.implicitWidth + Style.space(12)
                    height: profileText.implicitHeight + Style.space(4)
                    radius: Style.cornerRadius > 0 ? height / 2 : 0
                    color: Util.alpha(root.fg, 0.06)

                    Text {
                        id: profileText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: root.profileLabel(root.s.profile).toUpperCase()
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 1
                    }
                }

                // AUTO SAVER pill: armed (will switch below the threshold) or active.
                Rectangle {
                    id: saverPill
                    readonly property string mode: root.autoInfo.forced ? "active" : (root.autoInfo.armed ? "armed" : "off")
                    readonly property color tone: mode === "active" ? root.theme.warn : root.theme.ok
                    readonly property real washAlpha: mode === "active" ? 0.18 : 0.14
                    visible: mode !== "off"
                    anchors.right: parent.right
                    width: saverText.implicitWidth + Style.space(12)
                    height: saverText.implicitHeight + Style.space(4)
                    radius: Style.cornerRadius > 0 ? height / 2 : 0
                    color: Util.alpha(tone, washAlpha)

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Text {
                        id: saverText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: saverPill.mode === "active" ? "AUTO SAVER ON" : "AUTO SAVER"
                        color: Theme.legibleOn(saverPill.tone, saverPill.washAlpha, root.theme.bg, root.fg)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 1
                    }
                }
            }
        }

        // ---- headline tiles ----------------------------------------------------
        Row {
            id: tiles
            visible: root.live
            width: parent.width
            spacing: Style.space(8)

            readonly property real tileWidth: (width - spacing * 2) / 3
            readonly property real tileHeight: Math.max(chargeTile.implicitHeight, timeTile.implicitHeight, drawTile.implicitHeight)

            StatTile {
                id: chargeTile
                width: tiles.tileWidth
                height: tiles.tileHeight
                label: "Charge"
                value: root.charge >= 0 ? String(root.charge) : "—"
                unit: root.charge >= 0 ? "%" : ""
                detail: root.has(root.s.charge_limit) ? ("limit " + root.s.charge_limit + "%") : (root.s.status ? String(root.s.status).toLowerCase() : "")
                progress: root.charge >= 0 ? root.charge / 100 : 0
                marker: root.discharging ? root.thresholdMarker : -1
                accent: root.discharging ? root.stateColor : root.theme.ok
                tinted: root.discharging
                foreground: root.fg
                muted: root.muted
                fill: root.fillColor
                background: root.theme.bg
                fontFamily: root.fontFamily
            }

            StatTile {
                id: timeTile
                readonly property real secs: root.estimate.ok ? root.estimate.seconds : -1
                width: tiles.tileWidth
                height: tiles.tileHeight
                label: root.charging ? "To full" : "Time left"
                value: secs < 0 ? "—" : (secs >= 3600 ? Projection.durationLabel(secs) : String(Math.max(1, Math.round(secs / 60))))
                unit: secs >= 0 && secs < 3600 ? "min" : ""
                detail: root.estimate.ok ? ("until " + root.estimate.label) : (root.discharging || root.charging ? "learning the rate" : "")
                foreground: root.fg
                muted: root.muted
                fill: root.fillColor
                background: root.theme.bg
                accent: root.theme.runtime
                fontFamily: root.fontFamily
            }

            StatTile {
                id: drawTile
                width: tiles.tileWidth
                height: tiles.tileHeight
                label: root.charging ? "Charging" : "Draw"
                value: root.has(root.s.power_w) ? Format.fixed(root.s.power_w, 1) : "—"
                unit: root.has(root.s.power_w) ? "W" : ""
                detail: {
                    if (root.charging) return root.has(root.s.charge_pct_h) ? ("+" + root.s.charge_pct_h + " %/h") : ""
                    var avg = root.has(root.s.avg_since_unplug_w) ? root.s.avg_since_unplug_w : root.s.ewma_w
                    return root.has(avg) && root.discharging ? ("avg " + Format.fixed(avg, 1) + " W") : ""
                }
                foreground: root.fg
                muted: root.muted
                fill: root.fillColor
                background: root.theme.bg
                accent: root.accent
                fontFamily: root.fontFamily
            }
        }

        // ---- readings -------------------------------------------------------------
        Row {
            id: readings
            visible: root.live
            width: parent.width

            Repeater {
                model: {
                    var items = [
                        { label: "Health", value: Format.fixed(root.s.health_pct, 0, "%") },
                        { label: "Temp", value: Format.fixed(root.s.temp_c, 1, " °C") },
                        { label: "Voltage", value: Format.fixed(root.s.voltage_v, 1, " V") }
                    ]
                    if (root.has(root.s.cycle_count)) items.push({ label: "Cycles", value: String(root.s.cycle_count) })
                    return items
                }

                Column {
                    required property var modelData
                    required property int index
                    width: readings.width / (root.has(root.s.cycle_count) ? 4 : 3)
                    spacing: Style.space(2)

                    Text {
                        textFormat: Text.PlainText
                        text: String(parent.modelData.label).toUpperCase()
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        font.letterSpacing: 1.2
                    }

                    Text {
                        textFormat: Text.PlainText
                        text: parent.modelData.value
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                    }
                }
            }
        }

        // ---- power profile ---------------------------------------------------------
        Column {
            visible: root.live && !!root.s.profiles && root.s.profiles.length > 0
            width: parent.width
            spacing: Style.space(8)

            SectionHeader {
                width: parent.width
                text: "Power profile"
                trailing: root.autoInfo.forced ? ("auto saver · was " + root.profileLabel(root.autoInfo.prev_profile)) : ""
                trailingColor: root.theme.warn
                foreground: root.muted
                fontFamily: root.fontFamily
            }

            SegmentedPicker {
                width: parent.width
                options: {
                    var list = root.s.profiles || []
                    var out = []
                    for (var i = 0; i < list.length; i++) out.push({ value: list[i], label: root.profileLabel(list[i]) })
                    return out
                }
                value: root.s.profile ? String(root.s.profile) : ""
                foreground: root.fg
                muted: root.muted
                accent: root.accent
                trackColor: root.fillColor
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onChanged: function(v) { if (root.service) root.service.setProfile(v, null) }
            }

            // Auto power saver: switch to Power saver at or below the threshold on battery.
            // The slider stages the value and writes it once it settles.
            SettingSliderRow {
                id: saverRow
                width: parent.width
                enabled: !!root.service && !!root.service.config
                label: "Auto power saver below"
                checkable: true
                checked: root.autoInfo.enabled === true
                value: saverRow.staged >= 0 ? saverRow.staged : (root.has(root.autoInfo.threshold) ? root.autoInfo.threshold : 30)
                from: 10
                to: 60
                stepSize: 5
                unit: "%"
                nowText: root.charge >= 0 ? ("now " + root.charge + "%") : ""
                bar: root.bar
                foreground: root.fg
                muted: root.muted
                accent: root.autoInfo.forced ? root.theme.warn : root.accent
                fontFamily: root.fontFamily
                property real staged: -1
                onToggled: root.service.setConfig({ auto_saver: { enabled: !(root.autoInfo.enabled === true) } }, null)
                onMoved: function(v) { saverRow.staged = v; saverCommit.restart() }

                Timer {
                    id: saverCommit
                    interval: 450
                    onTriggered: {
                        var v = saverRow.staged
                        if (v < 0 || !root.service) return
                        root.service.setConfig({ auto_saver: { threshold: v } }, function() { saverRow.staged = -1 })
                    }
                }
            }
        }

        // ---- tab strip -----------------------------------------------------------
        SegmentedPicker {
            visible: root.live
            width: parent.width
            options: root.tabOptions
            value: String(root.activeTab)
            foreground: root.fg
            muted: root.muted
            accent: root.accent
            trackColor: root.fillColor
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            onChanged: function(v) { root.activeTab = Number(v) }
        }

        // ---- active tab ------------------------------------------------------------
        Item {
            id: body
            visible: root.live
            width: parent.width
            height: root.currentTab ? root.currentTab.implicitHeight : 0

            StatsTab {
                id: statsTab
                popup: root
                width: parent.width
                visible: root.activeTab === 0
                active: root.opened && root.live && visible
            }

            SleepTab {
                id: sleepTab
                popup: root
                width: parent.width
                visible: root.activeTab === 1
                active: root.opened && root.live && visible
            }

            DetailsTab {
                id: detailsTab
                popup: root
                width: parent.width
                visible: root.activeTab === 2
                active: root.opened && root.live && visible
            }
        }

        // ---- offline hint ------------------------------------------------------------
        Text {
            visible: !root.live
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.daemonDown
                ? "The panel reconnects on its own once the service is back.\nCheck it with: systemctl --user status sl7-batteryd"
                : "No battery was found by the daemon."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            lineHeight: 1.2
        }
    }

    // ---- keyboard (via PanelKeyCatcher's signals in Panel.qml) ------------------------
    function handleTextKey(t) {
        if (!root.live) return false
        var n = Number(t)
        if (n >= 1 && n <= root.tabOptions.length) { root.activeTab = n - 1; return true }
        return false
    }
    function handleMove(dx, dy) {
        if (!root.live || !root.currentTab || typeof root.currentTab.handleMove !== "function") return false
        return root.currentTab.handleMove(dx, dy)
    }
}
