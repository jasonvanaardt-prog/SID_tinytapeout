#!/usr/bin/env bash
# Build the Verilator SID-tune player. Writes tools/obj_dir/sidplay.
#
# SPDX-FileCopyrightText: 2026 Jason van Aardt
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Find verilator: an explicit $VERILATOR wins, then PATH, then the local
# toolchain prefixes scripts/eda_env.sh knows about.
if [[ -z "${VERILATOR:-}" ]]; then
    if command -v verilator >/dev/null; then
        VERILATOR=verilator
    else
        for c in "${SID_EDA:-/home/van496/eda2}/bin/verilator" \
                 /home/van496/eda2/bin/verilator; do
            [[ -x "$c" ]] && { VERILATOR="$c"; break; }
        done
    fi
fi
[[ -n "${VERILATOR:-}" ]] || {
    echo "verilator not found. Install it, put it on PATH, or set VERILATOR=" >&2
    exit 2; }

# The conda-forge verilator build defaults to a conda toolchain that is not
# installed here -- compiler, linker and archiver alike -- so point the
# generated makefile at the system ones.
export CXX="${CXX:-g++}"
export AR="${AR:-ar}"

cd "$root/tools"
exec "$VERILATOR" --cc --build --public-flat-rw -O3 \
    -CFLAGS "-O2" -MAKEFLAGS "CXX=$CXX LINK=$CXX AR=$AR" \
    -Mdir obj_dir --top-module tt_um_sid6581 \
    --exe sidplay_tb.cpp -o sidplay \
    "$root"/src/*.v
