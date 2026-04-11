---
name: emulate
description: apexgov の Apex→Java トランスパイル・エミュレーション (emulate) コマンド群。transpile, test, java キャリブレーション。「emulate」「transpile」「Java」「トランスパイル」「エミュレーション」「テスト実行」などの話題で自動トリガー。
---

# apexgov emulate — Apex→Java エミュレーション

## サブコマンド

### `emulate transpile` — Apex→Java トランスパイル

```bash
# 基本
apexgov emulate transpile force-app/main/default/classes --out reports/apex-transpile --package generated

# Strict モード（未変換行があれば exit 1）
apexgov emulate transpile force-app/main/default/classes --out reports/apex-transpile --package generated --strict

# 上書きモード
apexgov emulate transpile force-app/main/default/classes --out reports/apex-transpile --package generated --overwrite
```

主な変換: `@IsTest` → `@Test`、`System.assert*` → `SystemAssert.*`、`switch on/when` → Java switch、SOQL → `Database.query()`、DML → `Database.*` 呼び出し。

### `emulate test` — ローカルテスト実行

```bash
# Nix 環境でテスト実行
apexgov emulate test --nix

# 特定ディレクトリのテスト
apexgov emulate test reports/apex-transpile --out reports/test-results --nix

# Best-effort モード（コンパイルエラーをスタブで回避）
apexgov emulate test reports/apex-transpile --best-effort --nix

# Governor 制限カスタマイズ
apexgov emulate test --cpu-limit-ms 8000 --heap-limit-bytes 5000000 --nix
```

ランタイム: `Database` CRUD、`Limits` API、`Test.startTest/stopTest`、トリガー自動発火、SOQL サブセット。

### `emulate java` — CPU 係数キャリブレーション

```bash
apexgov emulate java --nix
apexgov emulate java reports/java-calibration-local --iterations 80000 --nix
```

生成された `cpu_model.toml` を `apexgov.toml` の `[cpu.model]` にマージして AG009 の精度を向上。

## 外部リポジトリ検証

```bash
# Git URL からクローンして検証
./tools/transpile-external.sh https://github.com/org/repo.git \
  --subpath force-app/main/default/classes --run-tests --nix

# ローカルプロジェクト
./tools/transpile-external.sh /path/to/project \
  --subpath force-app/main/default/classes --strict
```

クローン先: `.local-fixtures/apex/repos/`（git-ignored）
