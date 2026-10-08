# shellcheck shell=bash
# shellcheck disable=SC2034
# omarchy-sl7-faceunlock: shared settings and helpers. Sourced, never executed.
#
# Test hooks: every path below can be redirected with an SL7_* variable so the
# PAM and menu editors can run against fixtures. Running as root, the hooks are
# ignored unless SL7_ALLOW_ENV_HOOKS=1, so a hostile environment cannot point
# the privileged helper at other files.

SL7_VERSION=0.1.0

sl7_is_root() {
  [[ $EUID -eq 0 ]]
}

if sl7_is_root && [[ -z ${SL7_ALLOW_ENV_HOOKS:-} ]]; then
  unset SL7_PAM_DIR SL7_VENDOR_PAM_DIR SL7_STATE_DIR SL7_PAM_MODULE SL7_LID_GATE \
    SL7_HOWDY_BIN SL7_HOWDY_CONFIG SL7_DROPIN_VENDOR SL7_DROPIN_DIR SL7_NO_SYSTEMCTL \
    SL7_ASSUME_ROOT SL7_USER SL7_DRY_RUN SL7_HELPER SL7_BRIDGE_UNIT SL7_CAMERA
fi

PAM_DIR=${SL7_PAM_DIR:-/etc/pam.d}
VENDOR_PAM_DIR=${SL7_VENDOR_PAM_DIR:-/usr/lib/pam.d}
STATE_DIR=${SL7_STATE_DIR:-/var/lib/sl7-faceunlock}
PAM_MODULE=${SL7_PAM_MODULE:-/usr/lib/security/pam_howdy.so}
LID_GATE=${SL7_LID_GATE:-/usr/lib/sl7-faceunlock/lid-closed}
HOWDY_BIN=${SL7_HOWDY_BIN:-howdy}
HOWDY_CONFIG=${SL7_HOWDY_CONFIG:-/etc/howdy/config.ini}
DROPIN_VENDOR=${SL7_DROPIN_VENDOR:-/usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf}
DROPIN_DIR=${SL7_DROPIN_DIR:-/etc/systemd/system/polkit-agent-helper@.service.d}
DROPIN_NAME=10-sl7-faceunlock.conf
CAMERA=${SL7_CAMERA:-/dev/v4l/by-id/sl7-ir-camera}
BRIDGE_UNIT=${SL7_BRIDGE_UNIT:-sl7-ir-bridge.service}
# written by sl7-ir-bridge when its session starts have failed with EBUSY for 30 s
BRIDGE_BUSY_FILE=${SL7_BRIDGE_BUSY_FILE:-/run/sl7-ir-bridge/ebusy}
DRY_RUN=${SL7_DRY_RUN:-0}

# Defaults the wizard applies to howdy-next (README: tune on the device). The
# timeout stays at 4 s or less so a scan never streams longer than 5 s, well
# inside the bridge's 10 s session cap. The dark threshold is howdy's limit for
# the share of a frame in the darkest histogram bin: IR frames lit at Windows'
# 100 line exposure are dim (mean about 20 of 255), so the limit is set near
# its maximum; frames with no light at all still fail it.
CFG_DEVICE=$CAMERA
CFG_DARK_THRESHOLD=99
CFG_TIMEOUT=4

SL7_BEGIN='# sl7-faceunlock BEGIN (managed by omarchy-sl7-faceunlock; do not edit)'
SL7_END='# sl7-faceunlock END'

STACKS=(sudo polkit lock)

# --- output -----------------------------------------------------------------

if [[ -t 1 ]]; then
  C_G=$'\e[32m' C_R=$'\e[31m' C_Y=$'\e[33m' C_D=$'\e[2m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  C_G='' C_R='' C_Y='' C_D='' C_B='' C_0=''
fi

say() { printf '%s\n' "$*"; }
ok() { printf '%s\n' "${C_G}ok${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}warning${C_0} $*" >&2; }
err() { printf '%s\n' "${C_R}error${C_0} $*" >&2; }
note() { printf '%s\n' "${C_D}$*${C_0}"; }

die() {
  err "$*"
  exit 1
}

# Append to the audit log when the state dir is writable; never fatal.
audit() {
  [[ $DRY_RUN == 1 ]] && return 0
  [[ -d $STATE_DIR && -w $STATE_DIR ]] || return 0
  printf '%s %s\n' "$(date -Is)" "$*" >>"$STATE_DIR/audit.log" 2>/dev/null || true
}

# --- small utilities ---------------------------------------------------------

sl7_user() {
  printf '%s' "${SL7_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
}

# Reject anything that is not a plain account name before it reaches a path.
valid_user() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ $1 != root ]]
}

# howdy-next labels: at most 24 characters, no slash, backslash or control
# characters (its own rule, plus the 24-character interactive cap).
valid_label() {
  local label=$1
  [[ -n $label && ${#label} -le 24 ]] || return 1
  [[ $label != *[/\\]* ]] || return 1
  [[ $label != *[[:cntrl:]]* ]] || return 1
  return 0
}

timestamp() {
  date +%Y%m%dT%H%M%S
}

# Write stdin to $1 atomically: temp file in the same directory, then rename.
atomic_write() {
  local dest=$1 mode=${2:-0644} tmp
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] would write $dest"
    cat >/dev/null
    return 0
  fi
  tmp=$(mktemp "$dest.sl7.XXXXXX") || return 1
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp" && mv -f "$tmp" "$dest" || {
    rm -f "$tmp"
    return 1
  }
}

# Export the active Omarchy theme's gum colours when Omarchy is present.
omarchy_gum_env() {
  if command -v omarchy-restart-gum >/dev/null 2>&1; then
    # shellcheck disable=SC1091,SC1090
    source "$(command -v omarchy-restart-gum)" || true
  fi
}
