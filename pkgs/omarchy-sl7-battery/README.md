# omarchy-sl7-battery

A battery app for Omarchy on the Microsoft Surface Laptop 7. It replaces Omarchy's Power bar
widget (`omarchy.power`) with a Quickshell plugin, `qbit.sl7battery`, backed by `sl7-batteryd`,
a small Rust user daemon written for this laptop's `qcom-battmgr` battery.

The popup's styling and chart components (dot-matrix charts, stat tiles, segmented pickers,
theme handling from the live Omarchy `colors.toml`) are adapted from CyberPowerPanel, a UPS panel
by the same author (MIT). Nothing of its daemon is reused: this is a laptop battery, not a UPS.

## What it shows

- **Bar:** battery glyph and percentage (right-click toggles the percentage), tooltip with the
  state, time left and the profile. Click opens the popup; so does
  `omarchy-shell qbit.sl7battery toggle` or the "SL7 Battery" launcher entry.
- **Header:** On battery / Charging / Plugged in, a power profile pill, and an `AUTO SAVER` pill
  when the auto power saver is armed (quiet) or active. Under the title: **hours since the
  battery was last full** and how much of it has gone ("14h 20m since full · 62% used").
- **Tiles:** Charge % (a notch marks the auto-saver threshold), Time left / To full ("until
  Tonight 10:40pm"), Draw in W (with the average).
- **Readings:** health (full vs design energy), temperature, voltage, cycles (hidden when the
  firmware reports 0).
- **Power profile** picker (Power saver, Balanced, and Performance only if PPD lists it) and
  **Auto power saver below [30]%** (toggle and a 10-60 slider).
- **Stats tab:** 6h / 24h / 7d / 30d, series Charge / Draw / Temp / Screen-on, a 16-row dot chart.
  The charge chart has a fixed 0-100 axis, marks stretches on AC, shows sleep gaps as dim track
  and **projects forward**: faint hollow columns after a "now" divider run to the projected 0%
  (or to full when charging, to the charge limit if one is set, tapering above 80%), and the end
  label is human time ("Tonight 10pm", "This afternoon 3pm", "Today 11am", "Tomorrow 2am",
  "Fri 9am"; rounded to 10-15 minutes; "—" when the rate is under 0.3 W or there is under five
  minutes of data).
- **Sleep tab:** last night ("−6% over 8h 12m · 0.37 W avg · woke 3×") and recent sleeps.
- **Details tab:** usage since full split awake/asleep, time on battery, average draw today,
  drain per hour with the screen on, off and suspended, charging rate, the power mode applied by
  `omarchy-sl7-powermode` and the CPU cap, and SoC rails (relative, `qcom_pld_power`).

## Install

```
sudo pacman -S omarchy-sl7-battery        # from the omarchy-sl7 repository
```

Log out and in. Three things then happen in your session:

1. `sl7-batteryd.service` (user, `graphical-session.target`) starts the daemon.
2. `omarchy-sl7-battery-plugin.service` (user oneshot) copies the plugin to
   `~/.config/omarchy/plugins/qbit.sl7battery` (Omarchy loads third-party plugins only from there,
   as copies) whenever it differs from `/usr/share/omarchy-sl7-battery/plugin`, and rescans.
3. **Once**, it swaps the bar widget with Omarchy's own commands: the plugin is enabled right
   after `omarchy.power`, then `omarchy.power` is disabled. `~/.local/state/omarchy-sl7-battery/widget-swap`
   records it; afterwards the bar is yours (re-add the Power widget, move or remove ours, and it
   stays that way). If `omarchy.power` is not on your bar nothing is placed
   (`omarchy plugin enable qbit.sl7battery`). Your `shell.json` is only edited through
   `omarchy plugin enable|disable`, never by hand.

Undo: `omarchy-sl7-battery-plugin uninstall` re-enables `omarchy.power` where ours was, removes
the plugin and records that you opted out (the login service then leaves things alone until
`omarchy-sl7-battery-plugin install --force`). Do it before `pacman -R`. `omarchy-sl7-battery-plugin
status` shows the state. Omarchy's `SUPER + CTRL + P` binding targets `omarchy.power`, so it does
nothing while that widget is disabled; bind `omarchy-shell qbit.sl7battery toggle` instead.

## Data and files

| What | Where |
|---|---|
| Daemon | `/usr/lib/omarchy-sl7-battery/sl7-batteryd` (user unit `sl7-batteryd.service`) |
| Socket | `$XDG_RUNTIME_DIR/sl7-batteryd.sock` (mode 0600) |
| History | `$XDG_STATE_HOME/sl7-battery/`: `m1.ring` (1-minute buckets, 7 days), `m15.ring` (15-minute, 1 year), `sleeps.jsonl`, `state.json` (last full charge) |
| Config | `~/.config/omarchy-sl7-battery/config.json`, written by the daemon's `config.set` |
| Plugin source | `/usr/share/omarchy-sl7-battery/plugin` (copied per user) |

The daemon reads `/sys/class/power_supply/qcom-battmgr-bat` (capacity with an
`energy_now/energy_full` fallback, energy, `power_now` whose sign is not trusted, status,
temperature, voltage), the AC/USB supplies, `hyprctl monitors -j` (screen on), power-profiles-daemon
over `busctl`, and subscribes to logind `PrepareForSleep`, UPower `OnBattery` and PPD
`ActiveProfile` through `gdbus monitor`. It samples **every 20 s while awake** (never faster),
keeps buckets in memory and flushes every 5 minutes and before sleep and at exit. Sleep periods
record the charge and energy before and after, and the `wake: irq` lines that
`omarchy-surface-sl7` logged to the journal in that window. On the first run it imports UPower's
`history-charge-*.dat` into the 15-minute ring when readable, and seeds "last full" from history.

## Auto power saver

Edge-triggered, in the daemon: when **on battery** and the charge falls to the threshold (default
30%, 10-60), it remembers the current profile and runs `powerprofilesctl set power-saver`. If you
change the profile while it is forced, it forgets (and does not fire again until the charge climbs
5 points above the threshold). On AC it only clears (Omarchy restores its AC profile itself). If
forced and the charge reaches threshold + 5 on battery, or you disable it, it restores the
previous profile. It resets at boot and re-checks after resume. Changing the threshold or the toggle
re-arms it, so setting the threshold above the current charge switches immediately.

The profile itself only does something because `omarchy-surface-sl7` (>= 0.1.0-55) acts on it:
`omarchy-sl7-powermode` reads the PPD profile and picks the CPU/GPU caps, Wi-Fi power save,
parking, refresh rate, animations and blur from the power source and the profile. Check with
`omarchy-sl7-powermode status`.

## Socket protocol

Newline-delimited JSON, the same envelope as the CyberPowerPanel client:
the daemon sends `{"type":"hello",...}`; requests are `{"v":1,"id":N,"cmd":"...","args":{...}}`,
answered by `{"type":"response","id":N,"ok":true,"data":...}` or `"ok":false,"error":{"code","message"}`;
pushes are `{"type":"push","topic":"status"|"config","data":...}`.

| cmd | args | data |
|---|---|---|
| `subscribe` | `{topics:["status","config"]}` | acknowledges; a status push follows at once, then one per sample and on events |
| `status.get` | | the status object (charge, flow, energies, `power_w`, `ewma_w`, `avg_since_unplug_w`, `since_unplug_s`, `charge_w`, `temp_c`, `voltage_v`, `profile`, `profiles`, `auto`, `since_full`, ...) |
| `history.get` | `{window:"6h"\|"24h"\|"7d"\|"30d", metrics:[...], points:N}` | `{step_s, from, to, series:[{metric, avg:[...]}]}`; metrics `charge`, `draw_w`, `charge_w`, `temp_c`, `screen_on`, `on_ac`, `asleep` |
| `details.get` | `{since: unix}` | drain by state, today's average, charging rate, power mode, rails, `since_full` |
| `sleeps.get` | `{limit}` | recent sleeps with drain, average W and wake count |
| `config.get` / `config.set` | `{base_rev, patch:{auto_saver:{enabled, threshold}}}` | config and `rev`; `conflict` if the rev is stale |
| `profile.set` | `{profile}` | sets the profile through Omarchy so it is remembered per power source |

`since_full` is `{full_ts, secs, used_pct, asleep_s, awake_s, on_ac}`, or null while the battery is
full. "Full" is status Full, 99% or more, or the charge limit when one is set.

## Development

No part of this runs on the x86 dev box: edit here, CI builds and tests, the SL7 runs it.
CI (`.github/workflows/omarchy-sl7-battery.yml`) runs `node --test tests/js` (projection, time
labels and the reused chart/theme libraries), `cargo test --locked` (ring storage, rate model,
auto saver, protocol, sysfs parsing against fake trees), shellcheck on the user script, and builds
the package in the Arch Linux ARM container.

## License

MIT, Copyright (c) 2026 qBitnaut. The chart and theme components derive from CyberPowerPanel
(MIT, same author).
