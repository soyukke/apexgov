# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

apexgov は Salesforce Apex コード向けのオフライン静的チェッカー & デバッグログプロファイラー。CI/CD パイプラインでの利用を想定し、Governor 制限リスク（ループ内 SOQL/DML/Callout 等）の検出、デバッグログからの CPU/Heap 解析、Apex→Java トランスパイルによるローカルテスト実行を提供する。

## ビルド & テスト

```bash
zig build                        # ビルド (zig-out/bin/apexgov)
zig build test                   # 全ユニットテスト実行
zig build run -- <subcommand>    # ビルド & 実行
```

主なサブコマンド:
- `check <path> [--format json|sarif|text]` — 静的解析
- `profile <path> [--format json|text]` — デバッグログプロファイル
- `emulate transpile <path>` — Apex→Java トランスパイル
- `emulate test [--nix]` — Java エミュレーションテスト実行

Java エミュレーションテストの直接実行:
```bash
CPU_LIMIT_MS=8000 HEAP_LIMIT_BYTES=5000000 ./tools/java-emulation/run-tests.sh
```

Nix 開発環境: `nix develop` (Zig + ZLS + JDK 21)

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

#### src/transpile/ — Apex→Java トランスパイラー（ファサード + 8 サブモジュール + compat/）

`transpile/root.zig` がエントリポイント。

| サブモジュール | 役割 |
|---|---|
| `types.zig` | 共有データ型（Options, クラス/メソッド情報） |
| `util.zig` | 文字列比較・トークン分割等の汎用ユーティリティ |
| `parser.zig` | Apex クラス構造のパース |
| `renderer.zig` | Java ソースコードのレンダリング |
| `line_and_expr.zig` | 行単位の式変換エンジン |
| `file_io.zig` | ファイル読み書き |
| `trigger.zig` | Apex トリガーの Java 変換 |
| `compat.zig` | Apex 互換変換ファサード（8 サブモジュール） |

##### src/transpile/compat/ — Apex 固有構文の Java 互換変換

| サブモジュール | 役割 |
|---|---|
| `operator.zig` | 演算子変換 |
| `numeric.zig` | 数値型変換 |
| `getas.zig` | SObject 型付きフィールド取得 |
| `patterns.zig` | 構文パターン認識・変換 |
| `helpers.zig` | 互換変換共通ヘルパー |
| `query.zig` | SOQL/SOSL クエリ変換 |
| `misc.zig` | その他の互換変換 |
| `sobject.zig` | SObject フィールドアクセス変換 |

### tools/ — Java エミュレーション環境

- **java-emulation/** — トランスパイル後の Java コードをローカル実行するテスト環境
  - `runner/Runner.java` — リフレクションベースのテストランナー
  - `runtime/` — Apex ランタイムのエミュレーション (Database, Limits, SObject, Schema 等)
  - `run-tests.sh` — コンパイル & テスト実行スクリプト (best-effort モード対応)
- **java-calibration/** — CPU 係数マイクロベンチマーク
- **transpile-external.sh** — 外部リポジトリの transpile 検証

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

テストは各ソースファイル内にインラインで記述 (Zig 標準の `test` ブロック)。check.zig (ファサード) に約 50+ 個、transpile 系に約 30+ 個、profile.zig に 7 個のテストがある。`zig build test` でモジュールテストと実行ファイルテストが並行実行される。

Java エミュレーションテスト:
```bash
zig build run -- emulate test --nix   # 58 テスト
```

## 設定ファイル

`apexgov.toml` で budget (CPU/Heap 上限)、cpu.model (各操作のコスト係数)、ci (リグレッション閾値) を設定。`apexgov.toml.example` を参照。

## 言語

常に日本語で返答してください。
