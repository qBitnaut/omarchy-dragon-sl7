# shellcheck shell=bash
# omarchy-sl7-faceunlock: howdy-next access. Two halves.
#   user-level: read state, call the privileged helper
#   root-level: functions the helper runs (faces, config, snapshot)

# --- user-level ---------------------------------------------------------------

howdy_installed() {
  command -v "$HOWDY_BIN" >/dev/null 2>&1 && [[ -e $PAM_MODULE ]]
}

howdy_version() {
  "$HOWDY_BIN" version 2>/dev/null | head -n1
}

# active | inactive | missing
bridge_state() {
  local out
  if ! systemctl cat "$BRIDGE_UNIT" >/dev/null 2>&1; then
    printf 'missing'
    return
  fi
  out=$(systemctl is-active "$BRIDGE_UNIT" 2>/dev/null)
  printf '%s' "${out:-inactive}"
}

# missing | unreadable | ok. The lock screen runs PAM in the user's own
# process, so the user (not just root) must be able to open the node.
camera_state() {
  if [[ ! -e $CAMERA ]]; then
    printf 'missing'
  elif [[ ! -r $CAMERA || ! -w $CAMERA ]]; then
    printf 'unreadable'
  else
    printf 'ok'
  fi
}

# The emitter is not available yet. Later the bridge sets the sensor's
# led_mode before it streams; this app never drives the emitter itself.
emitter_state() {
  printf 'unavailable'
}

# closed | open | unknown
lid_state() {
  local gate=$LID_GATE
  [[ -x $gate ]] || gate=${SL7_LIB:-/usr/lib/sl7-faceunlock}/lid-closed
  if "$gate"; then
    printf 'closed'
  elif [[ -n ${SL7_LID_STATE:-} ]] || busctl --system get-property org.freedesktop.login1 \
    /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed >/dev/null 2>&1; then
    printf 'open'
  else
    printf 'unknown'
  fi
}

# Root-written snapshots, readable by the user (models themselves are not).
snapshot_file() {
  printf '%s/state-%s.json' "$STATE_DIR" "$(sl7_user)"
}

faces_count_cached() {
  local f
  f=$(snapshot_file)
  if [[ -r $f ]]; then
    jq -r '.faces | length' "$f" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

# Run the privileged helper. Plain sudo (face allowed): for tightening actions
# such as disabling a stack. Under SL7_ASSUME_ROOT (tests, and --dry-run) the
# helper runs directly with no sudo.
sl7_priv() {
  local -a flags=()
  [[ $DRY_RUN == 1 ]] && flags=(--dry-run)
  if sl7_is_root || [[ ${SL7_ASSUME_ROOT:-0} == 1 ]]; then
    "$SL7_HELPER" "${flags[@]}" "$@"
  elif [[ $DRY_RUN == 1 ]]; then
    SL7_ASSUME_ROOT=1 "$SL7_HELPER" "${flags[@]}" "$@"
  else
    sudo "$SL7_HELPER" "$@"
  fi
}

SL7_PW_AT=-1000

# Password-only sudo: for actions that add trust (enrol, remove, configure,
# enable a stack). Drops any cached timestamp, then runs sudo with an
# SSH_CONNECTION marker in sudo's own environment. pam_howdy honours
# core.abort_if_ssh (the wizard sets it true) and skips itself, so sudo has to
# ask for the password. Fingerprint, if set up, is still accepted. A password
# typed less than two minutes ago is reused, so the wizard asks once.
sl7_priv_pw() {
  local rc
  if sl7_is_root || [[ ${SL7_ASSUME_ROOT:-0} == 1 ]] || [[ $DRY_RUN == 1 ]]; then
    sl7_priv "$@"
    return
  fi
  if ((SECONDS - SL7_PW_AT > 120)); then
    sudo -k
  fi
  SSH_CONNECTION="sl7-faceunlock password-only" \
    sudo -p "[sudo] password for %u (face unlock is bypassed for this step): " "$SL7_HELPER" "$@"
  rc=$?
  ((rc == 0)) && SL7_PW_AT=$SECONDS
  return "$rc"
}

# --- root-level ---------------------------------------------------------------

# Read one key from config.ini (first match, any section).
cfg_get() {
  awk -F= -v k="$1" '
    /^[[:space:]]*[#;]/ { next }
    { key = $1; gsub(/[[:space:]]/, "", key) }
    key == k { v = $2; sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit }' "$HOWDY_CONFIG"
}

# howdy list --plain -> JSON array of {id,time,label}. CSV: id,time,label with
# the label quoted when it contains commas or quotes.
faces_json_for() {
  local user=$1 line id rest time label
  local -a rows=()
  while IFS= read -r line; do
    [[ $line =~ ^[0-9]+, ]] || continue
    id=${line%%,*}
    rest=${line#*,}
    time=${rest%%,*}
    label=${rest#*,}
    if [[ $label == \"*\" ]]; then
      label=${label:1:${#label}-2}
      label=${label//\"\"/\"}
    fi
    rows+=("$(jq -cn --argjson id "$id" --arg time "$time" --arg label "$label" \
      '{id: $id, time: $time, label: $label}')")
  done < <("$HOWDY_BIN" list --plain -U "$user" 2>/dev/null)
  if ((${#rows[@]} == 0)); then
    printf '[]'
  else
    printf '%s\n' "${rows[@]}" | jq -cs '.'
  fi
}

# Refresh the world-readable snapshot and the enrolled marker the lock screen
# checks. Models stay root-only; labels and counts are not secret.
sync_snapshot() {
  local user=$1 faces count
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p "$STATE_DIR" || return 1
  chmod 0755 "$STATE_DIR"
  faces=$(faces_json_for "$user")
  count=$(jq -r 'length' <<<"$faces")
  jq -n --argjson faces "$faces" \
    --arg device "$(cfg_get device_path)" \
    --arg dark "$(cfg_get dark_threshold)" \
    --arg timeout "$(cfg_get timeout)" \
    --arg disabled "$(cfg_get disabled)" \
    --arg at "$(date -Is)" \
    '{faces: $faces, device_path: $device, dark_threshold: $dark, timeout: $timeout, disabled: $disabled, synced: $at}' |
    atomic_write "$STATE_DIR/state-$user.json" 0644
  if ((count > 0)); then
    printf '%s\n' "$count" | atomic_write "$STATE_DIR/enrolled-$user" 0644
  else
    rm -f "$STATE_DIR/enrolled-$user"
  fi
}

howdy_set() {
  local key=$1 value=$2
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] howdy set $key $value"
    return 0
  fi
  "$HOWDY_BIN" set "$key" "$value" >/dev/null || {
    err "howdy set $key failed"
    return 1
  }
}

valid_device() {
  [[ $1 =~ ^/dev/(video[0-9]+|v4l/by-(id|path)/[A-Za-z0-9._:+-]+)$ ]]
}

valid_number() {
  [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# configure DEVICE DARK TIMEOUT
howdy_configure() {
  local device=$1 dark=$2 timeout=$3
  valid_device "$device" || {
    err "device_path must be /dev/video*, /dev/v4l/by-id/* or /dev/v4l/by-path/*"
    return 1
  }
  valid_number "$dark" && awk -v d="$dark" 'BEGIN { exit (d >= 0 && d <= 99.9) ? 0 : 1 }' || {
    err "dark_threshold must be between 0 and 99.9"
    return 1
  }
  # A scan must never stream longer than 5 s: cap howdy's timeout at 4.
  valid_number "$timeout" && awk -v t="$timeout" 'BEGIN { exit (t >= 1 && t <= 4) ? 0 : 1 }' || {
    err "timeout must be between 1 and 4 seconds"
    return 1
  }
  howdy_set device_path "$device" &&
    howdy_set dark_threshold "$dark" &&
    howdy_set timeout "$timeout" &&
    howdy_set abort_if_ssh true &&
    howdy_set disabled false
}

faces_add() {
  local user=$1 label=$2
  valid_user "$user" || { err "invalid user: $user"; return 1; }
  valid_label "$label" || { err "invalid label (1-24 characters, no / or \\)"; return 1; }
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] howdy add --plain -U $user '$label'"
    return 0
  fi
  "$HOWDY_BIN" add --plain -U "$user" "$label" || return 1
  sync_snapshot "$user"
}

faces_remove() {
  local user=$1 id=$2
  valid_user "$user" || { err "invalid user: $user"; return 1; }
  [[ $id =~ ^[0-9]+$ ]] || { err "invalid face id: $id"; return 1; }
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] howdy remove -y -U $user $id"
    return 0
  fi
  "$HOWDY_BIN" remove -y -U "$user" "$id" || return 1
  sync_snapshot "$user"
}

faces_clear() {
  local user=$1
  valid_user "$user" || { err "invalid user: $user"; return 1; }
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] howdy clear -y -U $user"
    return 0
  fi
  "$HOWDY_BIN" clear -y -U "$user" || return 1
  sync_snapshot "$user"
}

howdy_disable() {
  [[ $1 == 0 || $1 == 1 ]] || { err "disable takes 0 or 1"; return 1; }
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] howdy disable $1"
    return 0
  fi
  "$HOWDY_BIN" disable "$1"
}
