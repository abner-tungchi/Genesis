---
name: presenter
description: Genesis bundle-writing skill (read-side AS design). Inside a Genesis-bootstrapped project, /presenter reads the read models via `genesis bundle-parse` (canonical result, works on Cosmogony canvas exports whose readModels carry queryName/parameters/returnType), asks user which readmodel to expose + output shape (array/single/scalar) via AskUserQuestion, and appends a new entry to bundle.presenters[]. Does NOT generate Swift / openapi.yaml — that is Phase 1.k renderer's job.
argument-hint: [readModelName]
disable-model-invocation: true
allowed-tools: Read, Write, AskUserQuestion, Bash
---

# /presenter — Bundle-writing skill for read-side AS design

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

在 Genesis-bootstrapped project 內：

1. 找 bundle JSON，透過 `genesis bundle-parse` 取 canonical parse 結果
2. 列 canonical `readModels[]`，user 選一個要 expose 為 read API 的
3. 用 AskUserQuestion 收 user 對 output shape / type / source 的選擇 (5 steps)
4. 把新 presenter entry append 到**原始 bundle** 的 `presenters[]`（保持原檔格式）
5. 印 next-step hint「待 Phase 1.k renderer ship 後可 codegen Get<X>ApplicationService」

**絕對不要**：
- 不寫 Sources/ 任何 Swift 檔
- 不寫 openapi.yaml / event.yaml / 任何 *.yaml
- 不執行 genesis new（只准執行唯讀的 `genesis bundle-parse`）
- 不修改 bundle 內既有其他 entries
- **不要把 `genesis bundle-parse` 的輸出寫回** bundle——canonical JSON 只用來讀；寫入對象永遠是原始 bundle 檔

## 輸入解析

`$ARGUMENTS` 可為空或一個 readModelName。

### 取得 canonical readModels（不自己解析 bundle JSON schema）

Cosmogony 畫布匯出的 bundle，`readModels[]` 只有 `queryName`／`parameters`／`returnType`（以及 `links`）；
`name`／`key`／`storedFields` 是 Genesis 解析時才推導的（`name` = `queryName` 首字大寫，如 `getPermissions` → `GetPermissions`；
`key` 由 `parameters[0]` 推得；`storedFields` 由 `returnType.fields` 攤平）。因此**不自己解析 bundle JSON schema**，一律跑：

```bash
genesis bundle-parse <bundle.json>
```

- `genesis` 不在 PATH → exit 1：`genesis CLI not on PATH`。
- `genesis bundle-parse` exit ≠ 0（bundle invalid / JSON syntax error）→ 把 stderr 原樣印給 user，exit 1。
- 成功 → stdout 是 canonical FullBundle JSON（stderr 的 `⚠ derived key ...` 提示可忽略）。以下「readModel」一律指 canonical `readModels[]` 的 entry，
  可用欄位：`name`、`aggregateRef`、`key{field,type}`、`storedFields[{name,type}]`。`presenters[]` 也取自 canonical 結果（檢查 name 唯一）。
- canonical `readModels[]` 為空 → exit 1 hint「請先在畫布建 Remodel（或跑 `/readmodel`）」。

```
若 $ARGUMENTS 非空 → readModelRef = $ARGUMENTS；比對 canonical `readModels[].name`（大小寫不敏感；命中後一律改用 canonical 的 PascalCase 名），
                      找不到 → exit 4
否則 step 2 互動選
```

**readModelRef 一律是 canonical `readModels[].name`（PascalCase，如 `GetPermissions`）**，不是畫布的 `queryName`（`getPermissions`），
否則 `genesis bundle-parse` 會判 `presenter ... references missing readModel`。

## Step 1 — Locate bundle

已在「輸入解析」做完。

## Step 2 — Choose readmodel (single-select)

```
若 $ARGUMENTS 提供 → 跳過。
否則：
  AskUserQuestion (header="ReadModel", multiSelect=false):
    "選一個 readmodel 來 expose 為 read API"
    options = canonical readModels[].name (with description hint)
Selected → 取對應 readModel object 為 step 5 element-source 候選來源
```

## Step 3 — Name the presenter

```
default = canonical readModel.name (e.g. "GetQuotingProofs"；已是 PascalCase 且以 Get 開頭)
AskUserQuestion (header="Presenter name", multiSelect=false):
  options = [<default> (Recommended), "Other"]
若 Other → free-form text input
Validate: regex /^Get[A-Z][A-Za-z0-9]+$/, uniqueness in bundle.presenters[]
若衝突 → AskUserQuestion: [overwrite / pick new / abort]，abort = exit 3
```

## Step 4 — Choose output shape (single-select)

```
AskUserQuestion (header="Output shape", multiSelect=false):
  "Read API output 形狀？"
  options = [
    "array (e.g. [QuotingProofDto])",
    "single (e.g. AccountingTypeDto)",
    "scalar (e.g. String?)"
  ]
Selected → output.kind
```

## Step 5 — Configure output details

對 step 4 選的 kind 分支收集：

```
elementType (Swift type name):
  AskUserQuestion (header="Element type", multiSelect=false):
    options = bundle.dtos[].name + "Other (free-form)"
  Other → free-form (e.g. "String", "[String]", custom DTO not in bundle)
Selected → output.elementType

elementSource (readModel field to map from):
  AskUserQuestion (header="Source field in readModel", multiSelect=false):
    options = canonical readModel.storedFields[].name + readModel.key.field + "Other (free-form)"
    （畫布匯出的 returnType.fields 已被攤平成 storedFields；一個 presenter 只能選一個欄位）
  Other → free-form
Selected → output.elementSource

if output.kind in [single, scalar]:
  AskUserQuestion (header="Optional?"):
    options = ["true (nullable from readModel)", "false (required)"]
  Selected → output.isOptional

input fields (path/header params for AS Input):
  Default: { name: readModel.key.field, type: readModel.key.type, fromPath: readModel.key.field }
  AskUserQuestion (header="Add filter params?"):
    options = ["Use default (just ID)", "Add custom"]
  若 Add custom → free-form list of {name, type, fromPath}
Set → input.fields

endpoint:
  Default: path = "/<kebab-aggregateRef>/{<readModel.key.field>}/<kebab-stripGetPrefix(name)>"
  method = "GET"
  (v1 不問 user override；defer v2)
```

## Build & Write

```
1. Build PresenterSpec per bundle.presenters[] schema:
   { presenterSpecId, name, readModelRef, aggregateRef (from readmodel),
     input, output, endpoint, comment }
2. Read **原始 bundle** 檔（不是 bundle-parse 輸出），在頂層 `presenters` 陣列 append 新 entry
   （原檔沒有 `presenters` key → 新增在物件最後）；其餘所有 key 與內容原樣保留，2-space indent，preserve key order
3. Single Write call to bundle path
4. 寫完再跑一次 `genesis bundle-parse <bundle.json>` 驗證：exit 0 才算成功；
   exit ≠ 0 → 把 stderr 印給 user 並提示用 Write 還原原內容（先前已 Read 的原始內容）後 exit 1
```

## Success message

```
✅ presenter '<name>' appended to <bundle-path>
   → readModelRef: <canonical readModel name>
   → output: <kind> of <elementType> from readModel.<elementSource>
   → endpoint: GET <path>
   → Next step (when Phase 1.k renderer ships): re-run `genesis new <bundle>` to scaffold
     Adapter/<Get<X>>/<Get<X>>ApplicationService.swift + ApiHandler read method + openapi GET entry.
```

## 失敗路徑

| 情況 | 行為 |
|---|---|
| Bundle 不存在 | exit 1 |
| bundle-parse 失敗（invalid / 找不到 genesis） | exit 1（stderr 原樣印出） |
| canonical readModels[] 為空 | exit 1 + hint 先建 Remodel / `/readmodel` |
| readModelRef 不存在於 canonical readModels[].name (arg-provided) | exit 4 |
| 寫入後 bundle-parse 驗證失敗 | exit 1（還原原檔） |
| 重複 name + abort | exit 3 |
| step 2-5 cancel | exit 2 (no partial writes) |
| AskUserQuestion 不可用 | exit 1 |
| Write 失敗 | exit 1 |

## Atomicity 保證

- 5 步全完成 + final confirm → single Write call
- Single Write 之前 bundle 完全未動
- POSIX atomic-rename 不在 v1 保證 (同 /readmodel)

## 命名慣例

- `name`: `^Get[A-Z][A-Za-z0-9]+$`，typically same as readModel.name
- `readModelRef`: must exist in canonical readModels[].name（`genesis bundle-parse` 的結果，PascalCase）
- `aggregateRef`: 自 readmodel 繼承 (denormalized)
- `output.kind`: `array` | `single` | `scalar`
- `endpoint.method`: `GET` v1

## 與其他 skills 的關係

```
[此 skill] /presenter (design)
    ↓ 寫 bundle.presenters[]
bundle JSON 更新
    ↓ user 手動跑 (Phase 1.k 完成後)
genesis new <bundle>
    ↓ Phase 1.k ReadAsRenderer 產 Get<X>ApplicationService scaffold
    ↓ AS execute() body 為 TODO，user 填 readModel → output mapping
    ↓
[sibling] /readmodel — design ReadModel + projection
[future] Phase 1.k — codegen read-side AS scaffold
[future] /presenter-fill — AI 填 execute() body (sibling to /api skill v3)
```

## 重要約束（不可違反）

- 只寫 bundle-path（原始 bundle），**不寫**其他任何 file；Bash 只准跑 `genesis bundle-parse`
- AskUserQuestion 必須用
- D18 absolute: 不寫 openapi.yaml / 不寫 Sources/ / 不執行 genesis new（bundle-parse 除外）
- readModelRef 必須對應 canonical readModels[].name（PascalCase）
