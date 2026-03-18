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
- **check.zig** — 静的解析エンジン (最重要)。ルール AG001〜AG011 の検出、ループ上限推論、メソッド呼び出しグラフによるクロスクラス間接呼び出し追跡
- **transpile.zig** — Apex→Java トランスパイラー (最大ファイル ~13K行)。クラス/メソッドパース、Apex 構文の Java 変換
- **profile.zig** — デバッグログパーサー。CPU/Heap 計測、マルチトランザクション分割、ベースライン比較によるリグレッション検出
- **model.zig** — 共通データ型 (`Severity`, `OutputFormat`, `Finding`, `ProfileResult`)
- **config.zig** — `apexgov.toml` の手書き TOML パーサー
- **report.zig** — text/json/sarif フォーマッター

### tools/ — Java エミュレーション環境

- **java-emulation/** — トランスパイル後の Java コードをローカル実行するテスト環境
  - `runner/Runner.java` — リフレクションベースのテストランナー
  - `runtime/` — Apex ランタイムのエミュレーション (Database, Limits, SObject, Schema 等)
  - `run-tests.sh` — コンパイル & テスト実行スクリプト (best-effort モード対応)
- **java-calibration/** — CPU 係数マイクロベンチマーク
- **transpile-external.sh** — 外部リポジトリの transpile 検証

### 静的解析ルール (check.zig)

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

テストは各ソースファイル内にインラインで記述 (Zig 標準の `test` ブロック)。check.zig に約50+個、transpile.zig に約30+個、profile.zig に7個のテストがある。`zig build test` でモジュールテストと実行ファイルテストが並行実行される。

## 設定ファイル

`apexgov.toml` で budget (CPU/Heap 上限)、cpu.model (各操作のコスト係数)、ci (リグレッション閾値) を設定。`apexgov.toml.example` を参照。

## 言語

常に日本語で返答してください。
