#!/bin/bash
# Fixture tests for omarchy-sl7-faceunlock. No real PAM, no sudo, no camera.
# Usage: tests/run-tests.sh   (set SL7_TEST_NATE_REPO to a local clone of
# nate8199/omarchy-plugin-howdy-face at e5e5402 to run the lock-plugin tests
# offline; otherwise it is cloned from GitHub, or the tests are skipped).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB=$ROOT/lib
APP=$ROOT/omarchy-sl7-faceunlock
pass=0
fail=0
skip=0

ok_() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad_() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { # name, command...
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok_ "$name"; else bad_ "$name"; fi
}
check_not() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then bad_ "$name"; else ok_ "$name"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# --- fixtures -------------------------------------------------------------------
fresh_env() {
  rm -rf "$T/env"
  mkdir -p "$T/env/pam" "$T/env/vendor" "$T/env/state"
  cat >"$T/env/pam/sudo" <<'PAM'
#%PAM-1.0
auth		include		system-auth
account		include		system-auth
session		include		system-auth
session		optional	pam_systemd.so class=none
PAM
  cat >"$T/env/vendor/polkit-1" <<'PAM'
#%PAM-1.0
auth		include		system-auth
account		include		system-auth
password	include		system-auth
session		include		system-auth
PAM
  : >"$T/env/pam_howdy.so"
  : >"$T/env/pam_faillock.so"
  printf '[core]\ndisabled = false\nabort_if_ssh = true\n[video]\ndevice_path =\ndark_threshold = 75.0\ntimeout = 4\n' >"$T/env/config.ini"
  cp "$T/env/pam/sudo" "$T/env/sudo.orig"
  export SL7_PAM_DIR=$T/env/pam SL7_VENDOR_PAM_DIR=$T/env/vendor SL7_STATE_DIR=$T/env/state
  export SL7_PAM_MODULE=$T/env/pam_howdy.so SL7_FAILLOCK_MODULE=$T/env/pam_faillock.so SL7_LID_GATE=$LIB/lid-closed
  export SL7_ASSUME_ROOT=1 SL7_NO_SYSTEMCTL=1 SL7_DROPIN_DIR=$T/env/dropin SL7_DROPIN_VENDOR=$T/env/none
  export SL7_HOWDY_BIN=$ROOT/tests/fake-howdy FAKE_HOWDY_DIR=$T/env/howdy SL7_HOWDY_CONFIG=$T/env/config.ini
  export SL7_USER=tester SL7_MENU_FILE=$T/env/menu.jsonc XDG_STATE_HOME=$T/env/xdg SL7_BRIDGE_UNIT=none.service
  export SL7_CAMERA=$T/env/camera SL7_PLUGIN_DIR=$T/env/plugins SL7_BRIDGE_BUSY_FILE=$T/env/no-ebusy SL7_BRIDGE_FOREIGN_FILE=$T/env/no-foreign
}
H=$LIB/root-helper

# --- static ---------------------------------------------------------------------
check "no trailing whitespace" bash -c "! grep -rIn '[[:space:]]\$' '$ROOT' --exclude-dir=.git"
if command -v shellcheck >/dev/null; then
  check "shellcheck -S warning" shellcheck -S warning -x "$APP" "$LIB"/*.sh "$H" "$LIB/lid-closed" "$ROOT/tests/run-tests.sh" "$ROOT/tests/fake-howdy"
fi

# --- lid gate -------------------------------------------------------------------
check "lid gate: closed" env SL7_LID_STATE=closed "$LIB/lid-closed"
check_not "lid gate: open" env SL7_LID_STATE=open "$LIB/lid-closed"

# --- PAM: sudo ------------------------------------------------------------------
fresh_env
check "sudo enable" "$H" pam-enable sudo
check "sudo block above include system-auth" bash -c "awk '/sl7-faceunlock BEGIN/{b=NR} /include.*system-auth/{if(!a)a=NR} END{exit !(b && b<a)}' '$SL7_PAM_DIR/sudo'"
check "sudo uses workaround=native" grep -q 'pam_howdy.so workaround=native' "$SL7_PAM_DIR/sudo"
check "sudo lid gate before howdy" bash -c "awk '/lid-closed/{g=NR} /pam_howdy/{h=NR} END{exit !(g && g<h)}' '$SL7_PAM_DIR/sudo'"
check "sudo has faillock preauth, authfail and authsucc" bash -c "grep -q 'pam_faillock.so preauth' '$SL7_PAM_DIR/sudo' && grep -q 'pam_faillock.so authfail' '$SL7_PAM_DIR/sudo' && grep -q 'pam_faillock.so authsucc' '$SL7_PAM_DIR/sudo'"
check "sudo faillock order: gate, preauth, howdy, authfail, authsucc" bash -c "awk '/lid-closed/{g=NR} /faillock.so preauth/{p=NR} /pam_howdy/{h=NR} /faillock.so authfail/{f=NR} /faillock.so authsucc/{s=NR} END{exit !(g<p && p<h && h<f && f<s)}' '$SL7_PAM_DIR/sudo'"
check "sudo gate skips the whole block (success=4)" grep -q 'success=4 default=ignore] pam_exec.so quiet' "$SL7_PAM_DIR/sudo"
check "sudo password fallback: authfail does not die" bash -c "! grep -q 'default=die\] pam_faillock.so authfail' '$SL7_PAM_DIR/sudo'"
check "sudo no uinput or sufficient howdy line" bash -c "! grep -q 'sufficient pam_howdy' '$SL7_PAM_DIR/sudo'"
cp "$SL7_PAM_DIR/sudo" "$T/sudo.once"
check "sudo enable idempotent" "$H" pam-enable sudo
check "sudo second enable changes nothing" cmp "$T/sudo.once" "$SL7_PAM_DIR/sudo"
check "timestamped backup exists" bash -c "ls '$SL7_STATE_DIR'/backups/sudo.*.bak"
check "sudo disable" "$H" pam-disable sudo
check "sudo restored byte for byte" cmp "$SL7_PAM_DIR/sudo" "$T/env/sudo.orig"
check "sudo disable idempotent" "$H" pam-disable sudo

# --- PAM: Omarchy fingerprint already present -------------------------------------
fresh_env
sed -i '1a auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed\nauth      sufficient pam_fprintd.so' "$SL7_PAM_DIR/sudo"
cp "$SL7_PAM_DIR/sudo" "$T/sudo.fp"
check "sudo enable beside fingerprint" "$H" pam-enable sudo
check "fingerprint lines untouched" bash -c "grep -c 'pam_fprintd.so' '$SL7_PAM_DIR/sudo' | grep -qx 1"
check "sudo disable beside fingerprint" "$H" pam-disable sudo
check "fingerprint config restored exactly" cmp "$SL7_PAM_DIR/sudo" "$T/sudo.fp"

# --- PAM: foreign howdy line, missing module, no auth line -------------------------
fresh_env
sed -i '1a auth sufficient pam_howdy.so' "$SL7_PAM_DIR/sudo"
check_not "foreign pam_howdy line refused" "$H" pam-enable sudo
fresh_env
check_not "missing module refused" env SL7_PAM_MODULE=$T/env/nonexistent "$H" pam-enable sudo
check_not "missing faillock module refused" env SL7_FAILLOCK_MODULE=$T/env/nonexistent "$H" pam-enable sudo
printf '#%%PAM-1.0\naccount include system-auth\n' >"$SL7_PAM_DIR/sudo"
check_not "stack without auth line refused" "$H" pam-enable sudo
check "refusal leaves file alone" bash -c "! grep -q sl7-faceunlock '$SL7_PAM_DIR/sudo'"
fresh_env
printf '%s\n' '# sl7-faceunlock BEGIN (x)' >>"$SL7_PAM_DIR/sudo"
check_not "unbalanced markers refused" "$H" pam-enable sudo

# --- PAM: polkit and lock -------------------------------------------------------------
fresh_env
check "polkit enable (copies vendor file)" "$H" pam-enable polkit
check "polkit has no workaround" bash -c "grep -q 'pam_howdy.so\$' '$SL7_PAM_DIR/polkit-1'"
check "polkit sandbox drop-in written" test -f "$SL7_DROPIN_DIR/10-sl7-faceunlock.conf"
check "lock enable" "$H" pam-enable lock
check "lock service ends in faillock authsucc, deny, account" bash -c "grep -A2 'faillock.so authsucc' '$SL7_PAM_DIR/omarchy-lock-face' | grep -q 'pam_deny.so' && grep -q '^account' '$SL7_PAM_DIR/omarchy-lock-face'"
check "lock has faillock preauth before howdy" bash -c "awk '/faillock.so preauth/{p=NR} /pam_howdy/{h=NR} END{exit !(p && p<h)}' '$SL7_PAM_DIR/omarchy-lock-face'"
check "polkit has faillock lines" bash -c "grep -q 'faillock.so preauth' '$SL7_PAM_DIR/polkit-1' && grep -q 'faillock.so authsucc' '$SL7_PAM_DIR/polkit-1'"
check "polkit drop-in has no uinput" bash -c "! grep -q uinput '$SL7_DROPIN_DIR/10-sl7-faceunlock.conf'"
check "state reports enabled" bash -c "'$H' pam-state | grep -qx 'lock=enabled'"
check "disable all" "$H" pam-disable all
check "polkit file we created is gone" test ! -e "$SL7_PAM_DIR/polkit-1"
check "lock file we created is gone" test ! -e "$SL7_PAM_DIR/omarchy-lock-face"
check "drop-in removed" test ! -e "$SL7_DROPIN_DIR/10-sl7-faceunlock.conf"

# vendor drop-in from howdy-next is used instead of writing our own
fresh_env
: >"$T/env/vendor-dropin"
check "polkit with vendor drop-in" env SL7_DROPIN_VENDOR=$T/env/vendor-dropin "$H" pam-enable polkit
check "no duplicate drop-in" test ! -e "$SL7_DROPIN_DIR/10-sl7-faceunlock.conf"

# existing polkit-1 (from Omarchy fingerprint setup) is edited in place and kept
fresh_env
cp "$T/env/vendor/polkit-1" "$SL7_PAM_DIR/polkit-1"
sed -i '1i auth      sufficient pam_fprintd.so' "$SL7_PAM_DIR/polkit-1"
cp "$SL7_PAM_DIR/polkit-1" "$T/polkit.fp"
"$H" pam-enable polkit >/dev/null
"$H" pam-disable polkit >/dev/null
check "existing polkit-1 restored exactly" cmp "$SL7_PAM_DIR/polkit-1" "$T/polkit.fp"

# --- PAM: rollback ----------------------------------------------------------------------
fresh_env
rb=$(
  # shellcheck source=../lib/common.sh
  source "$LIB/common.sh"
  # shellcheck source=../lib/pam.sh
  source "$LIB/pam.sh"
  n=0
  real_validate=$(declare -f pam_validate)
  eval "${real_validate/pam_validate/real_pam_validate}"
  pam_validate() { n=$((n + 1)); [[ $n -ge 2 ]] && return 1; real_pam_validate "$@"; }
  pam_enable sudo >/dev/null 2>&1
  echo "rc=$?"
)
check "post-write validation failure reports error" bash -c "[[ '$rb' == rc=1 ]]"
check "post-write validation failure rolled back" cmp "$SL7_PAM_DIR/sudo" "$T/env/sudo.orig"
fresh_env
rb=$(
  # shellcheck source=../lib/common.sh
  source "$LIB/common.sh"
  # shellcheck source=../lib/pam.sh
  source "$LIB/pam.sh"
  pam_install() { return 1; }
  pam_enable lock >/dev/null 2>&1
  echo "rc=$?"
)
check "failed install of new file leaves nothing" bash -c "[[ '$rb' == rc=1 && ! -e '$SL7_PAM_DIR/omarchy-lock-face' ]]"

# --- PAM: dry run -------------------------------------------------------------------------
fresh_env
check "dry-run enable" "$H" --dry-run pam-enable sudo
check "dry-run changed nothing" cmp "$SL7_PAM_DIR/sudo" "$T/env/sudo.orig"
check "dry-run wrote no state" bash -c "[[ -z \$(ls '$SL7_STATE_DIR') ]]"

# --- helper argument validation -------------------------------------------------------------
fresh_env
check_not "helper rejects root as user" "$H" faces-add root "x"
check_not "helper rejects label with slash" "$H" faces-add tester "a/b"
check_not "helper rejects 25-char label" "$H" faces-add tester "aaaaaaaaaaaaaaaaaaaaaaaaa"
check_not "helper rejects non-numeric id" "$H" faces-remove tester "1;rm"
check_not "helper rejects odd device" "$H" configure /tmp/evil 90 4
check_not "helper rejects timeout over 4 s" "$H" configure /dev/v4l/by-id/sl7-ir-camera 90 6
check_not "helper rejects unknown stack" "$H" pam-enable login

# --- faces and snapshot ---------------------------------------------------------------------
fresh_env
check "faces add" "$H" faces-add tester "No glasses"
check "faces add custom label with comma" "$H" faces-add tester 'Sun, "shade"'
json=$("$H" faces-json tester)
check "faces json has two entries" bash -c "[[ \$(jq length <<<'$json') == 2 ]]"
check "faces json keeps quoted label" bash -c "jq -e '.[1].label == \"Sun, \\\"shade\\\"\"' <<<'$json'"
check "snapshot written" test -s "$SL7_STATE_DIR/state-tester.json"
check "enrolled marker written" test -s "$SL7_STATE_DIR/enrolled-tester"
check "faces remove" "$H" faces-remove tester 1
check "faces clear" "$H" faces-clear tester
check "enrolled marker removed at zero" test ! -e "$SL7_STATE_DIR/enrolled-tester"
check "configure applies keys" "$H" configure /dev/v4l/by-id/sl7-ir-camera 90 4
check "configure set abort_if_ssh" grep -q 'abort_if_ssh=true' "$FAKE_HOWDY_DIR/config.set"
check "configure set timeout 4" grep -q 'timeout=4' "$FAKE_HOWDY_DIR/config.set"
"$H" off >/dev/null 2>&1
check "off runs howdy disable 1" grep -qx 1 "$FAKE_HOWDY_DIR/disabled"

# --- CLI end to end ---------------------------------------------------------------------------
fresh_env
mkdir -p "$SL7_STATE_DIR"
check_not "cli: auth enable sudo refused without --accept-risk" "$APP" auth enable sudo
check "cli: refused enable changed nothing" cmp "$SL7_PAM_DIR/sudo" "$T/env/sudo.orig"
check "cli: warning text printed" bash -c "'$APP' auth enable sudo 2>&1 | grep -q 'impersonate your face'"
check "cli: auth enable sudo" "$APP" auth enable sudo --accept-risk
check "cli: status warns about sudo" bash -c "'$APP' status 2>&1 | grep -q 'impersonate your face' && '$APP' status | grep -q 'auth disable sudo'"
check "cli: howdy enabled after enable" bash -c "[[ ! -e '$FAKE_HOWDY_DIR/disabled' ]] || grep -qx 0 '$FAKE_HOWDY_DIR/disabled'"
check "cli: auth status json" bash -c "'$APP' auth status --json | jq -e '.sudo == \"enabled\"'"
check "cli: faces add" "$APP" faces add Glasses
check "cli: faces list json" bash -c "'$APP' faces list --json | jq -e '.[0].label == \"Glasses\"'"
check "cli: faces list cached" bash -c "'$APP' faces list --json --cached | jq -e 'length == 1'"
check "cli: status json" bash -c "'$APP' status --json | jq -e '.emitter == \"unavailable\" and .faces[0].label == \"Glasses\" and .stacks.sudo == \"enabled\"'"
check "cli: status text mentions emitter" bash -c "'$APP' status | grep -q 'not yet available'"
printf '# comment\nIR_EMITTER=off\n' >"$T/env/bridge-off.conf"
printf 'IR_EMITTER=on\n' >"$T/env/bridge-on.conf"
emitter_with() ( # conf file: the state with an active bridge
  # shellcheck source=../lib/common.sh
  source "$LIB/common.sh"
  # shellcheck source=../lib/howdy.sh
  source "$LIB/howdy.sh"
  bridge_state() { printf active; }
  SL7_BRIDGE_CONF=$1 emitter_state
)
em_none=$(emitter_with "$T/env/none.conf")
em_on=$(emitter_with "$T/env/bridge-on.conf")
em_off=$(emitter_with "$T/env/bridge-off.conf")
check "emitter: on when no conf is readable" bash -c "[[ '$em_none' == on ]]"
check "emitter: on from the conf" bash -c "[[ '$em_on' == on ]]"
check "emitter: off from the conf" bash -c "[[ '$em_off' == off ]]"
check "cli: status json, bridge not stuck without the flag file" bash -c "'$APP' status --json | jq -e '.bridge_busy == false'"
printf 'since=1\nholders=1\npid 5 (wireplumber) uid 1000 holds /dev/video3 (IR video node)\n' >"$T/env/ebusy"
check "cli: status json, bridge stuck with the flag file" bash -c "SL7_BRIDGE_BUSY_FILE='$T/env/ebusy' '$APP' status --json | jq -e '.bridge_busy == true'"
check "cli: status text gives the fix and the holder when stuck" bash -c "SL7_BRIDGE_BUSY_FILE='$T/env/ebusy' '$APP' status | grep -q 'systemctl --user restart pipewire wireplumber' && SL7_BRIDGE_BUSY_FILE='$T/env/ebusy' '$APP' status | grep -q 'holder: pid 5 (wireplumber)'"
check "cli: --off" "$APP" --off
check "cli: --off removed the lines" bash -c "! grep -rq sl7-faceunlock '$SL7_PAM_DIR'"
check "cli: sudo restored" cmp "$SL7_PAM_DIR/sudo" "$T/env/sudo.orig"
printf 'since=1\nholders=1\npid 7 (evil) uid 1000 writes /dev/video42\n' >"$T/env/foreign"
check "cli: status json, no foreign writer by default" bash -c "'$APP' status --json | jq -e '.foreign_writer == false'"
check "cli: status json, foreign writer with the flag file" bash -c "SL7_BRIDGE_FOREIGN_FILE='$T/env/foreign' '$APP' status --json | jq -e '.foreign_writer == true'"
check "cli: status text shows the foreign writer in full" bash -c "SL7_BRIDGE_FOREIGN_FILE='$T/env/foreign' '$APP' status | grep -q 'foreign writer on the IR camera' && SL7_BRIDGE_FOREIGN_FILE='$T/env/foreign' '$APP' status | grep -q 'holder: pid 7 (evil)'"
check "cli: dry-run enable" "$APP" --dry-run auth enable polkit --accept-risk
check "cli: bad stack rejected" bash -c "! '$APP' auth enable login"

# --- menu merge -------------------------------------------------------------------------------
fresh_env
cat >"$SL7_MENU_FILE" <<'JSONC'
{
  // user rows
  "personal": {"icon":"x","label":"Personal"},
  "personal.notes": {"icon":"y","label":"Notes","action":"true"}
}
JSONC
cp "$SL7_MENU_FILE" "$T/menu.orig"
check "menu install" "$APP" --menu-install
check "menu valid after install" bash -c "sed -E '/^[[:space:]]*\/\/.*\$/d' '$SL7_MENU_FILE' | sed -zE 's/,([[:space:]]*[]}])/\1/g' | jq -e 'has(\"setup.security.face\") and has(\"remove.security.face\") and has(\"personal.notes\")'"
check "menu backup created" bash -c "ls '$SL7_MENU_FILE'.bak.*"
cp "$SL7_MENU_FILE" "$T/menu.once"
check "menu install idempotent" "$APP" --menu-install
check "menu second install unchanged" cmp "$T/menu.once" "$SL7_MENU_FILE"
check "menu remove" "$APP" --menu-remove
check "menu remove keeps user content" bash -c "diff <(sed -E 's/,\$//' '$SL7_MENU_FILE') <(sed -E 's/,\$//' '$T/menu.orig')"
check "auto install respects opt-out" bash -c "'$APP' --menu-install --auto; ! grep -q setup.security.face '$SL7_MENU_FILE'"
check "explicit install clears opt-out" bash -c "'$APP' --menu-install; grep -q setup.security.face '$SL7_MENU_FILE'"
rm -f "$SL7_MENU_FILE"
check "menu creates missing file" "$APP" --menu-install
printf '{ "a": \n' >"$SL7_MENU_FILE"
check_not "menu refuses broken file" "$APP" --menu-install
check "broken file left alone" bash -c "[[ \$(cat '$SL7_MENU_FILE') == '{ \"a\": ' ]]"

# --- lock plugin overlay ------------------------------------------------------------------------
nate=${SL7_TEST_NATE_REPO:-}
if [[ -z $nate ]]; then
  nate=$T/nate
  git clone -q https://github.com/nate8199/omarchy-plugin-howdy-face.git "$nate" 2>/dev/null || nate=""
fi
if [[ -n $nate ]] && git -C "$nate" -c advice.detachedHead=false checkout -q e5e5402 2>/dev/null; then
  fresh_env
  mkdir -p "$T/bin" "$SL7_PLUGIN_DIR"
  cat >"$T/bin/omarchy" <<STUB
#!/bin/bash
# stub: omarchy plugin add|enable|remove
[[ \$1 == plugin ]] || exit 1
case \$2 in
add) git clone -q "\$3" "$SL7_PLUGIN_DIR/nate.howdy-lock" ;;
enable) echo "enable \$3" >>"$T/omarchy.log" ;;
remove) rm -rf "$SL7_PLUGIN_DIR/nate.howdy-lock" ;;
update) echo "update" >>"$T/omarchy.log" ;;
esac
STUB
  printf '#!/bin/bash\necho "disable $1" >>"%s/omarchy.log"\n' "$T" >"$T/bin/omarchy-plugin-disable"
  chmod +x "$T/bin/omarchy" "$T/bin/omarchy-plugin-disable"
  export PATH=$T/bin:$PATH SL7_LOCK_URL=$nate
  check "lock install applies patch then enables" "$APP" lock install
  check "lock patched marker" grep -q 'sl7-faceunlock: PAM patch' "$SL7_PLUGIN_DIR/nate.howdy-lock/Service.qml"
  check "lock no longer calls compare.py" bash -c "! grep -v '^//' '$SL7_PLUGIN_DIR/nate.howdy-lock/Service.qml' | grep -q '/usr/lib/howdy/compare.py \"'"
  check "lock uses PAM service" grep -q 'config: "omarchy-lock-face"' "$SL7_PLUGIN_DIR/nate.howdy-lock/Service.qml"
  check "lock keeps nate8199 license" grep -q 'nate8199' "$SL7_PLUGIN_DIR/nate.howdy-lock/LICENSE"
  check "lock enabled after patch" grep -q 'enable nate.howdy-lock' "$T/omarchy.log"
  check "lock apply idempotent" "$APP" lock apply
  svc=$SL7_PLUGIN_DIR/nate.howdy-lock/Service.qml
  check "lock state-sync marker" grep -q 'sl7-faceunlock: lock-state sync' "$svc"
  check "lock locked uses the mirror" grep -q 'readonly property bool locked: lockRequested || sessionLockHeld || sessionLock.secure' "$svc"
  check "lock has freshLocked and syncSessionLockState" bash -c "grep -q 'function freshLocked()' '$svc' && grep -q 'function syncSessionLockState()' '$svc' && grep -q 'function releaseLockRequest()' '$svc'"
  check "lock IPC lock() decides on the fresh state" bash -c "grep -A8 'function lock(): string' '$svc' | grep -q 'freshLocked()'"
  check "lock status reports each patch" bash -c "'$APP' lock status | grep -q 'howdy-lock-pam.patch: applied' && '$APP' lock status | grep -q 'howdy-lock-state-sync.patch: applied'"
  check "lock status patched=yes" bash -c "'$APP' lock status | grep -q 'patched=yes'"
  check "lock records the patch set" bash -c "[[ -s '$XDG_STATE_HOME/omarchy-sl7-faceunlock/lock-patchset' ]]"
  # upgrade from a PAM-only overlay (previous package): apply adds the missing patch
  cp -p "$svc" "$T/svc.full"
  cp -p "$svc.sl7-orig" "$svc"
  patch -p1 -s -d "$SL7_PLUGIN_DIR/nate.howdy-lock" -i "$LIB/lock-patch/howdy-lock-pam.patch" >/dev/null 2>&1
  check "PAM-only overlay reported" bash -c "'$APP' lock status | grep -q 'howdy-lock-state-sync.patch: missing'"
  check "lock apply upgrades a PAM-only overlay" "$APP" lock apply
  check "upgraded overlay equals a fresh one" cmp -s "$svc" "$T/svc.full"
  # login hook: skips while locked, applies when not, then goes quiet
  cat >"$T/bin/omarchy-shell" <<STUB
#!/bin/bash
[[ \$1 == -q ]] && shift
[[ \$1 == lock && \$2 == status ]] && { cat "$T/shell-state"; exit 0; }
echo "\$*" >>"$T/shell.log"
STUB
  chmod +x "$T/bin/omarchy-shell"
  cp -p "$svc.sl7-orig" "$svc"
  patch -p1 -s -d "$SL7_PLUGIN_DIR/nate.howdy-lock" -i "$LIB/lock-patch/howdy-lock-pam.patch" >/dev/null 2>&1
  rm -f "$XDG_STATE_HOME/omarchy-sl7-faceunlock/lock-patchset"
  : >"$T/shell.log"
  printf '{"locked":true,"requested":false,"sessionLocked":false,"secure":true}\n' >"$T/shell-state"
  check "lock auto while locked succeeds" "$APP" lock auto
  check "lock auto while locked edits nothing" bash -c "! grep -q 'lock-state sync' '$svc'"
  printf '{"locked":true,"requested":false,"sessionLocked":false,"secure":false}\n' >"$T/shell-state"
  check "lock auto ignores the stale cached locked" "$APP" lock auto
  check "lock auto applied the missing patch" grep -q 'sl7-faceunlock: lock-state sync' "$svc"
  check "lock auto rescans plugins" grep -q 'shell rescanPlugins' "$T/shell.log"
  : >"$T/shell.log"
  check "lock auto is quiet once current" bash -c "'$APP' lock auto && [[ ! -s '$T/shell.log' ]]"
  # upstream drift: patch must fail safe
  rm -rf "$SL7_PLUGIN_DIR/nate.howdy-lock/.git" "$SL7_PLUGIN_DIR/nate.howdy-lock/Service.qml.sl7-orig"
  printf 'import QtQuick\nItem {}\n' >"$SL7_PLUGIN_DIR/nate.howdy-lock/Service.qml"
  : >"$T/omarchy.log"
  check_not "drifted upstream: apply fails" "$APP" lock apply
  check "drifted upstream: plugin disabled (stock lock stays)" grep -q 'disable nate.howdy-lock' "$T/omarchy.log"
  check "drifted upstream: file untouched" bash -c "[[ \$(head -n1 '$SL7_PLUGIN_DIR/nate.howdy-lock/Service.qml') == 'import QtQuick' ]]"
  check "lock remove" "$APP" lock remove
else
  skip=$((skip + 1))
  printf 'SKIP lock plugin tests (no clone of nate8199/omarchy-plugin-howdy-face)\n'
fi

printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
((fail == 0))
