#!/usr/bin/env bash
# Scenario `pointer-natural-scroll` (owner's first login, 2026-10-15): with no casement settings file a
# mouse wheel scrolls natural-direction, content following the finger, the Mac's default for mice too;
# `[pointer] natural_scroll = "off"` in casement/settings.toml turns it off. In the jail.
#
# The client is casement's `casement-probe session` (crates/casement-testclient in the casement checkout):
# foot cannot report axis events, and no other client of the harness logs wl_pointer. It binds a
# wl_pointer and its protocol transcript records `< wl_pointer#N.axis(time, axis, value)`; a full-output
# layer surface under the pointer receives the wheel. Casement runs twice (a fresh run state each, stepped
# clock), once with no settings file and once with the file below; each run injects one wheel detent
# the way a mouse reports it when the wheel is rolled forward, away from the user (`axis vertical -15`:
# the traditional direction scrolls the content up the page, i.e. a negative value), and reads the value
# the client receives:
#   schema    `casement --write-schema` lists pointer.natural_scroll with the default on (casement.settings.toml,
#             one [[key]] per setting with `path` and `default`); runs in the jail, needs no compositor
#   default   no settings file: the client receives +15 (natural: the content follows the finger)
#   off       settings.toml with `[pointer] natural_scroll = "off"`: the client receives -15
#
# Natural scrolling is a libinput device setting that casement applies to physical devices on the tty backend
# (core_loop/tty.rs; backend/input/libinput_real.rs). The headless backend's injection (casementctl debug inject)
# enters after libinput, so both runs may well deliver -15; then the delivery steps cannot show anything and end
# with exit 2 (finding FD-L02, listed in gate/expected-skips.toml) rather than pass vacuously. If injection is ever
# made to go through the device profile, the same script starts asserting.
#
# budget: 120
# Exit: 0 pass | 1 a step failed | 2 the delivery cannot be observed in the jail (FD-L02) | 3 artefacts missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../harness/lib/all.sh"
source "$HERE/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/casement-probe" \
  "$SCEN_TOOLS/bin/fake-logind"

export CASEMENT_TOOLS="$SCEN_TOOLS" CASEMENT_REPO="$SCEN_SIB/casement"
# shellcheck source=/dev/null
source "$SCEN_SIB/casement/dev/lib/compositor.sh"
# shellcheck source=/dev/null
source "$SCEN_SIB/casement/dev/lib/probe.sh"
# shellcheck source=/dev/null
source "$SCEN_SIB/casement/dev/lib/wait.sh"
OUT_DIR=$(scenario_out pointer-natural-scroll)
AXIS_EVENT='^< wl_pointer#[0-9]+\.axis\('
RAW=-15          # one detent, the wheel rolled forward, as a mouse reports it before natural scrolling
NATURAL=15
GOT_DEFAULT= GOT_OFF=

cleanup() {
  probe_stop_all
  stop_compositor || true
}
trap cleanup EXIT

# axis_value SESSION_LABEL SETTINGS_TEXT: casement up on a fresh run state (the settings text written first, when
# not empty), a layer under the pointer, one wheel detent; prints the value the client received.
axis_value() {
  local label=$1 settings=$2 line value
  casement_new_state
  if [ -n "$settings" ]; then
    mkdir -p "$CASEMENT_STATE/config/casement"
    printf '%s\n' "$settings" >"$CASEMENT_STATE/config/casement/settings.toml"
  fi
  start_compositor >&2 || return 1
  inject "device plug keyboard" "device plug pointer" "move 960 540" >/dev/null || return 1
  probe_start P >&2 || return 1
  probe_do P layer c level=top kbd=none size=1920x1080 anchor=top,bottom,left,right >&2 || return 1
  probe_wait P '^probe: layer-mapped c ' >&2 || return 1
  probe_sync P >&2 || return 1
  inject "move 961 541" "axis vertical $RAW" "sleep 50" >/dev/null || return 1
  probe_wait P "$AXIS_EVENT" >&2 || { echo "$label: the client received no axis event" >&2; return 1; }
  probe_sync P >&2
  probe_log P >"$OUT_DIR/$label.transcript.log"
  line=$(grep -E "$AXIS_EVENT" "$OUT_DIR/$label.transcript.log" | tail -n 1)
  value=$(sed -n 's/.*(\(.*\))$/\1/p' <<<"$line" | awk -F', *' '{print $NF}' | grep -Eo -- '-?[0-9]+(\.[0-9]+)?' | tail -n 1)
  probe_stop_all
  stop_compositor >&2
  [ -n "$value" ] || { echo "$label: cannot read a value from '$line'" >&2; return 1; }
  echo "$value"
}

same_number() { python3 -I -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 0.01 else 1)' "$1" "$2"; }

step_schema() {
  local dir="$OUT_DIR/schema" file
  rm -rf "$dir"; mkdir -p "$dir"
  "$SCEN_TOOLS/bin/casement" --write-schema "$dir" >"$OUT_DIR/schema.log" 2>&1 || { cat "$OUT_DIR/schema.log" >&2; return 1; }
  file="$dir/casement.settings.toml"
  [ -s "$file" ] || { echo "casement --write-schema wrote no casement.settings.toml in $dir: $(ls "$dir")" >&2; return 1; }
  python3 -I - "$file" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    keys = {k["path"]: k for k in tomllib.load(handle)["key"]}
key = keys.get("pointer.natural_scroll")
if key is None:
    sys.exit("the schema has no pointer.natural_scroll key")
if str(key["default"]).lower() not in ("on", "true"):
    sys.exit("the schema's default for pointer.natural_scroll is %r, not on" % (key["default"],))
print("schema: pointer.natural_scroll defaults to on", file=sys.stderr)
PY
}

step_default() {
  GOT_DEFAULT=$(axis_value default "") || return 1
  echo "no settings file: the client received $GOT_DEFAULT for a raw $RAW" >&2
}

step_off() {
  GOT_OFF=$(axis_value off $'[pointer]\nnatural_scroll = "off"') || return 1
  echo "natural_scroll = \"off\": the client received $GOT_OFF for a raw $RAW" >&2
}

step_verdict() {
  if same_number "$GOT_DEFAULT" "$GOT_OFF"; then
    echo "FD-L02: the setting changed nothing the client receives ($GOT_DEFAULT both ways): injection enters after libinput, where natural scrolling is applied; this needs the tty backend (real or fake libinput session), not the jail" >&2
    return 2
  fi
  same_number "$GOT_DEFAULT" "$NATURAL" || { echo "by default the client received $GOT_DEFAULT, not natural $NATURAL" >&2; return 1; }
  same_number "$GOT_OFF" "$RAW" || { echo "with natural_scroll off the client received $GOT_OFF, not $RAW" >&2; return 1; }
}

for name in step_schema step_default step_off step_verdict; do
  STEP_BUDGET=45 step "$name" "$name" || [ "$?" = 2 ] || break
done
steps_exit
