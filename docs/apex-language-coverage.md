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
| `do { ... } while (...)` | planned | 未対応 |
| guard (`if (n > K) return/throw`) | supported | `>` / `>=` を上限として採用 |
| guard with `&&` | supported | 各節が上限式なら採用 |
| guard with `\|\|` | planned | 保守的に未採用 |
| bounds from literal assignment | supported | `Integer n = 120;` |
| bounds from size alias | supported | `Integer n = list.size();` |
| bounds from SOQL `LIMIT` | supported | `[SELECT ... LIMIT 100]` |
| bounds from `Math.min(x, literal)` | supported | 右側 literal を上限採用 |
| `Trigger.new` / `Trigger.old` | supported | 200 を上限採用 |
| arithmetic symbolic bounds | partial | 複雑式は unknown 扱い |

### Method / Type Resolution Coverage

| Feature | Status | Notes |
| --- | --- | --- |
| same-class calls | supported | 裸呼び出し、`this.` 呼び出し |
| cross-class qualified calls | supported | `Owner.method(...)` |
| transitive helper chain | supported | 呼び出し連鎖を集約 |
| callee loop multiplier propagation | supported | 内部ループを乗算反映 |
| overload resolution by arity | supported | 同名メソッド対応 |
| overload resolution by argument type | partial | literal / `new` / ローカル型 / indexed element |
| dynamic dispatch / interface polymorphism | planned | 未対応 |

### Parser Model Limits

| Area | Status | Notes |
| --- | --- | --- |
| line-based heuristic scan | partial | AST ではなく行解析中心 |
| line comment stripping (`//`) | supported | あり |
| block comment (`/* ... */`) | planned | 厳密対応なし |
| preprocessor / macro-like constructs | planned | 想定外 |

## Profile Coverage (`apexgov profile`)

| Feature | Status | Notes |
| --- | --- | --- |
| parse `Maximum CPU time:` | supported | `.log` から最大値を抽出 |
| parse `Maximum heap size:` | supported | `.log` から最大値を抽出 |
| async marker detection | supported | `FUTURE_HANDLER`, `QUEUEABLE`, `BATCH_`, `SCHEDULED` |
| label extraction (`CODE_UNIT_STARTED`) | supported | 未取得時は `unknown` |
| baseline regression compare | supported | label/mode 優先、fallback で basename |
| multi-transaction structuring | partial | 1ファイル内は最大値集約モデル |

## Java Emulation Coverage (`apexgov emulate test`)

| Feature | Status | Notes |
| --- | --- | --- |
| `@Test` method discovery/execution | supported | 0引数メソッド実行 |
| assertion API (`SystemAssert.*`) | supported | equals / null / bool / fail |
| failure location (`File.java:line`) | supported | 失敗時に表示 |
| CPU/Heap threshold fail | supported | `--cpu-limit-ms` / `--heap-limit-bytes` |
| `Limits.get*` API | supported | queries/dml/cpu/heap と limit 値を取得 |
| `Test.startTest()/stopTest()` | supported | start/stop 窓での計測に切り替え |
| async flush at `stopTest()` | supported | `@Future`, Queueable, Batchable, Schedulable を順次実行 |
| Trigger context (`new/old/maps/flags`) | supported | `before/after` + `insert/update/delete/undelete` |
| in-memory CRUD store | supported | `insert/update/upsert/delete/undelete` |
| savepoint / rollback | supported | `Database.setSavepoint()`, `Database.rollback(savepoint)` |
| allOrNone + SaveResult | supported | `Database.*(records, allOrNone)` の部分成功/全体ロールバック |
| schema registry (custom object validation) | partial | `Schema.object(...).register()` で required/type の簡易検証 |
| SOQL subset query | partial | `FROM` / `[SELECT ...]`, `WHERE` (`AND`/`OR`, `= != > >= < <=`, `IN`, `NOT IN`, `LIKE` with escape), `ORDER BY` multi-key, `LIMIT` |
| SOQL/DML counters | partial | `ApexDb` と `Database` API の呼び出しベース |
| Apex VM semantic parity | planned | 完全再現は対象外 |

## Maintenance Rules

1. 新しい検出ルールや解析機能を追加したら、このファイルの該当行を更新する。  
2. `status` を変えたら、対応テストも同時に追加する。  
3. README には要約のみ置き、詳細はこのファイルを参照する。  
4. 不明な場合は `partial` を選ぶ（過大申告をしない）。
