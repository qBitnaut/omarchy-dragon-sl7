# omarchy-sl7-faceunlock

Face Unlock setup and face manager for Omarchy on the Surface Laptop 7. It is
a gum TUI in Omarchy's floating terminal, in the style of
`omarchy-setup-security-fingerprint`. It configures
[howdy-next](https://codeberg.org/nathawat/howdy-next) against the IR camera
that `sl7-ir-bridge` exposes at `/dev/v4l/by-id/sl7-ir-camera`, manages
enrolled faces, and edits the PAM stacks for sudo, polkit and the lock screen
with backups, markers and rollback.

MIT licensed. The lock screen overlay is a patch against nate8199's
`nate.howdy-lock` plugin (MIT); its license text ships in
`/usr/share/licenses/omarchy-sl7-faceunlock/LICENSE.nate8199`.

## Start it

- Omarchy menu: Setup > Security > Face Unlock (rows are added per user by
  `omarchy-sl7-faceunlock-menu.service` at login, or by the first app run, or
  by `omarchy-sl7-faceunlock --menu-install`).
- Terminal: `omarchy-launch-floating-terminal-with-presentation omarchy-sl7-faceunlock`
- Removal row: Remove > Security > Face Unlock runs `omarchy-sl7-faceunlock --remove`.

## What the screens look like

The app uses the active Omarchy theme's gum colours.

- **Main menu**: a title line (face glyph, "Face Unlock", your user name), then
  a gum list: Status, Set up face unlock (wizard), Manage faces, Test
  recognition, Use face unlock for..., Lock screen, Lid gate, Disable all
  (emergency off), Quit.
- **Status**: one line per check with a coloured dot (green good, yellow
  attention, red broken): howdy-next installed, bridge service, camera
  reachable by your user (the lock screen runs PAM as you, so the loopback
  node must be openable by the logged-in user), enrolled faces, which stacks
  are on (sudo, polkit, lock), lock plugin state, lid, and
  the IR emitter (`on` while the bridge streams, `off` if `IR_EMITTER=off`
  is set in `/etc/sl7-ir-bridge.conf`, `not yet available` without the bridge).
  A red "IR bridge is stuck" line appears when the bridge has been unable to start
  a camera session for 30 s because something holds the IR camera path (EBUSY,
  `/run/sl7-ir-bridge/ebusy`); it shows the fix (`systemctl --user restart
  pipewire wireplumber; sudo systemctl restart sl7-ir-bridge`) and the holding
  processes. `status --json` has `bridge_busy` (true when stuck).
- **Manage faces**: a table of id, label and enrolment time, then Add a
  variation, Remove one, Remove all, Refresh list. Adding offers No glasses,
  Glasses, Sunglasses, Low light, Bright light, Hat or a custom label (24
  characters, no `/` or `\`). A bordered box gives the guidance for that look
  (for example "Take your glasses off. Face the camera, about 40 cm away"),
  then a 3-2-1 countdown, then the scan.
- **Use face unlock for**: sudo, polkit, lock screen, each a toggle with a
  guided test and a "Yes, keep it / No, roll it back" question.
- **Lock screen**, **Lid gate**, **Test recognition**, **Disable all**: as
  named; see below.

## Subcommands (the interface a Quickshell panel will call)

```
omarchy-sl7-faceunlock status [--json]
omarchy-sl7-faceunlock faces list [--json] [--cached]
omarchy-sl7-faceunlock faces add LABEL | remove ID | clear
omarchy-sl7-faceunlock auth status [--json]
omarchy-sl7-faceunlock auth enable lock | sudo|polkit --accept-risk
omarchy-sl7-faceunlock auth disable sudo|polkit|lock|all
omarchy-sl7-faceunlock lock install|apply|update|remove|status
omarchy-sl7-faceunlock --off
omarchy-sl7-faceunlock --menu-install [--auto] | --menu-remove
omarchy-sl7-faceunlock --dry-run ...
```

`--cached` reads the world-readable snapshot at
`/var/lib/sl7-faceunlock/state-<user>.json`, refreshed after every privileged
action, so a panel can show faces without a password. Every privileged action
goes through `/usr/lib/sl7-faceunlock/root-helper`, a single entry point a
future panel can call with `pkexec`.

## Settings the wizard applies (and why)

| Key | Value | Reason |
|---|---|---|
| `device_path` | `/dev/v4l/by-id/sl7-ir-camera` | howdy-next only accepts `/dev/video*`, `by-id` and `by-path` |
| `dark_threshold` | 99 (upstream 75) | the share of a frame in the darkest histogram bin that howdy tolerates. IR frames lit at Windows' 100 line exposure are dim (stage C: mean 20 of 255, p99 38), and the first frames of a stream are dimmer still; unlit frames (flat, no face) still fail |
| `timeout` | 4 s (hard cap) | a scan never streams longer than 5 s; the lock screen watchdog is 5 s; the bridge allows 10 s per session including sensor start |
| `abort_if_ssh` | true | lets the password-only sudo path skip the camera (below) |

These are starting values. Tune `dark_threshold` and `sface_threshold` on the
device.

## sudo and polkit are opt-in

The lock screen is the default and the only stack the wizard offers by
default. Face unlock for sudo and polkit is a separate, explicit choice with
this warning:

> Any program running as you can impersonate your face to sudo/admin prompts
> (the IR camera is reachable from your user session). Use only if you accept
> this.

The wizard asks for each separately (default No), "Use face unlock for..."
repeats the warning, and the CLI needs `auth enable sudo --accept-risk` (or a
typed `yes` on a terminal). Existing sudo and polkit configuration is never
removed on upgrade. When either is on, `status` shows the warning in yellow and
the way out: `omarchy-sl7-faceunlock auth disable sudo` (or `polkit`).

The bridge also watches for the likely attack: when another process holds the
loopback it feeds (EBUSY on open or on setting the output format) it logs the
holder and writes `/run/sl7-ir-bridge/foreign-writer`. `status` (and
`sl7-doctor`) then show a red "foreign writer on the IR camera" line with the
holder; `status --json` has `foreign_writer`.

## Passwords for adding and removing faces

Adding, removing or clearing faces, changing settings and turning a stack on
all ask for your password, never your face, so a false accept cannot enrol an
attacker. This works by running sudo after `sudo -k` with `SSH_CONNECTION` set
in sudo's own environment: pam_howdy honours `abort_if_ssh` and skips itself.
A password typed less than two minutes earlier is reused so the wizard asks
once. A fingerprint, if you set Omarchy's fingerprint up, is still accepted by
sudo. Turning things off (disable, `--off`) uses plain sudo, because that only
tightens.

## What each toggle edits (research section 6)

Each block sits above the first `auth` line, so above `include system-auth`
(pam_unix and faillock), and carries its own pam_faillock lines so face
attempts count toward the same lockout as password attempts:

```
# sl7-faceunlock BEGIN (managed by omarchy-sl7-faceunlock; do not edit)
auth      [success=4 default=ignore] pam_exec.so quiet /usr/lib/sl7-faceunlock/lid-closed
auth      [success=ok auth_err=die default=ignore] pam_faillock.so preauth
auth      [success=1 auth_err=ok default=2] pam_howdy.so workaround=native
auth      [default=1] pam_faillock.so authfail
auth      sufficient pam_faillock.so authsucc
# sl7-faceunlock END
```

Lid closed skips the block. A locked-out account stops at `preauth` (no
password fallback while locked; a faillock fault is ignored, never fatal). A
face match skips `authfail`, resets the failure record in `authsucc` and ends
the stack as `sufficient` did. A non-match records a failure and falls through
to the password stack, which still works (until the lockout trips). Anything
else (module skipped, camera unavailable, the `abort_if_ssh` password-only
path the app uses) jumps over the faillock lines and counts nothing. The
lockout limits come from `/etc/security/faillock.conf` (by default 3 failures,
10 minutes), shared with the password. The lock screen process runs as you:
faillock can only count there once a tally file exists, so check
`faillock --user $USER` after a few failed face attempts on the SL7. Clear a
lockout with `sudo faillock --user $USER --reset`.

Blocks written by an older version have no faillock lines. They keep working and
are not changed on upgrade; `status` lists them. Re-run
`omarchy-sl7-faceunlock auth enable <stack>` to bring one up to date.

- **sudo** (opt-in, see below): `/etc/pam.d/sudo`, `workaround=native`.
- **polkit** (opt-in, see below): `/etc/pam.d/polkit-1`, copied from `/usr/lib/pam.d/polkit-1` when
  absent, no workaround (`native-input` would inject Enter into the focused
  window). Also makes sure the polkit-agent-helper sandbox lets the camera
  through: it uses howdy-next's own drop-in when present, otherwise writes
  `/etc/systemd/system/polkit-agent-helper@.service.d/10-sl7-faceunlock.conf`.
- **lock** (the default): a new `/etc/pam.d/omarchy-lock-face` (lid gate,
  faillock, pam_howdy, pam_deny, `account include system-local-login`). The stock
  password context is never touched.
- **Never touched**: login, SDDM, su, sshd.

Every change: a timestamped backup in `/var/lib/sl7-faceunlock/backups/`, a
copy of the pre-edit state as `<file>.orig`, validation of the candidate
before the rename (one balanced block, one pam_howdy line, gate first, our
line above the password stack, everything outside our block byte-identical),
validation of what is on disk afterwards, and an automatic rollback if either
fails. The app then asks you to test from a second terminal and rolls back
when you answer no. A `pam_howdy.so` line that is not ours makes the app
refuse rather than stack a second one.

## Lid gate

The SL7 lid is a devicetree switch, so howdy's `abort_if_lid_closed` and
Omarchy's `omarchy-hw-laptop-closed` (both read `/proc/acpi/button/lid`) are
inert. `/usr/lib/sl7-faceunlock/lid-closed` asks logind (`busctl ... LidClosed`)
and `pam_exec` skips pam_howdy when the lid is shut, so an external-monitor
setup never wakes the camera. It fails open when logind cannot be queried.

## Lock screen

Lock screen menu > Install and enable runs
`omarchy plugin add https://github.com/nate8199/omarchy-plugin-howdy-face.git`
(pinned at commit `e5e5402`, nate.howdy-lock 1.1.1, MIT), applies
`lock-patch/howdy-lock-pam.patch`, and only then enables the plugin. The patch
replaces the one call that ran `python3 /usr/lib/howdy/compare.py` as the user
with a `PamContext` on `omarchy-lock-face`, and changes the "is it set up"
check to the PAM file plus a root-owned marker
(`/var/lib/sl7-faceunlock/enrolled-<user>`), because the models are root-only.
The "Unlock with face" button (camera only when pressed), the attempt cap of
five and everything else are nate8199's. Do not run the plugin's `setup.sh`: it
installs howdy-git and python-dlib.

After an Omarchy or plugin upgrade: Lock screen > Re-apply patch, or
`omarchy-sl7-faceunlock lock apply`. If the patch no longer applies the app
says so, leaves the file untouched and disables the plugin so the stock lock
screen returns.

## Safety notes

- Face unlock is weaker than your password. It never replaces it: the
  password prompt is always the fallback.
- Face attempts go through pam_faillock (preauth, authfail, authsucc), so
  repeated non-matches lock the account out like repeated wrong passwords. A
  covered camera counts as a non-match.
- Each extra look slightly raises the false accept surface: keep the set small.
- Models are SFace embeddings in `/etc/howdy/models/<user>.dat` (0600,
  root-only, not encrypted). Enrolment never writes images. `Test
  recognition` shows a live window and saves nothing.
- Keep a root shell open (`sudo -i`) while changing PAM. Omarchy's root account
  usually has no password, so `su` will not rescue you.
- IR emitter: the bridge lights it (sensor strobe, led_mode flash, Windows'
  exposure and frame length, held by the kernel) only while a scan streams, at
  most 10 s per session, and sets `led_mode` back to none first when the stream
  ends. The app does not drive any LED. `IR_EMITTER=off` in
  `/etc/sl7-ir-bridge.conf` keeps it dark; dark rooms then fail with "too dark".

## Rollback and emergency off

In order of preference:

1. App: Disable all, or `omarchy-sl7-faceunlock --off` (runs
   `howdy disable 1` then removes every line we added; faces are kept).
2. Per stack: `omarchy-sl7-faceunlock auth disable sudo` (or polkit, lock).
   The result says whether the file is byte-identical to the original.
3. With sudo broken, from a root shell or `pkexec`:
   ```
   sed -i '/^# sl7-faceunlock BEGIN/,/^# sl7-faceunlock END/d' /etc/pam.d/sudo /etc/pam.d/polkit-1
   rm -f /etc/pam.d/omarchy-lock-face
   ```
4. Restore a backup: `cp -a /var/lib/sl7-faceunlock/backups/sudo.<timestamp>.bak /etc/pam.d/sudo`
   (as root).
5. `howdy disable 1` alone sends every pam_howdy call straight to the password.

`pacman -R omarchy-sl7-faceunlock` runs the same restore from its
`pre_remove` scriptlet. Per-user leftovers it cannot reach: the menu rows
(`omarchy-sl7-faceunlock --menu-remove`, run first) and the lock plugin
(`omarchy plugin remove nate.howdy-lock`).

## Tests

`tests/run-tests.sh` runs everything that does not need the device, against
fixture copies in a temp directory: the PAM editors (idempotence, exact
restore, foreign lines, rollback, dry run), the JSONC menu merge, the CSV
parsing of `howdy list --plain`, argument validation of the root helper, the
CLI end to end with a fake `howdy`, and the lock overlay against a clone of
the plugin at `e5e5402` (set `SL7_TEST_NATE_REPO` to use a local clone).
Hooks: `SL7_PAM_DIR`, `SL7_VENDOR_PAM_DIR`, `SL7_STATE_DIR`, `SL7_PAM_MODULE`,
`SL7_FAILLOCK_MODULE`, `SL7_BRIDGE_FOREIGN_FILE`, `SL7_LID_GATE`, `SL7_LID_STATE`, `SL7_HOWDY_BIN`, `SL7_HOWDY_CONFIG`,
`SL7_MENU_FILE`, `SL7_PLUGIN_DIR`, `SL7_ASSUME_ROOT=1`, `SL7_NO_SYSTEMCTL=1`.
The hooks are ignored when running as root.
