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
```

## Outputs

- `report.json`: 各テストの pass/fail、cpu_ms、heap_bytes、soql_count、dml_count
- `build/`: コンパイル済み `.class`

## Notes

- これは Apex VM の完全再現ではなく、ローカルのデバッグ/概算向けです。
- `apexemu.runtime.ApexDb` と `apexemu.runtime.Limits` を使って負荷や回数を明示的に記録します。

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
- `apexemu.runtime.System.schedule(name, cron, Schedulable)`

## Trigger Context Emulation

`apexemu.runtime.Trigger` で trigger 文脈を作ってハンドラを実行できます。

- `beforeInsert`, `beforeUpdate`, `beforeDelete`
- `afterInsert`, `afterUpdate`, `afterDelete`, `afterUndelete`
- `isBefore/isAfter/isInsert/isUpdate/isDelete/isUndelete`
- `getNew/getOld/getNewMap/getOldMap/size`

`Trigger.run(...)` は実行後にコンテキストを自動クリアします。

## In-Memory SObject Store

`apexemu.runtime.Database` と `apexemu.runtime.ApexSObject` で、簡易CRUDとSOQLサブセットを使えます。

- CRUD: `insert`, `update`, `upsert`, `delete`, `undelete`
- transactional: `setSavepoint()`, `rollback(savepoint)`
- save-result mode: `insert/update/upsert/delete/undelete(records, allOrNone)` + `Database.SaveResult`
  - `SaveResult.getErrors()` から `statusCode` / `message` / `fields` を参照可能
- schema registry: `Schema.object(\"Custom__c\")...register()`
  - registered object は required field / simple type validation を実施
- Query: `query(soql)`, `countQuery(soql)`
- reset: `clearInMemoryStore()`

対応SOQLは最小サブセットです。

- `SELECT ... FROM Object`
- bracket style: `[SELECT ... FROM Object ...]`
- optional `WHERE` with `AND` of simple predicates (`field op literal`)
- supported operators: `=`, `!=`, `>`, `>=`, `<`, `<=`
- optional `ORDER BY field [ASC|DESC]`
- optional `LIMIT n`
