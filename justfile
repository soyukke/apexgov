_default:
    @just --list

# CI 相当のローカル実行
ci:
    zig fmt --check src/
    just lint
    zig build
    zig build test --summary all
    cd editors/vscode && npm run compile

# --- Zig style checker (tiger style lite) ---
#
# `just lint` は src/ の現状を tools/style_baseline.txt と比較し、
# 増えた違反だけで失敗する (ratcheting baseline)。既存違反を直した後は
# `just lint-update-baseline` で baseline を更新する。
# ZIG_STYLE_CHECKER 環境変数で checker 本体のパスを差し替え可能。
style_checker := env("ZIG_STYLE_CHECKER", "tools/check_style.zig")

# 共通オプション。
#
# src/interpret/ と src/apex_parser/ は Apex 言語の camelCase mirroring を
# 優先し、以下 3 ルールの対象外にする（Apex の組み込みメソッド名やトークンを
# コード中の文字列リテラル・identifier として扱うので、snake_case 化や
# 機械的な line wrap を行うと interpret が壊れる — PR #90 で実証済み）:
#   * function_not_snake_case  : Apex 識別子 mirror
#   * line_too_long            : Apex 文字列リテラルの構文保持
#   * function_too_long        : Apex runtime dispatcher は本質的に巨大
#
# その他 (src/check/, src/lsp/, src/typegen/ 等) では全ルールを維持する。
style_checker_args := "--root src \
    --disable-path src/interpret/:function_not_snake_case \
    --disable-path src/apex_parser/:function_not_snake_case \
    --disable-path src/interpret/:line_too_long \
    --disable-path src/apex_parser/:line_too_long \
    --disable-path src/interpret/:function_too_long \
    --disable-path src/apex_parser/:function_too_long \
    --disable-path src/check/scanner.zig:function_too_long \
    --disable-path src/check/call_graph.zig:function_too_long"

# zig fmt でフォーマット崩れを検出 (書き換えはしない)
fmt-check:
    zig fmt --check src

# zig fmt でフォーマットを書き換え
fmt:
    zig fmt src

# baseline と比較して新規違反があれば fail
lint:
    zig run {{style_checker}} -- {{style_checker_args}}

# baseline を無視して全違反を列挙
lint-strict:
    zig run {{style_checker}} -- {{style_checker_args}} --strict

# baseline を現在の違反で再スナップショット
lint-update-baseline:
    zig run {{style_checker}} -- {{style_checker_args}} --update-baseline

# fmt-check + lint をまとめて実行 (PR 前の最低限チェック)
check: fmt-check lint

# fmt-check + strict lint をまとめて実行
check-strict: fmt-check lint-strict
# --- end zig style checker ---

# fixture-backed な回帰テストを明示実行
test-fixtures:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -d ".local-fixtures/apex/repos" ]]; then
        echo "Missing .local-fixtures/apex/repos" >&2
        exit 1
    fi
    APEXGOV_ENABLE_FIXTURE_TESTS=1 zig test -O ReleaseFast src/root.zig --test-filter "fixture "

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
