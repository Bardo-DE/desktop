#!/usr/bin/env bash
# Scenario `app-switcher-cmd-tab` (owner's first login, 2026-10-15): Cmd+Tab switches apps the way a Mac
# user expects, driven with the keys keycap delivers on our desktop, in the jail.
#
# On our desktop keycap writes Cmd+Tab as Super+Tab (sill/dist/keycap/keycap.toml) and casement runs
# `sill switcher next` for it (casement keymap/shell.rs). Three foot windows (app ids org.example.sw.a,
# .b, .c, opened in that order) are driven through one `casementctl debug inject` session with real key
# events. The scenario keeps its own most-recently-used list from what it observes and expects:
#   tap        Super down, Tab, Super up: the previous app becomes the active window, no panel left
#              over; repeated 4 times in a row (the owner saw it work once, then not): each must work
#   hold       Super down, Tab, Tab, (hold past the show delay) Super up: the THIRD app in the list is
#              active after the release, and the switcher panel (`sill-switcher-<out>`) was mapped before
#              the release (captured: switcher-hold.png, the whole output: switcher-hold-output.png)
#   (keycap holds Super across Cmd+Tab, `hold = "while_held"`, keycap f77b789, so its keys are the hold's)
#
# budget: 150
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../harness/lib/all.sh"
source "$HERE/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_TOOLS/bin/foot" "$SCEN_BUILD/sill-target/debug/sill"
OUT_DIR=$(scenario_out app-switcher-cmd-tab)
source "$HERE/../harness/lib/shellrig.sh"

A=org.example.sw.a B=org.example.sw.b C=org.example.sw.c
MRU=()   # app ids, most recent first, as the scenario expects the switcher to order them
SWITCHER=
trap rig_down EXIT

step_boot() {
  rig_up || return 1
  SWITCHER="sill-switcher-$(output_name)"
  local app
  for app in "$A" "$B" "$C"; do rig_foot "$app" || return 1; done
  MRU=("$C" "$B" "$A")
  [ "$(win_active)" = "$C" ] || { echo "the last window opened is not active: $(win_active)" >&2; return 1; }
}

# promote APP: APP to the front of the expected list.
promote() {
  local app=$1 rest=() one
  for one in "${MRU[@]}"; do [ "$one" = "$app" ] || rest+=("$one"); done
  MRU=("$app" "${rest[@]}")
}

# expect_active WHAT APP: APP is the active window within 4 s; the list follows.
expect_active() {
  win_wait_active "$2" 4 || {
    echo "$1: expected $2 active, but the active window is '$(win_active)' (expected order: ${MRU[*]})" >&2
    return 1
  }
  promote "$2"
}

# panel_gone: the switcher panel is no longer mapped within 3 s.
panel_gone() { rig_until 30 not_mapped; }
not_mapped() { ! mapped "$SWITCHER"; }

tap() { input "key Super_L down" "sleep 30" "key Tab down" "sleep 30" "key Tab up" "sleep 30" "key Super_L up" "sleep 150"; }

step_tap() {
  local round want
  for round in 1 2 3 4; do
    want="${MRU[1]}"
    tap || return 1
    expect_active "quick tap $round of 4 (Super+Tab)" "$want" || { sill switcher cancel >/dev/null 2>&1; return 1; }
    panel_gone || { echo "quick tap $round: the switcher panel stayed up" >&2; return 1; }
  done
}

step_hold() {
  local want="${MRU[2]}"
  input "key Super_L down" "sleep 40" "key Tab down" "sleep 30" "key Tab up" "sleep 60" \
    "key Tab down" "sleep 30" "key Tab up" || return 1
  if ! rig_until 40 mapped "$SWITCHER"; then
    echo "hold: the switcher panel was not shown while Super was held" >&2
    input "key Super_L up" >/dev/null; sill switcher cancel >/dev/null 2>&1
    return 1
  fi
  capture "$SWITCHER" "$OUT_DIR/switcher-hold.png"
  shot "$OUT_DIR/switcher-hold-output.png" >/dev/null 2>&1 || true
  input "key Super_L up" "sleep 150" || return 1
  expect_active "hold (Super+Tab, Tab, release)" "$want" || { sill switcher cancel >/dev/null 2>&1; return 1; }
  panel_gone || { echo "hold: the switcher panel stayed up after the release" >&2; return 1; }
}

run_steps step_boot step_tap step_hold
[ "$STATUS" = 0 ] || rig_logs
exit "$STATUS"
