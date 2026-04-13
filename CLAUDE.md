# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

apexgov は Salesforce Apex コード向けのオフライン静的チェッカー & デバッグログプロファイラー。CI/CD パイプラインでの利用を想定し、Governor 制限リスク（ループ内 SOQL/DML/Callout 等）の検出、デバッグログからの CPU/Heap 解析を提供する。

## ビルド & テスト

```bash
zig build                        # ビルド (zig-out/bin/apexgov)
zig build test                   # 全ユニットテスト実行
zig build run -- <subcommand>    # ビルド & 実行
```

主なサブコマンド:
- `check <path> [--format json|sarif|text]` — 静的解析
- `profile <path> [--format json|text]` — デバッグログプロファイル
- `interpret test <paths...>` — Zig ネイティブ Apex テスト実行
- `typegen <sfdx-project-root> [--out DIR]` — LWC 用 TypeScript 型定義生成
- `lsp` — Language Server Protocol サーバー起動（stdio）

Nix 開発環境: `nix develop` (Zig + ZLS)

## アーキテクチャ

### src/ — Zig コア (外部依存ゼロ)

- **main.zig** — CLI エントリポイント。サブコマンドルーティングと引数パース
- **model.zig** — 共通データ型 (`Severity`, `OutputFormat`, `Finding`, `ProfileResult`)
- **config.zig** — `apexgov.toml` の手書き TOML パーサー
- **report.zig** — text/json/sarif フォーマッター
- **profile.zig** — デバッグログパーサー。CPU/Heap 計測、マルチトランザクション分割、ベースライン比較

#### src/check/ — 静的解析エンジン（ファサード + 12 サブモジュール）

`check.zig` がファサードで、公開 API (`run`, `runWithConfig`) の再エクスポートとテストを提供する。

| サブモジュール | 役割 |
|---|---|
| `types.zig` | 共有データ型（LoopScope, MethodSummary, TypeDecl 等） |
| `utils.zig` | 汎用ユーティリティ（識別子抽出、飽和演算、型名正規化等） |
| `preprocessor.zig` | コメント除去、do-while 条件収集 |
| `detectors.zig` | Governor 制限操作のパターン検出（SOQL/DML/SOSL/Callout 等） |
| `scope.zig` | クラス/トリガー/ループのスコープ管理 |
| `parser.zig` | メソッド・型宣言のパース |
| `type_env.zig` | 変数の型バインディング追跡 |
| `bounds.zig` | ループ反復回数のバウンド推論 |
| `call_graph.zig` | メソッド呼び出しグラフ構築・解決（最大サブモジュール） |
| `rules.zig` | Governor 制限定数と Finding 生成 |
| `file_collector.zig` | ファイルシステムからの Apex ソース収集 |
| `scanner.zig` | メイン解析ループ（scanContent） |

#### src/typegen/ — LWC 用 TypeScript 型定義ジェネレータ

`typegen/root.zig` がエントリポイント。SFDX メタデータ XML から `.d.ts` ファイルを生成する。

| 生成対象 | 入力 | 出力ファイル |
|---|---|---|
| `@salesforce/schema/Obj.Field` | `*.field-meta.xml` | `schema.d.ts` |
| `@salesforce/label/c.XXX` | `CustomLabels.labels-meta.xml` | `customlabels.d.ts` |
| `@salesforce/resourceUrl/XXX` | `*.resource-meta.xml` | `{name}.resource.d.ts` |
| `@salesforce/messageChannel/XXX` | `*.messageChannel-meta.xml` | `{name}.messageChannel.d.ts` |
| `@salesforce/contentAssetUrl/XXX` | `*.asset-meta.xml` | `{name}.asset.d.ts` |
| `@salesforce/apex/Class.method` | `*.cls` の `@AuraEnabled` | `apex.d.ts` |

resource/messageChannel/asset は公式 LWC Language Server と同一フォーマット（diff 0 検証済み）。ファイル走査はパスのアルファベット順で決定的。

#### src/lsp/ — Language Server Protocol サーバー

`lsp/server.zig` がメインループ。JSON-RPC over stdio。

主要機能: 補完、ホバー、定義ジャンプ（クロスファイル対応）、参照検索（クロスファイル対応）、リネーム、コードアクション（Governor 制限クイックフィックス）、セマンティックトークン、フォーマット、折りたたみ、シグネチャヘルプ、Incremental Document Sync。

### 静的解析ルール (check/)

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

## テスト構造

テストは各ソースファイル内にインラインで記述 (Zig 標準の `test` ブロック)。check.zig (ファサード) に約 50+ 個、profile.zig に 7 個のテストがある。`zig build test` でモジュールテストと実行ファイルテストが並行実行される。

## 設定ファイル

`apexgov.toml` で budget (CPU/Heap 上限)、cpu.model (各操作のコスト係数)、ci (リグレッション閾値) を設定。`apexgov.toml.example` を参照。

## 言語

常に日本語で返答してください。
