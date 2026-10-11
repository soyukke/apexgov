---
name: lsp
description: apexgov の Language Server Protocol (LSP) サーバーのセットアップ・機能・トラブルシューティング。Neovim、VS Code での設定方法。「lsp」「language server」「補完」「定義ジャンプ」「Neovim」「VS Code」「エディタ設定」「CodeLens」「Run Test」などの話題で自動トリガー。
---

# apexgov lsp — Language Server

## 起動

```bash
apexgov lsp   # stdio で JSON-RPC サーバー起動
```

## 対応機能

| 機能 | 対応 |
|---|---|
| コード補完 | SObject フィールド、stdlib、ローカル変数、キーワード |
| ホバー | シンボルの型・種別情報 |
| 定義ジャンプ | 同一ファイル + クロスファイル（トップレベル型） |
| 参照検索 | 同一ファイル + クロスファイル |
| リネーム | 全参照箇所の一括変更 |
| コードアクション | AG002/AG003/AG010 のクイックフィックス提案 |
| 診断 | 構文エラー + Governor 制限違反（リアルタイム） |
| セマンティックトークン | キーワード、型、変数、文字列、数値、演算子、コメント |
| シグネチャヘルプ | メソッド呼び出し時のパラメータ情報 |
| フォーマット | インデント正規化 |
| 折りたたみ | クラス、メソッド、ブロック |
| ドキュメントシンボル | クラス、メソッド、フィールドの階層一覧 |
| ワークスペースシンボル | 全ファイル横断のシンボル検索 |
| ドキュメントハイライト | カーソル下シンボルの読み/書き箇所を強調 |
| CodeLens | `@IsTest` / `testMethod` メソッドに「Run Test」ボタン表示。クリックで Zig インタプリタによるローカルテスト実行（保存済みファイル対象）。クラスレベルの「Run All Tests」も対応 |
| Incremental Sync | 差分テキスト更新に対応 |

## Neovim + lazy.nvim セットアップ

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

## VS Code セットアップ

`docs/lsp-setup.md` を参照。

## トラブルシューティング

- **補完が出ない**: ファイルが `didOpen` されているか確認。`.cls` 拡張子が `apex` filetype にマッピングされているか。
- **クロスファイルジャンプが効かない**: ジャンプ先のファイルもエディタで開いている必要がある（ワークスペースインデックスは未実装）。
- **診断が更新されない**: Incremental Sync 対応済み。エディタ側が `textDocumentSync: 2` (incremental) をサポートしているか確認。
