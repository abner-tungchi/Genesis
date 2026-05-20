---
name: presenter
description: Genesis bundle-writing skill (read-side AS design). Inside a Genesis-bootstrapped project, /presenter reads bundle.readModels[], asks user which readmodel to expose + output shape (array/single/scalar) via AskUserQuestion, and appends a new entry to bundle.presenters[]. Does NOT generate Swift / openapi.yaml — that is Phase 1.k renderer's job.
argument-hint: [readModelName]
disable-model-invocation: true
allowed-tools: Read, Write, AskUserQuestion
---

# /presenter — Bundle-writing skill for read-side AS design

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

在 Genesis-bootstrapped project 內：

1. 找 bundle JSON 並 parse
2. 列既有 `bundle.readModels[]`，user 選一個要 expose 為 read API 的
3. 用 AskUserQuestion 收 user 對 output shape / type / source 的選擇 (5 steps)
4. Append 新 readmodel entry 到 `bundle.presenters[]`
5. 印 next-step hint「待 Phase 1.k renderer ship 後可 codegen Get<X>ApplicationService」

**絕對不要**：
- 不寫 Sources/ 任何 Swift 檔
- 不寫 openapi.yaml / event.yaml / 任何 *.yaml
- 不執行 genesis new
- 不修改 bundle 內既有其他 entries

## 輸入解析

`$ARGUMENTS` 可為空或一個 readModelName。

```
若 $ARGUMENTS 非空 → readModelRef = $ARGUMENTS（validate exists in bundle.readModels[]，否則 exit 4）
否則 step 2 互動選
```

Parse bundle JSON；fail-fast on syntax error (exit 1)。
Validate `bundle.readModels[]` 非空 → 否則 exit 1 hint「請先跑 `/readmodel` 建 readmodel」。

## Step 1 — Locate bundle

已在「輸入解析」做完。

## Step 2 — Choose readmodel (single-select)

```
若 $ARGUMENTS 提供 → 跳過。
否則：
  AskUserQuestion (header="ReadModel", multiSelect=false):
    "選一個 readmodel 來 expose 為 read API"
    options = bundle.readModels[].name (with description hint)
Selected → 取對應 readModel object 為 step 5 element-source 候選來源
```

## Step 3 — Name the presenter

```
default = readModel.name (e.g. "GetQuotingProofs")
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
    options = readModel.storedFields[].name + readModel.key.field + "Other (free-form)"
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
2. JSON-stringify bundle (2-space indent), preserve key order
3. Single Write call to bundle path
```

## Success message

```
✅ presenter '<name>' appended to <bundle-path>
   → readModelRef: <name> (links to bundle.readModels['<name>'])
   → output: <kind> of <elementType> from readModel.<elementSource>
   → endpoint: GET <path>
   → Next step (when Phase 1.k renderer ships): re-run `genesis new <bundle>` to scaffold
     Adapter/<Get<X>>/<Get<X>>ApplicationService.swift + ApiHandler read method + openapi GET entry.
```

## 失敗路徑

| 情況 | 行為 |
|---|---|
| Bundle 不存在 | exit 1 |
| Bundle 缺 readModels[] | exit 1 + hint `/readmodel` first |
| readModelRef 不存在 (arg-provided) | exit 4 |
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
- `readModelRef`: must exist in bundle.readModels[].name
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

- 只寫 bundle-path，**不寫**其他任何 file
- AskUserQuestion 必須用
- D18 absolute: 不寫 openapi.yaml / 不寫 Sources/ / 不執行 genesis new
- readModelRef 必須對應既存 bundle.readModels[].name
