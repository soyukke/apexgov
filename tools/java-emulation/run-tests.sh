#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
tests_dir="$repo_root/tools/java-emulation/examples"
out_dir="$repo_root/reports/java-emulation"
cpu_limit_ms="${CPU_LIMIT_MS:-10000}"
heap_limit_bytes="${HEAP_LIMIT_BYTES:-6000000}"
soql_null_order_default="${SOQL_NULL_ORDER_DEFAULT:-FIRST}"

usage() {
  cat <<'USAGE'
usage: run-tests.sh [--tests-dir DIR] [--out-dir DIR]

options:
  --tests-dir DIR   Java test source directory (default: tools/java-emulation/examples)
  --out-dir DIR     Output directory (default: reports/java-emulation)
env:
  SOQL_NULL_ORDER_DEFAULT=FIRST|LAST|DIRECTIONAL (default: FIRST)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tests-dir)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --tests-dir" >&2
        exit 2
      fi
      tests_dir="$2"
      shift 2
      ;;
    --out-dir)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --out-dir" >&2
        exit 2
      fi
      out_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -d "$tests_dir" ]]; then
  echo "tests directory not found: $tests_dir" >&2
  exit 2
fi

mkdir -p "$out_dir/build"

sources_file="$out_dir/sources.zlist"
find "$repo_root/tools/java-emulation/src" "$tests_dir" -type f -name '*.java' -print0 | sort -z > "$sources_file"

if [[ ! -s "$sources_file" ]]; then
  echo "no Java sources found in: $tests_dir" >&2
  exit 2
fi

xargs -0 javac -d "$out_dir/build" < "$sources_file"

java -cp "$out_dir/build" apexemu.runner.Runner \
  --classes-dir "$out_dir/build" \
  --out "$out_dir/report.json" \
  --cpu-limit-ms "$cpu_limit_ms" \
  --heap-limit-bytes "$heap_limit_bytes" \
  --soql-null-order-default "$soql_null_order_default"
