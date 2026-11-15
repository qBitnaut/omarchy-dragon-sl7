#!/bin/bash
# Compatibility check of the lock-screen overlay against an Omarchy checkout.
# Usage: tests/omarchy-compat.sh <omarchy-checkout>
#
# Applies the shipped patches to nate8199's clone (LOCK_PIN) in a scratch
# directory, derives what the patched QML and shell code depend on, and
# verifies each dependency against <omarchy-checkout> (the repository root:
# shell/ and bin/ live there; /usr/share/omarchy has the same layout).
# Set SL7_TEST_NATE_REPO to a local clone of nate8199/omarchy-plugin-howdy-face
# to stay offline. Read-only on the checkout; nothing is installed or run.
# Exit 1 when a hard dependency is missing. Stock lock hash drift only warns.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB=$ROOT/lib
CK=${1:-}
if [[ -z $CK || ! -d $CK/shell || ! -d $CK/bin ]]; then
  printf 'usage: %s <omarchy-checkout (with shell/ and bin/)>\n' "$0" >&2
  exit 2
fi
CK=$(cd "$CK" && pwd)
SH=$CK/shell

pass=0
fail=0
warn=0
ok_() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad_() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
warn_() { warn=$((warn + 1)); printf 'WARN %s\n' "$1"; }
check() { # name, command...
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok_ "$name"; else bad_ "$name"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# shellcheck source=../lib/lock.sh
source "$LIB/lock.sh"

# --- the patched clone ------------------------------------------------------------
nate=${SL7_TEST_NATE_REPO:-}
if [[ -z $nate ]]; then
  nate=$T/nate-src
  git clone -q https://github.com/nate8199/omarchy-plugin-howdy-face.git "$nate" 2>/dev/null || {
    printf 'FAIL cannot clone nate8199/omarchy-plugin-howdy-face\n'
    exit 1
  }
fi
W=$T/clone
mkdir -p "$W"
if ! git -C "$nate" archive "$LOCK_PIN" 2>/dev/null | tar -x -C "$W"; then
  printf 'FAIL no commit %s in %s\n' "$LOCK_PIN" "$nate"
  exit 1
fi
applied=1
for entry in "${LOCK_PATCHES[@]}"; do
  p=$(lock_entry_patch "$entry")
  if ! patch -p1 -s -d "$W" -i "$LIB/lock-patch/$p" >/dev/null 2>&1; then
    bad_ "patch applies to $LOCK_PIN: $p"
    applied=0
  fi
done
if ((!applied)); then
  printf '\n%s passed, %s failed, %s warnings\n' "$pass" "$fail" "$warn"
  exit 1
fi
ok_ "all ${#LOCK_PATCHES[@]} patches apply to nate8199 $LOCK_PIN"
QML=("$W/Service.qml" "$W/LockView.qml")

# Names used by the patched clone, one per line, matching the given regex.
uses() { grep -ohE "$1" "${QML[@]}" | sort -u; }
# Body of the "QtObject <name> {" block (up to the closing brace at the same
# indent) of a QML file.
qobject_block() { # file, name
  awk -v n="$2" '
    $0 ~ "property QtObject " n ": QtObject *\\{" { match($0, /^ */); ind = RLENGTH; on = 1; next }
    on { match($0, /^ */); if (RLENGTH <= ind && $0 ~ /^ *}/) exit; print }
  ' "$1"
}
has_prop() { grep -Eq "property +[A-Za-z]+ +$1:" "${@:2}"; }

# --- module exports -------------------------------------------------------------------
for n in Border Color Style; do
  check "Commons qmldir exports $n" grep -Eq "^singleton $n [0-9.]+ $n\\.qml" "$SH/Commons/qmldir"
  check "Commons/$n.qml exists" test -f "$SH/Commons/$n.qml"
done
for n in Button BorderSurface; do
  check "Ui qmldir exports $n" grep -Eq "^$n [0-9.]+ $n\\.qml" "$SH/Ui/qmldir"
  check "Ui/$n.qml exists" test -f "$SH/Ui/$n.qml"
done

# --- Color.qml tokens -------------------------------------------------------------------
lockblock=$(qobject_block "$SH/Commons/Color.qml" lock)
check "Color.qml has a lock block" test -n "$lockblock"
tokens=$(uses 'Color\.lock\.[A-Za-z]+' | sed 's/.*\.//')
check "clone uses Color.lock tokens (parsed)" test -n "$tokens"
for t in $tokens; do
  check "Color.lock.$t" grep -Eq "property +[A-Za-z]+ +$t:" <<<"$lockblock"
done
for t in $(uses 'Color\.[a-z][A-Za-z]*\b' | grep -v '^Color\.lock$' | sed 's/.*\.//'); do
  check "Color.$t" has_prop "$t" "$SH/Commons/Color.qml"
done

# --- Style.qml -------------------------------------------------------------------------------
check "Style.cornerRadius" has_prop cornerRadius "$SH/Commons/Style.qml"
check "Style.space()" grep -Eq 'function +space\(' "$SH/Commons/Style.qml"
fontblock=$(qobject_block "$SH/Commons/Style.qml" font)
for t in $(uses 'Style\.font\.[a-z]+' | sed 's/.*\.//'); do
  check "Style.font.$t" grep -Eq "property +[A-Za-z]+ +$t:" <<<"$fontblock"
done

# --- Border.qml surfaceSpec --------------------------------------------------------------------
sig=$(grep -E 'function +surfaceSpec\(' "$SH/Commons/Border.qml" | head -n1 | sed -E 's/.*surfaceSpec\(([^)]*)\).*/\1/; s/ //g')
check "Border.surfaceSpec(section, token, fallbackColor, fallbackWidth, alphaKey)" test "$sig" = "section,token,fallbackColor,fallbackWidth,alphaKey"
calls=$(grep -ohE 'Border\.surfaceSpec\([^)]*\)' "$W/LockView.qml")
check "clone calls Border.surfaceSpec" test -n "$calls"
while IFS= read -r c; do
  [[ -n $c ]] || continue
  n=$(awk -F, '{ print NF }' <<<"$c")
  check "Border.surfaceSpec call has 5 arguments" test "$n" -eq 5
done <<<"$calls"

# --- Button and BorderSurface -----------------------------------------------------------------
# Properties set on the Button and BorderSurface items in LockView.qml.
item_props() { # type
  awk -v t="$1" '
    $0 ~ "^ *" t " *\\{" { match($0, /^ */); ind = RLENGTH; on = 1; next }
    on { match($0, /^ */); if (RLENGTH <= ind && $0 ~ /^ *}/) exit
         if (RLENGTH == ind + 2 && $0 ~ /^ *[a-z][A-Za-z]*: /) { sub(/^ */, ""); sub(/:.*/, ""); print } }
  ' "$W/LockView.qml"
}
button_props=$(item_props Button)
check "LockView sets Button properties (parsed)" test -n "$button_props"
for p in $button_props; do
  case $p in
    enabled | visible | width | height | opacity) ;; # Item
    onClicked) check "Button.clicked signal" grep -Eq 'signal +clicked\(' "$SH/Ui/Button.qml" ;;
    on[A-Z]*) ;;
    *) check "Button.$p" has_prop "$p" "$SH/Ui/Button.qml" ;;
  esac
done
check "BorderSurface is a Rectangle" grep -Eq '^Rectangle *\{' "$SH/Ui/BorderSurface.qml"
check "BorderSurface.borderSpec" has_prop borderSpec "$SH/Ui/BorderSurface.qml"
for p in $(uses 'inputField\.border[A-Za-z]+' | sed 's/.*\.//'); do
  check "BorderSurface.$p" has_prop "$p" "$SH/Ui/BorderSurface.qml"
done
for p in $(item_props BorderSurface); do
  case $p in
    id | width | height | clip | color | radius | borderSpec) ;; # Rectangle/Item, or checked above
    *) check "BorderSurface.$p" has_prop "$p" "$SH/Ui/BorderSurface.qml" ;;
  esac
done

# --- helper binaries -----------------------------------------------------------------------------
# Every omarchy-* name in the patched clone is a helper binary, except the
# clone's own names (PAM services, the preview layer namespace).
for h in $(uses 'omarchy-[a-z][a-z0-9-]*[a-z0-9]'); do
  case $h in
    omarchy-lock-password | omarchy-lock-fingerprint | omarchy-lock-face | omarchy-lock-preview | omarchy-sl7-*) continue ;;
  esac
  check "helper binary bin/$h" test -x "$CK/bin/$h"
done
# What the app's own tooling and health check call.
for h in omarchy-hyprland-session-lock-stranded omarchy-hyprland-session-locked omarchy-restart-shell \
  omarchy-plugin-disable omarchy-shell; do
  check "helper binary bin/$h (overlay tooling)" test -x "$CK/bin/$h"
done

# --- bin/omarchy-shell ---------------------------------------------------------------------------------
# The health check relies on the qs ipc fallback and on the exact
# "Target not found." text reaching it as a failure.
check "omarchy-shell: qs ipc fallback" grep -Eq 'qs ipc .*call' "$CK/bin/omarchy-shell"
check "omarchy-shell: 'Target not found.' is mapped to a failure" awk '
  /"Target not found\."/ { on = 1 }
  on && /fail "\$output"/ { found = 1; exit }
  END { exit !found }' "$CK/bin/omarchy-shell"

# --- PluginRegistry.qml -----------------------------------------------------------------------------------
PR=$SH/services/PluginRegistry.qml
check "PluginRegistry: clone inherits its clonedFrom source's capabilities" bash -c "
  grep -Eq 'firstParty\[clonedFrom\]' '$PR' && grep -Eq '__hostCapabilities *= *source' '$PR'"
check "PluginRegistry: addDisabled() exists" grep -Eq 'function +addDisabled\(' "$PR"
check "PluginRegistry: enabling a clone disables its source (addDisabled on clonedFrom)" grep -Eq 'addDisabled\(config, *clonedFrom\)' "$PR"

# --- stock lock plugin --------------------------------------------------------------------------------------
M=$SH/plugins/lock/manifest.json
check "stock lock manifest exists" test -f "$M"
check "stock lock manifest id is omarchy.lock (what clonedFrom names)" jq -e '.id == "omarchy.lock"' "$M"
check "stock lock manifest declares the authentication capability" jq -e '.omarchy.capabilities | index("authentication")' "$M"
check "clone manifest clonedFrom is omarchy.lock" jq -e '.omarchy.clonedFrom == "omarchy.lock"' "$W/manifest.json"
if [[ -f $SH/plugins/lock/Service.qml && -f $SH/plugins/lock/LockView.qml ]]; then
  svc=$(sha256sum "$SH/plugins/lock/Service.qml" | cut -d' ' -f1)
  lv=$(sha256sum "$SH/plugins/lock/LockView.qml" | cut -d' ' -f1)
  if [[ $svc == "$LOCK_STOCK_SERVICE_SHA256" && $lv == "$LOCK_STOCK_LOCKVIEW_SHA256" ]]; then
    ok_ "stock lock files match omarchy $LOCK_STOCK_VERSION"
  else
    warn_ "stock lock files differ from the omarchy $LOCK_STOCK_VERSION hashes (the overlay was written against those; recheck)"
  fi
else
  warn_ "stock lock Service.qml/LockView.qml not found"
fi

printf '\n%s passed, %s failed, %s warnings\n' "$pass" "$fail" "$warn"
((fail == 0))
