---
name: profile
description: apexgov の debug log プロファイラー (profile) コマンド。CPU/Heap 使用量の解析、マルチトランザクション分割、ベースライン比較。「profile」「debug log」「CPU」「Heap」「パフォーマンス」などの話題で自動トリガー。
---

# apexgov profile — デバッグログプロファイラー

## 基本コマンド

```bash
# テキスト出力
apexgov profile artifacts/logs

# JSON 出力
apexgov profile artifacts/logs --format json --out reports/profile.json

# 設定ファイル指定（バジェット設定）
apexgov profile artifacts/logs --config apexgov.toml

# ベースライン比較（リグレッション検出）
apexgov profile artifacts/logs --baseline reports/profile-baseline.json --config apexgov.toml
```

## 機能

- Apex デバッグログから **CPU 時間** と **Heap 使用量** を計測
- **マルチトランザクション分割**: 1 ログファイル内の複数トランザクションを自動分離
- **ベースライン比較**: 前回実行結果と比較してリグレッションを検出
- バジェット超過時は **exit code 1** を返す（CI 連携用）

## 設定（apexgov.toml）

```toml
[budget.sync]
cpu_ms = 8000
heap_bytes = 5000000

[budget.async]
cpu_ms = 50000
heap_bytes = 10000000

[ci]
fail_on_regression = true
regression_percent = 15
```

## CI 組み込み

```yaml
- name: Profile debug logs
  run: |
    apexgov profile artifacts/logs \
      --config apexgov.toml \
      --baseline reports/profile-baseline.json \
      --format json --out reports/profile.json
```
