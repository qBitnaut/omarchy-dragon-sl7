# shellcheck shell=bash
# omarchy-sl7-faceunlock: the Howdy Lock lock-screen plugin.
#
# nate.howdy-lock (https://github.com/nate8199/omarchy-plugin-howdy-face, MIT,
# (c) nate8199 and David Heinemeier Hansson) is a replacement of omarchy.lock
# with an "Unlock with face" button. Upstream calls howdy-git's compare.py as
# the user; howdy-next has no such file and keeps its models root-only. Our
# overlay patch (lock-patch/howdy-lock-pam.patch) swaps that one call for a
# PamContext on the dedicated PAM service omarchy-lock-face. The button, the
# on-demand camera and the attempt cap are nate8199's and stay as they were.

LOCK_ID=nate.howdy-lock
LOCK_URL=${SL7_LOCK_URL:-https://github.com/nate8199/omarchy-plugin-howdy-face.git}
LOCK_PIN=e5e5402
# sha256 of each patched file at LOCK_PIN, used to warn about drift.
LOCK_PRISTINE_SHA256=1144e7a896f971001276997595f24c0d471ddbf196aee09c83f4f5809b620326
LOCK_PRISTINE_LOCKVIEW_SHA256=d60d682b6972a179774096fba8ba3d9f3340ff8f1e9e48978ed32db556c5f69f

# sha256 of Omarchy's own stock lock plugin files (omarchy.lock) as shipped in the
# omarchy 4.5.0-3 package (pacman -Qkk clean), used to report drift of the stock lock
# the overlay is compared against. Informational only: nothing is edited because of it.
LOCK_STOCK_VERSION=4.5.0-3
LOCK_STOCK_SERVICE_SHA256=cf9da581ab749194d44d5f7f73dc028704373f59dd6b131a90b9c07419fed7c9
LOCK_STOCK_LOCKVIEW_SHA256=e5ec598e4dfafc0c6acb3ab8de1c3be810437ae943f6888fdcf1f92a6400876a

# The plugin files the overlay edits, with their pristine hashes ("file|sha256").
LOCK_FILES=(
  "Service.qml|$LOCK_PRISTINE_SHA256"
  "LockView.qml|$LOCK_PRISTINE_LOCKVIEW_SHA256"
)

# The overlay is an ordered list of patches, applied top to bottom, each one
# with the file it edits and the marker it leaves there ("patch|file|marker").
# A later patch is written against the file as the earlier ones leave it:
#   howdy-lock-pam.patch           face unlock through PAM service omarchy-lock-face
#   howdy-lock-state-sync.patch    stale `locked` after unlock (quickshell 0.3.2,
#                                  omacom/omarchy#14588)
#   howdy-lock-upstream-4.0.6.patch  Service.qml follows Omarchy 4.0.6 lock-state
#                                  logic (currentlyLocked(), stranded-lock
#                                  helper) and Commons.Color (Qt 6.12)
#   howdy-lock-view-4.0.6.patch    LockView.qml: Commons.Color, plain-text
#                                  status, key auto-repeat guard
LOCK_PATCHES=(
  'howdy-lock-pam.patch|Service.qml|sl7-faceunlock: PAM patch'
  'howdy-lock-state-sync.patch|Service.qml|sl7-faceunlock: lock-state sync'
  'howdy-lock-upstream-4.0.6.patch|Service.qml|sl7-faceunlock: upstream 4.0.6 sync'
  'howdy-lock-view-4.0.6.patch|LockView.qml|sl7-faceunlock: lock-view sync'
)

# Field accessors for a LOCK_PATCHES / LOCK_FILES entry.
lock_entry_patch() { printf '%s' "${1%%|*}"; }
lock_entry_file() { local r=${1#*|}; printf '%s' "${r%%|*}"; }
lock_entry_mark() { local r=${1#*|}; printf '%s' "${r#*|}"; }

lock_plugin_dir() {
  printf '%s/%s' "${SL7_PLUGIN_DIR:-$HOME/.config/omarchy/plugins}" "$LOCK_ID"
}

lock_installed() {
  [[ -f $(lock_plugin_dir)/Service.qml ]]
}

# Is the patch entry $1 present in the file it edits?
lock_patch_applied() {
  local f
  f=$(lock_plugin_dir)/$(lock_entry_file "$1")
  lock_installed && [[ -f $f ]] && grep -qF -- "$(lock_entry_mark "$1")" "$f"
}

# Every patch of the overlay is in.
lock_patched() {
  local entry
  for entry in "${LOCK_PATCHES[@]}"; do
    lock_patch_applied "$entry" || return 1
  done
}

# One line per patch: applied or missing.
lock_patch_lines() {
  local entry
  for entry in "${LOCK_PATCHES[@]}"; do
    if lock_patch_applied "$entry"; then
      say "patch $(lock_entry_patch "$entry"): applied"
    else
      say "patch $(lock_entry_patch "$entry"): missing"
    fi
  done
}

lock_status() {
  say "installed=$(lock_installed && echo yes || echo no) patched=$(lock_patched && echo yes || echo no) state=$(lock_enabled_state)"
  lock_patch_lines
  say "stock-lock=$(lock_stock_state)"
  say "patchset=$(lock_patchset_version) applied-patchset=$(lock_recorded_patchset)"
}

# Compare Omarchy's stock lock files with the 4.5.0-3 hashes:
# "matches omarchy X", "differs from omarchy X (stock lock changed; recheck the overlay)",
# or "absent" when there is no stock lock plugin.
lock_stock_state() {
  local dir=${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/lock svc lv
  [[ -f $dir/Service.qml && -f $dir/LockView.qml ]] || { printf 'absent'; return; }
  svc=$(sha256sum "$dir/Service.qml" | cut -d' ' -f1)
  lv=$(sha256sum "$dir/LockView.qml" | cut -d' ' -f1)
  if [[ $svc == "$LOCK_STOCK_SERVICE_SHA256" && $lv == "$LOCK_STOCK_LOCKVIEW_SHA256" ]]; then
    printf 'matches omarchy %s' "$LOCK_STOCK_VERSION"
  else
    printf 'differs from omarchy %s (stock lock changed; recheck the overlay)' "$LOCK_STOCK_VERSION"
  fi
}

# Changes whenever any patch file changes, so an upgrade that edits a patch is
# noticed without anyone remembering to bump a number.
lock_patchset_version() {
  local entry
  for entry in "${LOCK_PATCHES[@]}"; do
    cat -- "$SL7_LIB/lock-patch/$(lock_entry_patch "$entry")" 2>/dev/null
  done | sha256sum | cut -c1-16
}

lock_patchset_file() {
  printf '%s/omarchy-sl7-faceunlock/lock-patchset' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

lock_recorded_patchset() {
  local f
  f=$(lock_patchset_file)
  if [[ -f $f ]]; then cat -- "$f"; else printf 'none'; fi
}

lock_record_patchset() {
  local f
  [[ $DRY_RUN == 1 ]] && return 0
  f=$(lock_patchset_file)
  mkdir -p -- "${f%/*}" && lock_patchset_version >"$f" 2>/dev/null || true
}

# enabled | disabled | absent
lock_enabled_state() {
  local json
  lock_installed || { printf 'absent'; return; }
  command -v omarchy-plugin-list >/dev/null 2>&1 || { printf 'unknown'; return; }
  json=$(omarchy-plugin-list --json 2>/dev/null) || { printf 'unknown'; return; }
  if jq -e --arg id "$LOCK_ID" 'any(.[]; .id == $id and .enabled)' >/dev/null 2>&1 <<<"$json"; then
    printf 'enabled'
  else
    printf 'disabled'
  fi
}

lock_disable_plugin() {
  command -v omarchy-plugin-disable >/dev/null 2>&1 || return 0
  omarchy-plugin-disable "$LOCK_ID" >/dev/null 2>&1 || true
}

# Apply the overlay: every patch, in order, the ones already in skipped.
# Idempotent. The patches are tried on a scratch copy of every patched file
# first and the results are swapped in atomically, so no file is ever half
# patched. On failure the stock lock is left in charge (the plugin stays or is
# made disabled) and the return code is non-zero.
lock_apply_patch() {
  local dir work entry fentry file mark patch sum target pristine marked
  local -a touched=()
  dir=$(lock_plugin_dir)
  for fentry in "${LOCK_FILES[@]}"; do
    file=$(lock_entry_patch "$fentry")
    [[ -f $dir/$file ]] || { err "$LOCK_ID is not installed (no $file)"; return 1; }
  done
  for entry in "${LOCK_PATCHES[@]}"; do
    patch=$(lock_entry_patch "$entry")
    [[ -f $SL7_LIB/lock-patch/$patch ]] || { err "patch file missing: $SL7_LIB/lock-patch/$patch"; return 1; }
  done
  if lock_patched; then
    ok "lock overlay already applied (${#LOCK_PATCHES[@]} patches)"
    lock_record_patchset
    return 0
  fi
  # A file none of whose patches is in yet is still upstream's: check its hash
  # and keep a pristine backup of it.
  work=$(mktemp -d) || { err "cannot create a scratch directory"; return 1; }
  for fentry in "${LOCK_FILES[@]}"; do
    file=$(lock_entry_patch "$fentry")
    pristine=${fentry#*|}
    marked=0
    for entry in "${LOCK_PATCHES[@]}"; do
      [[ $(lock_entry_file "$entry") == "$file" ]] && lock_patch_applied "$entry" && marked=1
    done
    if ((marked == 0)); then
      touched+=("$file")
      sum=$(sha256sum "$dir/$file" | cut -d' ' -f1)
      [[ $sum == "$pristine" ]] ||
        warn "$file differs from the version the patches were written for (upstream changed?); trying anyway"
    fi
    cp -p "$dir/$file" "$work/$file"
  done

  for entry in "${LOCK_PATCHES[@]}"; do
    patch=$(lock_entry_patch "$entry")
    target=$(lock_entry_file "$entry")
    mark=$(lock_entry_mark "$entry")
    if grep -qF -- "$mark" "$work/$target"; then
      note "$patch already applied"
      continue
    fi
    if ! patch -p1 --dry-run -s -d "$work" -i "$SL7_LIB/lock-patch/$patch" >/dev/null 2>&1 ||
      ! patch -p1 -s -d "$work" -i "$SL7_LIB/lock-patch/$patch" >/dev/null 2>&1 ||
      ! grep -qF -- "$mark" "$work/$target"; then
      rm -rf -- "$work"
      err "the overlay patch $patch does not apply to this version of $LOCK_ID"
      warn "leaving the stock Omarchy lock screen in place"
      lock_disable_plugin
      return 1
    fi
    note "$patch applies"
  done
  if [[ $DRY_RUN == 1 ]]; then
    rm -rf -- "$work"
    note "[dry-run] would patch $dir"
    return 0
  fi
  mkdir -p -- "$work/orig"
  for file in "${touched[@]}"; do
    [[ -e $dir/$file.sl7-orig ]] || cp -p "$dir/$file" "$dir/$file.sl7-orig"
  done
  for fentry in "${LOCK_FILES[@]}"; do
    file=$(lock_entry_patch "$fentry")
    cp -p "$dir/$file" "$work/orig/$file"
  done
  for fentry in "${LOCK_FILES[@]}"; do
    file=$(lock_entry_patch "$fentry")
    if ! cp -p "$work/$file" "$dir/$file.sl7-new" || ! mv -f "$dir/$file.sl7-new" "$dir/$file"; then
      lock_swap_failed "$dir" "$work"
      return 1
    fi
  done
  if ! lock_patched; then
    lock_swap_failed "$dir" "$work"
    return 1
  fi
  rm -rf -- "$work"
  lock_record_patchset
  ok "lock overlay applied (${#LOCK_PATCHES[@]} patches; face unlock goes through PAM service omarchy-lock-face)"
}

# Put every patched file back as it was before the swap.
lock_swap_failed() {
  local dir=$1 work=$2 fentry file
  for fentry in "${LOCK_FILES[@]}"; do
    file=$(lock_entry_patch "$fentry")
    cp -p "$work/orig/$file" "$dir/$file"
    rm -f -- "$dir/$file.sl7-new"
  done
  rm -rf -- "$work"
  err "patching failed; previous files restored"
  lock_disable_plugin
}

# Back to upstream's files, ready to re-patch.
lock_restore_original() {
  local dir fentry file
  dir=$(lock_plugin_dir)
  for fentry in "${LOCK_FILES[@]}"; do
    file=$(lock_entry_patch "$fentry")
    if [[ -e $dir/$file.sl7-orig ]]; then
      cp -p "$dir/$file.sl7-orig" "$dir/$file"
    elif git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "$dir" checkout -- "$file"
    fi
  done
}

lock_install() {
  local dir head
  dir=$(lock_plugin_dir)
  command -v omarchy >/dev/null 2>&1 || { err "the omarchy command is not available"; return 1; }
  if ! lock_installed; then
    [[ $DRY_RUN == 1 ]] && {
      note "[dry-run] omarchy plugin add $LOCK_URL --yes"
      return 0
    }
    omarchy plugin add "$LOCK_URL" --yes || { err "omarchy plugin add failed"; return 1; }
  fi
  lock_installed || { err "plugin did not land in $dir"; return 1; }

  # Pin the audited commit; the overlay is written against it.
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    head=$(git -C "$dir" rev-parse HEAD)
    if [[ $head != "$LOCK_PIN"* ]]; then
      lock_restore_original
      git -C "$dir" -c advice.detachedHead=false checkout -q "$LOCK_PIN" 2>/dev/null ||
        warn "could not check out pinned commit $LOCK_PIN; patch may not apply"
    fi
  fi

  # Patch before enabling, so the stock lock is never replaced by an unpatched
  # fork that still wants howdy-git's compare.py.
  lock_apply_patch || return 1
  omarchy plugin enable "$LOCK_ID" || { err "omarchy plugin enable failed"; return 1; }
  ok "$LOCK_ID enabled"
  note "Do not run the plugin's own setup.sh: it installs howdy-git and python-dlib."
}

# After an Omarchy or plugin upgrade: restore upstream's file and re-apply.
lock_reapply() {
  lock_installed || { err "$LOCK_ID is not installed"; return 1; }
  lock_restore_original
  lock_apply_patch
}

# Update the plugin from upstream, then re-apply the overlay.
lock_update() {
  lock_installed || { err "$LOCK_ID is not installed"; return 1; }
  lock_restore_original
  omarchy plugin update "$LOCK_ID" || { err "omarchy plugin update failed"; return 1; }
  lock_apply_patch
}

lock_remove() {
  lock_installed || { say "$LOCK_ID is not installed"; return 0; }
  omarchy plugin remove "$LOCK_ID" || { err "omarchy plugin remove failed"; return 1; }
  ok "$LOCK_ID removed; the stock Omarchy lock screen is back"
}

# Is a session lock in force right now? Reads the live fields of
# `omarchy-shell lock status` (not the cached "locked", which the plugin now
# derives the way upstream 4.0.6 does). 0 = locked or cannot tell, 1 = certainly not locked.
# When the shell is not running there is no lock of ours to disturb.
lock_session_locked() {
  local json
  command -v omarchy-shell >/dev/null 2>&1 || return 1
  json=$(omarchy-shell lock status 2>/dev/null) || return 1
  jq -e '.requested or .sessionLocked or .secure' >/dev/null 2>&1 <<<"$json"
  case $? in
  0) return 0 ;;
  1) return 1 ;;
  *) return 0 ;; # unparsable answer from a running shell: stay out
  esac
}

# Is the session locked, as far as the compositor and the session manager can tell?
# 0 = locked or cannot tell (leave it alone), 1 = certainly not locked.
# omarchy-hyprland-session-locked exits 0 locked, 1 unlocked, 2 undetermined; 0 and 2 both
# mean leave alone. logind LockedHint is only a secondary signal (the shell may not set it).
lock_hint_locked() {
  local rc hint
  if command -v omarchy-hyprland-session-locked >/dev/null 2>&1; then
    omarchy-hyprland-session-locked >/dev/null 2>&1
    rc=$?
    [[ $rc == 1 ]] || return 0
  fi
  command -v loginctl >/dev/null 2>&1 || return 1
  hint=$(loginctl show-session "${XDG_SESSION_ID:-auto}" -p LockedHint --value 2>/dev/null) || return 0
  [[ $hint == no ]] && return 1
  [[ $hint == yes ]] && return 0
  # no readable hint: the compositor said unlocked, trust it
  command -v omarchy-hyprland-session-locked >/dev/null 2>&1 && return 1
  return 0
}

# One probe of the lock plugin IPC. 0 = the plugin is certainly gone: the shell answered
# "Target not found." or "Function not found.". Anything else (answered, timed out, shell
# not ready, not running) is inconclusive and returns 1.
lock_ipc_dead() {
  local err
  err=$(OMARCHY_SHELL_IPC_TIMEOUT=5s timeout 7 omarchy-shell lock status 2>&1 >/dev/null) && return 1
  grep -qE '^(Target not found|Function not found)\.$' <<<"$err"
}

# Wait until the shell answers a ping: every SL7_LOCK_SHELL_POLL s (3) up to
# SL7_LOCK_SHELL_MAX s (90). 0 = it answers.
lock_wait_shell() {
  local poll=${SL7_LOCK_SHELL_POLL:-3} max=${SL7_LOCK_SHELL_MAX:-90} t=0
  until timeout 3 omarchy-shell shell ping >/dev/null 2>&1; do
    (( t >= max )) && return 1
    sleep "$poll"
    t=$((t + poll))
  done
}

# Health check of the enabled lock plugin. The login hook can run before the shell is up, so
# it first waits for the shell (ping) and for the plugin scan to finish (lock_enabled_state is
# not "unknown"). Then the plugin's IPC (lock status) must be dead (the shell says Target or
# Function not found) on three probes, SL7_LOCK_HEALTH_WAIT (10) s apart; any other outcome
# is inconclusive and leaves everything alone. Then disable it (the stock lock screen
# returns) and notify. Never acts while locked or possibly locked. Every early return logs
# why. Returns 1 only when it disabled the plugin.
lock_health_check() {
  local wait=${SL7_LOCK_HEALTH_WAIT:-10} poll=${SL7_LOCK_SHELL_POLL:-3} max=${SL7_LOCK_SHELL_MAX:-90}
  local state i t=0 body
  command -v omarchy-shell >/dev/null 2>&1 || { note "health check: omarchy-shell not found; skipping"; return 0; }
  lock_wait_shell || { note "health check: the shell did not answer within ${max}s; skipping"; return 0; }
  state=$(lock_enabled_state)
  while [[ $state == unknown ]]; do
    if (( t >= max )); then
      note "health check: plugin list not readable within ${max}s; skipping"
      return 0
    fi
    sleep "$poll"
    t=$((t + poll))
    state=$(lock_enabled_state)
  done
  [[ $state == enabled ]] || { note "health check: $LOCK_ID is $state; nothing to check"; return 0; }
  for i in 1 2 3; do
    lock_ipc_dead || { note "health check: lock IPC is not confirmed dead (probe $i); leaving it alone"; return 0; }
    (( i < 3 )) && sleep "$wait"
  done
  if lock_hint_locked; then
    note "health check: lock plugin IPC is dead, but the session is (or may be) locked; leaving it alone"
    return 0
  fi
  warn "$LOCK_ID IPC is gone while the shell is up; disabling it so the stock lock screen returns"
  lock_disable_plugin
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
  if [[ $(lock_enabled_state) == disabled ]]; then
    body='Its lock plugin did not answer; the stock Omarchy lock screen is back. Run: omarchy-sl7-faceunlock lock status'
    note "health check: $LOCK_ID disabled"
  else
    body='Its lock plugin did not answer and could not be disabled. Run: omarchy-sl7-faceunlock lock status / omarchy plugin disable nate.howdy-lock'
    warn "health check: could not disable $LOCK_ID"
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -a 'Face Unlock' 'Face Unlock lock screen problem' "$body" >/dev/null 2>&1 || true
  fi
  return 1
}

# Login-time hook (omarchy-sl7-faceunlock-lock.service): when the shipped patch
# set differs from the one last applied, re-apply it. Never edits while the
# screen is locked and never touches Omarchy's own files.
lock_auto_reapply() {
  local cur
  export OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
  PATH=$PATH:$OMARCHY_PATH/bin
  lock_installed || return 0
  lock_health_check || return 0
  cur=$(lock_patchset_version)
  if [[ $(lock_recorded_patchset) == "$cur" ]] && lock_patched; then
    return 0
  fi
  if lock_session_locked; then
    note "screen is locked (or the shell is not answering); the overlay is re-applied at the next login"
    return 0
  fi
  lock_reapply || return 1
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a 'Face Unlock' 'Lock screen overlay updated' 'Run omarchy-restart-shell (while unlocked) to load it.' >/dev/null 2>&1 || true
  fi
}
