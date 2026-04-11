---
name: typegen
description: apexgov の LWC 用 TypeScript 型定義生成 (typegen) コマンド。SFDX メタデータから .d.ts を生成。Org 接続不要。「typegen」「型定義」「LWC」「@salesforce/schema」「@salesforce/apex」「.d.ts」などの話題で自動トリガー。
---

# apexgov typegen — LWC TypeScript 型定義生成

## 基本コマンド

```bash
# デフォルト出力先 (.sfdx/typings/lwc)
apexgov typegen my-sfdx-project

# 出力先指定
apexgov typegen my-sfdx-project --out .sfdx/typings/lwc
```

Org 接続不要。完全オフラインで動作する。

## 生成される型定義

| モジュール | 入力 | 出力ファイル |
|---|---|---|
| `@salesforce/schema/Obj.Field` | `*.field-meta.xml` | `schema.d.ts` |
| `@salesforce/label/c.XXX` | `CustomLabels.labels-meta.xml` | `customlabels.d.ts` |
| `@salesforce/resourceUrl/XXX` | `*.resource-meta.xml` | `{name}.resource.d.ts` |
| `@salesforce/messageChannel/XXX__c` | `*.messageChannel-meta.xml` | `{name}.messageChannel.d.ts` |
| `@salesforce/contentAssetUrl/XXX` | `*.asset-meta.xml` | `{name}.asset.d.ts` |
| `@salesforce/apex/Class.method` | `*.cls`（`@AuraEnabled` ���出） | `apex.d.ts` |

## 公式互換性

`resource`, `messageChannel`, `asset`, `customlabels` の出力は公式 `@salesforce/lwc-language-server` とバイト単位で一致。`schema` と `apex` は apexgov 独自の付加価値���

## フィールド型マッピング

| Salesforce 型 | TypeScript ��� |
|---|---|
| Number, Currency, Percent | `number` |
| Checkbox | `boolean` |
| Text, Date, Lookup, Picklist 等 | `string` |
| その他 | `any` |

## 生成例

```typescript
// schema.d.ts
declare module "@salesforce/schema/Account.Revenue__c" {
    const Revenue__c: number;
    export default Revenue__c;
}

// apex.d.ts
declare module "@salesforce/apex/AccountController.getAccounts" {
    export default function getAccounts(params?: any): Promise<any>;
}

// customlabels.d.ts
declare module "@salesforce/label/c.Save" {
    var Save: string;
    export default Save;
}
```

## ���様

- ファイル走査はパスのアルファベット順（決定的出力）
- 複数の labels-meta.xml は結合して 1 つの customlabels.d.ts に出力
- `@AuraEnabled` 検出は `public/global static` メソッドのみ
