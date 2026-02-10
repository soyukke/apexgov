# apexgov

`apexgov` is an offline Apex static checker and debug log profiler for CI/CD.

## Why

- Detect governor-risk code paths before deploy
- Catch SOSL / Callout / Messaging operations inside loops with limit-aware warnings
- Estimate loop upper bounds from guards (for example `if (n > 200) return`) and show likely limit exceed points
- Follow helper method call chains across files/classes to catch indirect SOQL/DML in loops
- Multiply callee-side loop effects into governor estimates (for example nested helper loops)
- Use method arity and inferred literal/new-expression/local variable types to reduce false positives on overloaded calls
- Track CPU/Heap budgets from Apex Debug Logs in CI
- Emit machine-readable reports (`json`, `sarif`) for pipelines

## Commands

### `check`

Static heuristics for governor/CPU/Heap anti-patterns.

```bash
zig build run -- check force-app --format text
zig build run -- check force-app --format sarif --out reports/apexgov.sarif
```

### `profile`

Offline parser for Apex debug logs with budget checks.

```bash
zig build run -- profile artifacts/logs --config apexgov.toml
zig build run -- profile artifacts/logs --format json --out reports/profile.json
zig build run -- profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
```

If budget is exceeded, the process exits with code `1`.
When `[ci].fail_on_regression = true`, baseline regressions also exit with code `1`.

### `emulate`

Java系の補助エミュレーション機能です。

```bash
zig build run -- emulate java
zig build run -- emulate java reports/java-calibration-local --iterations 80000 --nix
zig build run -- emulate test tools/java-emulation/examples --out reports/java-emulation --nix
zig build run -- emulate transpile force-app/main/default/classes --out reports/apex-transpile --package generated
```

## Configuration

Copy `apexgov.toml.example` to `apexgov.toml` and tune budgets.

```toml
[budget.sync]
cpu_ms = 8000
heap_bytes = 5000000

[budget.async]
cpu_ms = 50000
heap_bytes = 10000000

[cpu.model]
base_ms = 500
soql_ms = 35
dml_ms = 25
json_ms = 8
clone_ms = 4

[ci]
fail_on_regression = true
regression_percent = 15
```

## Build and test

```bash
zig build
zig build test
```

## Apex Coverage

Apex言語対応カバレッジは次で管理します。

- `docs/apex-language-coverage.md`

PRで機能追加する場合は、実装・テストと同時にこのカバレッジ表も更新してください。

## Local validation fixtures

`examples/apex-validation` に、`check/profile` の再現用Apexプロジェクトとログを置いています。  
手順は `examples/apex-validation/README.md` を参照してください。

## Java Calibration

`tools/java-calibration` に、CPU係数の相対生成ツールがあります。

```bash
nix develop
./tools/java-calibration/run.sh
# または CLI から
zig build run -- emulate java --nix
```

生成された `cpu_model.toml` の `[cpu.model]` を `apexgov.toml` にマージすると、`AG009` のCPU見積もりで利用されます。

## Java Test Emulation

`tools/java-emulation` に、`@Test` をローカル実行して CPU/Heap 超過を検出する簡易ランナーがあります。

```bash
zig build run -- emulate test --nix
CPU_LIMIT_MS=8000 HEAP_LIMIT_BYTES=5000000 ./tools/java-emulation/run-tests.sh
SOQL_NULL_ORDER_DEFAULT=DIRECTIONAL ./tools/java-emulation/run-tests.sh
```

`apexemu.runtime.Limits` の `get*` API と `apexemu.runtime.Test.startTest/stopTest` も利用できます。
`stopTest()` では `@Future` / Queueable / Batch / Schedulable の簡易flushも実行されます。
Batch は `QueryLocatorBatchable` で `QueryLocator` を scope 分割して `execute(List<ApexSObject>)` 実行する経路も使えます。
この経路の `start/execute/finish` はそれぞれ独立したLimitsコンテキストで動き、scopeごとにCPU/Heap判定されます。
`BatchContext.getJobId()/getScopeIndex()/getTotalScopes()/getScopeSize()/getScopeRecordCount()/getPhase()` で batch 実行メタデータも参照できます。
`apexemu.runtime.Trigger` で `before/after` の trigger コンテキストも再現できます。
`apexemu.runtime.Database` + `ApexSObject` で in-memory CRUD（`merge` 含む）/ SOQLサブセットも使えます。
`Database.queryWithBinds/countQueryWithBinds`（`:name` bind、`IN :names` の collection bind）と `Database.getQueryLocator/getQueryLocatorWithBinds` にも対応しています。
SOQL サブセットは `GROUP BY` / `HAVING` / aggregate (`COUNT/COUNT_DISTINCT/SUM/AVG/MIN/MAX`) / `OFFSET` にも対応しています。
`WHERE` では date literal (`TODAY` / `LAST_N_DAYS:n` など) と unquoted ISO date/date-time literal も使えます。
relationship path (`Owner.Name`, `Parent__r.Name`) も `WHERE/ORDER BY/GROUP BY/HAVING` で使えます。
`Database.setSavepoint()/rollback()` と `Database.*(records, allOrNone)` + `SaveResult`、`Database.merge(master, duplicates, allOrNone)` + `MergeResult`（related reparent ids 含む）も使えます。
`apexemu.runtime.Schema` で custom object の required/type 検証も追加できます。
`Trigger.onBefore*/onAfter*` を登録すると `Database` CRUD（`upsert` / `merge` 含む）実行時に trigger を自動発火できます。
`merge` で related row が再親子付けされた場合は、関連オブジェクトの `before/after update` trigger も自動発火します。

詳細は `tools/java-emulation/README.md` を参照してください。

## Apex-to-Java Transpile (Scaffold)

`apexgov emulate transpile` は Apex `.cls` から Java クラス骨組みを自動生成します（best-effort）。
現状はメソッド本体をコメントとして埋め込み、`@IsTest` クラス/メソッドを `@Test` 付きメソッドに変換します。

```bash
zig build run -- emulate transpile force-app/main/default/classes --out reports/apex-transpile --package generated
```

## License

MIT License (`LICENSE`)
