#!/usr/bin/env bash
set -eo pipefail

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
best_effort_restore_limit="${APEXGOV_BEST_EFFORT_RESTORE_LIMIT:-128}"

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
# When the transpiled sources directory is reused as tests_dir, stale run-tests.sh
# outputs may already exist under it. Exclude the active out_dir and any nested
# best-effort source mirrors so reruns do not re-ingest their own generated inputs.
find "$tests_dir" \
  \( -path "$out_dir" -o -path "$out_dir/*" \) -prune -o \
  -type d -name 'best-effort-sources' -prune -o \
  -type f -name '*.java' -print0 | sort -z > "$test_sources_file"
cat "$runtime_sources_file" "$test_sources_file" > "$sources_file"

if [[ ! -s "$sources_file" ]]; then
  echo "no Java sources found in: $tests_dir" >&2
  exit 2
fi

# Fast JVM startup flags for javac
JAVAC_FLAGS=(-J-XX:+TieredCompilation -J-XX:TieredStopAtLevel=1)

# --- Compile daemon for in-process javac (avoids JVM startup per invocation) ---
_daemon_pid=""
_daemon_in=""
_daemon_out=""
start_compile_daemon() {
  if [[ -n "$_daemon_pid" ]]; then return; fi
  local daemon_class="apexemu.compiler.CompileDaemon"
  _daemon_fifo_in="$out_dir/.daemon-in.fifo"
  _daemon_fifo_out="$out_dir/.daemon-out.fifo"
  rm -f "$_daemon_fifo_in" "$_daemon_fifo_out"
  mkfifo "$_daemon_fifo_in" "$_daemon_fifo_out"
  java -cp "$out_dir/build" "$daemon_class" < "$_daemon_fifo_in" > "$_daemon_fifo_out" &
  _daemon_pid=$!
  exec 7>"$_daemon_fifo_in"
  exec 8<"$_daemon_fifo_out"
  _daemon_in=7
  _daemon_out=8
}
stop_compile_daemon() {
  if [[ -z "$_daemon_pid" ]]; then return; fi
  echo '{"quit":true}' >&${_daemon_in} 2>/dev/null || true
  exec 7>&- 2>/dev/null || true
  exec 8<&- 2>/dev/null || true
  wait "$_daemon_pid" 2>/dev/null || true
  rm -f "$_daemon_fifo_in" "$_daemon_fifo_out"
  _daemon_pid=""
}
# daemon_compile: compile files via daemon, returns 0 on success.
# Sets _daemon_error_files (array) with files that had errors.
# Usage: daemon_compile <classpath> <outputDir> <sourcepath> file1 file2 ...
daemon_compile() {
  local cp="$1" outd="$2" sp="$3"
  shift 3
  local files_json=""
  for f in "$@"; do
    if [[ -n "$files_json" ]]; then files_json="$files_json,"; fi
    files_json="$files_json\"$f\""
  done
  local req="{\"files\":[$files_json],\"classpath\":\"$cp\",\"outputDir\":\"$outd\",\"sourcepath\":\"$sp\"}"
  echo "$req" >&${_daemon_in}
  local resp
  IFS= read -r resp <&${_daemon_out}
  _daemon_error_files=()
  # Parse success field
  if [[ "$resp" == *'"success":true'* ]]; then
    return 0
  fi
  # Extract error files from response
  local ef_section="${resp#*\"errorFiles\":[}"
  ef_section="${ef_section%%]*}"
  while [[ "$ef_section" == *'"'* ]]; do
    local val="${ef_section#*\"}"
    val="${val%%\"*}"
    _daemon_error_files+=("$val")
    ef_section="${ef_section#*\"*\"}"
  done
  return 1
}
trap 'stop_compile_daemon' EXIT

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
  best_effort_sourcepath_dir="$out_dir/best-effort-sourcepath"
  best_effort_sources_file="$out_dir/best-effort-sources.zlist"
  compile_failures="$out_dir/compile-failures.txt"
  compile_fallbacks="$out_dir/compile-fallbacks.txt"
  rm -rf "$best_effort_sources_dir"
  rm -rf "$best_effort_sourcepath_dir"
  mkdir -p "$best_effort_sources_dir"
  mkdir -p "$best_effort_sourcepath_dir"
  : > "$compile_fallbacks"

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

  package_sourcepath_dir() {
    local src="$1"
    local package_name
    package_name="$(sed -n 's/^[[:space:]]*package[[:space:]]\+\([[:alnum:]_.]\+\)[[:space:]]*;[[:space:]]*$/\1/p' "$src" | head -n 1)"
    if [[ -z "$package_name" ]]; then
      printf '%s' "$best_effort_sourcepath_dir"
      return
    fi
    printf '%s/%s' "$best_effort_sourcepath_dir" "${package_name//./\/}"
  }

  link_sourcepath_entry() {
    local src="$1"
    local dst_dir
    dst_dir="$(package_sourcepath_dir "$src")"
    mkdir -p "$dst_dir"
    ln -sfn "$src" "$dst_dir/$(basename "$src")"
  }

  # Copy test sources preserving directory structure and expose them through a
  # package-aware sourcepath mirror so javac can resolve flat transpile outputs.
  : > "$best_effort_sources_file"
  while IFS= read -r -d '' src; do
    rel="${src#"$tests_dir"/}"
    dst="$best_effort_sources_dir/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    link_sourcepath_entry "$dst"
    printf '%s\0' "$dst" >> "$best_effort_sources_file"
  done < "$test_sources_file"

  declare -a pending=()
  while IFS= read -r -d '' src; do
    pending+=("$src")
  done < "$best_effort_sources_file"

  fallback_count=0
  _fallback_list=""
  record_fallback() {
    local src="$1"
    case "$_fallback_list" in
      *"|$src|"*) return ;;  # already recorded
    esac
    _fallback_list="${_fallback_list}|${src}|"
    printf '%s\n' "$src" >> "$compile_fallbacks"
    fallback_count=$((fallback_count + 1))
  }

  # Keep the initial batch compile cheap; use the package-aware sourcepath mirror
  # only when salvaging individual files and restoring placeholders.
  BATCH_JAVAC_FLAGS=("${JAVAC_FLAGS[@]}" -sourcepath "$tests_dir")
  RESOLVE_JAVAC_FLAGS=("${JAVAC_FLAGS[@]}" -sourcepath "$best_effort_sourcepath_dir")

  # --- Start compile daemon for fast in-process javac ---
  start_compile_daemon

  # --- Phase 1: Try compiling all files at once ---
  if daemon_compile "$out_dir/build" "$out_dir/build" "$tests_dir" "${pending[@]}"; then
    pending=()
  fi

  # --- Phase 2: Batch-bisect failing files ---
  while [[ ${#pending[@]} -gt 0 ]]; do
    progress=false

    # Try batch compile to identify error sources
    class_count_before="$(find "$out_dir/build" -type f -name '*.class' | wc -l | tr -d ' ')"
    if daemon_compile "$out_dir/build" "$out_dir/build" "$tests_dir" "${pending[@]}"; then
      progress=true
      pending=()
    else
      class_count_after="$(find "$out_dir/build" -type f -name '*.class' | wc -l | tr -d ' ')"
      if (( class_count_after > class_count_before )); then
        progress=true
      fi

      # Use error files from daemon response
      if [[ ${#_daemon_error_files[@]} -gt 0 ]]; then
        # Replace error sources with placeholders
        for src in "${_daemon_error_files[@]}"; do
          render_placeholder_source "$src"
          record_fallback "$src"
        done
        progress=true

        # Rebuild pending list excluding placeholders
        next_pending=()
        for src in "${pending[@]}"; do
          case "$_fallback_list" in *"|$src|"*) continue ;; esac
          if true; then
            next_pending+=("$src")
          fi
        done
        pending=()
        if [[ ${#next_pending[@]} -gt 0 ]]; then
          pending=("${next_pending[@]}")
        fi
      fi
    fi

    # If no progress from batch, fall back to individual salvage via daemon
    if [[ ${#pending[@]} -gt 0 && "$progress" == "false" ]]; then
      salvage_progress=false
      next_pending=()
      for src in "${pending[@]}"; do
        if daemon_compile "$out_dir/build" "$out_dir/build" "$best_effort_sourcepath_dir" "$src"; then
          salvage_progress=true
          progress=true
        else
          render_placeholder_source "$src"
          daemon_compile "$out_dir/build" "$out_dir/build" "$best_effort_sourcepath_dir" "$src" || true
          record_fallback "$src"
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
      if ! javac "${RESOLVE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$src" >/dev/null 2>"$out_dir/.javac.err"; then
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

# Phase 3: Recompile fallback sources using -sourcepath to resolve dependencies
# from original transpile output instead of placeholder .class stubs.
if [[ "$best_effort" == "true" && -s "$compile_fallbacks" ]]; then
  _t_p3=$(_timer_start)
  # Restore all fallback sources from transpile output
  while IFS= read -r fb_src; do
    rel="${fb_src#"$best_effort_sources_dir"/}"
    orig="$tests_dir/$rel"
    [ -f "$orig" ] && cp "$orig" "$fb_src"
  done < "$compile_fallbacks"
  # Compile with -sourcepath so javac resolves deps from source, not placeholder .class
  p3_restored=0
  p3_files=()
  while IFS= read -r fb_src; do p3_files+=("$fb_src"); done < "$compile_fallbacks"
  if [[ ${#p3_files[@]} -gt 0 ]]; then
    if javac "${RESOLVE_JAVAC_FLAGS[@]}" \
      -cp "$out_dir/build" -d "$out_dir/build" \
      "${p3_files[@]}" >/dev/null 2>"$out_dir/.javac.err"; then
      p3_restored=${#p3_files[@]}
      : > "$compile_fallbacks"
      rm -f "$out_dir/.javac.err"
    else
      p3_error_files=()
      while IFS= read -r err_src; do
        p3_error_files+=("$err_src")
      done < <(
        awk -F: 'NF >= 2 { print $1 }' "$out_dir/.javac.err" \
          | grep "^$best_effort_sources_dir/" \
          | sort -u
      )
      rm -f "$out_dir/.javac.err"

      if [[ ${#p3_error_files[@]} -gt 0 ]]; then
        next_fallbacks="$out_dir/.p3-fallbacks.txt"
        : > "$next_fallbacks"
        for err_src in "${p3_error_files[@]}"; do
          printf '%s\n' "$err_src" >> "$next_fallbacks"
        done
        p3_restored=$(( ${#p3_files[@]} - ${#p3_error_files[@]} ))
        cp "$next_fallbacks" "$compile_fallbacks"
        rm -f "$next_fallbacks"
      else
        # If javac fails without attributing errors to specific sources, keep the
        # full fallback set for the slower restore passes rather than guessing.
        p3_restored=0
      fi
    fi
  fi
  if [ "$p3_restored" -gt 0 ]; then
    remaining=$(wc -l < "$compile_fallbacks" | tr -d ' ')
    echo "best-effort: sourcepath recompile restored $p3_restored source(s), $remaining remaining" >&2
  fi
  echo "phase:recompile-sourcepath $(_timer_elapsed $_t_p3)" >&2
fi

skip_expensive_restore=false
if [[ "$best_effort" == "true" && -s "$compile_fallbacks" ]]; then
  remaining_fallbacks="$(wc -l < "$compile_fallbacks" | tr -d ' ')"
  if [[ "$remaining_fallbacks" =~ ^[0-9]+$ ]] && (( remaining_fallbacks > best_effort_restore_limit )); then
    skip_expensive_restore=true
    echo "best-effort: skipping expensive restore for $remaining_fallbacks remaining source(s) (limit=$best_effort_restore_limit)" >&2
  fi
fi

# Final pass: iteratively restore placeholder sources until no more progress
if [[ "$best_effort" == "true" && -s "$compile_fallbacks" && "$skip_expensive_restore" != "true" ]]; then
  # Compile all placeholders so their types are available
  RESTORE_JAVAC_FLAGS=("${RESOLVE_JAVAC_FLAGS[@]}")
  while IFS= read -r fb_src; do
    javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
  done < "$compile_fallbacks"
  # Iteratively restore original sources
  total_restored=0
  for _round in 1 2 3 4 5 6 7 8; do
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
      if javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "${batch_restore[@]}" >/dev/null 2>"$out_dir/.javac.err"; then
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

        # Revert error files to placeholders, collect non-error files for retry batch
        retry_batch=()
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
            javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
            printf '%s\n' "$fb_src" >> "$next_fallbacks"
          else
            retry_batch+=("$fb_src")
          fi
        done
        # Re-try non-error files as batch with iterative error removal
        for _retry in 1 2 3; do
          if [[ ${#retry_batch[@]} -eq 0 ]]; then break; fi
          if javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "${retry_batch[@]}" >/dev/null 2>"$out_dir/.javac.err"; then
            restored=$((restored + ${#retry_batch[@]}))
            rm -f "$out_dir/.javac.err"
            retry_batch=()
            break
          fi
          # Extract error files from this retry and remove them
          retry_errors=()
          while IFS= read -r err_src; do
            retry_errors+=("$err_src")
          done < <(awk -F: 'NF >= 2 { print $1 }' "$out_dir/.javac.err" | grep "^$best_effort_sources_dir/" | sort -u)
          rm -f "$out_dir/.javac.err"
          if [[ ${#retry_errors[@]} -eq 0 ]]; then break; fi
          next_retry=()
          for fb_src in "${retry_batch[@]}"; do
            is_err=false
            for err_src in "${retry_errors[@]}"; do
              if [[ "$fb_src" == "$err_src" ]]; then is_err=true; break; fi
            done
            if [[ "$is_err" == "true" ]]; then
              render_placeholder_source "$fb_src"
              javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
              printf '%s\n' "$fb_src" >> "$next_fallbacks"
            else
              next_retry+=("$fb_src")
            fi
          done
          retry_batch=("${next_retry[@]}")
        done
        # Any remaining retry files that still fail
        for fb_src in "${retry_batch[@]}"; do
          if ! javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1; then
            render_placeholder_source "$fb_src"
            javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
            printf '%s\n' "$fb_src" >> "$next_fallbacks"
          else
            restored=$((restored + 1))
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

  # Final individual-compile passes: iteratively try each remaining fallback
  # Multiple rounds needed because restoring one file may unblock others
  total_individual=0
  _parallel_jobs="${APEXGOV_JAVAC_PARALLEL:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
  for _iround in 1 2 3 4 5 6 7 8 9 10; do
    if [[ ! -s "$compile_fallbacks" ]]; then break; fi
    round_restored=0
    next_fallbacks="$out_dir/.final-fallbacks.txt"
    : > "$next_fallbacks"
    # Restore all original sources first
    restore_list=()
    no_orig_list=()
    while IFS= read -r fb_src; do
      rel="${fb_src#"$best_effort_sources_dir"/}"
      orig="$tests_dir/$rel"
      if [[ -f "$orig" ]]; then
        cp "$orig" "$fb_src"
        restore_list+=("$fb_src")
      else
        no_orig_list+=("$fb_src")
      fi
    done < "$compile_fallbacks"
    for fb_src in "${no_orig_list[@]}"; do
      printf '%s\n' "$fb_src" >> "$next_fallbacks"
    done
    # Try batch compile all restored sources first
    if [[ ${#restore_list[@]} -gt 0 ]]; then
      if javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "${restore_list[@]}" >/dev/null 2>/dev/null; then
        round_restored=${#restore_list[@]}
      else
        # Batch failed — parallel individual compile
        _final_ok="$out_dir/.final-ok.txt"
        _final_fail="$out_dir/.final-fail.txt"
        : > "$_final_ok"
        : > "$_final_fail"
        printf '%s\0' "${restore_list[@]}" | xargs -0 -P "$_parallel_jobs" -I{} bash -c '
          src="$1"
          if javac '"$(printf '%q ' "${RESTORE_JAVAC_FLAGS[@]}")"' -cp '"$(printf '%q' "$out_dir/build")"' -d '"$(printf '%q' "$out_dir/build")"' "$src" >/dev/null 2>&1; then
            printf "%s\n" "$src" >> '"$(printf '%q' "$_final_ok")"'
          else
            printf "%s\n" "$src" >> '"$(printf '%q' "$_final_fail")"'
          fi
        ' _ {}
        round_restored=$(wc -l < "$_final_ok" | tr -d ' ')
        while IFS= read -r fb_src; do
          render_placeholder_source "$fb_src"
          javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
          printf '%s\n' "$fb_src" >> "$next_fallbacks"
        done < "$_final_fail"
        rm -f "$_final_ok" "$_final_fail"
      fi
    fi
    cp "$next_fallbacks" "$compile_fallbacks"
    rm -f "$next_fallbacks"
    total_individual=$((total_individual + round_restored))
    if [[ "$round_restored" -eq 0 ]]; then break; fi
  done
  if [[ "$total_individual" -gt 0 ]]; then
    echo "best-effort: individually restored $total_individual additional source(s) in $_iround round(s)"
  fi
fi

# Full recompilation pass: recompile ALL sources against the final build state.
# This catches files that couldn't compile during initial best-effort but can now
# because their dependencies were restored in later rounds.
if [[ "$best_effort" == "true" && -s "$compile_fallbacks" && "$skip_expensive_restore" != "true" ]]; then
  _t_recomp=$(_timer_start)
  # Iterative individual recompilation: restore original source and compile
  # individually. Placeholder .class is kept (provides type stubs for dependents)
  # and overwritten on success. Each round may unblock dependents.
  recomp_restored=0
  _parallel_jobs="${APEXGOV_JAVAC_PARALLEL:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
  for _rr in 1 2 3 4 5 6 7 8; do
    rr_progress=0
    next_fallbacks="$out_dir/.recomp-fallbacks.txt"
    : > "$next_fallbacks"
    # Restore all original sources first
    recomp_list=()
    while IFS= read -r fb_src; do
      rel="${fb_src#"$best_effort_sources_dir"/}"
      orig="$tests_dir/$rel"
      if [[ -f "$orig" ]]; then
        cp "$orig" "$fb_src"
        recomp_list+=("$fb_src")
      else
        printf '%s\n' "$fb_src" >> "$next_fallbacks"
      fi
    done < "$compile_fallbacks"
    # Try batch compile first
    if [[ ${#recomp_list[@]} -gt 0 ]]; then
      if javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "${recomp_list[@]}" >/dev/null 2>/dev/null; then
        rr_progress=${#recomp_list[@]}
      else
        # Batch failed — parallel individual
        _recomp_ok="$out_dir/.recomp-ok.txt"
        _recomp_fail="$out_dir/.recomp-fail.txt"
        : > "$_recomp_ok"
        : > "$_recomp_fail"
        printf '%s\0' "${recomp_list[@]}" | xargs -0 -P "$_parallel_jobs" -I{} bash -c '
          src="$1"
          if javac '"$(printf '%q ' "${RESTORE_JAVAC_FLAGS[@]}")"' -cp '"$(printf '%q' "$out_dir/build")"' -d '"$(printf '%q' "$out_dir/build")"' "$src" >/dev/null 2>&1; then
            printf "%s\n" "$src" >> '"$(printf '%q' "$_recomp_ok")"'
          else
            printf "%s\n" "$src" >> '"$(printf '%q' "$_recomp_fail")"'
          fi
        ' _ {}
        rr_progress=$(wc -l < "$_recomp_ok" | tr -d ' ')
        while IFS= read -r fb_src; do
          render_placeholder_source "$fb_src"
          javac "${RESTORE_JAVAC_FLAGS[@]}" -cp "$out_dir/build" -d "$out_dir/build" "$fb_src" >/dev/null 2>&1 || true
          printf '%s\n' "$fb_src" >> "$next_fallbacks"
        done < "$_recomp_fail"
        rm -f "$_recomp_ok" "$_recomp_fail"
      fi
    fi
    cp "$next_fallbacks" "$compile_fallbacks"
    rm -f "$next_fallbacks"
    recomp_restored=$((recomp_restored + rr_progress))
    if [[ "$rr_progress" -eq 0 ]]; then break; fi
  done
  if [[ "$recomp_restored" -gt 0 ]]; then
    remaining=$(wc -l < "$compile_fallbacks" | tr -d ' ')
    echo "best-effort: recompilation restored $recomp_restored source(s), $remaining remaining" >&2
  fi
  echo "phase:recompile $(_timer_elapsed $_t_recomp)" >&2
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
runner_log="$out_dir/runner.log"
rm -f "$runner_log"
"${runner_cmd[@]}" 2>&1 | tee "$runner_log"
runner_exit=$?
set -e
echo "phase:test-runner $(_timer_elapsed $_t)" >&2

if [[ "$runner_exit" -eq 2 ]]; then
  # Some external repos intentionally ship no @Test classes in the selected source set.
  # Treat this as a successful compile/emulation run.
  exit 0
fi
exit "$runner_exit"
