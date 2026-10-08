# shellcheck shell=bash
# omarchy-sl7-faceunlock: status, subcommand bodies and the gum TUI.
# Every TUI action calls the same functions the CLI subcommands call, so a
# Quickshell panel can drive `omarchy-sl7-faceunlock <subcommand> --json`.

GLYPH=$(printf '\U000F0C9D')

notify() {
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send -g "$GLYPH" "Face Unlock" "$1" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "Face Unlock" "$1" >/dev/null 2>&1 || true
  fi
}

# --- status -------------------------------------------------------------------

status_json() {
  local user stacks faces lock_state lid
  user=$(sl7_user)
  stacks=$(pam_status_lines | jq -Rn '[inputs | split("=") | {key: .[0], value: .[1]}] | from_entries')
  faces=$(jq -c '.faces // []' "$(snapshot_file)" 2>/dev/null || printf '[]')
  lock_state=$(lock_enabled_state)
  lid=$(lid_state)
  jq -n --arg user "$user" \
    --argjson installed "$(howdy_installed && echo true || echo false)" \
    --arg version "$(howdy_version 2>/dev/null)" \
    --arg bridge "$(bridge_state)" --arg bridge_busy "$(bridge_busy_state)" \
    --arg camera_path "$CAMERA" --arg camera "$(camera_state)" \
    --arg emitter "$(emitter_state)" --arg lid "$lid" \
    --argjson faces "${faces:-[]}" --argjson stacks "$stacks" \
    --arg lock_plugin "$lock_state" \
    --argjson lock_patched "$(lock_patched && echo true || echo false)" \
    '{user: $user, howdy: {installed: $installed, version: $version},
      bridge: $bridge, bridge_busy: ($bridge_busy == "stuck"), camera: {path: $camera_path, state: $camera},
      emitter: $emitter, lid: $lid, faces: $faces, stacks: $stacks,
      lock_plugin: {state: $lock_plugin, patched: $lock_patched}}'
}

# mark LEVEL TEXT: good | warn | bad
mark() {
  case $1 in
  good) printf '  %s●%s %s\n' "$C_G" "$C_0" "$2" ;;
  warn) printf '  %s●%s %s\n' "$C_Y" "$C_0" "$2" ;;
  *) printf '  %s●%s %s\n' "$C_R" "$C_0" "$2" ;;
  esac
}

status_text() {
  local s count state stack
  say "${C_B}Face Unlock status${C_0}  ($(sl7_user))"
  say ""
  if howdy_installed; then
    mark good "howdy-next installed ($(howdy_version))"
  else
    mark bad "howdy-next / pam_howdy.so not found"
  fi
  s=$(bridge_state)
  case $s in
  active) mark good "IR bridge service (sl7-ir-bridge): running" ;;
  inactive) mark warn "IR bridge service: not running (start it: sudo systemctl start sl7-ir-bridge)" ;;
  *) mark bad "IR bridge service: not installed" ;;
  esac
  if [[ $(bridge_busy_state) == stuck ]]; then
    mark bad "IR bridge is stuck: something holds the IR camera path (EBUSY), so face unlock fails"
    say "      fix: systemctl --user restart pipewire wireplumber; sudo systemctl restart sl7-ir-bridge"
    sed -n '3,$p' "$BRIDGE_BUSY_FILE" 2>/dev/null | while IFS= read -r s; do say "      holder: $s"; done
  fi
  s=$(camera_state)
  case $s in
  ok) mark good "camera reachable: $CAMERA" ;;
  unreadable) mark bad "camera exists but your user cannot open it (the lock screen runs PAM as you): check the uaccess rule" ;;
  *) mark bad "camera missing: $CAMERA" ;;
  esac
  count=$(faces_count_cached)
  if ((count > 0)); then
    mark good "$count enrolled face(s) (snapshot $(stat -c %y "$(snapshot_file)" 2>/dev/null | cut -d. -f1))"
  else
    mark warn "no enrolled faces known (open Manage faces to refresh)"
  fi
  for stack in "${STACKS[@]}"; do
    state=$(pam_state "$stack")
    case $stack in sudo) s="sudo" ;; polkit) s="polkit (admin prompts in GUI apps)" ;; lock) s="lock screen (PAM service)" ;; esac
    case $state in
    enabled) mark good "face unlock for $s: on" ;;
    foreign) mark warn "face unlock for $s: another pam_howdy line exists, left alone" ;;
    *) mark warn "face unlock for $s: off" ;;
    esac
  done
  s=$(lock_enabled_state)
  if lock_patched; then
    mark good "lock screen plugin $LOCK_ID: patched, $s"
  elif [[ $s == absent ]]; then
    mark warn "lock screen plugin $LOCK_ID: not installed"
  else
    mark warn "lock screen plugin $LOCK_ID: installed, not patched ($s)"
  fi
  s=$(lid_state)
  mark good "lid (logind): $s"
  case $(emitter_state) in
  on) mark good "IR emitter: lit by the bridge while the camera streams (Windows timing, at most 10 s per scan)" ;;
  off) mark warn "IR emitter: off (IR_EMITTER=off in /etc/sl7-ir-bridge.conf); recognition works best in daylight" ;;
  *) mark warn "IR emitter: not yet available (recognition works best in daylight until then)" ;;
  esac
  mark good "login and SDDM: never touched"
}

# --- faces --------------------------------------------------------------------

face_guidance() {
  case $1 in
  "No glasses") say "Take your glasses off. Face the camera, about 40 cm away, neutral expression, head level." ;;
  "Glasses") say "Put on the glasses you wear most. Face the camera about 40 cm away; tilt your head a little so lamp reflections leave your eyes clear." ;;
  "Sunglasses") say "Face the camera about 40 cm away with the sunglasses on. Many sunglasses block infrared; if the test fails, remove this look rather than lowering security." ;;
  "Low light") say "Dim the room, face the camera about 40 cm away. The IR emitter lights your face at any room brightness; this look matters most when the room is dim." ;;
  "Bright light") say "Face a window or daylight, about 40 cm away, no strong sun directly behind you." ;;
  "Hat") say "Wear the hat or cap you use most. Face the camera about 40 cm away with your forehead and eyes visible." ;;
  *) say "Face the camera about 40 cm away, in the conditions this label describes." ;;
  esac
}

faces_list_json() {
  sl7_priv faces-json "$(sl7_user)"
}

faces_list_cached_json() {
  jq -c '.faces // []' "$(snapshot_file)" 2>/dev/null || printf '[]'
}

faces_print() {
  local json=$1
  if [[ $(jq 'length' <<<"$json") == 0 ]]; then
    say "  (no faces enrolled)"
    return
  fi
  jq -r '.[] | "  \(.id)\t\(.label)\t\(.time)"' <<<"$json" | column -t -s $'\t'
}

faces_add_cli() {
  local label=$1
  valid_label "$label" || die "invalid label (1-24 characters, no / or \\)"
  sl7_priv_pw faces-add "$(sl7_user)" "$label"
}

faces_remove_cli() {
  sl7_priv_pw faces-remove "$(sl7_user)" "$1"
}

faces_clear_cli() {
  sl7_priv_pw faces-clear "$(sl7_user)"
}

# --- subcommand: auth ---------------------------------------------------------

auth_enable_cli() {
  local stack=$1
  case $stack in sudo | polkit | lock) ;; *) die "unknown stack: $stack (sudo, polkit, lock)" ;; esac
  sl7_priv_pw enable "$stack" || return 1
  stack_test_hint "$stack"
}

auth_disable_cli() {
  sl7_priv pam-disable "$1"
}

stack_test_hint() {
  case $1 in
  sudo) note "Test in a SECOND terminal: sudo -k && sudo true   (face, or password after the camera times out)" ;;
  polkit) note "Test: pkexec true   (Omarchy's polkit dialog appears)" ;;
  lock) note "Test: lock with Super+Ctrl+L and press 'Unlock with face' (needs the lock plugin)" ;;
  esac
}

auth_status_json() {
  pam_status_lines | jq -Rn '[inputs | split("=") | {key: .[0], value: .[1]}] | from_entries'
}

off_cli() {
  sl7_priv off
  local rc=$?
  ((rc == 0)) && notify "Face unlock is off: every PAM line was removed, faces are kept."
  return "$rc"
}

# --- the TUI ------------------------------------------------------------------

ui_pause() {
  printf '\n'
  read -rsn1 -p "Press any key to continue..." </dev/tty
  printf '\n'
}

ui_header() {
  clear
  gum style --bold --foreground "${SL7_ACCENT:-2}" "$GLYPH  Face Unlock" 2>/dev/null || say "Face Unlock"
  gum style --faint "$1" 2>/dev/null || say "$1"
  printf '\n'
}

ui_box() {
  gum style --border rounded --padding "0 1" --width "$(($(tput cols 2>/dev/null || echo 80) - 4))" "$1"
}

ui_confirm() {
  gum confirm "$1"
}

ui_menu() {
  local header=$1
  shift
  gum choose --header "$header" --height 14 "$@"
}

ui_status() {
  ui_header "Status"
  status_text
  ui_pause
}

refresh_snapshot() {
  say "Refreshing the face list (needs your password)..."
  sl7_priv_pw sync "$(sl7_user)" || warn "could not refresh the snapshot"
}

ui_preflight() {
  local bad=0
  howdy_installed || { mark bad "howdy-next is not installed (pacman -S howdy-next)"; bad=1; }
  [[ $(bridge_state) != missing ]] || { mark bad "sl7-ir-bridge is not installed"; bad=1; }
  [[ $(camera_state) == ok ]] || { mark bad "camera not reachable at $CAMERA (state: $(camera_state))"; bad=1; }
  command -v jq >/dev/null 2>&1 || { mark bad "jq missing"; bad=1; }
  return "$bad"
}

ui_grab_frame() {
  if ! command -v v4l2-ctl >/dev/null 2>&1; then
    note "v4l-utils not installed: skipping the one-frame camera check."
    return 0
  fi
  say "Grabbing one frame (the sensor wakes for about a second; nothing is saved)..."
  if timeout 5 v4l2-ctl -d "$CAMERA" --stream-mmap --stream-count=1 --stream-to=/dev/null >/dev/null 2>&1; then
    mark good "the bridge delivered a frame"
  else
    mark warn "no frame within 5 s: check 'journalctl -u sl7-ir-bridge'; continuing"
  fi
}

ui_enroll() {
  local choice label count
  choice=$(ui_menu "Which look are you adding?" "No glasses" "Glasses" "Sunglasses" "Low light" "Bright light" "Hat" "Custom label..." "Back") || return 1
  case $choice in
  Back) return 1 ;;
  "Custom label...")
    label=$(gum input --placeholder "Label (max 24 characters)" --char-limit 24) || return 1
    valid_label "$label" || { err "invalid label (1-24 characters, no / or \\)"; ui_pause; return 1; }
    ;;
  *) label=$choice ;;
  esac
  ui_header "Add a look: $label"
  ui_box "$(face_guidance "$label")"
  count=$(faces_count_cached)
  if ((count >= 5)); then
    warn "You already have $count looks. Every extra look slightly raises the chance of a false match; keep the set small."
  fi
  say "Camera on only while scanning (4 s or less). Nothing is saved except the face embedding."
  ui_confirm "Ready? The scan starts after the countdown." || return 1
  for n in 3 2 1; do
    printf '\r  %s ' "$n"
    sleep 1
  done
  printf '\r        \n'
  if sl7_priv_pw faces-add "$(sl7_user)" "$label"; then
    ok "added '$label'"
  else
    err "enrolment failed: check the camera (Status) and lighting, then try again"
    return 1
  fi
}

ui_faces() {
  local choice json id line
  while true; do
    ui_header "Manage faces"
    json=$(faces_list_cached_json)
    faces_print "$json"
    say ""
    note "Passwords are always required to add or remove faces."
    choice=$(ui_menu "" "Add a variation" "Remove one" "Remove all" "Refresh list" "Back") || return 0
    case $choice in
    "Add a variation")
      ui_enroll
      ui_pause
      ;;
    "Remove one")
      if [[ $(jq 'length' <<<"$json") == 0 ]]; then
        say "Nothing to remove."
        ui_pause
        continue
      fi
      line=$(jq -r '.[] | "\(.id)  \(.label)"' <<<"$json" | gum choose --header "Remove which face?") || continue
      id=${line%% *}
      if ui_confirm "Remove '${line#* }'?"; then
        sl7_priv_pw faces-remove "$(sl7_user)" "$id" && ok "removed"
        ui_pause
      fi
      ;;
    "Remove all")
      if ui_confirm "Remove ALL enrolled faces? You will fall back to your password."; then
        sl7_priv_pw faces-clear "$(sl7_user)" && ok "all faces removed"
        ui_pause
      fi
      ;;
    "Refresh list") refresh_snapshot ;;
    *) return 0 ;;
    esac
  done
}

ui_wizard() {
  local choice stacks s
  ui_header "Set up face unlock"
  say "Step 1 of 3: checks"
  if ! ui_preflight; then
    say ""
    err "Fix the items above first, then run the wizard again."
    ui_pause
    return 0
  fi
  ui_grab_frame
  say ""
  say "Step 2 of 3: configure howdy-next"
  say "  device_path     $CFG_DEVICE"
  say "  dark_threshold  $CFG_DARK_THRESHOLD   (IR frames lit at Windows' short exposure are dim; this keeps them)"
  say "  timeout         $CFG_TIMEOUT s per attempt (the bridge allows 10 s per session; a scan never streams past 5 s)"
  say "  abort_if_ssh    true   (lets password-only sudo skip the camera)"
  if [[ $(emitter_state) == on ]]; then
    note "The IR emitter is lit by the bridge during each attempt (at most 10 s)."
  else
    note "No IR emitter: expect recognition to work best in daylight."
  fi
  ui_confirm "Apply these settings? (asks for your password)" || return 0
  sl7_priv_pw configure "$CFG_DEVICE" "$CFG_DARK_THRESHOLD" "$CFG_TIMEOUT" || {
    err "configuration failed"
    ui_pause
    return 0
  }
  say ""
  say "Step 3 of 3: enrol your first face"
  ui_enroll || {
    ui_pause
    return 0
  }
  ui_pause
  ui_header "Turn it on"
  say "Face unlock is configured but no login path uses it yet."
  stacks=$(printf '%s\n' "sudo" "polkit (admin prompts in GUI apps)" "lock screen (needs the lock plugin: Lock screen menu)" |
    gum choose --no-limit --header "Enable now? (space to select, enter to confirm; none is fine)") || return 0
  while IFS= read -r s; do
    case $s in
    sudo*) toggle_stack sudo on ;;
    polkit*) toggle_stack polkit on ;;
    lock*) toggle_stack lock on ;;
    esac
  done <<<"$stacks"
}

# toggle_stack STACK [on|off]: guided, validated, rolls back on request.
toggle_stack() {
  local stack=$1 want=${2:-} state choice
  state=$(pam_state "$stack")
  if [[ $state == foreign ]]; then
    err "$stack already has a pam_howdy.so line that is not ours. Remove it by hand first."
    return 1
  fi
  if [[ -z $want ]]; then
    [[ $state == enabled ]] && want=off || want=on
  fi
  if [[ $want == off ]]; then
    sl7_priv pam-disable "$stack"
    return
  fi
  [[ $state == enabled ]] && {
    say "$stack is already on."
    return 0
  }
  if (($(faces_count_cached) == 0)); then
    warn "No enrolled face is known. The stack would just fall through to your password."
    ui_confirm "Enable anyway?" || return 0
  fi
  ui_box "Keep a root shell open while you change authentication:
  open a second terminal and run:  sudo -i
Leave it open until the test below succeeds."
  ui_confirm "Enable face unlock for $stack now?" || return 0
  sl7_priv_pw enable "$stack" || {
    err "$stack: not enabled (the helper rolled back; see messages above)"
    return 1
  }
  say ""
  case $stack in
  sudo) say "Test it: open ANOTHER terminal and run:  sudo -k && sudo true
Expect: the camera looks for you; if it does not match you get the password prompt.
Also try with the camera covered: the password must still work." ;;
  polkit) say "Test it: in another terminal run:  pkexec true
Expect: Omarchy's polkit dialog; face first, then the password." ;;
  lock) say "Test it: install the lock plugin (Lock screen menu) if you have not, lock with Super+Ctrl+L
and press 'Unlock with face'. The password box always stays available." ;;
  esac
  if [[ $stack == lock ]] && command -v pamtester >/dev/null 2>&1; then
    say ""
    note "pamtester found: you can also run  pamtester omarchy-lock-face $(sl7_user) authenticate"
  fi
  choice=$(ui_menu "Did it work, and does your password still work?" "Yes, keep it" "No, roll it back") || choice="No, roll it back"
  if [[ $choice == "No, roll it back" ]]; then
    sl7_priv pam-disable "$stack"
    warn "$stack rolled back."
  else
    ok "$stack kept"
  fi
}

ui_use_for() {
  local choice stack
  while true; do
    ui_header "Use face unlock for"
    for stack in "${STACKS[@]}"; do
      mark "$([[ $(pam_state "$stack") == enabled ]] && echo good || echo warn)" "$stack: $(pam_state "$stack")"
    done
    say ""
    note "Login and SDDM stay off on purpose: face login would leave gnome-keyring locked."
    choice=$(ui_menu "Toggle which one?" "sudo" "polkit (admin prompts in GUI apps)" "lock screen" "Back") || return 0
    case $choice in
    sudo) toggle_stack sudo ;;
    polkit*) toggle_stack polkit ;;
    "lock screen") toggle_stack lock ;;
    *) return 0 ;;
    esac
    ui_pause
  done
}

ui_lock() {
  local choice
  while true; do
    ui_header "Lock screen"
    say "Plugin: $LOCK_ID (nate8199, MIT), pinned at $LOCK_PIN"
    say "Installed: $(lock_enabled_state)   Patched for howdy-next: $(lock_patched && echo yes || echo no)"
    say "PAM service omarchy-lock-face: $(pam_state lock)"
    say ""
    note "Adds an 'Unlock with face' button; the camera runs only when you press it. 5 failed tries, then password only."
    note "The overlay patch swaps howdy-git's compare.py for PAM. If it fails to apply the stock lock stays."
    choice=$(ui_menu "" "Install and enable" "Re-apply patch (after an upgrade)" "Update plugin and re-apply" "Remove plugin" "Back") || return 0
    case $choice in
    "Install and enable")
      [[ $(pam_state lock) == enabled ]] || toggle_stack lock on
      ui_confirm "Install $LOCK_ID? It runs unsandboxed inside omarchy-shell; its code is MIT and was verified at $LOCK_PIN." && lock_install
      ui_pause
      ;;
    "Re-apply patch"*) lock_reapply; ui_pause ;;
    "Update plugin"*) lock_update; ui_pause ;;
    "Remove plugin") lock_remove; ui_pause ;;
    *) return 0 ;;
    esac
  done
}

ui_lid() {
  local st
  ui_header "Lid gate"
  st=$(lid_state)
  say "logind reports the lid as: $st"
  case $st in
  closed) say "Face auth would be skipped right now (camera stays off)." ;;
  open) say "Face auth would run." ;;
  *) say "logind could not be queried; the gate fails open (face auth runs)." ;;
  esac
  say ""
  note "The SL7 lid is a devicetree switch, so howdy's own lid check and Omarchy's omarchy-hw-laptop-closed are inert."
  note "Every face line we write is preceded by:  pam_exec.so quiet $LID_GATE"
  note "Close the lid on an external monitor and run 'sudo -k && sudo true': it should ask for the password at once."
  ui_pause
}

ui_test() {
  local choice
  while true; do
    ui_header "Test recognition"
    choice=$(ui_menu "" "Live preview (howdy test)" "PAM check (lock screen service)" "Back") || return 0
    case $choice in
    "Live preview"*)
      say "An OpenCV window opens with the IR view and detection boxes. Press q or Esc to close it."
      say "No images are saved."
      ui_confirm "Open the preview?" && sl7_priv howdy-test "$(sl7_user)"
      ui_pause
      ;;
    "PAM check"*)
      if command -v pamtester >/dev/null 2>&1; then
        say "Look at the camera now..."
        if pamtester omarchy-lock-face "$(sl7_user)" authenticate; then
          ok "recognised"
        else
          err "not recognised (or the service is off)"
        fi
      else
        say "pamtester is not installed (optional). Alternatives:"
        say "  sudo -k && sudo true        (needs the sudo stack on)"
        say "  or install it: yay -S pamtester"
      fi
      ui_pause
      ;;
    *) return 0 ;;
    esac
  done
}

ui_off() {
  ui_header "Disable all (emergency off)"
  say "This runs 'howdy disable 1' and removes every PAM line we added (sudo, polkit, lock)."
  say "Your enrolled faces are kept."
  if ui_confirm "Turn face unlock off everywhere?"; then
    off_cli
    ui_pause
  fi
}

ui_main() {
  local choice
  omarchy_gum_env
  menu_install --auto >/dev/null 2>&1 || true
  while true; do
    ui_header "$(sl7_user)"
    choice=$(ui_menu "" "Status" "Set up face unlock (wizard)" "Manage faces" "Test recognition" "Use face unlock for..." "Lock screen" "Lid gate" "Disable all (emergency off)" "Quit") || exit 130
    case $choice in
    Status) ui_status ;;
    Set*) ui_wizard ;;
    Manage*) ui_faces ;;
    Test*) ui_test ;;
    Use*) ui_use_for ;;
    Lock*) ui_lock ;;
    Lid*) ui_lid ;;
    Disable*) ui_off ;;
    *) exit 130 ;;
    esac
  done
}

# --remove: the menu's Remove > Security > Face Unlock row.
ui_remove() {
  omarchy_gum_env
  ui_header "Remove face unlock"
  say "1. every PAM line we added is removed (sudo, polkit, lock screen)"
  say "2. optionally: your enrolled faces and the lock screen plugin"
  ui_confirm "Continue?" || exit 130
  off_cli
  if ui_confirm "Also delete all enrolled faces?"; then
    sl7_priv_pw faces-clear "$(sl7_user)" && ok "faces deleted"
  fi
  if lock_installed && ui_confirm "Also remove the $LOCK_ID plugin (stock lock screen returns)?"; then
    lock_remove
  fi
  if ui_confirm "Hide the Face Unlock rows from the Omarchy menu?"; then
    menu_remove
  fi
  say ""
  note "The packages stay installed: pacman -Rns omarchy-sl7-faceunlock howdy-next removes them."
}
