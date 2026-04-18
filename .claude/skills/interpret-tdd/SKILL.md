---
name: interpret-tdd
description: interpret test のフィクスチャカバレッジ向上ワークフロー。100%近いリポジトリから順に failing test を TDD で修正し、全体リグレッションチェックを回す。「interpret」「カバレッジ」「フィクスチャテスト」「TDD」「テスト通す」などのキーワードで自動トリガー。
---

# interpret-tdd — フィクスチャテスト TDD ワークフロー

`.local-fixtures/apex/repos/` の外部リポジトリに対して `apexgov interpret test` を実行し、パス率を向上させる TDD ワークフロー。

## ワークフロー概要

```
1. ベースライン計測  →  2. ターゲット選定  →  3. ブランチ作成
      ↑                                           ↓
6. 次のターゲットへ  ←  5. リグレッションチェック  ←  4. TDD 修正
```

## 手順

### Step 1: ベースライン計測

全フィクスチャに対して interpret test を実行し、現在のパス率を計測する。

```bash
total_pass=0; total_fail=0; total_tests=0; total_repos=0; perfect_repos=0; results=""
for repo in .local-fixtures/apex/repos/*/; do
  name=$(basename "$repo")
  output=$(timeout 120 ./zig-out/bin/apexgov interpret test "$repo" 2>&1)
  line=$(echo "$output" | grep -E "^--- Results:")
  if [ -n "$line" ]; then
    tests=$(echo "$line" | grep -oE '[0-9]+ total' | grep -oE '[0-9]+')
    passed=$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
    failed=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
    total_tests=$((total_tests + tests))
    total_pass=$((total_pass + passed))
    total_fail=$((total_fail + failed))
    total_repos=$((total_repos + 1))
    if [ "$failed" = "0" ]; then
      perfect_repos=$((perfect_repos + 1))
      results="${results}${name}: ${passed}/${tests} (100%)\n"
    else
      pct=$((passed * 100 / tests))
      results="${results}${name}: ${passed}/${tests} (${pct}%) [${failed} FAIL]\n"
    fi
  else
    notest=$(echo "$output" | grep -c "No test classes found")
    if [ "$notest" -gt 0 ]; then
      results="${results}${name}: no tests\n"
    else
      err=$(echo "$output" | tail -1)
      results="${results}${name}: ERROR - ${err}\n"
    fi
  fi
done
echo "===== SUMMARY ====="
echo "Repos with tests: $total_repos"
echo "Perfect (100%): $perfect_repos"
echo "Total tests: $total_tests"
echo "Passed: $total_pass"
echo "Failed: $total_fail"
if [ "$total_tests" -gt 0 ]; then
  echo "Pass rate: $((total_pass * 100 / total_tests))%"
fi
echo ""
echo "===== PER-REPO ====="
printf "$results"
```

このコマンドは `run_in_background` で実行し、完了通知を待つ。

### Step 2: ターゲット選定

ベースラインから **100% に近いが少数の FAIL があるリポジトリ** を優先度順に選ぶ。

優先度ルール:
1. **FAIL 数が少ないリポジトリ** を先に（1-5 FAIL を最優先）
2. パス率が高いリポジトリを先に（99% > 95% > 91% > ...）
3. ERROR（クラッシュ）はパース/ランタイムの根本問題の可能性があるため、FAIL 消化後に取り組む

### Step 3: ブランチ作成

ターゲットリポジトリごとに feature ブランチを作成する。

```bash
git checkout -b fix/interpret-<リポジトリ名>
```

命名規則: `fix/interpret-<リポジトリ名>`（例: `fix/interpret-coral-cloud`）

### Step 4: TDD 修正

#### 4a. 失敗テストの特定

```bash
./zig-out/bin/apexgov interpret test .local-fixtures/apex/repos/<リポジトリ名>/ 2>&1 | grep '^\[FAIL\]'
```

#### 4b. 失敗原因の調査

各 FAIL の出力から:
- `Expected: X, Actual: Y` — 値の不一致。interpret エンジンのロジックバグ
- `null` / `panic` / スタックトレース — ランタイムエラー。未実装メソッドや型の問題
- `error:` — パースエラーまたはコンパイルエラー

テストクラスの Apex ソースを読んで、何を期待しているか理解する:

```bash
# テストクラスを探す
find .local-fixtures/apex/repos/<リポジトリ名> -name '*Test*.cls' -o -name '*_Tests.cls' | sort
```

#### 4c. 修正の実装

interpret エンジンの修正対象は主に以下:

| 修正対象 | ファイル |
|---|---|
| メソッド実装追加 | `src/interpret/` 配下の該当クラス |
| 型システム修正 | `src/interpret/` 配下 |
| パーサー修正 | `src/check/` 配下（パーサー共有） |
| stdlib 追加 | `src/interpret/` 配下 |

TDD サイクル:
1. **Red**: 失敗するテストを確認（`interpret test` で FAIL を再現）
2. **Green**: 最小限の修正で PASS させる
3. **Refactor**: 必要なら整理

修正ごとに対象リポジトリのテストを再実行して確認:

```bash
zig build && ./zig-out/bin/apexgov interpret test .local-fixtures/apex/repos/<リポジトリ名>/
```

#### 4d. ユニットテストの確認

interpret エンジンの修正が既存ユニットテストを壊していないか確認:

```bash
zig build test
```

### Step 5: リグレッションチェック

修正が完了したら、**全フィクスチャ** に対してリグレッションチェックを実行する。Step 1 と同じコマンドを `run_in_background` で実行。

チェック項目:
- ターゲットリポジトリが 100%（または目標値）に到達したか
- **他のリポジトリの PASS 数が減っていないか**（リグレッション）
- ERROR だったリポジトリが新たに壊れていないか

リグレッションがあった場合:
1. どのテストが新たに FAIL したか特定
2. 修正の副作用を調査
3. 修正を調整して再テスト

### Step 6: コミット & 次のターゲットへ

リグレッションなしを確認したらコミット:

```bash
git add src/
git commit -m "fix: interpret — <リポジトリ名> のテスト N 件を修正

<修正内容の要約>"
```

次のターゲットリポジトリへ進む（Step 2 に戻る）。

## 注意事項

- **ビルドを忘れない**: ソース修正後は `zig build` してからテスト実行
- **タイムアウト**: 1 リポジトリ 120 秒でタイムアウト設定。NPSP など大規模リポジトリはより長い時間が必要な場合あり
- **ERROR の扱い**: スタックトレースが出るケース（fflib-apex-common 系等）はパーサーまたはランタイムの根本的なバグの可能性が高い。個別の FAIL より影響範囲が大きいため、優先的に調査する価値がある場合もある
- **全体のベースライン保存**: ワークフロー開始時のベースライン数値を記録しておき、進捗を追跡する
