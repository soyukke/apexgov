# Java Test Emulation

`@Test` 付きのJavaコードをローカルで実行し、CPU/Heapの上限チェックを行う簡易ランナーです。

## Quick Start

```bash
# 直接実行
./tools/java-emulation/run-tests.sh

# apexgov CLI から実行
zig build run -- emulate test --nix
```

## Options

```bash
./tools/java-emulation/run-tests.sh \
  --tests-dir tools/java-emulation/examples \
  --out-dir reports/java-emulation-local
```

上限は環境変数で変更できます。

```bash
CPU_LIMIT_MS=8000 HEAP_LIMIT_BYTES=5000000 ./tools/java-emulation/run-tests.sh
SOQL_NULL_ORDER_DEFAULT=DIRECTIONAL ./tools/java-emulation/run-tests.sh
```

## Outputs

- `report.json`: 各テストの pass/fail、cpu_ms、heap_bytes、soql_count、dml_count
- `build/`: コンパイル済み `.class`

## Notes

- これは Apex VM の完全再現ではなく、ローカルのデバッグ/概算向けです。
- `apexemu.runtime.ApexDb` と `apexemu.runtime.Limits` を使って負荷や回数を明示的に記録します。
- Apex `.cls` から Java 骨組みを生成したい場合は `apexgov emulate transpile` を使えます（best-effort / 手動移植前提、`System.assert*` は `SystemAssert.*`、`System.debug` は `System.out.println`。メソッド署名/コンストラクタ/クラスフィールド/`{ get; set; }` プロパティ、`List/Map/Set` 宣言・コンストラクタ・リテラル、named-arg 風 SObject コンストラクタ、単行/複数行 `[SELECT ...]`、基本 DML 文の変換に対応）。

## Assertion API

`apexemu.runtime.SystemAssert` で `System.assert*` 相当の検証ができます。

- `assertTrue(boolean, message)`
- `assertFalse(boolean, message)`
- `assertEquals(expected, actual, message)`
- `assertNotEquals(expected, actual, message)`
- `assertNull(value, message)`
- `assertNotNull(value, message)`
- `fail(message)`

失敗時は `AssertionError` と、テスト側の位置情報（`File.java:line`）を出力します。

## Limits / Test API

`apexemu.runtime.Limits` で governor 風メトリクスを参照できます。

- `getQueries()`, `getLimitQueries()`
- `getDmlStatements()`, `getLimitDmlStatements()`
- `getCpuTime()`, `getLimitCpuTime()`
- `getHeapSize()`, `getLimitHeapSize()`

`apexemu.runtime.Test` で `startTest/stopTest` 相当の窓計測を使えます。

- `startTest()` を呼ぶと、その時点から CPU/Heap/Query/DML の計測窓を開始
- `stopTest()` 時に async キュー（future/queueable/batch/schedulable）を flush し、その窓の値を確定
- `startTest/stopTest` を使わない場合はテストメソッド全体を計測

## Async Emulation

`startTest/stopTest` と組み合わせて非同期ジョブの flush を再現できます。

- `apexemu.runtime.Test.enqueueFutureMethod(Foo.class, "methodName")` (`@apexemu.annotations.Future` 必須)
- `apexemu.runtime.System.enqueueJob(Queueable)`
- `apexemu.runtime.Database.executeBatch(Batchable, scopeSize)`
- `apexemu.runtime.Database.executeBatch(QueryLocatorBatchable, scopeSize)` (`start()` の `QueryLocator` を scope で分割して `execute(List<ApexSObject>)`)
  - `QueryLocatorBatchable.start()` は `null` を返せません（`IllegalArgumentException`）
  - `start/execute/finish` はそれぞれ fresh な Limits コンテキストで実行（scopeごとにquery/dml/cpu/heapがリセット）
  - 各コンテキストで CPU/Heap limit を超えると `AssertionError` で失敗
  - `BatchContext.getJobId()/getScopeIndex()/getTotalScopes()/getScopeSize()/getScopeRecordCount()/getPhase()` でbatchメタデータを参照可能
- `apexemu.runtime.System.schedule(name, cron, Schedulable)`

## Trigger Context Emulation

`apexemu.runtime.Trigger` で trigger 文脈を作ってハンドラを実行できます。

- `beforeInsert`, `beforeUpdate`, `beforeDelete`
- `afterInsert`, `afterUpdate`, `afterDelete`, `afterUndelete`
- `isBefore/isAfter/isInsert/isUpdate/isDelete/isUndelete`
- `getNew/getOld/getNewMap/getOldMap/size`
- auto-dispatch registration:
  - `onBeforeInsert/onAfterInsert`
  - `onBeforeUpdate/onAfterUpdate`
  - `onBeforeDelete/onAfterDelete`
  - `onAfterUndelete`

`Trigger.run(...)` は実行後にコンテキストを自動クリアします。
登録済みハンドラは `Database.insert/update/upsert/delete/undelete/merge` 実行時に自動起動されます。
`Database.upsert` は insert/update の実行経路に応じて trigger を自動起動します。

## In-Memory SObject Store

`apexemu.runtime.Database` と `apexemu.runtime.ApexSObject` で、簡易CRUDとSOQLサブセットを使えます。

- CRUD: `insert`, `update`, `upsert`, `delete`, `undelete`, `merge`
- transactional: `setSavepoint()`, `rollback(savepoint)`
- save-result mode:
  - `insert/update/upsert/delete/undelete(records, allOrNone)` + `Database.SaveResult[]`
  - `merge(master, duplicateRecords, allOrNone)` + `Database.MergeResult`
    - `getMergedRecordIds()` / `getUpdatedRelatedIds()` を参照可能
    - related row の簡易reparentを実施（参照Id系フィールドの duplicate id を master id に置換）
    - related row 更新時は `before/after update` trigger を自動発火
    - `updatedRelatedIds` は安定ソート順（case-insensitive）で返却
  - `SaveResult.getErrors()` から `statusCode` / `message` / `fields` を参照可能
- schema registry: `Schema.object(\"Custom__c\")...register()`
  - registered object は required field / simple type validation を実施
- Query:
  - `query(soql)`, `countQuery(soql)`
  - `queryWithBinds(soql, binds)`, `countQueryWithBinds(soql, binds)`
  - `getQueryLocator(soql)`, `getQueryLocatorWithBinds(soql, binds)` (`QueryLocator#size`, `#getRecords`, iteration)
  - bind は `:name` 形式（`Map<String, Object>` から解決）
  - 文字列bindは `'` を `''` にエスケープして展開（`'`/`"` 混在値にも対応）
  - scalar (`String`/`Number`/`Boolean`/`null`) と collection bind（`IN :names`）をサポート
  - 空collection bindは `IN :names` で0件、`NOT IN :names` で全件として扱う
- reset: `clearInMemoryStore()`

対応SOQLは最小サブセットです。

- `SELECT ... FROM Object`
- bracket style: `[SELECT ... FROM Object ...]`
- optional `WHERE` with `AND` / `OR` of predicates (`AND` 優先)
- unary `NOT (...)` predicate is supported (including compound forms like `NOT (A OR B)`)
- supported operators: `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN (...)`, `NOT IN (...)`, `LIKE`
- date literal subset: `TODAY`, `YESTERDAY`, `TOMORROW`, `LAST_N_DAYS:n`, `NEXT_N_DAYS:n`, `N_DAYS_AGO:n`
- absolute date/date-time literal subset: unquoted ISO date/date-time (`2026-02-09`, `2026-02-09T12:34:56Z`)
- `LIKE` は大文字小文字を区別せず、`\%` / `\_` でワイルドカードをエスケープ可能
- aggregate select: `COUNT()`, `COUNT(field)`, `COUNT_DISTINCT(field)`, `SUM(field)`, `AVG(field)`, `MIN(field)`, `MAX(field)`（`AS alias` 対応）
- optional `GROUP BY field[, ...]` + optional `HAVING`（`AND`/`OR`/`NOT` と `= != > >= < <=`）
  - `HAVING` は aggregate operand（例: `COUNT(Id)`）か `GROUP BY` に含まれる field を評価対象にできます
- field path traversal: `Owner.Name`, `Parent__r.Name` のような relationship path を `SELECT`/`WHERE`/`GROUP BY`/`HAVING`/`ORDER BY` で利用可能
- optional `ORDER BY field [ASC|DESC] [NULLS FIRST|LAST]` (comma-separated multi-key supported)
  - NULL sort default は `Database.setSoqlNullOrderDefault(...)` または `SOQL_NULL_ORDER_DEFAULT` で切替可能
    - `FIRST` (default), `LAST`, `DIRECTIONAL` (`ASC=NULLS FIRST`, `DESC=NULLS LAST`)
- optional `LIMIT n`
- optional `OFFSET n`
