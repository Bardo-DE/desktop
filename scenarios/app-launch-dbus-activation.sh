#!/usr/bin/env bash
# Scenario `app-launch-dbus-activation` (owner's first login, 2026-10-15): opening an app from the launcher
# (type the name, Enter) maps a window, by both launch paths sill uses, in the jail.
#
# The jail, a headless casement and sill's daemon come up as in sill-boots-on-casement, except that the
# private bus has a service directory (the stock private bus has none, so nothing is ever activated):
# a copy of harness/private-bus.conf plus <servicedir> and a 3 s service_start_timeout, started before
# casement and handed to it (casement's dev/lib/bus.sh skips its own bus when CASEMENT_BUS_PID is
# alive). Fixtures, all under this scenario's directory (the daemon's XDG_DATA_DIRS is only that):
#   share/applications/org.example.ZzPlain.desktop   a plain Exec app: foot with app id org.example.ZzPlain
#   share/applications/org.example.ZzDbus.desktop     DBusActivatable=true, Exec= unused
#   share/dbus-1/services/org.example.ZzDbus.service  Exec: harness/fixtures/dbus-app.py, a GApplication that
#                                                     opens foot (app id org.example.ZzDbus) on Activate
#   share/applications/org.example.ZzGhost.desktop    DBusActivatable=true whose service never claims its name
#   share/dbus-1/services/org.example.ZzGhost.service Exec: sleep 20
# The bus's activation environment gets WAYLAND_DISPLAY and XDG_RUNTIME_DIR (dbus-update-activation-
# environment on the private bus), as the real session does (session/desktop-session publish_environment).
# Steps:
#   boot      the bus, casement, sill's daemon, the input session
#   session   the session script publishes WAYLAND_DISPLAY to the activation environment (a text check)
#   plain     launcher open, "zzplain" typed with real keys, Enter: a toplevel with app id org.example.ZzPlain maps
#   dbus      the same for "zzdbus": a toplevel with app id org.example.ZzDbus maps through Activate on the bus
#   ghost     "zzghost", Enter: the launcher closes and the daemon keeps answering (no hang); a visible failure
#             ("couldn't open" in `sill notifications status`) is looked for, and its absence is a FINDING
#             printed in the log, not a failure
#
# budget: 180
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../harness/lib/all.sh"
source "$HERE/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_TOOLS/bin/foot" "$SCEN_BUILD/sill-target/debug/sill" "$HERE/../harness/fixtures/dbus-app.py" \
  /usr/bin/dbus-update-activation-environment /usr/bin/python3
OUT_DIR=$(scenario_out app-launch-dbus-activation)
source "$HERE/../harness/lib/shellrig.sh"

SHARE="$OUT_DIR/share"
PLAIN=org.example.ZzPlain DBUS=org.example.ZzDbus GHOST=org.example.ZzGhost
BUS_PID=
trap 'rig_down; [ -z "$BUS_PID" ] || kill "$BUS_PID" 2>/dev/null' EXIT

write_fixtures() {
  rm -rf "$SHARE"
  mkdir -p "$SHARE/applications" "$SHARE/dbus-1/services"
  local foot="$SCEN_TOOLS/bin/foot" app="$HERE/../harness/fixtures/dbus-app.py"
  cat >"$SHARE/applications/$PLAIN.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=ZzPlain Fixture
Exec=$foot --app-id $PLAIN sleep 3600
DESKTOP
  cat >"$SHARE/applications/$DBUS.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=ZzDbus Fixture
Exec=$foot --app-id $DBUS sleep 3600
DBusActivatable=true
DESKTOP
  cat >"$SHARE/dbus-1/services/$DBUS.service" <<SERVICE
[D-BUS Service]
Name=$DBUS
Exec=/usr/bin/python3 $app $DBUS $foot
SERVICE
  cat >"$SHARE/applications/$GHOST.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=ZzGhost Fixture
Exec=/bin/true
DBusActivatable=true
DESKTOP
  cat >"$SHARE/dbus-1/services/$GHOST.service" <<SERVICE
[D-BUS Service]
Name=$GHOST
Exec=/bin/sleep 20
SERVICE
}

# The private bus with the service directory, recorded in casement's run state so that start_compositor
# uses it instead of starting its own.
start_fixture_bus() {
  local conf="$OUT_DIR/bus.conf" out address
  sed "s#</busconfig>#  <servicedir>$SHARE/dbus-1/services</servicedir>\n  <limit name=\"service_start_timeout\">3000</limit>\n</busconfig>#" \
    "$HARNESS_DIR/private-bus.conf" >"$conf"
  out=$(dbus-daemon --config-file "$conf" --fork --print-address=1 --print-pid=1) || return 1
  address=$(sed -n 1p <<<"$out")
  BUS_PID=$(sed -n 2p <<<"$out")
  casement_new_state
  # The addresses go in the run's env file only (a subshell: env_set also exports), because
  # start_casement refuses a bus that is this shell's own; casement's bus_up reads them from the file.
  (
    env_set DBUS_SESSION_BUS_ADDRESS "$address"
    env_set DBUS_SYSTEM_BUS_ADDRESS "$address"
  )
  env_set CASEMENT_BUS_PID "$BUS_PID"
}

step_boot() {
  write_fixtures
  start_fixture_bus || return 1
  RIG_ENV=("XDG_DATA_DIRS=$SHARE")
  rig_up || return 1
  # The activation environment the real session publishes (session/desktop-session publish_environment).
  DBUS_SESSION_BUS_ADDRESS="$BUS" dbus-update-activation-environment "WAYLAND_DISPLAY=$WL" "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
    || { echo "dbus-update-activation-environment failed on the private bus" >&2; return 1; }
}

step_session() {
  grep -A8 '^publish_environment()' "$HERE/../session/desktop-session" | grep -q 'WAYLAND_DISPLAY' \
    && grep -q 'dbus-update-activation-environment' "$HERE/../session/desktop-session" \
    || { echo "session/desktop-session no longer publishes WAYLAND_DISPLAY to the activation environment" >&2; return 1; }
}

# open_and_type WORD TITLE: the launcher open, WORD typed with real keys; waits until the daemon lists a row
# titled TITLE (which the query alone, echoed in the rows, would not prove).
open_and_type() {
  sill launcher open >>"$OUT_DIR/launcher.log" 2>&1 || return 1
  rig_until 100 mapped "sill-launcher-$(output_name)" || { echo "the launcher never mapped" >&2; return 1; }
  sleep 0.5
  input "type $1" || return 1
  rig_until 50 launcher_has "$2" || {
    echo "typing '$1' gave no row '$2' (keys not delivered to the launcher, or no such app listed): $(sill debug launcher-rows 2>&1 | head -c 600)" >&2
    return 1
  }
}

# launcher_has TITLE: the launcher's rows mention TITLE.
launcher_has() { sill debug launcher-rows 2>/dev/null | grep -qi -- "$1"; }

launch_from_launcher() {
  local word=$1 title=$2 app=$3
  open_and_type "$word" "$title" || return 1
  shot "$OUT_DIR/launcher-$word.png" >/dev/null 2>&1 || true
  key Return || return 1
  casementctl debug wait mapped "$app" --timeout 15000 >>"$OUT_DIR/windows.log" 2>&1 \
    || { echo "no toplevel with app id $app mapped after Enter on '$word' (daemon.log tail follows)" >&2; tail -15 "$OUT_DIR/daemon.log" >&2; return 1; }
  casementctl debug windows | grep -q "\"class\":\"$app\"" || { echo "$app is not in 'debug windows'" >&2; return 1; }
  rig_until 50 launcher_closed || { echo "the launcher stayed open after Enter" >&2; return 1; }
}

launcher_closed() { ! mapped "sill-launcher-$(output_name)"; }

step_plain() { launch_from_launcher zzplain "ZzPlain Fixture" "$PLAIN"; }
step_dbus() {
  launch_from_launcher zzdbus "ZzDbus Fixture" "$DBUS" && return 0
  echo "the bus ($BUS) can activate: $(DBUS_SESSION_BUS_ADDRESS="$BUS" dbus-send --session --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListActivatableNames 2>&1 | grep -o '"[^"]*"' | tr '\n' ' ')" >&2
  return 1
}

step_ghost() {
  open_and_type zzghost "ZzGhost Fixture" || return 1
  key Return || return 1
  # Not a hang: the launcher goes away, the daemon answers, and the launcher opens again, within seconds
  # of Enter, while the 3 s activation timeout of the bus is still running or has just ended.
  rig_until 50 launcher_closed || { echo "the launcher stayed open after Enter on an app that never starts" >&2; return 1; }
  sill ping >/dev/null 2>&1 || { echo "the daemon does not answer after launching a dead DBusActivatable app" >&2; return 1; }
  sill launcher open >>"$OUT_DIR/launcher.log" 2>&1 \
    && rig_until 50 mapped "sill-launcher-$(output_name)" \
    || { echo "the launcher cannot be opened again after a dead DBusActivatable app" >&2; return 1; }
  sill launcher close >>"$OUT_DIR/launcher.log" 2>&1
  if casementctl debug windows | grep -q "\"class\":\"$GHOST\""; then echo "a window appeared for $GHOST" >&2; return 1; fi
  # Visible failure: sill posts a notice ("<App> couldn't open") for a launch that failed.
  if rig_until 200 ghost_notice; then
    echo "the failed launch is told to the person: $(sill notifications status 2>&1 | grep -o "[^\"]*couldn't open[^\"]*" | head -1)" >&2
  else
    echo "FINDING: a DBusActivatable app that never appears shows the person nothing (no 'couldn't open' notice within 20 s)" | tee -a "$OUT_DIR/findings.log" >&2
  fi
}

ghost_notice() { sill notifications status 2>&1 | grep -q "couldn't open"; }

run_steps step_boot step_session step_plain step_dbus step_ghost
[ "$STATUS" = 0 ] || rig_logs
exit "$STATUS"
