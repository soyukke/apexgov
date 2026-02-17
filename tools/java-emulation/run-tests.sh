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
usage: run-tests.sh [--tests-dir DIR] [--out-dir DIR] [--best-effort]

options:
  --tests-dir DIR   Java test source directory (default: tools/java-emulation/examples)
  --out-dir DIR     Output directory (default: reports/java-emulation)
  --best-effort     Compile transpilations incrementally and skip unresolved sources
env:
  SOQL_NULL_ORDER_DEFAULT=FIRST|LAST|DIRECTIONAL (default: FIRST)
USAGE
}

best_effort=false

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
    --best-effort)
      best_effort=true
      shift
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
runtime_sources_file="$out_dir/runtime-sources.zlist"
test_sources_file="$out_dir/test-sources.zlist"
find "$repo_root/tools/java-emulation/src" -type f -name '*.java' -print0 | sort -z > "$runtime_sources_file"
find "$tests_dir" -type f -name '*.java' -print0 | sort -z > "$test_sources_file"
cat "$runtime_sources_file" "$test_sources_file" > "$sources_file"

if [[ ! -s "$sources_file" ]]; then
  echo "no Java sources found in: $tests_dir" >&2
  exit 2
fi

xargs -0 javac -d "$out_dir/build" < "$runtime_sources_file"

if [[ "$best_effort" == "true" ]]; then
  declare -a pending=()
  while IFS= read -r -d '' src; do
    pending+=("$src")
  done < "$test_sources_file"

  while [[ ${#pending[@]} -gt 0 ]]; do
    progress=false
    next_pending=()

    for src in "${pending[@]}"; do
      if javac -cp "$out_dir/build" -d "$out_dir/build" "$src" >/dev/null 2>&1; then
        progress=true
      else
        next_pending+=("$src")
      fi
    done

    pending=()
    if [[ ${#next_pending[@]} -gt 0 ]]; then
      pending=("${next_pending[@]}")
    fi
    if [[ "$progress" == "false" ]]; then
      break
    fi
  done

  if [[ ${#pending[@]} -gt 0 ]]; then
    compile_failures="$out_dir/compile-failures.txt"
    : > "$compile_failures"
    for src in "${pending[@]}"; do
      if ! javac -cp "$out_dir/build" -d "$out_dir/build" "$src" >/dev/null 2>"$out_dir/.javac.err"; then
        first_line="$(head -n 1 "$out_dir/.javac.err")"
        printf '%s\t%s\n' "$src" "$first_line" >> "$compile_failures"
      fi
    done
    rm -f "$out_dir/.javac.err"
    echo "best-effort: skipped ${#pending[@]} source(s), see $compile_failures"
  fi
else
  xargs -0 javac -cp "$out_dir/build" -d "$out_dir/build" < "$test_sources_file"
fi

java -cp "$out_dir/build" apexemu.runner.Runner \
  --classes-dir "$out_dir/build" \
  --out "$out_dir/report.json" \
  --cpu-limit-ms "$cpu_limit_ms" \
  --heap-limit-bytes "$heap_limit_bytes" \
  --soql-null-order-default "$soql_null_order_default"
