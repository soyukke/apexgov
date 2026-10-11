# Apex Validation Fixtures

`apexgov` のローカル検証用サンプルです。

## 構成

- `force-app/`: SFDX形式のApexサンプル
  - `CustomService.cls`: `instanceof` の non-SObject 型比較確認用ヘルパ
  - `BulkSafeService.cls`: バルク化済みのOK例
  - `GovernorRiskService.cls`: SOQL/DML in loop などのNG例
  - `GuardedLoopService.cls`: `if (n > 120) return;` で上限を与える例
  - `DoWhileRiskService.cls`: `do` / 次行 `{` / `} while (i < n)` 形式の上限推論 + DML検出例
  - `ExceededGuardService.cls`: `if (n > 200) return;` でもSOQL上限を超える例
  - `ElseIfGuardService.cls`: `} else if (n > 140) return;` 形式の上限ガード例
  - `CrossFileCallerService.cls` + `CrossFileDmlHelper.cls`: 別クラス呼び出し経由でDMLに到達する例
  - `HelperChainService.cls`: ループ内ヘルパー呼び出し経由でDMLに到達する例
  - `NestedHelperMultiplierService.cls`: ヘルパー内ループ呼び出しでDML回数が乗算される例
  - `SameArityOverloadService.cls`: 同一arityオーバーロードを型で選別する例
  - `TranspileQueryBindsService.cls`: `Database.countQueryWithBinds/getQueryLocatorWithBinds` の transpile 検証例
  - `TranspileMergeService.cls`: `merge` 文（index参照 / helper呼び出し / 複数duplicate）の transpile 検証例
  - `TranspileMapConstructorService.cls`: `new Map<Id, SObject>(list/map)` の transpile 検証例
  - `TranspileSwitchService.cls`: `switch on / when` の transpile 検証例
  - `TranspileSwitchTypeService.cls`: `switch on SObject` + `when Account acc` 型分岐の transpile 検証例
  - `TranspileInstanceofService.cls`: `record instanceof Account` / 否定 / OR / `instanceof SObject` の transpile 検証例
  - `TranspileDoWhileService.cls`: `do` / 次行 `{` を含む `do-while` の transpile 検証例
  - `TranspileStringService.cls`: `String.isBlank/join/escapeSingleQuotes` の transpile 検証例
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
- `DoWhileRiskService.cls` でも `Loop upper bound <= 120` の `AG003` が出る
- `ExceededGuardService.cls` では `Loop upper bound <= 200` の超過エラーが出る
- `CrossFileCallerService.cls` では別クラス経由でも `AG003` が出る
- `HelperChainService.cls` ではヘルパーチェーン経由でも `AG003` が出る
- `NestedHelperMultiplierService.cls` では `up to 200 times` 相当の `AG003` 超過エラーが出る
- `SameArityOverloadService.cls` では `Contact target = records[i]; touch(target);` から `touch(Contact)` 側だけが選ばれて `AG003` が出る
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

## 5) Transpile + Java compile smoke

```bash
./zig-out/bin/apexgov emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-validation-transpile --overwrite
nix develop -c javac -d reports/apex-validation-transpile/classes \
  $(find tools/java-emulation/src -name "*.java") \
  $(find reports/apex-validation-transpile -name "*.java")
```

期待結果:
- `TranspileQueryBindsService.cls` の `countQueryWithBinds/getQueryLocatorWithBinds` が query string 引数でJava化される
- `TranspileMergeService.cls` の `merge` 文が `Database.merge(...)` 呼び出しに変換される
- `TranspileMapConstructorService.cls` の `new Map<Id, Account>(list/map)` が `ApexCollections.toIdMap(...)` へ変換される
- `TranspileSwitchService.cls` の `switch on / when / when else` が Java `switch (...)` / `case ... ->` / `default ->` へ変換される
- `TranspileSwitchTypeService.cls` の `when Account acc` / `when Contact con` が Java `switch (ApexSwitch.typeName(...))` + `case "Account"` 形式へ変換される
- `TranspileInstanceofService.cls` の SObject 型比較（否定/OR含む）が `ApexSwitch.typeName(...)` ベースへ変換され、`instanceof SObject` は `instanceof ApexSObject` へ変換される
- `TranspileDoWhileService.cls` の `} while (records[i] instanceof Account);` が Java do-while + `ApexSwitch.typeName(...)` 形式へ変換される
- `TranspileStringService.cls` の `String.isBlank/join/escapeSingleQuotes` が `ApexStrings.*` へ変換される
