#!/usr/bin/env bash
# Scenario `vt-switch-chord` (owner's first login, 2026-10-15): Ctrl+Alt+F3, the XF86Switch_VT_3 keysym after
# xkb, reaches casement's VT switch.
#
# Not runnable in the jail yet: exits 2 (SKIP), listed in gate/expected-skips.toml as FD-L03.
#
# What casement does with the chord is in core_loop/tty.rs `vt_chord`: on the tty backend only
# (`BackendKind::Tty`), a press whose keysym names a VT asks the seat session for it
# (`TtyBackend::request_vt` -> `Session::switch_vt`, tty/mod.rs) and swallows the key; on the headless backend
# it returns at once and the key goes on to a client as any other. The jail has no VT and no real seat, the
# headless casement logs nothing for the chord, and fake-logind (the jail's system bus) is not asked for a
# switch, so there is no report or log line to assert. The same behaviour is asserted with the fake
# session seam by casement's own cargo test (casement-testkit tests/it/tty/integration.rs, "Ctrl+Alt+F3 is
# XF86Switch_VT_3 after xkb"), which the lane gate runs; what this scenario would add is the chord through
# the whole keyboard path (keycap's output, xkb) of a running casement, and that needs either a tty backend
# on a fake session in the jail or a headless counter for the request. Both are casement work.
#
# Contract: require_jail first, only harness/lib, exits with plan 6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP vt-switch-chord: nothing observable in the jail (the headless backend ignores the VT chord and the jail has no VT; FD-L03)" >&2
exit 2
