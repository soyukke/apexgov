# apexgov

[English README](README.md)

`apexgov` は Salesforce Apex コード向けのオフライン静的チェッカー & デバッグログプロファイラーです。CI/CD パイプラインでの利用を想定しています。

## 特徴

- デプロイ前に Governor 制限リスクのあるコードパスを検出
- ループ内の SOQL / DML / SOSL / Callout / Messaging 操作を制限値を考慮して警告
- ガード条件（`for`/`while`/`do-while`、例: `if (n > 200) return`）からループ上限を推定し、制限超過の可能性がある箇所を表示
- ヘルパーメソッドの呼び出しチェーンをファイル/クラスを跨いで追跡し、間接的なループ内 SOQL/DML を検出
- 呼び出し先のループ効果を Governor 見積もりに乗算（例: ネストされたヘルパーループ）
- メソッドのアリティと推論されたリテラル/new式/ローカル変数の型を使い、オーバーロード呼び出しの誤検知を削減
- インターフェース/継承ベースの動的ディスパッチをより正確に解決（`implements` / `extends`）
- Apex デバッグログから CPU/Heap バジェットを CI で追跡
- マルチトランザクションのデバッグログをトランザクションごとに分割し、リグレッションを比較
- パイプライン向けの機械可読レポート（`json`, `sarif`）を出力
- Apex を Java にトランスパイルし、`@Test` メソッドを Governor 制限エミュレーション付きでローカル実行

## 静的解析ルール

| ID | 検出対象 |
|---|---|
| AG001 | ネストされたループ |
| AG002 | ループ内 SOQL |
| AG003 | ループ内 DML |
| AG004 | ループ内 JSON シリアライズ/デシリアライズ |
| AG005 | ループ内 clone/deepClone |
| AG006 | ループ内コレクション確保 |
| AG007 | ループ内文字列連結 |
| AG008 | ループ内 SOSL |
| AG009 | ヒューリスティック CPU 見積もり |
| AG010 | ループ内 HTTP callout |
| AG011 | ループ内 Messaging.sendEmail |

## LSP (言語サーバー)

apexgov には Apex 言語サーバーが内蔵されています。Governor 制限違反の診断、コード補完、定義ジャンプ、参照検索、ホバー、リネーム、セマンティックハイライトなどを提供します。

```bash
apexgov lsp   # LSP サーバーを起動 (stdio)
```

Neovim + lazy.nvim クイックセットアップ (プリビルドバイナリ、Zig 不要):

```lua
{ "soyukke/apexgov", build = function(p)
    local u = vim.uv.os_uname()
    local os = u.sysname == "Darwin" and "darwin" or "linux"
    local arch = u.machine == "arm64" and "aarch64" or "x86_64"
    vim.fn.mkdir(p.dir.."/bin", "p")
    vim.fn.system(("curl -sL https://github.com/soyukke/apexgov/releases/latest/download/apexgov-%s-%s.tar.gz | tar xz -C %s/bin"):format(os, arch, p.dir))
  end, config = function(p)
    vim.filetype.add({ extension = { cls = "apex", trigger = "apex" } })
    vim.lsp.config("apexgov", { cmd = { p.dir.."/bin/apexgov", "lsp" },
      filetypes = { "apex" }, root_markers = { "sfdx-project.json", ".git" } })
    vim.lsp.enable("apexgov")
end }
```

詳細なセットアップ手順は [docs/lsp-setup.md](docs/lsp-setup.md) を参照してください（VS Code / Neovim 対応）。

## コマンド

### `check`

Governor / CPU / Heap アンチパターンの静的ヒューリスティクス検出。

```bash
zig build run -- check force-app --format text
zig build run -- check force-app --format sarif --out reports/apexgov.sarif
```

### `profile`

Apex デバッグログのオフラインパーサー（バジェットチェック付き）。

```bash
zig build run -- profile artifacts/logs --config apexgov.toml
zig build run -- profile artifacts/logs --format json --out reports/profile.json
zig build run -- profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
```

バジェット超過時はプロセスが終了コード `1` で終了します。
`[ci].fail_on_regression = true` の場合、ベースラインリグレッションも終了コード `1` を返します。

### `emulate`

Java ベースの補助エミュレーション機能。

```bash
zig build run -- emulate java
zig build run -- emulate java reports/java-calibration-local --iterations 80000 --nix
zig build run -- emulate test tools/java-emulation/examples --out reports/java-emulation --nix
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated --strict
```

## 設定

`apexgov.toml.example` を `apexgov.toml` にコピーし、バジェットを調整してください。

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

## ビルドとテスト

[Zig](https://ziglang.org/) (0.15+) が必要です。`nix develop` を使うと Zig + ZLS + JDK 21 の再現可能な環境を利用できます。

```bash
zig build          # ビルド (zig-out/bin/apexgov)
zig build test     # 全ユニットテスト実行
zig build run -- <subcommand>  # ビルド & 実行
```

## Apex 言語カバレッジ

トランスパイラーの Apex 言語対応カバレッジは `docs/apex-language-coverage.md` で管理しています。

2026-03-07 時点の non-best-effort snapshot:

- `apex-recipes`: `322/322`
- `fflib-apex-mocks`: `471/471`
- `fflib-apex-common + fflib-apex-mocks`: `158/158`
- `fflib-apex-common-samplecode + fflib-apex-common + fflib-apex-mocks`: `16/16`

PR で機能追加する場合は、実装・テストと同時にこのカバレッジ表も更新してください。

## ローカル検証フィクスチャ

`examples/apex-validation` に、`check` / `profile` の再現用 Apex プロジェクトとログを置いています。
手順は `examples/apex-validation/README.md` を参照してください。

## 外部 Apex 検証（git 管理外）

実プロジェクトに近い Apex コードで検証するために、git 管理外の入力を使って transpile 検証できます。
`./tools/transpile-external.sh` は git URL かローカルパスを受け取り、`emulate transpile` を実行します。

```bash
# public repo から取得して検証（clone 先は .local-fixtures/ 配下）
./tools/transpile-external.sh \
  https://example.com/your-apex-repo.git \
  --subpath force-app/main/default/classes

# ローカルの SFDX プロジェクトを strict で検証
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --strict

# transpile 後にローカル emulation test まで実行
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --run-tests --nix

# unresolved source がある場合に best-effort で段階実行
./tools/transpile-external.sh \
  /path/to/your/sfdx-project \
  --subpath force-app/main/default/classes \
  --run-tests --best-effort --nix
```

- キャッシュ/取得先: `.local-fixtures/apex/repos/`（`.gitignore` 済み）
- 出力先: `reports/apex-transpile-external/<label>/`

## 定期トランスパイルチェック (just)

複数リポジトリの定期点検は、git 管理外のローカル targets ファイルで管理します。

```bash
cp tools/periodic-targets.example.txt .local-fixtures/periodic-targets.txt
# .local-fixtures/periodic-targets.txt を編集して対象を設定
just periodic-transpile
just periodic-transpile-strict
```

- 既定の targets ファイル: `.local-fixtures/periodic-targets.txt`（git 管理外）
- 環境変数 `APEXGOV_PERIODIC_TARGETS_FILE` で別ファイル指定可能
- 出力先: `reports/apex-transpile-periodic/<timestamp>/`

## Java キャリブレーション

`tools/java-calibration` に、CPU 係数の相対生成ツールがあります。

```bash
nix develop
./tools/java-calibration/run.sh
# または CLI から
zig build run -- emulate java --nix
```

生成された `cpu_model.toml` の `[cpu.model]` を `apexgov.toml` にマージすると、AG009 の CPU 見積もりで利用されます。

## Java テストエミュレーション

`tools/java-emulation` に、`@Test` をローカル実行して CPU/Heap 超過を検出する簡易ランナーがあります。

```bash
zig build run -- emulate test --nix
zig build run -- emulate test reports/apex-transpile-external/my-repo --nix
# unresolved source がある場合
zig build run -- emulate test reports/apex-transpile-external/my-repo --best-effort --nix
CPU_LIMIT_MS=8000 HEAP_LIMIT_BYTES=5000000 ./tools/java-emulation/run-tests.sh
SOQL_NULL_ORDER_DEFAULT=DIRECTIONAL ./tools/java-emulation/run-tests.sh
```

- `--best-effort` を付けると、`javac` で解決できないソースを段階的に placeholder stub に置き換えて、実行可能な `@Test` を先に実行します（元ソースは変更しません）。
- placeholder 化されたソースは `OUT_DIR/compile-fallbacks.txt` に出力されます。
- それでもコンパイル不能なソースが残る場合は `OUT_DIR/compile-failures.txt` に出力されます。

主な対応:

- `Limits` API (`get*`) と `Test.startTest/stopTest`
- `Test.runAs(...)` / `UserInfo.getUserId()/getUsername()/getUserName()/getProfileId()` のコンテキスト切り替え（`Schema` profile context 含む）
- `Test.loadData(sobjectType, csvPath)` による CSV フィクスチャの取り込み
- `Test.setMock(...)` + `Http.send` / `WebServiceCallout.invoke` モック実行
- `stopTest()` 時の `@Future` / Queueable / Batch / Schedulable 簡易 flush
- `QueryLocatorBatchable` 経由の scope 分割 `execute(List<ApexSObject>)`
- `start/execute/finish` を独立した Limits コンテキストで評価
- `BatchContext.getJobId()/getScopeIndex()/getTotalScopes()/getScopeSize()/getScopeRecordCount()/getPhase()`
- `Trigger` による `before/after` トリガーコンテキスト再現
- `Database` + `ApexSObject` による in-memory CRUD（`merge` 含む）/ SOQL サブセット
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
- `Schema` による custom object の required/type/maxLength/restricted picklist/precision(scale)/lookup reference/unique/externalId 検証
- `Database` CRUD（`upsert` / `merge` 含む）での登録済みトリガー自動発火
- `merge` 時の related row 再親子付けで関連オブジェクト `before/after update` トリガーも自動発火
- SOQL semi-join (`WHERE Id IN (SELECT ...)` / `NOT IN`) と child subquery (`SELECT ..., (SELECT ... FROM Contacts)`) のサブセット対応（schema metadata の relationship 名解決を優先）

詳細は `tools/java-emulation/README.md` を参照してください。

## Apex→Java トランスパイル（スキャフォールド）

`apexgov emulate transpile` は Apex `.cls` から Java クラスの骨組みを自動生成します。

主な変換:

- `@IsTest` → `@Test`
- メソッド署名（戻り値/引数/static）とコンストラクタ、クラスフィールド/`{ get; set; }` プロパティ骨組み生成
- `System.assert*` → `SystemAssert.*`、`Assert.*` / `System.Assert.*` → `ApexAssert.*`、`System.debug(...)` → `System.out.println(...)`
- `switch on / when` → Java `switch` / `case ... ->` / `default ->`
- `when Account acc` → `switch (ApexSwitch.typeName(...))` + `case "Account"` 形式
- `record instanceof Account` → `"Account".equals(ApexSwitch.typeName(record))`
- `instanceof` の否定/複合式も変換（`instanceof SObject` → `instanceof ApexSObject`）
- `do { ... } while (...)` の末尾を Java do-while 形式へ正規化
- `String.isBlank/isNotBlank/isEmpty/isNotEmpty/join/escapeSingleQuotes` → `ApexStrings.*`
- `List/Map/Set` 宣言・コンストラクタ・リテラル（`new List<T>{...}`）→ Java collection (`ArrayList/LinkedHashMap/LinkedHashSet`)
- `new Map<Id, Account>(records)` / `new Map<Id, Account>(existingMap)` → `ApexCollections.toIdMap(...)`
- named-arg 風 SObject コンストラクタ（`new Task(Subject='x', WhatId=...)`）→ `ApexSObject.of(...).set(...)`
- `[SELECT ...]`（単行/複数行）→ `Database.query(...)`（単一 SObject 代入は `ApexCollections.firstOrNull(Database.query(...))`)
- `Database.getQueryLocator/countQuery/queryWithBinds` 系の `[SELECT ...]` → query string に正規化
- `insert/update/upsert/delete/undelete/merge`（`upsert ... ExternalId__c` 含む）→ `Database.*` 呼び出し
- `merge` は `merge master dup` / `merge master dup1 dup2` / `merge master, dup1, dup2` を処理
- 未解決型は `ApexSObject` にフォールバック、SObject 風フィールド参照 (`record.Id`) → `record.getAs("Id")`
- 未変換行（comment fallback）は `file:line [method] reason: statement` 形式で出力
- `--strict` 指定時は未変換行が 1 件でもあると終了コード 1 で失敗

```bash
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated
zig build run -- emulate transpile examples/apex-validation/force-app/main/default/classes --out reports/apex-transpile --package generated --strict
```

`[APEX_PATHS...]` を省略した場合は、`force-app/main/default/classes` が存在すればそれを、無ければリポジトリの検証フィクスチャ (`examples/apex-validation/...`) を自動利用します。

## ライセンス

MIT License (`LICENSE`)
