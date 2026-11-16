#!/usr/bin/env bash
# Lint and simulate sram_arbiter with Verilator 5 (tested with 5.020).
# Run from anywhere:
#   tb/memory/sram_arbiter/run_sim.sh                 BankBusyCycles=0, SramLatency=3
#   tb/memory/sram_arbiter/run_sim.sh 2 4             BankBusyCycles=2, SramLatency=4
#   tb/memory/sram_arbiter/run_sim.sh 0 3 invalid     invalid-input test
set -euo pipefail
TB_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TB_DIR/../../.." && pwd)"
RTL_DIR="$ROOT/rtl/memory/sram_arbiter"
BUSY=${1:-0}
LAT=${2:-3}
MODE=${3:-normal}

RTL="$RTL_DIR/sram_arbiter_pkg.sv $RTL_DIR/sram_arb_priority.sv $RTL_DIR/sram_arb_req_mux.sv \
     $RTL_DIR/sram_arb_addr_decode.sv $RTL_DIR/sram_arb_bank_conflict.sv \
     $RTL_DIR/sram_arb_port_ctrl.sv $RTL_DIR/sram_arb_rsp_route.sv $RTL_DIR/sram_arbiter.sv"
TB="$TB_DIR/sram_model.sv $TB_DIR/sram_arbiter_tb.sv"

DEFS=""
INVALID=0
if [ "$MODE" = "invalid" ]; then
  DEFS="+define+SRAM_ARB_NO_INPUT_ASSERTS"
  INVALID=1
fi

# RTL lint, all warnings. Waiver: SYNCASYNCNET, raised by `disable iff (!rst_ni)` in the assertions.
verilator --lint-only -Wall -Wno-SYNCASYNCNET -GBankBusyCycles="$BUSY" --top-module sram_arbiter $RTL

# Testbench build, all warnings enabled except:
#  - TIMESCALEMOD: only the testbench declares timeunit; the RTL has no delays and needs none.
#  - SYNCASYNCNET: raised because the assertions use `disable iff (!rst_ni)` on the async reset.
OBJ="${TMPDIR:-/tmp}/sram_arbiter_sim/busy${BUSY}_lat${LAT}_${MODE}"  # outside the repo
mkdir -p "$OBJ"
verilator --binary --timing --assert -j 0 -Wall -Wno-TIMESCALEMOD -Wno-SYNCASYNCNET $DEFS \
  -GBankBusyCycles="$BUSY" -GSramLatency="$LAT" -GTestInvalid="1'b$INVALID" \
  --top-module sram_arbiter_tb --Mdir "$OBJ" -o sim $RTL $TB > "$OBJ/build.log" 2>&1 \
  || { cat "$OBJ/build.log"; exit 1; }
"$OBJ/sim"