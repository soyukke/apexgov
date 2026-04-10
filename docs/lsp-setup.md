# apexgov LSP セットアップガイド

apexgov には Apex 言語サーバー (LSP) が内蔵されています。エディタと連携することで、Governor 制限違反の診断、コード補完、定義ジャンプなどをリアルタイムで利用できます。

## 前提条件

[Zig](https://ziglang.org/) (0.15+) が必要です。Neovim + lazy.nvim の場合はプラグイン側で自動ビルドされるため、手動ビルドは不要です。

手動でビルドする場合:

```bash
zig build
# バイナリ: zig-out/bin/apexgov
```

パスを通す例:

```bash
# シンボリックリンク
ln -s "$(pwd)/zig-out/bin/apexgov" ~/.local/bin/apexgov

# または PATH に追加 (~/.zshrc / ~/.bashrc)
export PATH="$PATH:/path/to/apexgov/zig-out/bin"
```

## 対応機能

| 機能 | 説明 |
|------|------|
| Diagnostics | パースエラー + Governor 制限違反 (AG001-AG011) |
| Hover | シンボル情報の表示 |
| Go to Definition | 定義へのジャンプ |
| Find References | 参照の検索 |
| Completion | コード補完 (Apex 標準ライブラリ + SObject) |
| Signature Help | 関数シグネチャ表示 |
| Document Symbol | ファイル内シンボル一覧 |
| Workspace Symbol | ワークスペース全体のシンボル検索 |
| Rename | シンボル名の一括変更 |
| Semantic Tokens | セマンティックハイライト |
| Folding Range | コード折り畳み |
| Formatting | コードフォーマット |
| Document Highlight | カーソル位置のシンボルハイライト |

---

## VS Code

### 方法 1: 汎用 LSP 拡張を使う

[Generic LSP Client](https://marketplace.visualstudio.com/items?itemName=llllvvuu.llllvvuu-glspc) など汎用の LSP クライアント拡張をインストールし、設定を追加します。

#### glspc を使う場合

1. 拡張をインストール:
   - VS Code で `Ctrl+Shift+X` → `llllvvuu-glspc` を検索してインストール

2. `.vscode/settings.json` に設定を追加:

```jsonc
{
  "glspc.serverPath": "apexgov",
  "glspc.serverArgs": ["lsp"],
  "glspc.languageId": "apex"
}
```

### 方法 2: lsp-client 拡張を使う

[LSP Client](https://marketplace.visualstudio.com/items?itemName=APerezGrworworworworx.lsp-client) など他の汎用 LSP クライアントでも同様に設定できます。

### 方法 3: `.vscode/settings.json` で直接設定 (推奨)

Apex 用の VS Code 拡張（例: [Apex PMD](https://marketplace.visualstudio.com/items?itemName=chuckjonas.apex-pmd)）が既にインストールされている場合、`apexgov` は追加の LSP として共存できます。

最も柔軟な方法は、汎用 LSP 拡張 **[vscode-lsp-client](https://marketplace.visualstudio.com/items?itemName=nickmass.vscode-lsp-client)** を使うことです:

1. `nickmass.vscode-lsp-client` をインストール
2. `.vscode/settings.json`:

```jsonc
{
  "lsp-client.serverCommands": [
    {
      "id": "apexgov",
      "name": "apexgov LSP",
      "command": "apexgov",
      "args": ["lsp"],
      "documentSelector": [
        { "language": "apex" },
        { "pattern": "**/*.cls" },
        { "pattern": "**/*.trigger" }
      ]
    }
  ]
}
```

> **Note**: `.cls` / `.trigger` ファイルのシンタックスハイライトには [Apex](https://marketplace.visualstudio.com/items?itemName=salesforce.salesforcedx-vscode-apex) 拡張や他の Apex 言語サポート拡張を併用してください。

---

## Neovim

### 方法 1: lazy.nvim (推奨)

[lazy.nvim](https://github.com/folke/lazy.nvim) でリポジトリを指定するだけで、clone・ビルド・LSP 設定が一括で完了します。

```lua
{
  "soyukke/apexgov",
  build = "zig build",
  config = function(plugin)
    vim.filetype.add({
      extension = { cls = "apex", trigger = "apex" },
    })

    local bin = plugin.dir .. "/zig-out/bin/apexgov"

    vim.lsp.config("apexgov", {
      cmd = { bin, "lsp" },
      filetypes = { "apex" },
      root_markers = { "sfdx-project.json", ".git" },
    })

    vim.lsp.enable("apexgov")
  end,
}
```

`:Lazy install` で初回ビルド、`:Lazy update` で pull + 再ビルドが実行されます。

> **Note**: `vim.lsp.config` / `vim.lsp.enable` は Neovim 0.11+ の API です。それ以前のバージョンでは方法 2 を参照してください。

### 方法 2: vim.lsp.start (Neovim 0.10 以前)

`apexgov` を手動ビルドしてパスを通した上で、`init.lua` に以下を追加:

```lua
vim.filetype.add({
  extension = { cls = "apex", trigger = "apex" },
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "apex",
  callback = function()
    vim.lsp.start({
      name = "apexgov",
      cmd = { "apexgov", "lsp" },
      root_dir = vim.fs.root(0, { "sfdx-project.json", ".git" }),
    })
  end,
})
```

### 方法 3: nvim-lspconfig

[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) を使う場合。apexgov はまだ組み込まれていないため、カスタム設定を追加します:

```lua
{
  "neovim/nvim-lspconfig",
  config = function()
    vim.filetype.add({
      extension = { cls = "apex", trigger = "apex" },
    })

    local configs = require("lspconfig.configs")
    if not configs.apexgov then
      configs.apexgov = {
        default_config = {
          cmd = { "apexgov", "lsp" },
          filetypes = { "apex" },
          root_dir = require("lspconfig.util").root_pattern("sfdx-project.json", ".git"),
        },
      }
    end

    require("lspconfig").apexgov.setup({})
  end,
}
```

### 方法 4: coc.nvim

[coc.nvim](https://github.com/neoclide/coc.nvim) を使う場合は `:CocConfig` で以下を追加:

```json
{
  "languageserver": {
    "apexgov": {
      "command": "apexgov",
      "args": ["lsp"],
      "filetypes": ["apex"],
      "rootPatterns": ["sfdx-project.json", ".git"]
    }
  }
}
```

filetype の認識は上記と同様に `vim.filetype.add` で設定してください。

---

## 動作確認

LSP が正しく接続されているか確認するには:

1. `.cls` ファイルを開く
2. 意図的にエラーを含むコードを書く（例: ループ内 SOQL）:
   ```apex
   for (Account a : accounts) {
       List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :a.Id];
   }
   ```
3. AG002 (ループ内 SOQL) の診断が表示されることを確認

## トラブルシューティング

### LSP が起動しない

- `apexgov lsp` がターミナルで実行できるか確認 (Ctrl+C で終了):
  ```bash
  apexgov lsp
  ```
- パスが通っているか確認:
  ```bash
  which apexgov
  ```

### 診断が表示されない

- ファイルの拡張子が `.cls` または `.trigger` であることを確認
- エディタの LSP ログを確認 (VS Code: 出力パネル → 言語サーバー, Neovim: `:LspLog`)

### Neovim で filetype が認識されない

- `:set filetype?` でファイルタイプを確認
- `apex` でなければ `vim.filetype.add` の設定を確認
