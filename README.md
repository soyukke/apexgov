# apexgov

`apexgov` is an offline Apex static checker and debug log profiler for CI/CD.

## Why

- Detect governor-risk code paths before deploy
- Catch SOSL / Callout / Messaging operations inside loops with limit-aware warnings
- Estimate loop upper bounds from guards (for/while/do-while, for example `if (n > 200) return`) and show likely limit exceed points
- Follow helper method call chains across files/classes to catch indirect SOQL/DML in loops
- Multiply callee-side loop effects into governor estimates (for example nested helper loops)
- Use method arity and inferred literal/new-expression/local variable types to reduce false positives on overloaded calls
- Resolve interface/inheritance based dynamic dispatch more accurately (`implements` / `extends`)
- Track CPU/Heap budgets from Apex Debug Logs in CI
- Split multi-transaction debug logs per transaction and compare regressions transaction-by-transaction
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
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated --strict
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

2026-03-07 時点の non-best-effort snapshot は次を通過しています。

- `apex-recipes`: `322/322`
- `fflib-apex-mocks`: `471/471`
- `fflib-apex-common + fflib-apex-mocks`: `158/158`
- `fflib-apex-common-samplecode + fflib-apex-common + fflib-apex-mocks`: `16/16`

PRで機能追加する場合は、実装・テストと同時にこのカバレッジ表も更新してください。

## Local validation fixtures

`examples/apex-validation` に、`check/profile` の再現用Apexプロジェクトとログを置いています。  
手順は `examples/apex-validation/README.md` を参照してください。

## External Apex validation (git-ignored)

実プロジェクトに近いApexコードで検証するために、git管理外の入力を使って transpile 検証できます。  
`./tools/transpile-external.sh` は git URL かローカルパスを受け取り、`emulate transpile` を実行します。

```bash
# public repo から取得して検証（clone先は .local-fixtures/ 配下）
./tools/transpile-external.sh \
  https://example.com/your-apex-repo.git \
  --subpath force-app/main/default/classes

# ローカルのSFDXプロジェクトを strict で検証
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --strict

# transpile 後にローカル emulation test まで実行
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --run-tests --nix

# unresolved source がある場合のみ best-effort で段階実行
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --run-tests --best-effort --nix
```

- キャッシュ/取得先: `.local-fixtures/apex/repos/`（`.gitignore` 済み）
- 出力先: `reports/apex-transpile-external/<label>/`

## Periodic Transpile Check (just)

複数リポジトリの定期点検は、git管理外のローカル targets ファイルで管理します。

```bash
cp tools/periodic-targets.example.txt .local-fixtures/periodic-targets.txt
# .local-fixtures/periodic-targets.txt を編集して対象を設定
just periodic-transpile
just periodic-transpile-strict
```

- 既定の targets ファイル: `.local-fixtures/periodic-targets.txt`（git管理外）
- 環境変数 `APEXGOV_PERIODIC_TARGETS_FILE` で別ファイル指定可能
- 出力先: `reports/apex-transpile-periodic/<timestamp>/`

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
zig build run -- emulate test reports/apex-transpile-external/my-repo --nix
# unresolved source がある場合のみ
zig build run -- emulate test reports/apex-transpile-external/my-repo --best-effort --nix
CPU_LIMIT_MS=8000 HEAP_LIMIT_BYTES=5000000 ./tools/java-emulation/run-tests.sh
SOQL_NULL_ORDER_DEFAULT=DIRECTIONAL ./tools/java-emulation/run-tests.sh
```

- `--best-effort` を付けると、`javac` で解決できないソースを段階的に placeholder stub に置き換えて、実行可能な `@Test` を先に実行します（元ソースは変更しません）。
- placeholder 化されたソースは `OUT_DIR/compile-fallbacks.txt` に出力されます。
- それでもコンパイル不能なソースが残る場合は `OUT_DIR/compile-failures.txt` に出力されます。

主な対応:

- `apexemu.runtime.Limits` の `get*` API と `apexemu.runtime.Test.startTest/stopTest`
- `Test.runAs(...)` / `UserInfo.getUserId()/getUsername()/getUserName()/getProfileId()` のローカル実行コンテキスト切り替え（`Schema` profile context 含む）
- `Test.loadData(sobjectType, csvPath)` による CSV fixture の取り込み
- `Test.setMock(...)` + `Http.send` / `WebServiceCallout.invoke` mock 実行
- `stopTest()` 時の `@Future` / Queueable / Batch / Schedulable 簡易 flush
- `QueryLocatorBatchable` 経由の scope 分割 `execute(List<ApexSObject>)`
- `start/execute/finish` を独立した Limits コンテキストで評価
- `BatchContext.getJobId()/getScopeIndex()/getTotalScopes()/getScopeSize()/getScopeRecordCount()/getPhase()`
- `apexemu.runtime.Trigger` による `before/after` trigger コンテキスト再現
- `apexemu.runtime.Database` + `ApexSObject` による in-memory CRUD（`merge` 含む）/ SOQL サブセット
- `Database.queryWithBinds/countQueryWithBinds`（`:name` bind、`IN :names` の collection bind）
- `Database.getQueryLocator/getQueryLocatorWithBinds`
- SOQL 末尾 `FOR UPDATE` / `FOR VIEW` / `FOR REFERENCE` / `ALL ROWS` を無視して評価
- `GROUP BY` / `HAVING` / aggregate (`COUNT/COUNT_DISTINCT/SUM/AVG/MIN/MAX`) / `OFFSET`
- date literal (`TODAY` / `LAST_N_DAYS:n` など) と unquoted ISO date/date-time literal
- `WHERE` の `IS NULL` / `IS NOT NULL`
- relationship path (`Owner.Name`, `Parent__r.Name`) の `WHERE/ORDER BY/GROUP BY/HAVING` 利用
- `Database.setSavepoint()/rollback()`
- `Database.*(records, allOrNone)` + `SaveResult`
- `Database.merge(master, duplicates, allOrNone)` + `MergeResult`（related reparent ids 含む）
- `apexemu.runtime.Schema` による custom object の required/type/maxLength/restricted picklist/precision(scale)/lookup reference/unique/externalId 検証
- `Trigger.onBefore*/onAfter*` 登録時の `Database` CRUD（`upsert` / `merge` 含む）での自動発火
- `merge` 時の related row 再親子付けで関連オブジェクト `before/after update` trigger も自動発火
- SOQL semi-join (`WHERE Id IN (SELECT ...)` / `NOT IN`) と child subquery (`SELECT ..., (SELECT ... FROM Contacts)`) のサブセット対応（schema metadata の relationship 名解決を優先）

詳細は `tools/java-emulation/README.md` を参照してください。

## Apex-to-Java Transpile (Scaffold)

`apexgov emulate transpile` は Apex `.cls` から Java クラス骨組みを自動生成します（scaffold 生成）。

主な変換:

- `@IsTest` を `@Test` 化
- メソッド署名（戻り値/引数/static）とコンストラクタ、クラスフィールド/`{ get; set; }` プロパティ骨組み生成
- `System.assert*` を `SystemAssert.*`、`Assert.*`/`System.Assert.*` を `ApexAssert.*`、`System.debug(...)` を `System.out.println(...)` に変換
- `switch on / when` を Java `switch` / `case ... ->` / `default ->` に変換
- `when Account acc` は `switch (ApexSwitch.typeName(...))` + `case "Account"` 形式で変換
- `record instanceof Account` は `"Account".equals(ApexSwitch.typeName(record))` に変換
- `!(record instanceof Contact)` や `record instanceof A || record instanceof B` の否定/複合式も変換（`instanceof SObject` は `instanceof ApexSObject`）
- `do { ... } while (...)` の末尾（`} while (...)`）を Java `do-while` 形式へ正規化
- `String.isBlank/isNotBlank/isEmpty/isNotEmpty/join/escapeSingleQuotes` を `ApexStrings.*` に変換
- `List/Map/Set` 宣言・コンストラクタ・リテラル（`new List<T>{...}`）を Java collection (`ArrayList/LinkedHashMap/LinkedHashSet`) に変換
- `new Map<Id, Account>(records)` / `new Map<Id, Account>(existingMap)` を `ApexCollections.toIdMap(...)` に変換
- named-arg 風 SObject コンストラクタ（`new Task(Subject='x', WhatId=...)`）を `ApexSObject.of(...).set(...)` に変換
- `[SELECT ...]`（単行/複数行）を `Database.query(...)` に変換し、単一SObject代入は `ApexCollections.firstOrNull(Database.query(...))` に変換
- `Database.getQueryLocator/countQuery/queryWithBinds` 系に渡る `[SELECT ...]` を query string に正規化
- `insert/update/upsert/delete/undelete/merge`（`upsert ... ExternalId__c` 含む）を `Database.*` 呼び出しに変換
- `merge` は `merge master dup` / `merge master dup1 dup2` / `merge master, dup1, dup2` を処理
- 未解決型は `ApexSObject` にフォールバックし、`record.Id` などの SObject 風フィールド参照は `record.getAs("Id")` に変換
- 未変換行（comment fallback）は `file:line [method] reason: statement` 形式で出力
- `--strict` 指定時は未変換行が 1 件でもあると終了コード 1 で失敗

```bash
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated --strict
```

`[APEX_PATHS...]` を省略した場合は、`force-app/main/default/classes` が存在すればそれを、無ければこのリポジトリの検証 fixture (`examples/apex-validation/...`) を自動利用します。

## License

MIT License (`LICENSE`)
