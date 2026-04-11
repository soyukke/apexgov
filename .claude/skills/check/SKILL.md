---
name: check
description: apexgov の静的解析 (check) コマンドの実行・結果解釈・修正ガイド。Governor 制限違反 (AG001-AG011) の検出、SARIF/JSON 出力、CI 組み込み。「check」「静的解析」「Governor」「SOQL in loop」「AG002」などの話題で自動トリガー。
---

# apexgov check — 静的解析

## 基本コマンド

```bash
# テキスト出力（デフォルト）
apexgov check force-app

# JSON 出力
apexgov check force-app --format json --out reports/apexgov.json

# SARIF 出力（GitHub Code Scanning 連携用）
apexgov check force-app --format sarif --out reports/apexgov.sarif

# テストクラスも含める
apexgov check force-app --include-tests

# 閾値設定（warning 以上で exit 1）
apexgov check force-app --severity-threshold warning

# 設定ファイル指定
apexgov check force-app --config apexgov.toml
```

## 検出ルール一覧

| ID | 検出対象 | 重要度 | 修正パターン |
|---|---|---|---|
| AG001 | ネストされたループ | warning | ループの平坦化、Map による事前集約 |
| AG002 | ループ内 SOQL | warning | ループ外でクエリし Map に格納 |
| AG003 | ループ内 DML | warning | List に溜めてループ外で一括 DML |
| AG004 | ループ内 JSON シリアライズ | info | ループ外で一括処理 |
| AG005 | ループ内 clone/deepClone | info | 必要なものだけ事前コピー |
| AG006 | ループ内コレクション確保 | info | ループ外で初期化 |
| AG007 | ループ内文字列連結 | info | String.join() や List 利用 |
| AG008 | ループ内 SOSL | warning | ループ外で一括検索 |
| AG009 | ヒューリスティック CPU 見積もり | info/warning | コスト分散、非同期処理への移行 |
| AG010 | ループ内 HTTP callout | warning | ループ外でバッチ送信 |
| AG011 | ループ内 Messaging.sendEmail | warning | メール List をループ外で一括送信 |

## 典型的な修正例

### AG002: ループ内 SOQL → Map 化

```apex
// NG
for (Account acc : accounts) {
    List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
}

// OK
Map<Id, List<Contact>> contactsByAccount = new Map<Id, List<Contact>>();
for (Contact c : [SELECT Id, AccountId FROM Contact WHERE AccountId IN :accountIds]) {
    if (!contactsByAccount.containsKey(c.AccountId)) {
        contactsByAccount.put(c.AccountId, new List<Contact>());
    }
    contactsByAccount.get(c.AccountId).add(c);
}
```

### AG003: ループ内 DML → バルク化

```apex
// NG
for (Account acc : accounts) {
    acc.Status__c = 'Active';
    update acc;
}

// OK
for (Account acc : accounts) {
    acc.Status__c = 'Active';
}
update accounts;
```

## CI 組み込み

```yaml
# GitHub Actions
- name: Apex static analysis
  run: apexgov check force-app --format sarif --out reports/apexgov.sarif --severity-threshold warning
- name: Upload SARIF
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: reports/apexgov.sarif
```

## 設定ファイル（apexgov.toml）

```toml
[budget.sync]
cpu_ms = 8000
heap_bytes = 5000000

[cpu.model]
base_ms = 500
soql_ms = 35
dml_ms = 25
```

`apexgov.toml.example` を参照のこと。
