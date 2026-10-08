#!/usr/bin/env bash
# Build the Verilator SID-tune player. Writes tools/obj_dir/sidplay.
#
# SPDX-FileCopyrightText: 2026 Jason van Aardt
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERILATOR="${VERILATOR:-verilator}"

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
