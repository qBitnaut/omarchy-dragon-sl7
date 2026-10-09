# shellcheck shell=bash
# omarchy-sl7-faceunlock: PAM stack editing. Sourced by the root helper.
#
# Rules (research section 6):
#   - only `sufficient`, placed above the first `auth` line of the stack, so it
#     sits above `include system-auth` (pam_unix and faillock);
#   - one stack at a time, each with its own backup and idempotent markers;
#   - a lid gate (logind) in front of pam_howdy;
#   - the file is validated before and after the rename, and rolled back when
#     either check fails.
#
# Every block also carries pam_faillock lines (see pam_block); sudo and polkit
# are opt-in because any process running as the user can reach the camera.
#
# Stacks: sudo (/etc/pam.d/sudo), polkit (/etc/pam.d/polkit-1, copied from the
# vendor file when absent) and lock (/etc/pam.d/omarchy-lock-face, ours alone).
# Login, SDDM, su and sshd are never touched.

pam_file_for() {
  case $1 in
  sudo) printf 'sudo' ;;
  polkit) printf 'polkit-1' ;;
  lock) printf 'omarchy-lock-face' ;;
  *) return 1 ;;
  esac
}

# The block we own, for one stack.
#
# Lockout (pam_faillock), so face attempts count toward the same lockout as
# password attempts:
#   gate      lid closed: skip the whole block (success=4 jumps over four lines)
#   preauth   a locked-out account stops here (auth_err=die: no password
#             fallback while locked); a faillock fault is ignored, never fatal
#   howdy     match: skip authfail, reach authsucc (success=1); no match
#             (auth_err) records a failure; anything else (module skipped,
#             camera unavailable, abort_if_ssh) jumps over both (default=2)
#   authfail  records the failure and falls through to the password stack
#             ([default=1] hops over authsucc; the password prompt still works)
#   authsucc  resets the failure record and ends the stack, as `sufficient`
#             pam_howdy.so did before
pam_block() {
  local stack=$1 howdy
  case $stack in
  sudo) howdy="pam_howdy.so workaround=native" ;;
  *) howdy="pam_howdy.so" ;;
  esac
  printf '%s\n' "$SL7_BEGIN"
  printf '%s\n' "auth      [success=4 default=ignore] pam_exec.so quiet $LID_GATE"
  printf '%s\n' "auth      [success=ok auth_err=die default=ignore] pam_faillock.so preauth"
  printf '%s\n' "auth      [success=1 auth_err=ok default=2] $howdy"
  printf '%s\n' "auth      [default=1] pam_faillock.so authfail"
  printf '%s\n' "auth      sufficient pam_faillock.so authsucc"
  if [[ $stack == lock ]]; then
    printf '%s\n' "auth      required pam_deny.so"
    printf '%s\n' "account   include system-local-login"
  fi
  printf '%s\n' "$SL7_END"
}

# 0 when the block in $1 carries the lockout lines.
pam_has_faillock() {
  grep -q '^[^#]*pam_faillock\.so preauth' "$1" 2>/dev/null
}

# stdin -> stdout without our block.
pam_strip() {
  awk -v b="# sl7-faceunlock BEGIN" -v e="# sl7-faceunlock END" '
    index($0, b) == 1 { skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { print }'
}

# stdin -> stdout, only our block.
pam_extract() {
  awk -v b="# sl7-faceunlock BEGIN" -v e="# sl7-faceunlock END" '
    index($0, b) == 1 { on = 1 }
    on { print }
    on && index($0, e) == 1 { on = 0 }'
}

# stdin = base, $1 = block file. Insert the block above the first auth line.
pam_insert() {
  awk -v blockfile="$1" '
    BEGIN { while ((getline line < blockfile) > 0) block = block line "\n" }
    !done && /^[[:space:]]*auth[[:space:]]/ { printf "%s", block; done = 1 }
    { print }
    END { exit done ? 0 : 1 }'
}

# 0 when the file has zero or one balanced block.
pam_markers_ok() {
  local begins ends
  begins=$(grep -c '^# sl7-faceunlock BEGIN' "$1")
  ends=$(grep -c '^# sl7-faceunlock END' "$1")
  [[ $begins == "$ends" && $begins -le 1 ]] || return 1
  if [[ $begins == 1 ]]; then
    awk '/^# sl7-faceunlock BEGIN/ { b = NR } /^# sl7-faceunlock END/ { e = NR } END { exit (b < e) ? 0 : 1 }' "$1"
  fi
}

# Print enabled, disabled or foreign for a stack. Foreign means pam_howdy is
# already present without our markers: we will not stack a second line on it.
pam_state() {
  local file target
  file=$(pam_file_for "$1") || return 1
  target=$PAM_DIR/$file
  if [[ ! -e $target ]]; then
    printf 'disabled'
  elif grep -q '^# sl7-faceunlock BEGIN' "$target"; then
    printf 'enabled'
  elif grep -q '^[^#]*pam_howdy\.so' "$target"; then
    printf 'foreign'
  elif [[ $1 == lock ]]; then
    printf 'foreign'
  else
    printf 'disabled'
  fi
}

# Checks shared by the pre-install and post-install passes.
# $1 = candidate file, $2 = base file (what the file looked like without us).
pam_validate() {
  local cand=$1 base=$2 stack=$3 gate_line howdy_line anchor_line
  pam_markers_ok "$cand" || {
    err "markers unbalanced in candidate"
    return 1
  }
  [[ $(grep -c '^# sl7-faceunlock BEGIN' "$cand") == 1 ]] || {
    err "expected exactly one sl7-faceunlock block"
    return 1
  }
  pam_strip <"$cand" | cmp -s - "$base" || {
    err "candidate differs from the original outside our block"
    return 1
  }
  [[ $(grep -c '^[^#]*pam_howdy\.so' "$cand") == 1 ]] || {
    err "expected exactly one pam_howdy.so line"
    return 1
  }
  gate_line=$(grep -n '^[^#]*lid-closed' "$cand" | head -n1 | cut -d: -f1)
  howdy_line=$(grep -n '^[^#]*pam_howdy\.so' "$cand" | head -n1 | cut -d: -f1)
  [[ -n $gate_line && -n $howdy_line && $gate_line -lt $howdy_line ]] || {
    err "lid gate must precede pam_howdy.so"
    return 1
  }
  local pre_line fail_line succ_line
  pre_line=$(grep -n '^[^#]*pam_faillock\.so preauth' "$cand" | head -n1 | cut -d: -f1)
  fail_line=$(grep -n '^[^#]*pam_faillock\.so authfail' "$cand" | head -n1 | cut -d: -f1)
  succ_line=$(grep -n '^[^#]*pam_faillock\.so authsucc' "$cand" | head -n1 | cut -d: -f1)
  [[ -n $pre_line && -n $fail_line && -n $succ_line ]] || {
    err "pam_faillock preauth/authfail/authsucc lines are missing"
    return 1
  }
  [[ $gate_line -lt $pre_line && $pre_line -lt $howdy_line && $howdy_line -lt $fail_line && $fail_line -lt $succ_line ]] || {
    err "block order must be: lid gate, faillock preauth, pam_howdy.so, authfail, authsucc"
    return 1
  }
  if [[ $stack != lock ]]; then
    # Our line must sit above the first line that can authenticate with a
    # password (include system-auth, pam_unix).
    anchor_line=$(grep -n -E '^[[:space:]]*auth[[:space:]].*(system-auth|pam_unix\.so)' "$cand" | head -n1 | cut -d: -f1)
    if [[ -n $anchor_line && $howdy_line -gt $anchor_line ]]; then
      err "pam_howdy.so would sit below the password stack"
      return 1
    fi
  fi
  return 0
}

# Install $1 over $2 atomically, preserving root:root 0644.
pam_install() {
  local src=$1 dest=$2 tmp
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] would install $dest"
    return 0
  fi
  tmp=$(mktemp "$dest.sl7.XXXXXX") || return 1
  if ! cp "$src" "$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
}

pam_backup_dir() {
  printf '%s/backups' "$STATE_DIR"
}

pam_created_marker() {
  printf '%s/created/%s' "$STATE_DIR" "$1"
}

# Restore the pre-edit state. $1 = target, $2 = backup file or empty (absent).
pam_rollback() {
  local target=$1 prev=$2
  [[ $DRY_RUN == 1 ]] && return 0
  if [[ -n $prev && -e $prev ]]; then
    cp "$prev" "$target.sl7.rb" && mv -f "$target.sl7.rb" "$target"
  else
    rm -f "$target"
  fi
  err "rolled back $target"
  audit "rollback $target"
}

polkit_dropin_ensure() {
  local dest=$DROPIN_DIR/$DROPIN_NAME
  if [[ -e $DROPIN_VENDOR ]]; then
    note "polkit helper sandbox: using the howdy-next drop-in ($DROPIN_VENDOR)"
    return 0
  fi
  [[ -e $dest ]] && return 0
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] would write $dest"
    return 0
  fi
  mkdir -p "$DROPIN_DIR" "$STATE_DIR/created" || return 1
  atomic_write "$dest" 0644 <<'EOF' || return 1
# Written by omarchy-sl7-faceunlock: let polkit-agent-helper reach the camera.
[Service]
PrivateDevices=no
DeviceAllow=char-video4linux rw
EOF
  : >"$(pam_created_marker polkit-dropin)"
  if [[ -z ${SL7_NO_SYSTEMCTL:-} ]]; then
    systemctl daemon-reload || warn "systemctl daemon-reload failed"
  fi
  ok "polkit helper sandbox drop-in written ($dest)"
}

polkit_dropin_remove() {
  local marker dest=$DROPIN_DIR/$DROPIN_NAME
  marker=$(pam_created_marker polkit-dropin)
  [[ -e $marker ]] || return 0
  [[ $DRY_RUN == 1 ]] && {
    note "[dry-run] would remove $dest"
    return 0
  }
  rm -f "$dest" "$marker"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  if [[ -z ${SL7_NO_SYSTEMCTL:-} ]]; then
    systemctl daemon-reload || true
  fi
  ok "polkit helper sandbox drop-in removed"
}

pam_enable() {
  local stack=$1 file target bdir work base new prev="" created=0 state ts
  file=$(pam_file_for "$stack") || {
    err "unknown stack: $stack (sudo, polkit or lock)"
    return 2
  }
  target=$PAM_DIR/$file
  bdir=$(pam_backup_dir)

  [[ -e $PAM_MODULE ]] || {
    err "pam_howdy.so not found at $PAM_MODULE: refusing to write a stack line"
    return 1
  }
  [[ -e $FAILLOCK_MODULE ]] || {
    err "pam_faillock.so not found at $FAILLOCK_MODULE: refusing to write a stack without lockout"
    return 1
  }
  [[ -x $LID_GATE ]] || {
    err "lid gate $LID_GATE is missing or not executable"
    return 1
  }

  state=$(pam_state "$stack")
  if [[ $state == foreign ]]; then
    err "$target already has a pam_howdy.so line that is not ours: leaving it alone"
    return 1
  fi

  work=$(mktemp -d) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  base=$work/base
  new=$work/new

  if [[ -e $target ]]; then
    pam_markers_ok "$target" || {
      err "$target has unbalanced sl7-faceunlock markers: fix by hand"
      return 1
    }
    pam_strip <"$target" >"$base"
  else
    created=1
    case $stack in
    sudo)
      err "$target does not exist: the sudo package should provide it"
      return 1
      ;;
    polkit)
      [[ -r $VENDOR_PAM_DIR/polkit-1 ]] || {
        err "neither $target nor $VENDOR_PAM_DIR/polkit-1 exists"
        return 1
      }
      cp "$VENDOR_PAM_DIR/polkit-1" "$base"
      ;;
    lock) printf '#%%PAM-1.0\n' >"$base" ;;
    esac
  fi

  if [[ $stack == lock ]]; then
    { cat "$base"; pam_block "$stack"; } >"$new"
  else
    pam_block "$stack" >"$work/block"
    pam_insert "$work/block" <"$base" >"$new" || {
      err "no auth line found in $target: refusing to guess where to insert"
      return 1
    }
  fi

  if [[ $state == enabled ]] && cmp -s "$target" "$new"; then
    ok "$stack: already enabled (no change)"
    [[ $stack == polkit ]] && polkit_dropin_ensure
    return 0
  fi

  pam_validate "$new" "$base" "$stack" || {
    err "$stack: candidate rejected, nothing written"
    return 1
  }

  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] $stack: $target would change:"
    diff -u "$base" "$new" | sed 1,2d || true
    [[ $stack == polkit ]] && polkit_dropin_ensure
    return 0
  fi

  mkdir -p "$bdir" "$STATE_DIR/created" || return 1
  ts=$(timestamp)
  if [[ -e $target ]]; then
    prev=$bdir/$file.$ts.bak
    cp -a "$target" "$prev" || return 1
    [[ $state == enabled ]] || cp "$base" "$bdir/$file.orig"
    rm -f "$bdir/$file.absent"
  else
    : >"$bdir/$file.absent"
    rm -f "$bdir/$file.orig"
  fi
  if [[ $created == 1 ]]; then
    : >"$(pam_created_marker "$file")"
  fi

  if ! pam_install "$new" "$target"; then
    pam_rollback "$target" "$prev"
    [[ $created == 1 ]] && rm -f "$(pam_created_marker "$file")"
    return 1
  fi

  # Re-read what is on disk, not what we meant to write.
  if ! pam_validate "$target" "$base" "$stack"; then
    pam_rollback "$target" "$prev"
    [[ $created == 1 ]] && rm -f "$(pam_created_marker "$file")"
    return 1
  fi

  if [[ $stack == polkit ]] && ! polkit_dropin_ensure; then
    pam_rollback "$target" "$prev"
    [[ $created == 1 ]] && rm -f "$(pam_created_marker "$file")"
    return 1
  fi

  audit "enable $stack backup=${prev:-none}"
  ok "$stack: face unlock enabled in $target"
  [[ -n $prev ]] && note "backup: $prev"
  return 0
}

pam_disable() {
  local stack=$1 file target bdir work new ts prev cmpmsg removed=0 created_marker
  file=$(pam_file_for "$stack") || {
    err "unknown stack: $stack"
    return 2
  }
  target=$PAM_DIR/$file
  bdir=$(pam_backup_dir)
  created_marker=$(pam_created_marker "$file")

  if [[ ! -e $target ]]; then
    say "$stack: not enabled ($target does not exist)"
    [[ $stack == polkit ]] && polkit_dropin_remove
    return 0
  fi
  pam_markers_ok "$target" || {
    err "$target has unbalanced sl7-faceunlock markers: fix by hand"
    return 1
  }
  if ! grep -q '^# sl7-faceunlock BEGIN' "$target"; then
    say "$stack: not enabled (no sl7-faceunlock block in $target)"
    [[ $stack == polkit ]] && polkit_dropin_remove
    return 0
  fi

  work=$(mktemp -d) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  new=$work/new
  pam_strip <"$target" >"$new"

  # Files we created ourselves go away entirely once nothing else lives in them.
  if [[ -e $created_marker ]]; then
    if [[ $stack == lock ]] && ! grep -qvE '^[[:space:]]*(#|$)' "$new"; then
      removed=1
    elif [[ $stack == polkit ]] && cmp -s "$new" "$VENDOR_PAM_DIR/polkit-1"; then
      removed=1
    fi
  fi

  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] $stack: would $([[ $removed == 1 ]] && echo remove "$target" || echo "strip our block from $target")"
    [[ $stack == polkit ]] && polkit_dropin_remove
    return 0
  fi

  mkdir -p "$bdir" || return 1
  ts=$(timestamp)
  prev=$bdir/$file.$ts.disable.bak
  cp -a "$target" "$prev" || return 1

  if [[ $removed == 1 ]]; then
    rm -f "$target" "$created_marker"
    cmpmsg="removed $target (we created it; the vendor stack applies again)"
  else
    if ! pam_install "$new" "$target"; then
      pam_rollback "$target" "$prev"
      return 1
    fi
    if grep -q 'sl7-faceunlock' "$target"; then
      err "$target still mentions sl7-faceunlock after the edit"
      pam_rollback "$target" "$prev"
      return 1
    fi
    if [[ -e $bdir/$file.orig ]] && cmp -s "$target" "$bdir/$file.orig"; then
      cmpmsg="$target is byte-identical to the original"
    else
      cmpmsg="our lines removed; other changes made to $target since are kept"
    fi
  fi

  [[ $stack == polkit ]] && polkit_dropin_remove
  audit "disable $stack backup=$prev"
  ok "$stack: face unlock disabled: $cmpmsg"
  return 0
}

# Remove every line we added, in every stack. Keeps going past failures.
pam_disable_all() {
  local stack rc=0
  for stack in "${STACKS[@]}"; do
    pam_disable "$stack" || rc=1
  done
  polkit_dropin_remove || true
  return "$rc"
}

# user-level: print "stack=state" lines (readable without root).
pam_status_lines() {
  local stack
  for stack in "${STACKS[@]}"; do
    printf '%s=%s\n' "$stack" "$(pam_state "$stack")"
  done
}
