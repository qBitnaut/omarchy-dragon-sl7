# shellcheck shell=bash
# omarchy-sl7-faceunlock: Omarchy menu rows.
#
# Omarchy reads ~/.config/omarchy/extensions/omarchy-menu.jsonc after its own
# default menu; ids are object keys and a repeated id overrides. The shell
# strips whole-line // comments and trailing commas before JSON.parse, so we
# keep our rows between two marker comment lines, one row per line, and edit
# the file as text so everything else the user wrote survives untouched.

MENU_BEGIN='  // sl7-faceunlock BEGIN (managed by omarchy-sl7-faceunlock --menu-install)'
MENU_END='  // sl7-faceunlock END'

menu_file() {
  printf '%s' "${SL7_MENU_FILE:-$HOME/.config/omarchy/extensions/omarchy-menu.jsonc}"
}

menu_optout_file() {
  printf '%s/omarchy-sl7-faceunlock/menu-optout' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

menu_rows() {
  local glyph
  glyph=$(printf '\U000F0C9D')
  printf '%s\n' "$MENU_BEGIN"
  printf '  "setup.security.face": {"icon":"%s","label":"Face Unlock","description":"IR face unlock for sudo, polkit and the lock screen","when":"command -v omarchy-sl7-faceunlock","action":"omarchy-launch-floating-terminal-with-presentation omarchy-sl7-faceunlock"},\n' "$glyph"
  printf '  "remove.security.face": {"icon":"%s","label":"Face Unlock","when":"omarchy-pkg-present howdy-next","action":"omarchy-launch-floating-terminal-with-presentation '"'"'omarchy-sl7-faceunlock --remove'"'"'"},\n' "$glyph"
  printf '%s\n' "$MENU_END"
}

# Emulate the shell's stripJsonc (whole-line // comments, trailing commas) and
# check the result is a JSON object. stdin -> exit status.
jsonc_valid() {
  sed -E '/^[[:space:]]*\/\/.*$/d' | sed -zE 's/,([[:space:]]*[]}])/\1/g' | jq -e 'type == "object"' >/dev/null 2>&1
}

menu_has_ids() {
  sed -E '/^[[:space:]]*\/\/.*$/d' | sed -zE 's/,([[:space:]]*[]}])/\1/g' |
    jq -e 'has("setup.security.face") and has("remove.security.face")' >/dev/null 2>&1
}

# stdin = file, stdout = file without our block.
menu_strip() {
  awk -v b="// sl7-faceunlock BEGIN" -v e="// sl7-faceunlock END" '
    { t = $0; sub(/^[[:space:]]+/, "", t) }
    index(t, b) == 1 { skip = 1; next }
    skip && index(t, e) == 1 { skip = 0; next }
    !skip { print }'
}

# stdin = stripped file, $1 = rows file. Insert rows before the final closing
# brace, adding a comma to the previous entry when it lacks one.
menu_insert() {
  awk -v rows="$1" '
    BEGIN { while ((getline l < rows) > 0) block = block l "\n" }
    { line[NR] = $0 }
    END {
      last = 0
      for (i = NR; i >= 1; i--) if (line[i] ~ /^[[:space:]]*}[[:space:]]*$/) { last = i; break }
      if (!last) exit 1
      prev = 0
      for (i = last - 1; i >= 1; i--) {
        if (line[i] ~ /^[[:space:]]*$/ || line[i] ~ /^[[:space:]]*\/\//) continue
        prev = i; break
      }
      if (prev && line[prev] !~ /[,{][[:space:]]*$/) line[prev] = line[prev] ","
      for (i = 1; i < last; i++) print line[i]
      printf "%s", block
      for (i = last; i <= NR; i++) print line[i]
    }'
}

# menu_apply install|remove
menu_apply() {
  local mode=$1 file dir work new rows
  file=$(menu_file)
  dir=${file%/*}
  work=$(mktemp -d) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  new=$work/new
  rows=$work/rows

  if [[ ! -e $file ]]; then
    [[ $mode == remove ]] && { say "menu: nothing to remove ($file does not exist)"; return 0; }
    printf '{\n  // Omarchy menu extension. See /usr/share/omarchy/default/omarchy/omarchy-menu.jsonc\n}\n' >"$work/cur"
  else
    cp "$file" "$work/cur"
  fi

  menu_strip <"$work/cur" >"$work/stripped"
  if [[ $mode == install ]]; then
    menu_rows >"$rows"
    menu_insert "$rows" <"$work/stripped" >"$new" || {
      err "menu: $file has no closing brace; not touching it"
      return 1
    }
  else
    cp "$work/stripped" "$new"
  fi

  # The original must have parsed too, otherwise we would hide the user's own
  # syntax error behind ours.
  if [[ -e $file ]] && ! jsonc_valid <"$work/cur"; then
    err "menu: $file is not valid JSONC to begin with; not touching it"
    return 1
  fi
  jsonc_valid <"$new" || {
    err "menu: the edit would produce invalid JSONC; nothing written"
    return 1
  }
  if [[ $mode == install ]]; then
    menu_has_ids <"$new" || { err "menu: rows missing after merge; nothing written"; return 1; }
  fi

  if [[ -e $file ]] && cmp -s "$file" "$new"; then
    ok "menu: already up to date ($file)"
    return 0
  fi
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] menu: would change $file"
    diff -u "$work/cur" "$new" | sed 1,2d
    return 0
  fi

  mkdir -p "$dir" || return 1
  if [[ -e $file ]]; then
    cp -a "$file" "$file.bak.$(date +%s)" || return 1
  fi
  atomic_write "$file" 0644 <"$new" || return 1
  ok "menu: $mode done ($file)"
}

# menu_install [--auto]: --auto (the login service and first app run) honours
# an earlier --menu-remove.
menu_install() {
  local optout
  optout=$(menu_optout_file)
  if [[ ${1:-} == --auto ]]; then
    [[ -e $optout ]] && return 0
  else
    rm -f "$optout"
  fi
  menu_apply install
}

menu_remove() {
  local optout
  optout=$(menu_optout_file)
  menu_apply remove || return 1
  [[ $DRY_RUN == 1 ]] && return 0
  mkdir -p "${optout%/*}" && : >"$optout"
}
