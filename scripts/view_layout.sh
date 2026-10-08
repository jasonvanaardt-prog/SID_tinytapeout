#!/usr/bin/env bash
# ============================================================================
#  view_layout.sh -- open a hardened run's layout.
#
#  Usage:  scripts/view_layout.sh [run-tag] [viewer]
#
#      run-tag   a directory under asic/work   (default: submission)
#      viewer    openroad | klayout | magic | gltf   (default: openroad)
#
#  openroad  the placed-and-routed database itself: every layer, every net,
#            timing paths, congestion and power-density heatmaps.  This is
#            the one to use for looking at P&R results.  Needs a display.
#  klayout   the final GDS as the foundry sees it.  Tools > "2.5d View"
#            gives a rotatable extruded-layer view of the stack.
#  magic     the Magic view, useful for interactive DRC and device probing.
#  gltf      convert the GDS to a glTF 3D model (scripts/gds_to_gltf.sh)
#            and print where it landed -- open it in any 3D viewer.
#
#  SPDX-FileCopyrightText: 2026 Jason van Aardt
#  SPDX-License-Identifier: CERN-OHL-S-2.0
# ============================================================================
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${1:-submission}"
viewer="${2:-openroad}"
run="$root/asic/work/$tag/runs/wokwi"

[[ -d "$run" ]] || { echo "no such run: $run" >&2; echo "available:" >&2; ls "$root/asic/work" 2>/dev/null >&2; exit 2; }

SID_EDA_QUIET=1 source "$root/scripts/eda_env.sh"

case "$viewer" in
  openroad)
    # The last ODB the flow wrote is the fully routed, filled database.
    odb="$(ls -t "$run"/*/*.odb 2>/dev/null | head -1)"
    [[ -n "$odb" ]] || { echo "no .odb found under $run" >&2; exit 2; }
    echo "opening $odb"
    echo "(each step directory under the run has its own .odb, so earlier"
    echo " stages of the flow can be opened the same way)"
    script="$(mktemp --suffix=.tcl)"
    printf 'read_db %s\n' "$odb" > "$script"
    trap 'rm -f "$script"' EXIT
    openroad -gui -no_init "$script"
    ;;
  klayout)
    command -v klayout >/dev/null || { echo "no klayout binary on PATH." >&2; exit 2; }
    gds=("$run/final/gds/"*.gds)
    echo "opening ${gds[0]}"
    echo "In KLayout: Tools > 2.5d View for a rotatable 3D view of the layer stack."
    exec klayout "${gds[0]}"
    ;;
  magic)
    mag="$(ls -t "$run"/*magic*/*.mag 2>/dev/null | head -1)"
    [[ -n "$mag" ]] || { echo "no .mag found under $run" >&2; exit 2; }
    exec magic -T "$PDK_ROOT/$PDK/libs.tech/magic/$PDK.tech" "$mag"
    ;;
  gltf)
    exec "$root/scripts/gds_to_gltf.sh" "$tag"
    ;;
  *)
    echo "unknown viewer: $viewer (openroad | klayout | magic | gltf)" >&2
    exit 2
    ;;
esac
