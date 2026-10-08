#!/usr/bin/env bash
# ============================================================================
#  harden_local.sh -- run the Tiny Tapeout GDS flow locally on this project.
#
#  Reproduces what TinyTapeout/tt-gds-action does in CI: build the
#  user_config.json that tt_tool.py --create-user-config would write
#  (DESIGN_NAME, VERILOG_FILES, DIE_AREA, the tile's power DEF template,
#  VDD/GND pin names and the top metal layer, all from info.yaml), merge it
#  over the project's own src/config.json, and run OpenLane on the result.
#
#  Usage:
#     scripts/harden_local.sh [options]
#        --period NS     override CLOCK_PERIOD
#        --density P     override PL_TARGET_DENSITY_PCT
#        --tiles WxH     override the tile size from info.yaml
#        --tag NAME      run tag, default "local"
#        --to STEP       stop after this OpenLane step, e.g.
#                        OpenROAD.STAPrePNR for a fast synthesis+STA pass
#        --set K=V       override any other OpenLane variable, repeatable
#
#  Anything not overridden comes from the committed config, so the default
#  invocation hardens what CI would.
#
#  SPDX-FileCopyrightText: 2026 Jason van Aardt
#  SPDX-License-Identifier: CERN-OHL-S-2.0
# ============================================================================
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PDK_ROOT="${PDK_ROOT:-/home/van496/pdk}"
OL_PYTHON="${OL_PYTHON:-/home/van496/eda2/bin/python}"
EDA_BIN="${EDA_BIN:-/home/van496/eda2/bin}"
YS_BIN="${YS_BIN:-/home/van496/ys41/bin}"
OR_BIN="${OR_BIN:-/home/van496/or_env/bin}"
WORK="${WORK:-$root/asic/work}"
TT_TOOLS="${TT_TOOLS:-$root/asic/tt-support-tools}"

period=""; density=""; tiles=""; tag="local"; to_step=""
overrides=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --period)  period="$2";  shift 2 ;;
        --density) density="$2"; shift 2 ;;
        --tiles)   tiles="$2";   shift 2 ;;
        --tag)     tag="$2";     shift 2 ;;
        --to)      to_step="$2"; shift 2 ;;
        --set)     overrides+=("$2"); shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

top="$(sed -n 's/^  top_module: *"\([^"]*\)".*/\1/p' "$root/info.yaml")"
[[ -n "$tiles" ]] || tiles="$(sed -n 's/^  tiles: *"\([^"]*\)".*/\1/p' "$root/info.yaml")"

[[ -d "$TT_TOOLS/tech/sky130A/def" ]] || {
    echo "tt-support-tools not found at $TT_TOOLS" >&2
    echo "clone it: git clone https://github.com/TinyTapeout/tt-support-tools $TT_TOOLS" >&2
    exit 2; }

die_area="$(sed -n "s/^$tiles: *\"\(.*\)\"/\1/p" "$TT_TOOLS/tech/sky130A/tile_sizes.yaml")"
[[ -n "$die_area" ]] || { echo "unsupported tile size: $tiles" >&2; exit 2; }

# Lay the workspace out the way the CI job does: project at the top, the
# support-tools checkout in ./tt.
ws="$WORK/$tag"
rm -rf "$ws"
mkdir -p "$ws/src" "$ws/runs/wokwi" "$ws/tt/tech/sky130A"
cp "$root"/src/*.v "$root/src/config.json" "$ws/src/"
cp "$root/info.yaml" "$ws/"
cp -r "$TT_TOOLS/tech/sky130A/def" "$ws/tt/tech/sky130A/"

# Sources in the order info.yaml lists them, which is the order CI uses.
sources=$("$OL_PYTHON" - "$root/info.yaml" <<'PY'
import sys, yaml
info = yaml.safe_load(open(sys.argv[1]))
print(",".join(f'"dir::{s}"' for s in info["project"]["source_files"]))
PY
)

cat > "$ws/src/user_config.json" <<JSON
{
    "DESIGN_NAME": "$top",
    "VERILOG_FILES": [$sources],
    "DIE_AREA": "$die_area",
    "FP_DEF_TEMPLATE": "dir::../tt/tech/sky130A/def/tt_block_${tiles}_pg.def",
    "VDD_PIN": "VPWR",
    "GND_PIN": "VGND",
    "RT_MAX_LAYER": "met4"
}
JSON

"$OL_PYTHON" - "$ws" "$period" "$density" "${overrides[@]+"${overrides[@]}"}" <<'PY'
import json, re, sys
ws, period, density = sys.argv[1:4]
overrides = sys.argv[4:]

# config.json carries repeated "//" comment keys, so strip them before parsing.
raw = open(f"{ws}/src/config.json").read()
raw = re.sub(r'^\s*"//":.*$', '', raw, flags=re.M)
raw = re.sub(r',(\s*})', r'\1', raw)
cfg = json.loads(raw)
cfg.update(json.load(open(f"{ws}/src/user_config.json")))

if period:  cfg["CLOCK_PERIOD"] = float(period)
if density: cfg["PL_TARGET_DENSITY_PCT"] = float(density)

for ov in overrides:
    k, _, v = ov.partition("=")
    for conv in (int, float):
        try:
            cfg[k] = conv(v); break
        except ValueError:
            continue
    else:
        cfg[k] = v
    print(f"  override       : {k} = {cfg[k]!r}")

# OpenROAD's IR-drop analysis segfaults in the build on this machine, killing
# the run before GDS is written.  It is a report, not a stage the layout
# depends on, and TT's precheck does not use it.  Local runs only -- the
# committed config.json is untouched, so CI still runs it.
cfg["RUN_IRDROP_REPORT"] = 0

json.dump(cfg, open(f"{ws}/src/config_merged.json", "w"), indent=2)
print("  design         :", cfg["DESIGN_NAME"])
print("  CLOCK_PERIOD   :", cfg["CLOCK_PERIOD"], "ns  (%.3f MHz)" % (1000.0 / cfg["CLOCK_PERIOD"]))
print("  DIE_AREA       :", cfg["DIE_AREA"])
print("  DEF template   :", cfg["FP_DEF_TEMPLATE"])
print("  density        :", cfg.get("PL_TARGET_DENSITY_PCT"))
PY

export PDK_ROOT PDK=sky130A
export PATH="$YS_BIN:$EDA_BIN:$OR_BIN:$PATH"

cd "$ws"
ol_args=(--pdk-root "$PDK_ROOT" --run-tag wokwi --force-run-dir runs/wokwi)
[[ -n "$to_step" ]] && ol_args+=(--to "$to_step")

exec "$OL_PYTHON" -m openlane "${ol_args[@]}" src/config_merged.json
