# Apex Validation Fixtures

`apexgov` のローカル検証用サンプルです。

## 構成

- `force-app/`: SFDX形式のApexサンプル
  - `BulkSafeService.cls`: バルク化済みのOK例
  - `GovernorRiskService.cls`: SOQL/DML in loop などのNG例
  - `GuardedLoopService.cls`: `if (n > 120) return;` で上限を与える例
  - `ExceededGuardService.cls`: `if (n > 200) return;` でもSOQL上限を超える例
  - `ElseIfGuardService.cls`: `} else if (n > 140) return;` 形式の上限ガード例
  - `CrossFileCallerService.cls` + `CrossFileDmlHelper.cls`: 別クラス呼び出し経由でDMLに到達する例
  - `HelperChainService.cls`: ループ内ヘルパー呼び出し経由でDMLに到達する例
  - `NestedHelperMultiplierService.cls`: ヘルパー内ループ呼び出しでDML回数が乗算される例
  - `SameArityOverloadService.cls`: 同一arityオーバーロードを型で選別する例
  - `AccountValidation.trigger`: 上記クラスを呼ぶトリガ
- `logs/`: `profile` 検証用のDebug Log
- `baseline/profile-baseline.json`: 回帰比較用ベースライン
- `apexgov.toml`: 予算と回帰設定（厳しめ）
- `apexgov-regression.toml`: 予算は緩め、回帰でfail
- `apexgov-soft.toml`: 予算は緩め、回帰は警告のみ

## 1) 静的チェック (`check`)

```bash
zig build run -- check examples/apex-validation/force-app --format text
```

期待結果:
- `GovernorRiskService.cls` に対して `AG002/AG003` を含むfindingが出る
- `GuardedLoopService.cls` では `Loop upper bound <= 120` の警告が出る
- `ExceededGuardService.cls` では `Loop upper bound <= 200` の超過エラーが出る
- `CrossFileCallerService.cls` では別クラス経由でも `AG003` が出る
- `HelperChainService.cls` ではヘルパーチェーン経由でも `AG003` が出る
- `NestedHelperMultiplierService.cls` では `up to 200 times` 相当の `AG003` 超過エラーが出る
- `SameArityOverloadService.cls` では `touch(Contact)` 側だけが選ばれて `AG003` が出る
- exit code は `1`（デフォルト閾値 `warning`）

## 2) プロファイル予算チェック (`profile`)

```bash
zig build run -- profile examples/apex-validation/logs --config examples/apex-validation/apexgov.toml --format text
```

期待結果:
- `async-over-budget.log` のCPUが予算超過で `OVER_BUDGET`
- exit code は `1`

## 3) ベースライン回帰チェック（回帰でfail）

```bash
zig build run -- profile examples/apex-validation/logs \
  --config examples/apex-validation/apexgov-regression.toml \
  --baseline examples/apex-validation/baseline/profile-baseline.json \
  --format text
```

期待結果:
- `GovernorRiskService.run` と `QueueableJob.execute` が回帰として表示される
- `[ci].fail_on_regression = true` のため exit code は `1`（予算超過は無し）

## 4) 回帰を警告のみで通す（予算超過も無し）

```bash
zig build run -- profile examples/apex-validation/logs \
  --config examples/apex-validation/apexgov-soft.toml \
  --baseline examples/apex-validation/baseline/profile-baseline.json \
  --format text
```

この場合:
- 回帰メッセージは出る
- exit code は `0`
