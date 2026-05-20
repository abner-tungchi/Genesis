---
name: readmodel
description: Genesis bundle-writing skill (designed for Genesis-bootstrapped projects). Inside a Genesis-bootstrapped project, /readmodel reads the bundle JSON, runs a 6-step interactive flow using AskUserQuestion, and appends a new entry to bundle.readModels[]. Does NOT generate Swift / JS / YAML code — that is Phase 1.g renderer's job.
argument-hint: [bundle-path]
disable-model-invocation: true
allowed-tools: Read, Write, AskUserQuestion
---

# /readmodel — Bundle-writing skill for ReadModel design

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

在 Genesis-bootstrapped project 內：

1. 找 bundle JSON 並 parse
2. 用 6 個 step 跟 user 互動 (AskUserQuestion 全程必用，multiSelect:true 用於 events 跟 stored fields)
3. 把新 readmodel entry append 進 bundle.readModels[]
4. 用單一 Write call 寫回 bundle JSON
5. 印 next-step hint（包括 Phase 1.g status）

**絕對不要**：
- 不寫 Sources/ 任何 Swift 檔
- 不寫 projections/ 任何 JS 檔
- 不寫 *.yaml 任何 schema 檔
- 不執行 genesis new
- 不修改 bundle 內既有其他 entries

## 解析輸入

`$ARGUMENTS` 可能是空，或是一個 path。

```
若 $ARGUMENTS 非空 → bundle-path = $ARGUMENTS
否則：
  ls cwd 找 bundle.json / *-bundle.json
  若找到一個 → 用它
  若找到多個 → AskUserQuestion 單選
  若都找不到 → exit 1 提示「先 genesis new 產 bundle？」
```

Parse JSON；fail-fast on syntax error（exit 1 + 印第一個 error line:column）。

Validate top-level：`manifestVersion`, `context`, `aggregates` (non-empty)。

## Step 1 — Locate bundle

> 已在上面「解析輸入」做完。Step 2 開始才需 user 互動。

## Step 2 — Choose aggregate (single-select)

選項 = bundle.aggregates[].aggregate + 字面值 `<context-level>`

```
若 bundle.aggregates.count == 1 → 跳過 step 2，announce 「自動選 <name>」
否則：
  AskUserQuestion (header="Aggregate", multiSelect=false):
    "這個 readmodel 屬於哪個 aggregate？"
    options = ["AggA", "AggB", ..., "<context-level>"]
```

若選 `<context-level>` → step 3 source events 來自所有 aggregates。

## Step 3 — Choose events (multiSelect: true)

```
若 aggregateRef == "<context-level>":
  options = flatten(每個 aggregate.events[]) labelled "[<aggregateName>] <eventName>"
否則:
  options = chosen aggregate.events[]，options 顯示為 "<eventName>"

若 options 為空 → exit 1 「該 aggregate 還沒 event；先用 /aggregate 或 /usecase 加 event」

AskUserQuestion (header="Events", multiSelect=true):
  "哪些 events 影響這個 readmodel？"
  options = ↑

User 必須至少選一個；若選 0 → 再問一次。
```

對每個選到的 event，記錄 (name, sourceAggregate)。`sourceAggregate` 從 options label 反推（context-level 模式 label 有 `[A]` 前綴）或從 chosen aggregate 直接帶入。

對每個 event 透過下列演算法 resolvePayload，取 payload field names（用於 step 5/6 預設值）：

```
resolvePayload(eventName, bundle):
  Pass-1: 每個 aggregate.events[] 若有 payload (bundle schema 未來會擴) → 用它
  Pass-2: bundle.useCases[].emittedEvent == eventName → 用該 uc.eventPayload
  Pass-3: 都找不到 → 返回空 list (step 5/6 走 manual 路徑)
```

## Step 4 — Name the readmodel

```
default = "Get" + commonNoun(selectedEvents)  // 例：events=[QuotingProofUploadedToGcs, QuotingProofOnGcsRemoved] → "GetQuotingProofs"
若 default 算不出 → 預設 "Get"

AskUserQuestion (header="ReadModel name"):
  "ReadModel 名稱？(必須 ^Get[A-Z][A-Za-z0-9]+$)"
  options = [default + "(Recommended)", "Other"]

User 自訂 → 從 "Other" 自由輸入。
Validate: regex `^Get[A-Z][A-Za-z0-9]+$`。

若 name 已存在於 bundle.readModels[]:
  AskUserQuestion (header="Name conflict"):
    "'<name>' 已存在，怎麼辦？"
    options = ["Overwrite existing", "Pick new name", "Abort"]
  Overwrite → 設 overwriteIfExists=true
  Pick new → 回 step 4
  Abort → exit 3
```

## Step 5 — Key field selection

```
candidates = ∩(resolvePayload(e, bundle).map(\.name) for e in selectedEvents)

若 candidates 為空 (intersection 空 OR 某 event payload 為空):
  AskUserQuestion (header="Key field manual"):
    "找不到共用 payload key 欄位；手動指定 event payload 的 key 欄位"
    options = ["Manual entry"]  // 走 free-form
  warn user：違反 strict v1 共用 key 契約，可能 block codegen
否則若 candidates.count == 1:
  AskUserQuestion (header="Key field"):
    "推薦 key 欄位 (event payload 中):"
    options = [candidates[0] + "(Recommended)", "Other"]
否則：
  AskUserQuestion (header="Key field"):
    "選擇 event payload 中作為 readmodel key 的欄位:"
    options = candidates.map { $0 }
  user 選一個

設 keyFromPayload = chosen field name

AskUserQuestion (header="Key type"):
  "Key type?"
  options = ["String (Recommended)", "UUID", "Int", "Int64"]

設 keyType = chosen

AskUserQuestion (header="Key field name"):
  "ReadModel 內 key 欄位的本地名稱？(default = keyFromPayload，常 rename，例如 quotingId → auditQuotingId)"
  options = [keyFromPayload + " (default)", "Other"]

設 keyField = chosen (validate `^[a-z][A-Za-z0-9]*$`)
```

## Step 6 — Stored fields (multiSelect)

```
candidate = union(resolvePayload(e, bundle).map(\.name) for e in selectedEvents) - {keyField, keyFromPayload}

若 candidate 為空:
  AskUserQuestion (header="Stored fields manual"):
    "Payload schema 不足；手動加 stored fields"
    options = ["Continue with no stored fields", "Manually add fields"]
否則:
  AskUserQuestion (header="Stored fields", multiSelect=true):
    "選哪些欄位要存進 ReadModel？"
    options = candidate + ["Add custom field..."]

對每個選到的 field:
  type 預設用 payload schema 的 type (若已知；else "String?")
  AskUserQuestion (header="<field> type"):
    options = [inferredType + " (default)", "Other"]
  default 預設 nil

對 "Add custom field..." 或 manual entry 路徑:
  user 自由輸入 name + type + default
```

## Build & Write

```
1. Build entry = {
     name, aggregateRef, key{field,type,fromEventPayload},
     storedFields[], events[]{name,sourceAggregate}, comment
   }
2. 驗證所有 fields 符合 §Field validation rules
3. newBundle = bundle with readModels[] appended (or replaced if overwriteIfExists)
4. JSON-stringify newBundle with 2-space indent，preserve key order
5. Single Write call to bundle-path
```

## Success message

```
✅ readmodel '<name>' appended to <bundle-path>
   → Bundle entry now contains structural definition.
   → Next step (when Phase 1.g renderer ships):
     re-run `genesis new <bundle>` to scaffold ReadModel.swift / Presenter.swift /
     projection-model.yaml entry / OC_*Projection.js with empty when() bodies you'll
     fill in by hand.
   → Phase 1.g status: see docs/tasks/registry/phase-1g-readmodel-renderer.json
```

## 失敗路徑

| 情況 | 行為 |
|---|---|
| Bundle 不存在 | exit 1 |
| Bundle JSON syntax error | exit 1，印 error 位置 |
| `aggregates` 缺或為空 | exit 1 |
| Chosen aggregate 0 events | exit 1 + hint |
| 重複 name + user abort | exit 3 |
| Step 2-6 任一 cancel | exit 2，bundle 未動 |
| `events[].payloadKeyField` 不一致（strict v1） | warn but allow（manual path） |
| AskUserQuestion 不可用 | exit 1 |
| Write 失敗 (perm/disk) | exit 1，bundle 不變 |

## Atomicity 保證

- 6 步全部完成且 user 確認 → 才做 single Write call
- Single Write 之前 bundle 完全未動
- POSIX atomic-rename 不在 v1 保證內；SIGKILL during Write = known unmitigated risk
- 與 Genesis 其他 single-Write 工具同 risk profile

## streamPrefix resolution

Skill 不問 user prefix；deterministic：

1. `<bundle>.adapter.yaml` 若有 `streamPrefix` → 用它
2. bundle.context 若為 object 且含 streamPrefix → 用它
3. Fallback：strip `"Context"` suffix, alias map (`Opportunity → OC`)，else upper-snake + `_`

範例：`OpportunityContext` → `OC_`、`IAMContext` → `IAM_`、`BillingContext` → `BILLING_`

## 命名慣例 (verify before write)

- `name`: `^Get[A-Z][A-Za-z0-9]+$`
- `aggregateRef`: 一個 bundle.aggregates[].aggregate **或** 字面值 `<context-level>`
- `key.field`: `^[a-z][A-Za-z0-9]*$`
- `key.type`: `String` | `UUID` | `Int` | `Int64`
- `events[].sourceAggregate`: 必填，必須在 bundle.aggregates[]
- `storedFields[].name`: `^[a-z][A-Za-z0-9]*$`，不可等於 key.field

## 與其他 skills 的關係

```
[此 skill] /readmodel
    ↓ 寫 bundle.readModels[] 新 entry
bundle JSON 更新
    ↓ user 手動跑 (Phase 1.g 完成後)
genesis new <bundle>
    ↓ Genesis ReadModelRenderer 產 4 個 human-written files
    ↓ Presenter.when() body 是空 TODO，user 手填 mutation
    ↓
[未來 sibling skill] /presenter — design ApplicationService 轉換
[未來 v2 skill] /readmodel-mutation — 自動填 when() body
```

## 重要約束（不可違反）

- 只寫 bundle-path，**不寫**其他任何 file
- AskUserQuestion 必須用 (header / multiSelect: true / single-select 對應 step)
- v1 要求所有 selected events 共用同一 `fromEventPayload`（match OC canonical JS pattern）
- 違反 strict shared-key → manual entry path，warn user 後仍寫入（不 paternalistic）
