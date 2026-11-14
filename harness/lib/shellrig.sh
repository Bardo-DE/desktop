# What the scenarios that drive the whole shell on casement share: sill's daemon on casement's private
# bus, real keys through one `casementctl debug inject` session, foot windows to switch between, and
# readers for `casementctl debug windows`. Jail only. The caller has sourced all.sh and scenario.sh,
# called require_jail and scenario_need, and set OUT_DIR (the scenario's directory, scenario_out).
#
# Sourcing this file brings in sill's dev/lib (start_compositor, scratch_new, launch_daemon, sill,
# input, key, shot, capture, mapped, ...) from the private checkout scenario-build.sh made.
#
#   rig_up [DAEMON ARGS...]   casement up, the scratch tree, the daemon, devices plugged, the input session
#   rig_down                  everything above ended; the foot windows too
#   rig_foot APP              a foot window with app id APP (waits until it is mapped and has the focus)
#   win_active                the app id of the active window (empty when none)
#   win_wait_active APP [S]   up to S seconds (default 5) for APP to be the active window
#   win_frame APP             "x y w h" of APP's window
#
# The daemon shares the jail's XDG_RUNTIME_DIR (not sill's scratch one) and casement starts with the
# sill build on its PATH: casement runs `sill launcher toggle`, `sill switcher next`, `sill power-menu
# open` for the chords, and those must find this run's daemon, as they do in a login.
# RIG_ENV (an array of NAME=VALUE, set before rig_up) adds variables to every in_env call.

export SILL_COMPOSITOR=casement SILL_PREBUILT=1 SILL_PROFILE=debug
export CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" CASEMENT_REPO="$SCEN_SIB/casement" CASEMENT_TOOLS="$SCEN_TOOLS"
# shellcheck source=/dev/null
source "$SCEN_SRC/sill/dev/lib/all.sh"
# shellcheck source=/dev/null
source "$CASEMENT_REPO/dev/lib/bus.sh"

RIG_ENV=()
RIG_PIDS=()

rig_up() {
  PATH="$(dirname "$SILL_BIN"):$SCEN_TOOLS/bin:$PATH"
  export PATH
  start_compositor || return 1
  scratch_new
  IN_ENV_EXTRA+=("XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:?rig_up: XDG_RUNTIME_DIR is not set}" "${RIG_ENV[@]}")
  build || return 1
  launch_daemon "$@" || return 1
  output_name >/dev/null || return 1
  # Casement's session has no devices until some are plugged; the input session below needs them.
  casementctl debug inject "device plug keyboard" "device plug pointer" >>"$OUT_DIR/casement-up.log" 2>&1 || true
  start_input || return 1
}

rig_down() {
  local pid
  for pid in "${RIG_PIDS[@]}"; do
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  done
  RIG_PIDS=()
  stop_input
  stop_daemon
  stop_compositor
  scratch_drop
}

# A foot window with app id $1 running `sleep`, in the daemon's environment. Waits for it to map and
# to hold the focus; a window that maps unfocused is clicked once (the first click only activates).
rig_foot() {
  in_env "$SCEN_TOOLS/bin/foot" --app-id "$1" sleep 3600 >"$OUT_DIR/foot-$1.log" 2>&1 &
  RIG_PIDS+=("$!")
  casementctl debug wait mapped "$1" --timeout 15000 >>"$OUT_DIR/windows.log" 2>&1 \
    || { echo "$1 never mapped (see $OUT_DIR/foot-$1.log)" >&2; return 1; }
  win_wait_active "$1" 3 && return 0
  local x y w h
  read -r x y w h <<<"$(win_frame "$1")"
  click $(( x + w / 2 )) $(( y + h / 2 )) || return 1
  win_wait_active "$1" 5 || { echo "$1 never became the active window" >&2; return 1; }
}

win_active() {
  casementctl debug windows 2>/dev/null | python3 -I -c '
import json, sys
for w in json.load(sys.stdin):
    if w.get("active"):
        print(w.get("class"))
        break'
}

win_wait_active() {
  for _ in $(seq $(( ${2:-5} * 10 ))); do
    [ "$(win_active)" = "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

win_frame() {
  casementctl debug windows | python3 -I -c '
import json, sys
for w in json.load(sys.stdin):
    if w.get("class") == sys.argv[1]:
        print(*w["frame"])
        break' "$1"
}

# until TENTHS CMD...: up to TENTHS tenths of a second for CMD to succeed.
rig_until() {
  local tenths=$1; shift
  for _ in $(seq "$tenths"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# The tails of the logs a failed run leaves, on stderr.
rig_logs() {
  echo "--- daemon.log (tail)" >&2; tail -20 "$OUT_DIR/daemon.log" >&2 2>/dev/null
  echo "--- casement-up.log (tail)" >&2; tail -20 "$OUT_DIR/casement-up.log" >&2 2>/dev/null
  [ -z "${CASEMENT_ENV:-}" ] || { echo "--- casement.log (tail)" >&2; tail -20 "$(dirname "$CASEMENT_ENV")/casement.log" >&2 2>/dev/null; }
}
