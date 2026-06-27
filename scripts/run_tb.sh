#!/usr/bin/env bash
set -euo pipefail

sim="auto"
tb="core"
clean=0
norun=0
trace=0

usage() {
  cat <<USAGE
Usage: scripts/run_tb.sh [--sim auto|xsim|verilator] [--tb core|wrapper] [--clean] [--no-run] [--trace]

Examples:
  scripts/run_tb.sh --sim xsim --tb core
  scripts/run_tb.sh --sim verilator --tb wrapper --trace
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim="$2"; shift 2 ;;
    --tb) tb="$2"; shift 2 ;;
    --clean) clean=1; shift ;;
    --no-run) norun=1; shift ;;
    --trace) trace=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$tb" != "core" && "$tb" != "wrapper" ]]; then
  echo "--tb must be core or wrapper" >&2
  exit 2
fi

if [[ "$sim" != "auto" && "$sim" != "xsim" && "$sim" != "verilator" ]]; then
  echo "--sim must be auto, xsim, or verilator" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
top="rms_norm_tb"
tb_file="$root/sim/rms_norm_tb.sv"
if [[ "$tb" == "wrapper" ]]; then
  top="rms_norm_wrapper_tb"
  tb_file="$root/sim/rms_norm_wrapper_tb.sv"
fi

if [[ "$sim" == "auto" ]]; then
  if command -v xvlog >/dev/null 2>&1 && command -v xelab >/dev/null 2>&1 && command -v xsim >/dev/null 2>&1; then
    sim="xsim"
  elif command -v verilator >/dev/null 2>&1; then
    sim="verilator"
  else
    echo "Neither XSIM (xvlog/xelab/xsim) nor Verilator is available on PATH." >&2
    exit 1
  fi
fi

build="$root/build/sim/$sim/$top"
if [[ "$clean" -eq 1 ]]; then
  rm -rf "$build"
fi
mkdir -p "$build"

if [[ -d "$root/scripts/golden_mem" ]]; then
  cp -f "$root"/scripts/golden_mem/*.mem "$build"/
else
  echo "[run_tb] Warning: no scripts/golden_mem directory found. File-based tests may fail until vectors are generated." >&2
fi

sources=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  sources+=("$root/$line")
done < "$root/sim/sources.f"

inc_args=(
  "-I$root"
  "-I$root/precision_lib/floating_point"
  "-I$root/precision_lib/bfloat16"
)

cd "$build"

if [[ "$sim" == "xsim" ]]; then
  xsim_inc_args=()
  for dir in "$root" "$root/precision_lib/floating_point" "$root/precision_lib/bfloat16"; do
    xsim_inc_args+=("-i" "$dir")
  done

  echo "[run_tb] Compiling $top with XSIM..."
  xvlog -sv --work work "${xsim_inc_args[@]}" "${sources[@]}" "$tb_file" -log "$build/xvlog.log"
  snapshot="${top}_snapshot"
  xelab -debug typical "work.$top" -s "$snapshot" -log "$build/xelab.log"

  if [[ "$norun" -eq 0 ]]; then
    echo "[run_tb] Running $top with XSIM..."
    xsim "$snapshot" -R -log "$build/xsim.log"
  fi
else
  trace_args=()
  if [[ "$trace" -eq 1 ]]; then
    trace_args+=(--trace)
  fi

  obj_dir="$build/obj_dir"
  echo "[run_tb] Building $top with Verilator..."
  verilator --binary --timing --top-module "$top" --Mdir "$obj_dir" \
    -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
    "${trace_args[@]}" "${inc_args[@]}" "${sources[@]}" "$tb_file"

  if [[ "$norun" -eq 0 ]]; then
    exe="$obj_dir/V$top"
    if [[ -x "$exe.exe" ]]; then
      exe="$exe.exe"
    fi
    echo "[run_tb] Running $top with Verilator..."
    "$exe"
  fi
fi

echo "[run_tb] Done. Run directory: $build"
