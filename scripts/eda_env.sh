# ============================================================================
#  eda_env.sh -- put the local open-source ASIC toolchain on PATH.
#
#  Source it, don't run it:
#      source scripts/eda_env.sh
#
#  After that these all work from any directory:
#      yosys  openroad  magic  netgen  verilator  klayout  gtkwave
#      openroad -gui                   (layout viewer)
#
#  The pieces live in separate prefixes because they need incompatible
#  dependency sets.  This mirrors the layout set up for the symmul project
#  on this machine; override any of the variables if yours differ.
#
#  SPDX-FileCopyrightText: 2026 Jason van Aardt
#  SPDX-License-Identifier: CERN-OHL-S-2.0
# ============================================================================

export SID_EDA="${SID_EDA:-/home/van496/eda2}"       # OpenLane, Verilator, Python
export SID_OR="${SID_OR:-/home/van496/or_env}"       # OpenROAD, Magic, Netgen
export SID_YS="${SID_YS:-/home/van496/ys41}"         # Yosys + its share dir

export PDK_ROOT="${PDK_ROOT:-/home/van496/pdk}"
export PDK="${PDK:-sky130A}"

export PATH="$SID_YS/bin:$SID_EDA/bin:$SID_OR/bin:$PATH"

if [ -z "${SID_EDA_QUIET:-}" ]; then
    echo "ASIC toolchain ready:"
    printf '  %-10s %s\n' yosys     "$(yosys -V 2>/dev/null | cut -d' ' -f1-2)"
    printf '  %-10s %s\n' openroad  "$(openroad -version 2>/dev/null | head -1)"
    printf '  %-10s %s\n' magic     "$(magic --version 2>/dev/null | head -1)"
    printf '  %-10s %s\n' klayout   "$(command -v klayout >/dev/null && klayout -v 2>&1 | head -1 || echo '(not found)')"
    printf '  %-10s %s\n' gtkwave   "$(command -v gtkwave >/dev/null && echo present || echo '(not found)')"
    printf '  %-10s %s\n' openlane  "$($SID_EDA/bin/python -c 'import openlane;print(openlane.__version__)' 2>/dev/null)"
    printf '  %-10s %s\n' PDK       "$PDK_ROOT ($PDK)"
fi
