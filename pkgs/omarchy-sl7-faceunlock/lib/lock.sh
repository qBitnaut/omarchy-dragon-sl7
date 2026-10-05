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
LOCK_PRISTINE_SHA256=1144e7a896f971001276997595f24c0d471ddbf196aee09c83f4f5809b620326
LOCK_PATCH_MARK='sl7-faceunlock: PAM patch'

lock_plugin_dir() {
  printf '%s/%s' "${SL7_PLUGIN_DIR:-$HOME/.config/omarchy/plugins}" "$LOCK_ID"
}

lock_patch_file() {
  printf '%s/lock-patch/howdy-lock-pam.patch' "$SL7_LIB"
}

lock_installed() {
  [[ -f $(lock_plugin_dir)/Service.qml ]]
}

lock_patched() {
  lock_installed && grep -q "$LOCK_PATCH_MARK" "$(lock_plugin_dir)/Service.qml"
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

# Apply the overlay. Idempotent. On failure the stock lock is left in charge
# (the plugin stays or is made disabled) and the return code is non-zero.
lock_apply_patch() {
  local dir svc sum patch
  dir=$(lock_plugin_dir)
  svc=$dir/Service.qml
  patch=$(lock_patch_file)
  [[ -f $svc ]] || { err "$LOCK_ID is not installed"; return 1; }
  [[ -f $patch ]] || { err "patch file missing: $patch"; return 1; }
  if grep -q "$LOCK_PATCH_MARK" "$svc"; then
    ok "lock overlay already applied"
    return 0
  fi
  sum=$(sha256sum "$svc" | cut -d' ' -f1)
  [[ $sum == "$LOCK_PRISTINE_SHA256" ]] ||
    warn "Service.qml differs from the version the patch was written for (upstream changed?); trying anyway"
  if ! patch -p1 --dry-run -s -d "$dir" -i "$patch" >/dev/null 2>&1; then
    err "the overlay patch does not apply to this version of $LOCK_ID"
    warn "leaving the stock Omarchy lock screen in place"
    lock_disable_plugin
    return 1
  fi
  [[ $DRY_RUN == 1 ]] && {
    note "[dry-run] would patch $svc"
    return 0
  }
  [[ -e $svc.sl7-orig ]] || cp -p "$svc" "$svc.sl7-orig"
  if ! patch -p1 -s -d "$dir" -i "$patch" || ! grep -q "$LOCK_PATCH_MARK" "$svc"; then
    cp -p "$svc.sl7-orig" "$svc"
    err "patching failed; original restored"
    lock_disable_plugin
    return 1
  fi
  ok "lock overlay applied (face unlock now goes through PAM service omarchy-lock-face)"
}

# Back to upstream's Service.qml, ready to re-patch.
lock_restore_original() {
  local dir svc
  dir=$(lock_plugin_dir)
  svc=$dir/Service.qml
  if [[ -e $svc.sl7-orig ]]; then
    cp -p "$svc.sl7-orig" "$svc"
  elif git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$dir" checkout -- Service.qml
  fi
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
