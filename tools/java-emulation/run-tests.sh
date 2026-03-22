#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
tests_dir="$repo_root/tools/java-emulation/examples"
out_dir="$repo_root/reports/java-emulation"
cpu_limit_ms="${CPU_LIMIT_MS:-10000}"
heap_limit_bytes="${HEAP_LIMIT_BYTES:-12000000}"
soql_null_order_default="${SOQL_NULL_ORDER_DEFAULT:-FIRST}"
nix_bin=""

if command -v nix >/dev/null 2>&1; then
  nix_bin="$(command -v nix)"
elif [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
  nix_bin="/nix/var/nix/profiles/default/bin/nix"
  export PATH="/nix/var/nix/profiles/default/bin:$PATH"
fi

if ! javac -version >/dev/null 2>&1; then
  if [[ -n "$nix_bin" && "${APEXGOV_IN_NIX_DEV:-}" != "1" ]]; then
    echo "javac is unavailable; re-running inside nix develop"
    export APEXGOV_IN_NIX_DEV=1
    exec "$nix_bin" develop -c "$0" "$@"
  fi
  echo "javac is unavailable. Run under nix develop or install a JDK." >&2
  exit 127
fi

usage() {
  cat <<'USAGE'
usage: run-tests.sh [--tests-dir DIR] [--out-dir DIR] [--best-effort] [--class-name-pattern REGEX]

options:
  --tests-dir DIR   Java test source directory (default: tools/java-emulation/examples)
  --out-dir DIR     Output directory (default: reports/java-emulation)
  --best-effort     Compile incrementally and fallback unresolved sources to placeholders
  --class-name-pattern REGEX  run only classes whose fully qualified name matches REGEX
env:
  SOQL_NULL_ORDER_DEFAULT=FIRST|LAST|DIRECTIONAL (default: FIRST)
USAGE
}

best_effort=false
class_name_pattern=""

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
    --class-name-pattern)
      if [[ $# -lt 2 ]]; then
        echo "missing value for --class-name-pattern" >&2
        exit 2
      fi
      class_name_pattern="$2"
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
tests_dir="$(cd "$tests_dir" && pwd)"

mkdir -p "$out_dir/build"
out_dir="$(cd "$out_dir" && pwd)"
mkdir -p "$out_dir/build"

_timer_start() { date +%s; }
_timer_elapsed() { echo "$(( $(date +%s) - $1 ))s"; }

sources_file="$out_dir/sources.zlist"
runtime_sources_file="$out_dir/runtime-sources.zlist"
test_sources_file="$out_dir/test-sources.zlist"
find "$repo_root/tools/java-emulation/src" -type f -name '*.java' -print0 | sort -z > "$runtime_sources_file"
# When the transpiled sources directory is used as tests_dir, out_dir is often nested
# under tests_dir. Exclude out_dir to avoid re-ingesting previous run artifacts.
find "$tests_dir" \
  \( -path "$out_dir" -o -path "$out_dir/*" \) -prune -o \
  -type f -name '*.java' -print0 | sort -z > "$test_sources_file"
cat "$runtime_sources_file" "$test_sources_file" > "$sources_file"

if [[ ! -s "$sources_file" ]]; then
  echo "no Java sources found in: $tests_dir" >&2
  exit 2
fi

# Fast JVM startup flags for javac
JAVAC_FLAGS=(-J-XX:+TieredCompilation -J-XX:TieredStopAtLevel=1)

# Compile runtime — skip if no source is newer than the oldest .class
_t=$(_timer_start)
runtime_needs_rebuild=false
oldest_class="$(find "$out_dir/build/apexemu" -type f -name '*.class' -print0 2>/dev/null | xargs -0 ls -tr 2>/dev/null | head -n 1)" || true
if [[ -z "$oldest_class" ]]; then
  runtime_needs_rebuild=true
else
  newer_sources="$(find "$repo_root/tools/java-emulation/src" -type f -name '*.java' -newer "$oldest_class" -print -quit 2>/dev/null)" || true
  if [[ -n "$newer_sources" ]]; then
    runtime_needs_rebuild=true
  fi
fi
if [[ "$runtime_needs_rebuild" == "true" ]]; then
  xargs -0 javac "${JAVAC_FLAGS[@]}" -d "$out_dir/build" < "$runtime_sources_file"
fi
echo "phase:runtime $(_timer_elapsed $_t)" >&2

if [[ "$best_effort" == "true" ]]; then
  _t=$(_timer_start)
  best_effort_sources_dir="$out_dir/best-effort-sources"
  best_effort_sources_file="$out_dir/best-effort-sources.zlist"
  compile_failures="$out_dir/compile-failures.txt"
  compile_fallbacks="$out_dir/compile-fallbacks.txt"
  rm -rf "$best_effort_sources_dir"
  mkdir -p "$best_effort_sources_dir"
  : > "$compile_fallbacks"

  # Copy test sources preserving directory structure
  : > "$best_effort_sources_file"
  while IFS= read -r -d '' src; do
    rel="${src#"$tests_dir"/}"
    dst="$best_effort_sources_dir/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    printf '%s\0' "$dst" >> "$best_effort_sources_file"
  done < "$test_sources_file"

  sanitize_java_identifier() {
    local raw="$1"
    local ident="$raw"
    if [[ ! "$ident" =~ ^[A-Za-z_$][A-Za-z0-9_$]*$ ]]; then
      ident="ApexgovPlaceholder"
    fi
    case "$ident" in
      abstract|assert|boolean|break|byte|case|catch|char|class|const|continue|default|do|double|else|enum|extends|final|finally|float|for|goto|if|implements|import|instanceof|int|interface|long|native|new|package|private|protected|public|return|short|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|void|volatile|while|true|false|null|_)
        ident="${ident}_Apex"
        ;;
    esac
    printf '%s' "$ident"
  }

  render_placeholder_source() {
    local src="$1"
    local class_name
    local safe_class_name
    local package_name
    local kind="class"
    local has_test_annotation="false"

    class_name="$(basename "$src" .java)"
    safe_class_name="$(sanitize_java_identifier "$class_name")"
    package_name="$(sed -n 's/^[[:space:]]*package[[:space:]]\+\([[:alnum:]_.]\+\)[[:space:]]*;[[:space:]]*$/\1/p' "$src" | head -n 1)"

    if grep -Eq '^[[:space:]]*public[[:space:]]+interface[[:space:]]+' "$src"; then
      kind="interface"
    elif grep -Eq '^[[:space:]]*public[[:space:]]+enum[[:space:]]+' "$src"; then
      kind="enum"
    fi

    if grep -Eq '@(apexemu\.annotations\.)?Test\b' "$src"; then
      has_test_annotation="true"
    fi

    {
      if [[ -n "$package_name" ]]; then
        printf 'package %s;\n\n' "$package_name"
      fi
      printf '// best-effort placeholder generated by apexgov\n'
      case "$kind" in
        interface)
          printf 'interface %s {}\n' "$safe_class_name"
          ;;
        enum)
          printf 'enum %s { PLACEHOLDER }\n' "$safe_class_name"
          ;;
        *)
          printf 'class %s {\n' "$safe_class_name"
          if [[ "$has_test_annotation" == "true" ]] || [[ "$class_name" == *Test* ]] || [[ "$class_name" == *_Tests* ]]; then
            printf '  @apexemu.annotations.Test\n'
            printf '  public static void __apexgovBestEffortPlaceholderTest() {}\n'
          fi
          printf '}\n'
          ;;
      esac
    } > "$src"
  }

  declare -a pending=()
  while IFS= read -r -d '' src; do
    pending+=("$src")
  done < "$best_effort_sources_file"

  fallback_count=0
  declare -A fallback_set=()
  record_fallback() {
    local src="$1"
    if [[ -z "${fallback_set[$src]+x}" ]]; then
      fallback_set[$src]=1
      printf '%s\n' "$src" >> "$compile_fallbacks"
      fallback_count=$((fallback_count + 1))
    fi
  }

  # --- Phase 1: Try compiling all files at once ---
  if javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "${pending[@]}" >/dev/null 2>/dev/null; then
    pending=()
  fi

  # --- Phase 2: Batch-bisect failing files ---
  while [[ ${#pending[@]} -gt 0 ]]; do
    progress=false

    # Try batch compile to identify error sources
    class_count_before="$(find "$out_dir/build" -type f -name '*.class' | wc -l | tr -d ' ')"
    if javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "${pending[@]}" >/dev/null 2>"$out_dir/.javac.err"; then
      progress=true
      pending=()
      rm -f "$out_dir/.javac.err"
    else
      class_count_after="$(find "$out_dir/build" -type f -name '*.class' | wc -l | tr -d ' ')"
      if (( class_count_after > class_count_before )); then
        progress=true
      fi

      # Extract error sources from javac output
      batch_error_sources=()
      while IFS= read -r batch_src; do
        batch_error_sources+=("$batch_src")
      done < <(
        awk -F: 'NF >= 2 { print $1 }' "$out_dir/.javac.err" \
          | grep "^$best_effort_sources_dir/" \
          | sort -u
      )
      rm -f "$out_dir/.javac.err"

      if [[ ${#batch_error_sources[@]} -gt 0 ]]; then
        # Replace error sources with placeholders
        for src in "${batch_error_sources[@]}"; do
          render_placeholder_source "$src"
          record_fallback "$src"
        done
        progress=true

        # Rebuild pending list excluding placeholders
        next_pending=()
        for src in "${pending[@]}"; do
          if [[ -z "${fallback_set[$src]+x}" ]]; then
            next_pending+=("$src")
          fi
        done
        pending=()
        if [[ ${#next_pending[@]} -gt 0 ]]; then
          pending=("${next_pending[@]}")
        fi
      fi
    fi

    # If no progress from batch, fall back to individual salvage
    if [[ ${#pending[@]} -gt 0 && "$progress" == "false" ]]; then
      salvage_progress=false
      next_pending=()
      for src in "${pending[@]}"; do
        render_placeholder_source "$src"
        if javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$src" >/dev/null 2>&1; then
          salvage_progress=true
          progress=true
          record_fallback "$src"
        else
          next_pending+=("$src")
        fi
      done
      pending=()
      if [[ ${#next_pending[@]} -gt 0 ]]; then
        pending=("${next_pending[@]}")
      fi
      if [[ "$salvage_progress" == "false" ]]; then
        break
      fi
    fi

    if [[ "$progress" == "false" ]]; then
      break
    fi
  done

  echo "phase:best-effort-compile $(_timer_elapsed $_t)" >&2

  if [[ "$fallback_count" -gt 0 ]]; then
    echo "best-effort: replaced ${fallback_count} source(s) with placeholder stubs, see $compile_fallbacks"
  else
    rm -f "$compile_fallbacks"
  fi

  if [[ ${#pending[@]} -gt 0 ]]; then
    : > "$compile_failures"
    for src in "${pending[@]}"; do
      if ! javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$src" >/dev/null 2>"$out_dir/.javac.err"; then
        first_line="$(head -n 1 "$out_dir/.javac.err")"
        printf '%s\t%s\n' "$src" "$first_line" >> "$compile_failures"
      fi
    done
    rm -f "$out_dir/.javac.err"
    echo "best-effort: skipped ${#pending[@]} source(s), see $compile_failures"
  else
    rm -f "$compile_failures"
  fi
else
  xargs -0 javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" < "$test_sources_file"
fi

# Final pass: iteratively restore placeholder sources until no more progress
if [[ "$best_effort" == "true" && -s "$compile_fallbacks" ]]; then
  # Compile all placeholders so their types are available
  while IFS= read -r fb_src; do
    javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
  done < "$compile_fallbacks"
  # Iteratively restore original sources
  total_restored=0
  for _round in 1 2 3 4 5; do
    restored=0
    next_fallbacks="$out_dir/.next-fallbacks.txt"
    : > "$next_fallbacks"

    # First, try batch-restoring all placeholders at once (handles circular deps).
    batch_restore=()
    while IFS= read -r fb_src; do
      rel="${fb_src#"$best_effort_sources_dir"/}"
      orig="$tests_dir/$rel"
      if [[ -f "$orig" ]]; then
        cp "$orig" "$fb_src"
        batch_restore+=("$fb_src")
      else
        printf '%s\n' "$fb_src" >> "$next_fallbacks"
      fi
    done < "$compile_fallbacks"

    if [[ ${#batch_restore[@]} -gt 0 ]]; then
      if javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "${batch_restore[@]}" >/dev/null 2>"$out_dir/.javac.err"; then
        restored=${#batch_restore[@]}
        rm -f "$out_dir/.javac.err"
      else
        # Batch failed — identify which files have errors and revert those to placeholders.
        batch_error_files=()
        while IFS= read -r err_src; do
          batch_error_files+=("$err_src")
        done < <(
          awk -F: 'NF >= 2 { print $1 }' "$out_dir/.javac.err" \
            | grep "^$best_effort_sources_dir/" \
            | sort -u
        )
        rm -f "$out_dir/.javac.err"

        # Revert error files to placeholders, keep the rest
        for fb_src in "${batch_restore[@]}"; do
          is_error=false
          for err_src in "${batch_error_files[@]}"; do
            if [[ "$fb_src" == "$err_src" ]]; then
              is_error=true
              break
            fi
          done
          if [[ "$is_error" == "true" ]]; then
            render_placeholder_source "$fb_src"
            javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
            printf '%s\n' "$fb_src" >> "$next_fallbacks"
          else
            # Try individual compile to confirm
            if javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1; then
              restored=$((restored + 1))
            else
              render_placeholder_source "$fb_src"
              javac "${JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
              printf '%s\n' "$fb_src" >> "$next_fallbacks"
            fi
          fi
        done
      fi
    fi

    total_restored=$((total_restored + restored))
    cp "$next_fallbacks" "$compile_fallbacks"
    rm -f "$next_fallbacks"
    if [[ "$restored" -eq 0 ]]; then
      break
    fi
  done
  if [[ "$total_restored" -gt 0 ]]; then
    echo "best-effort: restored $total_restored source(s) from placeholders in $_round round(s)"
  fi
fi

if [[ -f "$tests_dir/apex-triggers.txt" ]]; then
  cp "$tests_dir/apex-triggers.txt" "$out_dir/build/apex-triggers.txt"
fi

# Auto-generate trigger manifest from .trigger source files (disabled by default —
# requires APEXGOV_AUTO_TRIGGERS=1 because some handlers have side effects).

_t=$(_timer_start)
set +e
runner_cmd=(
  java
  --add-opens java.base/java.lang=ALL-UNNAMED
  --add-opens java.base/java.lang.reflect=ALL-UNNAMED
  --add-opens java.base/java.util=ALL-UNNAMED
  -cp "$out_dir/build" apexemu.runner.Runner
  --classes-dir "$out_dir/build"
  --out "$out_dir/report.json"
  --cpu-limit-ms "$cpu_limit_ms"
  --heap-limit-bytes "$heap_limit_bytes"
  --soql-null-order-default "$soql_null_order_default"
)
if [[ -n "$class_name_pattern" ]]; then
  runner_cmd+=(--class-name-pattern "$class_name_pattern")
fi
"${runner_cmd[@]}"
runner_exit=$?
set -e
echo "phase:test-runner $(_timer_elapsed $_t)" >&2

if [[ "$runner_exit" -eq 2 ]]; then
  # Some external repos intentionally ship no @Test classes in the selected source set.
  # Treat this as a successful compile/emulation run.
  exit 0
fi
exit "$runner_exit"
