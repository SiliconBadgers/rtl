#!/usr/bin/env bash
# Regression runner for the SIMD vector unit (rtl/compute/Vector_Unit, top vec_simd).
# Builds and runs vec_simd_tb, requires exactly one "status=PASS" RESULT line and a
# zero simulator exit status, and exits nonzero on a compile error, a failed or
# missing result, or a timeout.
#
# Usage, from anywhere inside the repository:
#   bash tb/compute/Vector_Unit/run_tests.sh [options]
#   make test-vector-unit VECTOR_UNIT_ARGS="[options]"
#
# Options:
#   --sim vcs|modelsim  simulator (default: vcs, the project's required simulator;
#                       modelsim uses vlib/vlog/vsim from PATH, also Questa)
#   --timeout SECONDS   wall-clock limit per build and per run (default: 600)
#   --inject-failure    the testbench corrupts one expected value on purpose, so
#                       the run must fail and this script must exit 1
#   --out DIR           output directory (default: build/vector_unit)
#
# Outputs: DIR/<sim>/build.log, DIR/<sim>/logs/vec_simd_tb.log and DIR/<sim>/summary.md.
# Requires: Bash 3.2+, Python 3.11+, Git, and either
#   VCS Y-2026.03_Full64 with uv 0.12.23+ (on CAE: module load synopsys/vcs-mx/2026.03), or
#   ModelSim / Questa (vlib, vlog, vsim on PATH).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TB_DIR="tb/compute/Vector_Unit"
TB_TOP="vec_simd_tb"
RTL_LIST="rtl/compute/Vector_Unit/vec_simd.f"

sim="vcs"
run_timeout=600
inject=0
out="build/vector_unit"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim="$2"; shift 2 ;;
    --timeout) run_timeout="$2"; shift 2 ;;
    --inject-failure) inject=1; shift ;;
    --out) out="$2"; shift 2 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "run_tests.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

case "$sim" in
  vcs)
    PYTHON_CMD=("${UV:-uv}" run --locked --project "$ROOT" "${PYTHON:-python3}")
    required_tools=("${UV:-uv}" git)
    ;;
  modelsim)
    PYTHON_CMD=("${PYTHON:-python3}")
    required_tools=(vlib vlog vsim git "${PYTHON:-python3}")
    ;;
  *) echo "run_tests.sh: --sim must be vcs or modelsim" >&2; exit 2 ;;
esac
for tool in "${required_tools[@]}"; do
  command -v "$tool" > /dev/null || { echo "run_tests.sh: $tool not found on PATH" >&2; exit 2; }
done
"${PYTHON_CMD[@]}" -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'

cd "$ROOT"
work="$("${PYTHON_CMD[@]}" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$out/$sim")"
rm -rf "$work"
mkdir -p "$work/logs" "$work/build"

# Absolute source list, so the simulator can run from the build directory.
sources=()
while IFS= read -r line; do
  line="${line%%//*}"
  line="$(echo "$line" | tr -d '[:space:]')"
  [[ -n "$line" ]] && sources+=("$ROOT/$line")
done < "$RTL_LIST"
sources+=("$ROOT/$TB_DIR/$TB_TOP.sv")

plusargs=()
[[ "$inject" -eq 1 ]] && plusargs+=("+inject_error=1")

commit="$(git rev-parse HEAD)"
dirty=""
if [[ -n "$(git status --porcelain -- rtl/compute/Vector_Unit "$TB_DIR" Makefile)" ]]; then
  dirty=" (with uncommitted changes to the tested sources)"
fi

build_dir="$work/build"
log="$work/logs/$TB_TOP.log"
timeout_cmd=("${PYTHON_CMD[@]}" "$ROOT/scripts/run_with_timeout.py" --timeout "$run_timeout")

set +e
if [[ "$sim" == vcs ]]; then
  sim_version="$("${PYTHON_CMD[@]}" scripts/vcs.py check)"
  (
    cd "$build_dir"
    "${PYTHON_CMD[@]}" "$ROOT/scripts/vcs.py" --timeout "$run_timeout" \
      --elapsed-file "$build_dir/build.elapsed" compile -top "$TB_TOP" \
      "${sources[@]}" -Mdir="$build_dir/csrc" -o "$build_dir/simv"
  ) > "$work/build.log" 2>&1
  build_rc=$?
  if [[ "$build_rc" -eq 0 ]]; then
    (
      cd "$build_dir"
      "${PYTHON_CMD[@]}" "$ROOT/scripts/vcs.py" --timeout "$run_timeout" \
        --elapsed-file "$log.elapsed" run "$build_dir/simv" ${plusargs[@]+"${plusargs[@]}"}
    ) > "$log" 2>&1
    rc=$?
  fi
else
  sim_version="$(vsim -version 2>&1 | head -n 1)"
  (
    cd "$build_dir"
    vlib work && "${timeout_cmd[@]}" --elapsed-file "$build_dir/build.elapsed" \
      vlog -sv -work work "${sources[@]}"
  ) > "$work/build.log" 2>&1
  build_rc=$?
  if [[ "$build_rc" -eq 0 ]]; then
    (
      cd "$build_dir"
      "${timeout_cmd[@]}" --elapsed-file "$log.elapsed" \
        vsim -c -onfinish exit -work work "$TB_TOP" ${plusargs[@]+"${plusargs[@]}"} -do "run -all; quit -f"
    ) > "$log" 2>&1
    rc=$?
  fi
fi
set -e

if [[ "$build_rc" -ne 0 ]]; then
  verdict="FAIL (build exit $build_rc, see $work/build.log)"
  elapsed="-"
  counts=""
else
  elapsed="$(cat "$log.elapsed" 2> /dev/null || echo "-")"
  results="$(grep -c '^\(# \)\{0,1\}RESULT ' "$log" || true)"
  result_line="$(grep -m 1 '^\(# \)\{0,1\}RESULT ' "$log" || true)"
  result_line="${result_line#\# }"
  counts="${result_line#RESULT * }"
  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    verdict="FAIL (timeout after ${run_timeout}s)"
  elif [[ "$rc" -ne 0 ]]; then
    verdict="FAIL (exit $rc)"
  elif [[ "$results" -ne 1 ]]; then
    verdict="FAIL ($results RESULT lines)"
  elif [[ " $result_line " != *" status=PASS "* ]]; then
    verdict="FAIL (status)"
  elif grep -q '^\(# \)\{0,1\}\*\* Fatal' "$log"; then
    verdict="FAIL (fatal in log)"
  else
    verdict="PASS"
  fi
fi

echo "${verdict%% *}  $TB_TOP lanes=4 ${elapsed}s  $counts"

{
  echo "# vec_simd regression"
  echo
  echo "- Commit: \`$commit\`$dirty"
  echo "- Simulator: $sim_version"
  [[ "$inject" -eq 1 ]] && echo "- Mode: --inject-failure (the run is expected to fail)"
  echo "- Planned: 1, run: $([[ "$build_rc" -eq 0 ]] && echo 1 || echo 0)," \
    "passed: $([[ "$verdict" == PASS ]] && echo 1 || echo 0)," \
    "failed: $([[ "$verdict" == PASS ]] && echo 0 || echo 1), skipped: 0"
  echo
  echo "| Configuration | Result | Elapsed (s) | Counts from the RESULT line |"
  echo "| --- | --- | --- | --- |"
  echo "| $TB_TOP NumLanes=4 | $verdict | $elapsed | ${counts:-no RESULT line} |"
} > "$work/summary.md"

echo "Summary: $work/summary.md"
[[ "$verdict" == PASS ]]
