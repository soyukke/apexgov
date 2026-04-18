_default:
    @just --list

# ReleaseFast ビルド
build-fast:
    zig build -Doptimize=ReleaseFast

# 単一リポジトリで interpret test を実行 (time -l で計測)
# usage: just bench NebulaLogger
bench REPO: build-fast
    #!/usr/bin/env bash
    set -euo pipefail
    repo_path=".local-fixtures/apex/repos/{{REPO}}"
    if [[ ! -d "$repo_path" ]]; then
        echo "Repo not found: $repo_path" >&2
        exit 1
    fi
    mkdir -p tmp
    log="tmp/bench-{{REPO}}-$(date +%Y%m%d-%H%M%S).log"
    echo "=== {{REPO}} ===" | tee "$log"
    /usr/bin/time -l ./zig-out/bin/apexgov interpret test "$repo_path" 2>&1 | tee -a "$log"
    echo "Log: $log"

# .local-fixtures/interpret-targets.txt のリストを直列実行し、サマリーを出力
# (1 行 1 リポジトリ名、空行と # コメントは無視)
bench-all: build-fast
    #!/usr/bin/env bash
    set -euo pipefail
    targets=".local-fixtures/interpret-targets.txt"
    if [[ ! -f "$targets" ]]; then
        echo "Missing $targets — create it with one repo name per line" >&2
        exit 1
    fi
    mkdir -p tmp
    ts=$(date +%Y%m%d-%H%M%S)
    log="tmp/bench-all-$ts.log"
    summary="tmp/bench-all-$ts.summary"
    fmt='%-32s %8s %8s %8s %10s %10s\n'
    {
        printf "$fmt" REPO PASSED FAILED TOTAL "REAL(s)" "MEM(MB)"
        printf '%s\n' "--------------------------------------------------------------------------------"
    } | tee "$summary"
    while IFS= read -r repo || [[ -n "$repo" ]]; do
        repo="${repo%%#*}"
        repo="${repo// /}"
        repo="${repo//$'\t'/}"
        [[ -z "$repo" ]] && continue
        repo_path=".local-fixtures/apex/repos/$repo"
        echo "=== $repo ===" >> "$log"
        if [[ ! -d "$repo_path" ]]; then
            printf "$fmt" "$repo" MISSING - - - - | tee -a "$summary"
            continue
        fi
        out=$(/usr/bin/time -l ./zig-out/bin/apexgov interpret test "$repo_path" 2>&1) || true
        printf '%s\n' "$out" >> "$log"
        results_line=$(printf '%s\n' "$out" | grep -E 'Results: [0-9]+ total' | tail -1 || true)
        total=$(awk '{print $3}' <<< "$results_line")
        passed=$(awk '{print $5}' <<< "$results_line")
        failed=$(awk '{print $7}' <<< "$results_line")
        real=$(printf '%s\n' "$out" | awk '/real/ && /user/ && /sys/ {print $1; exit}')
        mem_bytes=$(printf '%s\n' "$out" | awk '/maximum resident set size/ {print $1; exit}')
        mem_mb=$(awk -v b="${mem_bytes:-0}" 'BEGIN { printf "%.1f", b/1024/1024 }')
        printf "$fmt" "$repo" "${passed:-?}" "${failed:-?}" "${total:-?}" "${real:-?}" "$mem_mb" | tee -a "$summary"
    done < "$targets"
    echo
    echo "Log:     $log"
    echo "Summary: $summary"
