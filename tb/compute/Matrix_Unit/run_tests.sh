#!/usr/bin/env bash
# Regression runner for the matrix unit (rtl/compute/Matrix_Unit): the
# output-stationary systolic array (bpu_sa_array, bpu_sa_pe, bpu_sa_delay), the
# block-scaling stage (bpu_sa_scale_acc) and the SRAM wrapper (bpu_sa_sram_wrapper,
# bpu_sa_read_stream, bpu_sa_fifo). Builds and runs every configuration below,
# requires exactly one "status=PASS" RESULT line and a zero simulator exit status
# from each run, and exits nonzero on a compile error, a failed or missing result,
# or a timeout.
#
# Usage, from anywhere inside the repository:
#   bash tb/compute/Matrix_Unit/run_tests.sh [options]
#   make test-matrix-unit MATRIX_UNIT_ARGS="[options]"
#
# Options:
#   --sim vcs               only supported simulator (default: vcs)
#   --seeds "1 2 3"         seeds for the array, scale and wrapper configurations
#                           (default: "1 2 3"); the PE configurations use the first
#   --only NAME             run one configuration from CONFIGS
#   --timeout SECONDS       wall-clock limit per run (default: 900)
#   --inject-failure        every testbench corrupts one expected value on purpose,
#                           so every run must fail and this script must exit 1
#   --check-reset-guard     array-only negative test; must fail before resetting idle hardware
#   --out DIR               output directory (default: build/matrix_unit)
#
# Outputs: DIR/<sim>/logs/<config>_seed<N>.log and DIR/<sim>/summary.md.
# Requires: Bash 3.2+, Python 3.11+, Git and VCS Y-2026.03_Full64.
# On CAE: module load synopsys/vcs-mx/2026.03. No simulator fallback.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TB_DIR="tb/compute/Matrix_Unit"
RTL_LIST="rtl/compute/Matrix_Unit/bpu_sa_array.f"

# name | testbench top | parameter overrides | seed mode (single: first seed only) |
# extra testbench files, in TB_DIR
M="sram_arbiter_matrix_model.sv"
CONFIGS=(
  "pe_acc32|bpu_sa_pe_tb|AccW=32|single|"
  "pe_acc16|bpu_sa_pe_tb|AccW=16|single|"
  "pe_acc32_int8only|bpu_sa_pe_tb|AccW=32 Int4=0|single|"
  "scale_8x8_acc32|bpu_sa_scale_acc_tb|Rows=8 Cols=8 AccW=32|all|"
  "scale_3x5_acc25|bpu_sa_scale_acc_tb|Rows=3 Cols=5 AccW=25|all|"
  "scale_1x2_acc22|bpu_sa_scale_acc_tb|Rows=1 Cols=2 AccW=22|all|"
  "array_8x8_acc32|bpu_sa_array_tb|Rows=8 Cols=8 AccW=32|all|"
  "array_8x8_int4|bpu_sa_array_tb|Rows=8 Cols=8 AccW=32 Mode=1|all|"
  "array_3x5_acc32|bpu_sa_array_tb|Rows=3 Cols=5 AccW=32|all|"
  "array_3x5_int4|bpu_sa_array_tb|Rows=3 Cols=5 AccW=32 Mode=1|all|"
  "array_5x2_acc17|bpu_sa_array_tb|Rows=5 Cols=2 AccW=17|all|"
  "array_1x1_int4_acc16|bpu_sa_array_tb|Rows=1 Cols=1 AccW=16 Mode=1|all|"
  "array_16x16_acc20|bpu_sa_array_tb|Rows=16 Cols=16 AccW=20|all|"
  "array_8x8_int8only|bpu_sa_array_tb|Rows=8 Cols=8 AccW=32 Int4=0|all|"
  "wrap_8x8_lat4|bpu_sa_sram_wrapper_tb|Rows=8 Cols=8 Latency=4 ReadyPct=70|all|$M"
  "wrap_8x8_lat40_wrack|bpu_sa_sram_wrapper_tb|Rows=8 Cols=8 Latency=40 ReadyPct=100 WriteAcks=1|all|$M"
  "wrap_4x16_acc24_lat1|bpu_sa_sram_wrapper_tb|Rows=4 Cols=16 AccW=24 Latency=1 ReadyPct=50|all|$M"
  "wrap_16x4_buf1|bpu_sa_sram_wrapper_tb|Rows=16 Cols=4 BufRows=1 Latency=7 ReadyPct=80|all|$M"
  "wrap_8x8_block32|bpu_sa_sram_wrapper_tb|Rows=8 Cols=8 BlockK=32 MaxBlocks=6 Latency=5 ReadyPct=75|all|$M"
  "wrap_8x8_int8only|bpu_sa_sram_wrapper_tb|Rows=8 Cols=8 Int4=0 Latency=4 ReadyPct=70|all|$M"
  "wrap_8x8_data256|bpu_sa_sram_wrapper_tb|Rows=8 Cols=8 DataW=256 SizeW=6 Latency=3 ReadyPct=60|all|$M"
  "wrap_2x128_noscale_acc20|bpu_sa_sram_wrapper_tb|Rows=2 Cols=128 AccW=20 Scale=0 BufRows=3 Latency=3 ReadyPct=90 Commands=4 MaxK=300|all|$M"
  "wrap_1x1_minimal|bpu_sa_sram_wrapper_tb|Rows=1 Cols=1 AccW=16 Int4=0 Scale=0 Latency=2 ReadyPct=60|all|$M"
)

sim="vcs"
seeds="1 2 3"
only=""
run_timeout=900
inject=0
check_reset_guard=0
out="build/matrix_unit"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim="$2"; shift 2 ;;
    --seeds) seeds="$2"; shift 2 ;;
    --only) only="$2"; shift 2 ;;
    --timeout) run_timeout="$2"; shift 2 ;;
    --inject-failure) inject=1; shift ;;
    --check-reset-guard) check_reset_guard=1; shift ;;
    --out) out="$2"; shift 2 ;;
    -h | --help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "run_tests.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

if [[ "$sim" != vcs ]]; then
  echo "run_tests.sh: VCS is the required simulator; --sim must be vcs" >&2
  exit 2
fi
for tool in python3 git; do
  command -v "$tool" > /dev/null || { echo "run_tests.sh: $tool not found on PATH" >&2; exit 2; }
done

python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
cd "$ROOT"
work="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$out/$sim")"
mkdir -p "$work/logs" "$work/build"
python3 - "$ROOT" "$RTL_LIST" "$work/sources.f" <<'SOURCES'
from pathlib import Path
import sys
root, file_list, output = sys.argv[1:]
paths = []
for line in (Path(root) / file_list).read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    paths.append('"' + str((Path(root) / line).resolve()) + '"')
Path(output).write_text("\n".join(paths) + "\n")
SOURCES
if [[ "$check_reset_guard" -eq 1 ]]; then
  if [[ "$inject" -eq 1 || -n "$only" ]]; then
    echo "--check-reset-guard cannot be combined with --only or --inject-failure" >&2
    exit 2
  fi
  CONFIGS=("reset_guard|bpu_sa_array_tb|Rows=8 Cols=8 AccW=32 TrafficCycles=0 ResetWaitCycles=0|single|")
fi

sim_version="$(python3 scripts/vcs.py check)"
commit="$(git rev-parse HEAD)"
dirty=""
if [[ -n "$(git status --porcelain -- rtl/compute/Matrix_Unit "$TB_DIR" scripts Makefile)" ]]; then
  dirty=" (with uncommitted changes to the tested sources)"
fi

# Build one configuration; simulator commands are arrays to preserve path boundaries.
build() {
  local name="$1" top="$2" params="$3" extra="$4"
  local dir="$work/build/$name" args=() tb_files=() p f
  mkdir -p "$dir"
  for f in $extra; do tb_files+=("$ROOT/$TB_DIR/$f"); done
  for p in $params; do args+=("-pvalue+$top.$p"); done
  (
    cd "$dir"
    python3 "$ROOT/scripts/vcs.py" --timeout "$run_timeout" \
      --elapsed-file "$dir/build.elapsed" compile -top "$top" "${args[@]}" \
      -f "$work/sources.f" ${tb_files[@]+"${tb_files[@]}"} "$ROOT/$TB_DIR/$top.sv" \
      -Mdir="$dir/csrc" -o "$dir/simv"
  ) > "$dir/build.log" 2>&1

}

planned=0
run=0
passed=0
failed=0
rows_md=""
first_seed="${seeds%% *}"

for entry in "${CONFIGS[@]}"; do
  IFS='|' read -r name top params seed_mode extra <<< "$entry"
  [[ -n "$only" && "$only" != "$name" ]] && continue
  run_seeds="$seeds"
  [[ "$seed_mode" == single ]] && run_seeds="$first_seed"

  if ! build "$name" "$top" "$params" "$extra"; then
    for seed in $run_seeds; do
      planned=$((planned + 1))
      failed=$((failed + 1))
      echo "FAIL  $name seed=$seed: build failed, see $work/build/$name/build.log"
      rows_md+="| $name | $seed | FAIL (build) | - | see build.log |"$'\n'
    done
    continue
  fi

  sim_cmd=("$work/build/$name/simv")
  for seed in $run_seeds; do
    planned=$((planned + 1))
    run=$((run + 1))
    log="$work/logs/${name}_seed${seed}.log"
    plusargs=("+seed=$seed")
    [[ "$inject" -eq 1 ]] && plusargs+=("+inject_error=1")
    set +e
    (
      cd "$work/build/$name"
      python3 "$ROOT/scripts/vcs.py" --timeout "$run_timeout" --elapsed-file "$log.elapsed" \
        run "${sim_cmd[@]}" "${plusargs[@]}"
    ) > "$log" 2>&1
    rc=$?
    set -e
    elapsed="$(cat "$log.elapsed")"
    results="$(grep -c '^RESULT ' "$log" || true)"
    result_line="$(grep -m 1 '^RESULT ' "$log" || true)"
    counts="${result_line#RESULT * }"
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      verdict="FAIL (timeout after ${run_timeout}s)"
    elif [[ "$rc" -ne 0 ]]; then
      verdict="FAIL (exit $rc)"
    elif [[ "$results" -ne 1 ]]; then
      verdict="FAIL ($results RESULT lines)"
    elif [[ " $result_line " != *" status=PASS "* ]]; then
      verdict="FAIL (status)"
    else
      verdict="PASS"
    fi
    if [[ "$verdict" == PASS ]]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
    echo "${verdict%% *}  $name seed=$seed ${elapsed}s  $counts"
    rows_md+="| $name | $seed | $verdict | $elapsed | ${counts:-no RESULT line} |"$'\n'
  done
done

if [[ "$planned" -eq 0 ]]; then
  echo "run_tests.sh: no configuration matched --only $only" >&2
  exit 2
fi

{
  echo "# bpu_sa_array regression"
  echo
  echo "- Commit: \`$commit\`$dirty"
  echo "- Simulator: $sim_version"
  echo "- Seeds: $seeds (PE configurations: $first_seed)"
  [[ "$inject" -eq 1 ]] && echo "- Mode: --inject-failure (every run is expected to fail)"
  [[ "$check_reset_guard" -eq 1 ]] && echo "- Mode: --check-reset-guard (must fail: active-reset precondition not reached)"
  echo "- Planned: $planned, run: $run, passed: $passed, failed: $failed, skipped: 0"
  echo
  echo "| Configuration | Seed | Result | Elapsed (s) | Counts from the RESULT line |"
  echo "| --- | --- | --- | --- | --- |"
  printf '%s' "$rows_md"
} > "$work/summary.md"

echo "Planned $planned, passed $passed, failed $failed. Summary: $work/summary.md"
[[ "$failed" -eq 0 ]]
