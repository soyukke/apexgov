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

# 共通オプション: ルール除外なし。全 src/ 配下に対して同一ルールを適用する。
style_checker_args := "--root src"

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

# LSP JSON-RPC smoke/regression suite
lsp-smoke: build-fast
    node tools/lsp_smoke.js --server ./zig-out/bin/apexgov

# Fixture-backed LSP dogfood sweep across real Apex repositories
lsp-dogfood: build-fast
    node tools/lsp_dogfood.js --server ./zig-out/bin/apexgov

# VS Code extension package
vsce-package:
    #!/usr/bin/env bash
    set -euo pipefail
    cd editors/vscode
    version="$(node -p "require('./package.json').version")"
    npx vsce package --out "apexgov-$version.vsix"

# Verify Visual Studio Marketplace publishing auth via Azure CLI / Entra.
vsce-azure-verify:
    #!/usr/bin/env bash
    set -euo pipefail
    azure_dir="${AZURE_CONFIG_DIR:-$HOME/.local/state/azure/apexgov-vsce}"
    mkdir -p "$azure_dir"
    chmod 700 "$azure_dir"
    cd editors/vscode
    publisher="$(node -p "require('./package.json').publisher")"
    AZURE_CONFIG_DIR="$azure_dir" npx vsce verify-pat "$publisher" --azure-credential

# Publish the current VSIX via Azure CLI / Entra. Run `az-apexgov-login` first.
vsce-azure-publish: vsce-package
    #!/usr/bin/env bash
    set -euo pipefail
    azure_dir="${AZURE_CONFIG_DIR:-$HOME/.local/state/azure/apexgov-vsce}"
    mkdir -p "$azure_dir"
    chmod 700 "$azure_dir"
    cd editors/vscode
    version="$(node -p "require('./package.json').version")"
    publisher="$(node -p "require('./package.json').publisher")"
    vsix="apexgov-$version.vsix"
    AZURE_CONFIG_DIR="$azure_dir" npx vsce verify-pat "$publisher" --azure-credential
    AZURE_CONFIG_DIR="$azure_dir" npx vsce publish --azure-credential --packagePath "$vsix"

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
    ts="$(date +%Y%m%d-%H%M%S)"
    log="tmp/bench-{{REPO}}-$ts.log"
    echo "=== {{REPO}} ===" | tee "$log"
    rc=0
    set +e
    if [[ "{{REPO}}" == "NPSP" ]]; then
        if [[ -n "${APEXGOV_NPSP_BENCH_JOBS:-}" ]]; then
            jobs="$APEXGOV_NPSP_BENCH_JOBS"
        else
            mem_bytes="${APEXGOV_NPSP_BENCH_MEM_BYTES:-$(sysctl -n hw.memsize 2>/dev/null || echo 0)}"
            if [[ "$mem_bytes" =~ ^[0-9]+$ ]] && (( mem_bytes > 0 && mem_bytes <= 8589934592 )); then
                jobs=2
            else
                jobs=4
            fi
        fi
        echo "NPSP bench jobs: $jobs" | tee -a "$log"
        /usr/bin/time -l bash -c '
            set -euo pipefail
            repo_path="$1"
            jobs="$2"
            ts="$3"
            declare -a pids=()
            for shard in $(seq 0 $((jobs - 1))); do
                ./zig-out/bin/apexgov interpret test --shard "$shard/$jobs" "$repo_path" \
                    > "tmp/bench-NPSP-shard-$shard-$ts.log" 2>&1 &
                pids+=("$!")
            done
            rc=0
            for pid in "${pids[@]}"; do
                wait "$pid" || rc=1
            done
            for shard in $(seq 0 $((jobs - 1))); do
                cat "tmp/bench-NPSP-shard-$shard-$ts.log"
            done
            set +o pipefail
            pass=$(grep -h "^\[PASS\]" tmp/bench-NPSP-shard-*-"$ts".log | wc -l | tr -d " ")
            fail=$(grep -h "^\[FAIL\]" tmp/bench-NPSP-shard-*-"$ts".log | wc -l | tr -d " ")
            error=$(grep -h "^\[ERROR\]" tmp/bench-NPSP-shard-*-"$ts".log | wc -l | tr -d " ")
            set -o pipefail
            total=$((pass + fail + error))
            echo
            echo "--- Results: $total total, $pass passed, $((fail + error)) failed ---"
            exit "$rc"
        ' bash "$repo_path" "$jobs" "$ts" 2>&1 | tee -a "$log"
        rc="${PIPESTATUS[0]}"
    else
        /usr/bin/time -l ./zig-out/bin/apexgov interpret test "$repo_path" 2>&1 | tee -a "$log"
        rc="${PIPESTATUS[0]}"
    fi
    set -e
    echo "Log: $log"
    exit "$rc"

# 非 git 管理のローカル target file を時間上限付きで直列実行する。
# usage: just bench-local .local-fixtures/interpret-experimental-targets.txt 180
bench-local TARGETS=".local-fixtures/interpret-experimental-targets.txt" SECONDS="180": build-fast
    #!/usr/bin/env bash
    set -euo pipefail
    targets="{{TARGETS}}"
    seconds="{{SECONDS}}"
    if [[ ! -f "$targets" ]]; then
        echo "Missing $targets — create it with one repo name per line" >&2
        exit 1
    fi
    mkdir -p tmp
    ts=$(date +%Y%m%d-%H%M%S)
    summary="tmp/bench-local-$ts.summary"
    fmt='%-32s %8s %8s %8s %10s\n'
    {
        printf "$fmt" REPO PASSED FAILED ERROR STATUS
        printf '%s\n' "--------------------------------------------------------------------------"
    } | tee "$summary"
    kill_tree() {
        local root="$1"
        local children child
        children=$(pgrep -P "$root" 2>/dev/null || true)
        for child in $children; do
            kill_tree "$child"
        done
        kill -TERM "$root" 2>/dev/null || true
    }
    while IFS= read -r repo || [[ -n "$repo" ]]; do
        repo="${repo%%#*}"
        repo="${repo// /}"
        repo="${repo//$'\t'/}"
        [[ -z "$repo" ]] && continue
        repo_path=".local-fixtures/apex/repos/$repo"
        log="tmp/bench-local-$repo-$ts.log"
        if [[ ! -d "$repo_path" ]]; then
            printf "$fmt" "$repo" MISSING - - - | tee -a "$summary"
            continue
        fi
        (
            /usr/bin/time -l ./zig-out/bin/apexgov interpret test "$repo_path"
        ) > "$log" 2>&1 &
        pid=$!
        rc=0
        for _ in $(seq 1 "$seconds"); do
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || rc=$?
                break
            fi
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill_tree "$pid"
            wait "$pid" 2>/dev/null || true
            rc=124
        fi
        pass=$(grep -c '^\[PASS\]' "$log" || true)
        fail=$(grep -c '^\[FAIL\]' "$log" || true)
        error=$(grep -c '^\[ERROR\]' "$log" || true)
        results_line=$(grep -E '^--- Results:' "$log" | tail -1 || true)
        status=$([[ -n "$results_line" ]] && echo "done" || echo "timeout")
        if [[ "$rc" != "0" && "$status" == "done" ]]; then
            status="failed"
        fi
        printf "$fmt" "$repo" "$pass" "$fail" "$error" "$status" | tee -a "$summary"
    done < "$targets"
    echo "Summary: $summary"

# 単一 repo の単一テスト/クラスを切り出して改善するためのショートカット。
# usage: just test-local SomeRepo SomeTestClass someMethod
test-local REPO CLASS METHOD="": build-fast
    #!/usr/bin/env bash
    set -euo pipefail
    repo_path=".local-fixtures/apex/repos/{{REPO}}"
    if [[ ! -d "$repo_path" ]]; then
        echo "Repo not found: $repo_path" >&2
        exit 1
    fi
    if [[ -n "{{METHOD}}" ]]; then
        ./zig-out/bin/apexgov interpret test --class "{{CLASS}}" --method "{{METHOD}}" "$repo_path"
    else
        ./zig-out/bin/apexgov interpret test --class "{{CLASS}}" "$repo_path"
    fi

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
    declare -a repos=()
    declare -A repo_logs=()
    declare -A repo_times=()
    declare -A repo_pids=()
    declare -A repo_missing=()
    while IFS= read -r repo || [[ -n "$repo" ]]; do
        repo="${repo%%#*}"
        repo="${repo// /}"
        repo="${repo//$'\t'/}"
        [[ -z "$repo" ]] && continue
        repos+=("$repo")
        repo_path=".local-fixtures/apex/repos/$repo"
        if [[ ! -d "$repo_path" ]]; then
            repo_missing["$repo"]=1
            continue
        fi
        repo_log="tmp/bench-all-$repo-$ts.log"
        repo_time="tmp/bench-all-$repo-$ts.time"
        repo_logs["$repo"]="$repo_log"
        repo_times["$repo"]="$repo_time"
        (
            start=$(perl -MTime::HiRes=time -e "printf \"%.0f\", time()*1000")
            if [[ "$repo" == "NebulaLogger" ]]; then
                jobs="${APEXGOV_BENCH_ALL_NEBULA_JOBS:-8}"
                declare -a shard_pids=()
                for shard in $(seq 0 $((jobs - 1))); do
                    ./zig-out/bin/apexgov interpret test --summary-only --shard "$shard/$jobs" "$repo_path" \
                        > "tmp/bench-all-$repo-shard-$shard-$ts.log" 2>&1 &
                    shard_pids+=("$!")
                done
                for pid in "${shard_pids[@]}"; do
                    wait "$pid" || true
                done
                cat tmp/bench-all-$repo-shard-*-"$ts".log > "$repo_log"
                pass=$(awk '/^--- Results:/ { passed += $5 } END { print passed + 0 }' "$repo_log")
                fail=$(awk '/^--- Results:/ { failed += $7 } END { print failed + 0 }' "$repo_log")
                total=$(awk '/^--- Results:/ { total += $3 } END { print total + 0 }' "$repo_log")
                printf '\n--- Results: %d total, %d passed, %d failed ---\n' "$total" "$pass" "$fail" >> "$repo_log"
            else
                ./zig-out/bin/apexgov interpret test --summary-only "$repo_path" > "$repo_log" 2>&1 || true
            fi
            end=$(perl -MTime::HiRes=time -e "printf \"%.0f\", time()*1000")
            awk -v ms="$((end - start))" 'BEGIN { printf "%.2f\n", ms / 1000 }' > "$repo_time"
        ) &
        repo_pids["$repo"]=$!
    done < "$targets"
    for repo in "${repos[@]}"; do
        if [[ -n "${repo_pids[$repo]:-}" ]]; then
            wait "${repo_pids[$repo]}" || true
        fi
    done
    for repo in "${repos[@]}"; do
        if [[ -n "${repo_missing[$repo]:-}" ]]; then
            printf "$fmt" "$repo" MISSING - - - - | tee -a "$summary"
            continue
        fi
        repo_log="${repo_logs[$repo]}"
        repo_time="${repo_times[$repo]}"
        echo "=== $repo ===" >> "$log"
        cat "$repo_log" >> "$log"
        out=$(cat "$repo_log")
        results_line=$(printf '%s\n' "$out" | grep -E 'Results: [0-9]+ total' | tail -1 || true)
        total=$(awk '{print $3}' <<< "$results_line")
        passed=$(awk '{print $5}' <<< "$results_line")
        failed=$(awk '{print $7}' <<< "$results_line")
        real=$(cat "$repo_time")
        mem_mb="0.0"
        printf "$fmt" "$repo" "${passed:-?}" "${failed:-?}" "${total:-?}" "${real:-?}" "$mem_mb" | tee -a "$summary"
    done
    echo
    echo "Log:     $log"
    echo "Summary: $summary"
