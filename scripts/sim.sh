#!/usr/bin/env bash
# ============================================================================
#  sim.sh -- run the cocotb suite, view waveforms, render audio.
#
#  Usage:
#     scripts/sim.sh                     whole suite (RTL)
#     scripts/sim.sh <testcase>          one test, e.g. test_lowpass_attenuates
#     scripts/sim.sh --wave [testcase]   run, then open the FST in gtkwave
#     scripts/sim.sh --record [ms]       render test/sid_demo.wav (default 1500)
#     scripts/sim.sh --gl [run-tag]      gate-level run against a hardened
#                                        netlist (default tag: submission)
#     scripts/sim.sh --div2 [testcase]   build with -DSID_I2S_SCK_DIV2
#     scripts/sim.sh --list              list the test cases
#
#  The suite needs the exact cocotb the shuttle pins (test/requirements.txt),
#  which is not the system one, so this keeps its own virtualenv in .venv
#  and creates it on first use.
#
#  SPDX-FileCopyrightText: 2026 Jason van Aardt
#  SPDX-License-Identifier: CERN-OHL-S-2.0
# ============================================================================
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
venv="${SID_VENV:-$root/.venv}"

if [[ ! -x "$venv/bin/cocotb-config" ]]; then
    echo "creating $venv from test/requirements.txt"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q --upgrade pip
    "$venv/bin/pip" install -q -r "$root/test/requirements.txt"
fi
export PATH="$venv/bin:$PATH"

wave=0; record=0; gl=0; div2=0; testcase=""; duration=""; tag="submission"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wave)   wave=1; shift ;;
        --record) record=1; [[ "${2:-}" =~ ^[0-9]+$ ]] && { duration="$2"; shift; }; shift ;;
        --gl)     gl=1; [[ -n "${2:-}" && "${2:0:2}" != "--" ]] && { tag="$2"; shift; }; shift ;;
        --div2)   div2=1; shift ;;
        --list)
            grep -oP '^async def \Ktest_\w+' "$root/test/test.py" || \
            grep -oP '^async def \Ktest_\w+' "$root/test/test.py"
            exit 0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) testcase="$1"; shift ;;
    esac
done

cd "$root/test"
args=()

if (( record )); then
    [[ -n "$duration" ]] && export DURATION_MS="$duration"
    echo "rendering ${DURATION_MS:-1500} ms to test/sid_demo.wav"
    exec make record
fi

if (( gl )); then
    nl="$(ls "$root/asic/work/$tag/runs/wokwi/final/pnl/"*.v 2>/dev/null | head -1)"
    [[ -n "$nl" ]] || nl="$(ls "$root/asic/work/$tag/runs/wokwi/final/nl/"*.v 2>/dev/null | head -1)"
    [[ -n "$nl" ]] || { echo "no netlist for run '$tag' under asic/work" >&2; exit 2; }
    echo "using netlist $nl"
    cp "$nl" gate_level_netlist.v
    args+=(GATES=yes)
    export PDK_ROOT="${PDK_ROOT:-/home/van496/pdk}"
fi

if (( div2 )); then
    args+=(COMPILE_ARGS="-I$root/src -DSID_I2S_SCK_DIV2")
fi

[[ -n "$testcase" ]] && args+=(COCOTB_TESTCASE="$testcase")

make "${args[@]+"${args[@]}"}"
python -m cocotb_tools.check_results results.xml && echo "all tests passed"

if (( wave )); then
    [[ -f tb.fst ]] || { echo "no tb.fst produced" >&2; exit 2; }
    command -v gtkwave >/dev/null || { echo "gtkwave not on PATH" >&2; exit 2; }
    echo "opening tb.fst in gtkwave"
    exec gtkwave tb.fst
fi
