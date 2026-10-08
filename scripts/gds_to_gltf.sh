#!/usr/bin/env bash
# ============================================================================
#  gds_to_gltf.sh -- turn a hardened run's GDS into a 3D glTF model.
#
#  Usage:  scripts/gds_to_gltf.sh [run-tag]      (default: submission)
#
#  Produces asic/viewer/<top>.gltf, which opens in any glTF viewer: a
#  browser viewer, Blender, or the VS Code glTF extension.  Each sky130
#  layer becomes an extruded solid at its real height in the stack, so you
#  are looking at the actual metal and via geometry.
#
#  Tiny Tapeout's own web viewer renders the GDS directly instead, and
#  wants a publicly reachable URL:
#      https://gds-viewer.tinytapeout.com/?process=SKY130&model=<url to .gds>
#  Pushing to GitHub gets that for free -- the gds workflow publishes the
#  GDS to GitHub Pages and links the viewer at it.
#
#  SPDX-FileCopyrightText: 2026 Jason van Aardt
#  SPDX-License-Identifier: CERN-OHL-S-2.0
# ============================================================================
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${1:-submission}"
gds="$(ls "$root/asic/work/$tag/runs/wokwi/final/gds/"*.gds 2>/dev/null | head -1)"
[[ -n "$gds" ]] || { echo "no GDS for run '$tag' - has it finished hardening?" >&2; exit 2; }

tool="${GDS2GLTF:-$root/asic/gds2gltf/gds2gltf.py}"
if [[ ! -f "$tool" ]]; then
    echo "fetching GDS2glTF into asic/gds2gltf"
    git clone --depth 1 https://github.com/mbalestrini/GDS2glTF "$root/asic/gds2gltf"
fi

PY="${SID_EDA:-/home/van496/eda2}/bin/python"
"$PY" -c "import gdspy, pygltflib, triangle, numpy" 2>/dev/null || \
    "$PY" -m pip install -q gdspy pygltflib triangle numpy

mkdir -p "$root/asic/viewer"
work="$(mktemp -d)"
cp "$gds" "$work/"
( cd "$work" && "$PY" "$tool" "$(basename "$gds")" )

out="$root/asic/viewer/$(basename "${gds%.gds}").gltf"
mv "$work/$(basename "$gds").gltf" "$out"
rm -rf "$work"

echo
echo "3D model written: $out"
echo "size: $(du -h "$out" | cut -f1)"
