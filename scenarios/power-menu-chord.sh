#!/usr/bin/env bash
# Scenario `power-menu-chord` (owner's first login, 2026-10-15): Shift+Super+Q (what keycap sends for
# Shift+Cmd+Q) opens sill's power menu, which lists Log Out, Restart and Shut Down; Escape closes it.
# In the jail, with casement running `sill power-menu open` for the chord (casement keymap/shell.rs).
#
# SAFETY. The daemon runs with `--session-dry-run RECORD`: a session action would be recorded, never sent
# to logind. The steps that press keys run only after the dry run is proven from the daemon's own log
# (prove_dry_run, as sill's power-menu.sh does); the only key pressed in the menu is Escape, and the record
# file must hold no `would=` line at the end.
#   boot     the daemon in its dry run, the input session; the dry run proven
#   chord    Shift_L, Super_L, q down and up: `sill-power-menu-<out>` maps with the sheet's pixels (captured:
#            power-menu.png, and the whole output: power-menu-output.png); the daemon logs `power_menu.offers=`
#            naming Log Out, Restart and Shut Down
#   escape   Escape (a real key; the menu holds the compositor's keyboard) closes it; nothing was recorded
#
# budget: 90
# Exit: 0 pass | 1 a step failed | 2 outside the jail or the dry run could not be proven | 3 artefacts missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../harness/lib/all.sh"
source "$HERE/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_BUILD/sill-target/debug/sill"
OUT_DIR=$(scenario_out power-menu-chord)
source "$HERE/../harness/lib/shellrig.sh"

RECORD="$OUT_DIR/dry-run.record"
MENU=
trap rig_down EXIT

step_boot() {
  : >"$RECORD"
  rig_up --session-dry-run "$RECORD" || return 1
  MENU="sill-power-menu-$(output_name)"
  prove_dry_run power_menu || { echo "the dry run is not proven: no keys are pressed" >&2; return 2; }
}

step_chord() {
  [ "$DRY_RUN" = proven ] || return 2
  mapped "$MENU" && { echo "the power menu is mapped before the chord" >&2; return 1; }
  input "key Shift_L down" "key Super_L down" "sleep 30" "key q down" "sleep 40" "key q up" "key Super_L up" "key Shift_L up" "sleep 100" || return 1
  wait_surface "$MENU" 30 up || { echo "Shift+Super+Q did not open the power menu ($MENU never mapped)" >&2; return 1; }
  sleep 0.7 # the sheet's peek-in
  capture "$MENU" "$OUT_DIR/power-menu.png" || { echo "no capture of the open menu" >&2; return 1; }
  shot "$OUT_DIR/power-menu-output.png" >/dev/null 2>&1 || true
  [ "$(opaque_pixels "$OUT_DIR/power-menu.png")" -gt 50000 ] || { echo "the power menu mapped but drew no sheet" >&2; return 1; }
  local offers label
  offers=$(grep 'power_menu.offers=' "$OUT_DIR/daemon.log" | tail -n 1)
  for label in "Log Out" "Restart" "Shut Down"; do
    grep -q -- "$label" <<<"$offers" || { echo "the menu does not offer '$label': ${offers:-no power_menu.offers line}" >&2; return 1; }
  done
  echo "$offers" >&2
}

step_escape() {
  [ "$DRY_RUN" = proven ] || return 2
  rig_until 30 grep -q 'power_menu.keyboard=held' "$OUT_DIR/daemon.log" \
    || { echo "the open menu does not hold the keyboard: Escape cannot reach it" >&2; return 1; }
  key Escape || return 1
  wait_surface "$MENU" 30 down || { echo "Escape did not close the power menu" >&2; return 1; }
  ! grep -q 'would=' "$RECORD" || { echo "something was recorded as chosen in the menu: $(cat "$RECORD")" >&2; return 1; }
}

run_steps step_boot step_chord step_escape
[ "$STATUS" = 0 ] || rig_logs
exit "$STATUS"
