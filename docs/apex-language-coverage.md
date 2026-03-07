# Apex Language Coverage

`apexgov` が現在どこまで Apex を扱えるかを管理するための台帳です。  
実装の真実はコードですが、このファイルを PR 時の確認表として使います。

## Legend

- `supported`: 現在の実装で対応
- `partial`: 一部対応（制約あり）
- `planned`: 未対応

## Static Check Coverage (`apexgov check`)

### Rule Coverage

| Rule | Status | What It Detects | Notes |
| --- | --- | --- | --- |
| AG001 | supported | nested loop | ループの入れ子を検出 |
| AG002 | supported | SOQL in loop | 上限推論つき |
| AG003 | supported | DML in loop | 上限推論つき |
| AG004 | supported | JSON serialize/deserialize in loop | CPU見積もりつき |
| AG005 | supported | clone/deepClone in loop | CPU見積もりつき |
| AG006 | supported | collection allocation in loop | `new List/Map/Set` |
| AG007 | supported | string concatenation in loop | `+=` ベースのヒューリスティック |
| AG008 | supported | SOSL in loop | 上限推論つき |
| AG009 | supported | heuristic CPU estimate | `base + N * per_iter` |
| AG010 | supported | callout in loop | `Http.send` / `WebServiceCallout.invoke` 等 |
| AG011 | supported | messaging send in loop | `Messaging.sendEmail` 系 |

### Apex Standard Library Pattern Coverage (current)

| Category | Status | Covered APIs |
| --- | --- | --- |
| SOQL-like | partial | inline `[SELECT ...]`, `Database.query`, `Database.queryWithBinds`, `Database.countQuery`, `Database.getQueryLocator` |
| SOSL-like | partial | inline `[FIND ...]`, `Search.query` |
| DML-like | partial | statement `insert/update/upsert/delete/undelete/merge`, `Database.insert/update/upsert/delete/undelete/merge/emptyRecycleBin/convertLead` |
| Callout-like | partial | `Http.send`, `WebServiceCallout.invoke`, `Continuation.addHttpRequest` |
| Messaging-like | partial | `Messaging.sendEmail`, `Messaging.sendEmailMessage`, `Messaging.sendNotification` |
| JSON CPU-heavy | partial | `JSON.serialize`, `JSON.serializePretty`, `JSON.deserialize`, `JSON.deserializeUntyped`, `JSON.deserializeStrict`, `JSON.createParser`, `JSON.createGenerator` |

### Syntax / Control Flow Coverage

| Feature | Status | Notes |
| --- | --- | --- |
| `for (init; cond; inc)` | supported | 条件式から上限推論 |
| `for (T x : collection)` | supported | `collection` の上限推論 |
| `while (...)` | supported | 条件式から上限推論 |
| `switch on / when` | partial | transpile は literal列挙 + `when else` に加え `when Account a` 形式を Java `switch (ApexSwitch.typeName(...))` へ変換。rangeパターン等は未対応 |
| `do { ... } while (...)` | partial | transpile は `} while (...)` を Java do-while へ変換。check も tail 条件から上限推論（`do {` と `} while (...)`、および `do` / 次行 `{`）に対応 |
| guard (`if (n > K) return/throw`) | supported | `>` / `>=` を上限として採用 |
| guard with `&&` | supported | 各節が上限式なら採用 |
| guard with `\|\|` | partial | `if (n > K \|\| bypass) return;` のように上限節を抽出できる場合のみ採用 |
| bounds from literal assignment | supported | `Integer n = 120;` |
| bounds from size alias | supported | `Integer n = list.size();` |
| bounds from SOQL `LIMIT` | supported | `[SELECT ... LIMIT 100]` |
| bounds from `Math.min(...)` | supported | `Math.min(a, b)` の各項から推定した上限の小さい方を採用 |
| `Trigger.new` / `Trigger.old` | supported | 200 を上限採用 |
| arithmetic symbolic bounds | partial | `a+b-c` の加減算上限推定に対応。乗除算や複合関数は unknown 扱い |

### Method / Type Resolution Coverage

| Feature | Status | Notes |
| --- | --- | --- |
| same-class calls | supported | 裸呼び出し、`this.` 呼び出し |
| cross-class qualified calls | supported | `Owner.method(...)` |
| transitive helper chain | supported | 呼び出し連鎖を集約 |
| callee loop multiplier propagation | supported | 内部ループを乗算反映 |
| overload resolution by arity | supported | 同名メソッド対応 |
| overload resolution by argument type | partial | literal / `new` / ローカル型 / indexed element |
| dynamic dispatch / interface polymorphism | partial | `new ConcreteType()` 束縛に加え、`implements` / `extends` 関係に基づく receiver 解決と interface 型引数の代入可能性を考慮 |

### Parser Model Limits

| Area | Status | Notes |
| --- | --- | --- |
| line-based heuristic scan | partial | AST ではなく行解析中心 |
| line comment stripping (`//`) | supported | あり |
| block comment (`/* ... */`) | supported | 解析前に除去（改行維持で行番号の整合を確保） |
| preprocessor / macro-like constructs | planned | 想定外 |

## Profile Coverage (`apexgov profile`)

| Feature | Status | Notes |
| --- | --- | --- |
| parse `Maximum CPU time:` | supported | `.log` から最大値を抽出 |
| parse `Maximum heap size:` | supported | `.log` から最大値を抽出 |
| async marker detection | supported | `FUTURE_HANDLER`, `QUEUEABLE`, `BATCH_`, `SCHEDULED` |
| label extraction (`CODE_UNIT_STARTED`) | supported | 未取得時は `unknown` |
| baseline regression compare | supported | label/mode 優先、fallback で basename |
| multi-transaction structuring | supported | `EXECUTION_STARTED` 単位で分割し、1ログファイルから複数 transaction を抽出 |

## Java Emulation Coverage (`apexgov emulate test`)

| Feature | Status | Notes |
| --- | --- | --- |
| `@Test` method discovery/execution | supported | 0引数メソッド実行 |
| `@TestSetup` execution | supported | 各 `@Test` 実行前に static void 0引数メソッドを実行 |
| assertion API (`SystemAssert.*`, `ApexAssert.*`) | supported | `System.assert*` + `Assert.*` 相当（equals/null/bool/fail/type-instance、実装interface/親class配下のnested interface名での instance 判定を含む） |
| failure location (`File.java:line`) | supported | 失敗時に表示 |
| CPU/Heap threshold fail | supported | `--cpu-limit-ms` / `--heap-limit-bytes` |
| `Limits.get*` API | supported | queries/dml/callouts/cpu/heap と limit 値を取得 |
| `Test.startTest()/stopTest()` | supported | start/stop 窓での計測に切り替え |
| `Test.runAs(...)` | partial | `UserInfo.getUserId()/getUsername()/getUserName()/getProfileId()` と `Schema` profile context の切替をローカル再現（権限モデル全体の完全再現は対象外） |
| `Test.loadData(...)` | partial | ローカルCSVを読み込み `Database.insert` まで実行（簡易CSV parser） |
| `Test.setMock(...)` + callout mock | partial | `Http.send` / `WebServiceCallout.invoke` を mock 実装へ委譲 |
| async flush at `stopTest()` | supported | `@Future`, Queueable, Batchable, Schedulable を順次実行（Batchable は `QueryLocatorBatchable` の scope 分割実行にも対応、`start/execute/finish` を fresh Limits で実行し scopeごとにCPU/Heap判定） |
| batch context metadata | supported | `BatchContext.getJobId()/getScopeIndex()/getTotalScopes()/getScopeSize()/getScopeRecordCount()/getPhase()` |
| Trigger context (`new/old/maps/flags`) | supported | manual run + `Database` CRUD auto-dispatch (`insert/update/upsert/delete/undelete/merge`) + merge-related update trigger dispatch |
| in-memory CRUD store | supported | `insert/update/upsert/delete/undelete/merge` |
| savepoint / rollback | supported | `Database.setSavepoint()`, `Database.rollback(savepoint)` |
| allOrNone + SaveResult | supported | `Database.*(records, allOrNone)` + `Database.merge(master, duplicates, allOrNone)` (`MergeResult`, related reparent ids + sorted `updatedRelatedIds`) |
| schema registry (custom object validation) | partial | `Schema.object(...).register()` で required/type + `maxLength` / restricted picklist (`requiredPicklist` / `optionalPicklist`) / numeric `precision(scale)` / ID `reference(...)` lookup整合 + `unique(...)` / `externalId(...)` 重複検証 |
| SOQL subset query | partial | `FROM` / `[SELECT ...]`, relationship field path (`Owner.Name`, `Parent__r.Name`), `WHERE` (`AND`/`OR`/unary `NOT` with grouped expression, `= != > >= < <=`, `IN`, `NOT IN`, `LIKE` with escape, `IS NULL`, `IS NOT NULL`, semi-join `IN (SELECT ...)` / `NOT IN (SELECT ...)`), date literals (`TODAY/YESTERDAY/TOMORROW/LAST_N_DAYS/NEXT_N_DAYS/N_DAYS_AGO`) + unquoted ISO date/date-time literals, aggregate select (`COUNT/COUNT_DISTINCT/SUM/AVG/MIN/MAX`), child subquery（schema `reference(field, type, childRelationshipName)` を優先して relation解決）, `GROUP BY`, `HAVING` (`AND`/`OR`/`NOT` over aggregate/group fields), `ORDER BY` multi-key + `NULLS FIRST/LAST` (default mode configurable: `FIRST`/`LAST`/`DIRECTIONAL`), `LIMIT`, `OFFSET`, trailing `FOR UPDATE` / `ALL ROWS` (ignored clause), `queryWithBinds/countQueryWithBinds` (`:name`, scalar + collection bind), `getQueryLocator/getQueryLocatorWithBinds` |
| SOQL/DML counters | partial | `ApexDb` と `Database` API の呼び出しベース |
| Apex-to-Java transpile scaffold (`emulate transpile`) | partial | `.cls` を Java 骨組みに変換し、`@IsTest` を `@Test` 化。`fflib_SObjectDomain.triggerHandler(...)` 形式の `.trigger` は `apex-triggers.txt` manifest に落として runner が自動登録。メソッド署名/コンストラクタ/クラスフィールド/`{ get; set; }` プロパティを出力。`System.assert*`→`SystemAssert.*`、`Assert.*`/`System.Assert.*`→`ApexAssert.*`、`System.debug`→`System.out.println`。`switch on / when`（literal列挙 + `when else` + `when Account a`）は Java `switch` へ変換。`record instanceof Account` のような SObject 型チェックは `"Account".equals(ApexSwitch.typeName(record))` に正規化し、否定/複合式（`!(...)`, `A || B`）と `instanceof SObject`（`instanceof ApexSObject`）も対応。`do { ... } while (...)` の末尾 `} while (...)` も Java do-while へ正規化。`String.isBlank/isNotBlank/isEmpty/isNotEmpty/join/escapeSingleQuotes` は `ApexStrings.*` へ変換。`List/Map/Set` 宣言・コンストラクタ・リテラルを Java collection 化。`new Map<Id, SObject>(list/map/query)` は `ApexCollections.mapById/toIdMap` に変換。named-arg 風 SObject コンストラクタ（`new Task(Subject=...)`）を `ApexSObject.of(...).set(...)` 化。単行/複数行 `[SELECT ...]` を `Database.query(...)` 化し、単一SObject代入は `ApexCollections.firstOrNull(...)` を使用。`Database.getQueryLocator/countQuery/queryWithBinds/countQueryWithBinds/getQueryLocatorWithBinds` 系に渡る `[SELECT ...]` は query string に正規化。`insert/update/upsert/delete/undelete/merge` を `Database.*` 化（`upsert ... ExternalId__c` は comment で保持、`merge` は `master+dup(1-2件)` 形式）。未解決型は `ApexSObject` にフォールバック、`record.Id` 等は `record.getAs("Id")` に変換。unsupported 行は `file:line + reason` で出力し、`--strict` 時は終了コード1で失敗。 |
| Apex VM semantic parity | planned | 完全再現は対象外 |

### External Compatibility Snapshot (2026-03-07)

- Fixture: `.local-fixtures/apex/repos/apex-recipes` (`force-app`)
- Command:
  - `./tools/transpile-external.sh <repo> --subpath force-app --out-root reports/apex-transpile-external --run-tests`
- Result (non-best-effort):
  - transpile: `139/139` classes generated, `unsupported=0`
  - emulate test: `total=322 passed=322 failed=0`
  - test discovery parity: generated `@Test` annotation count `322`, executed `322` (no skip)
  - `compile-fallbacks.txt` / `compile-failures.txt`: not generated

- Fixture: `.local-fixtures/apex/repos/fflib-apex-mocks` (`sfdx-source/apex-mocks`)
- Command:
  - `./tools/transpile-external.sh <repo> --subpath sfdx-source/apex-mocks --out-root reports/apex-transpile-external --run-tests`
- Result (non-best-effort):
  - transpile: `38/38` classes generated, `unsupported=0`
  - emulate test: `total=471 passed=471 failed=0`
  - `compile-fallbacks.txt` / `compile-failures.txt`: not generated

- Fixture: composite `.local-fixtures/apex/repos/fflib-apex-common` + `.local-fixtures/apex/repos/fflib-apex-mocks`
- Command:
  - `zig build run -- emulate transpile <common main> <common test> <mocks main> --out reports/apex-transpile-composite/fflib-apex-common-with-mocks --package generated --overwrite`
  - `zig build run -- emulate test reports/apex-transpile-composite/fflib-apex-common-with-mocks --out reports/apex-transpile-composite/fflib-apex-common-with-mocks/test --register-standard-schema`
- Result (non-best-effort):
  - transpile: `55/55` classes generated, `unsupported=0`
  - emulate test: `total=158 passed=158 failed=0`
  - `compile-fallbacks.txt` / `compile-failures.txt`: not generated

- Fixture: composite `.local-fixtures/apex/repos/fflib-apex-common-samplecode` + `.local-fixtures/apex/repos/fflib-apex-common` + `.local-fixtures/apex/repos/fflib-apex-mocks`
- Command:
  - `zig build run -- emulate transpile <samplecode main/test/triggers> <common main> <mocks main> --out reports/apex-transpile-composite/fflib-apex-common-samplecode-with-deps --package generated --overwrite`
  - `zig build run -- emulate test reports/apex-transpile-composite/fflib-apex-common-samplecode-with-deps --out reports/apex-transpile-composite/fflib-apex-common-samplecode-with-deps/test --register-standard-schema`
- Result (non-best-effort):
  - transpile: `97/97` classes generated, `unsupported=0`
  - emulate test: `total=16 passed=16 failed=0`
  - generated `apex-triggers.txt` auto-registration manifest consumed by runner
  - `compile-fallbacks.txt` / `compile-failures.txt`: not generated

## Maintenance Rules

1. 新しい検出ルールや解析機能を追加したら、このファイルの該当行を更新する。  
2. `status` を変えたら、対応テストも同時に追加する。  
3. README には要約のみ置き、詳細はこのファイルを参照する。  
4. 不明な場合は `partial` を選ぶ（過大申告をしない）。
