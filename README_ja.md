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

[Zig](https://ziglang.org/) 0.16+ が必要です。このフレークの devShell には zig/zls を同梱していません。home-manager の `zig-overlay` などで PATH 上の `zig` が 0.16 に解決されるようにセットアップしてください。

```bash
zig build          # ビルド (zig-out/bin/apexgov)
zig build test     # 全ユニットテスト実行
zig build run -- <subcommand>  # ビルド & 実行
```

## ローカル検証フィクスチャ

`examples/apex-validation` に、`check` / `profile` の再現用 Apex プロジェクトとログを置いています。
手順は `examples/apex-validation/README.md` を参照してください。

## ライセンス

MIT License (`LICENSE`)
