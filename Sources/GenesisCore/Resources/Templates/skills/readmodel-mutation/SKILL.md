---
name: readmodel-mutation
description: Genesis fill-in skill for projector when() bodies. Sibling of /api (write-side) and /presenter-fill (read-side AS). Inside a Genesis-bootstrapped project, /readmodel-mutation <presenterName> fills the `_ = readModel; _ = event;` stubs that Phase 1.g leaves inside `<presenterName>Presenter.swift` — choosing one of 5 mutation patterns (set scalar / set anchor / append struct / removeAll / updateAt) per event by matching event name + payload fields against readModel storedField types. Only fills when() bodies; never touches ReadModel.swift, framework wiring, or anything outside the projector file.
argument-hint: [presenterName]
disable-model-invocation: true
allowed-tools: Read, Edit, Glob, Grep
---

# /readmodel-mutation — Fill projector when() body

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

對 `<presenterName>Presenter.swift` 內每個 `when(readModel: inout ReadModelType, event: <E>) throws` 方法，把 Phase 1.g 留下的 `_ = readModel; _ = event;` stub 替換為實際 mutation body。
依 5 patterns（set scalar / set anchor / append struct / removeAll predicate / updateAt by id）+ assignList Set 對應 event payload 與 readModel storedFields 推測。

### 絕對約束（不可違反）

- **只動 when() body 內 stub**；不動 type signature / typealias / buildReadModel / coordinator / categoryRule / imports。
- **不動 ReadModel** swift（屬 /readmodel + Phase 1.g 範疇）。
- **不寫 openapi.yaml** / event.yaml / Package.swift / bundle JSON / 任何 *.yaml。
- **不動 read-side AS body**（屬 /presenter-fill 範疇）。
- 一次一 presenter；scaffold-once + idempotent per-method。

## 輸入解析

`$ARGUMENTS` = presenter / projector 名（e.g. `GetUserAccessProfileRoles`、`GetContractNotes`）。空 → exit 1。設 `presenterName = $ARGUMENTS`。

## Phase 0 — arg 檢查

空 arg → exit 1：`usage: /readmodel-mutation <presenterName>`。

## Phase 1 — Locate Presenter + ReadModel

Glob 兩種 module 路徑合併（Phase 1.k.2 後 cross-agg projector 在 context module）：

- `Sources/*Aggregate/Usecase/Projector/<presenterName>/<presenterName>Presenter.swift`（per-agg）
- `Sources/*/Projector/<presenterName>/<presenterName>Presenter.swift`，排除 `*Aggregate`（context-level）

判定：

- 0 match → exit 1：`prerequisite missing: <presenterName>Presenter.swift not found; run /readmodel + genesis new`
- ≥2 match → exit 4：`ambiguous presenter <presenterName> in [...]; manual disambiguation needed`
- 1 match → 推導 `<readModelTypeName>` = `<stripGet(presenterName)>ReadModel`；verify `<readModelTypeName>.swift` 在 projector 同 dir，缺 → exit 1。

## Phase 2 — Parse projector

Read `<presenterName>Presenter.swift`，抽出所有 `package func when(readModel: inout ReadModelType, event: <E>) throws` 方法及其 body block。記每個 method 的 `<EventTypeName>` (e.g. `UserAccessProfileCreated`, `RolesAssigned`)。

## Phase 3 — Parse ReadModel + event payloads

- Read `<readModelTypeName>.swift`：取所有 stored properties（`package var <field>: <type>`）。記名稱 + Swift 型別（含區分 scalar / collection: `[X]` / `Set<X>` / nested struct）。
- 對每個 `<EventTypeName>`，從 `event.yaml`（per-agg：`Sources/<A>Aggregate/event.yaml`；context-level：`Sources/<contextName>/event.yaml`）讀其 payload fields（name + type）。plugin 已 emit 對應 Swift type；本 skill 只看 yaml field declaration。

## Phase 4 — Idempotent per-method + pattern detection + emit body

對每個 method 的 body block（`{` 到 `}` 之間）做 **tolerant** 判定（忽略 whitespace、comment、placeholder 順序）：

| 狀態 | 判定 | 動作 |
|---|---|---|
| 已填 | 含 `readModel.` assignment / `.append(` / `.removeAll(` / `[i].`，**無** `_ = readModel` `_ = event` placeholder | skip |
| 未填 | 含 `_ = readModel` + `_ = event`（line-based grep 容差 trailing comment） | 套 pattern emit body |
| 半填 | 兩者皆非（placeholder 消失但無 mutation） | 整次 exit 4 abort：`partial fill detected in when(...event: <E>)` |

**Pattern priority**（event 名同時觸發多 pattern 時依序判定）：

1. 名含 `Removed` / `Deleted` 且 event 有 `*Id` 對應某 collection elem id → **removeAll**
2. 名含 `Edited` / `Updated` / `Renamed` 且 event 有 `*Id` locator + 其他 fields → **updateAt**
3. 名含 `Added` 且 payload fields ⊇ collection elem fields 全集（同名同型）→ **append struct**
4. 名含 `Created`（anchor）→ **set anchor 多 field**（即使有 collection storedField，初始空，**不**在 anchor event append）
5. 名含 `Set` / `Edited` 但 payload 全 scalar 直對 readModel scalar storedField → **set scalar**
6. event 有單一 `[X]` field 對應 readModel `Set<X>` storedField → **assignList**

### 5 patterns emit templates

**set scalar** — 對每個同名 event field f 對應 readModel.f 同型：
```swift
        readModel.<f> = event.<f>
```

**set anchor 多 field** — 多 scalar 對應，逐行 emit：
```swift
        readModel.<f1> = event.<f1>
        readModel.<f2> = event.<f2>
```

**append struct** — readModel.<col>: `[X]`，event payload fields ⊇ X fields 同名同型：
```swift
        readModel.<col>.append(.init(
            <f1>: event.<f1>,
            <f2>: event.<f2>
        ))
```

**removeAll** — event 有 `<idField>` 對應 collection elem 的 id property：
```swift
        readModel.<col>.removeAll { $0.<idField> == event.<idField> }
```

**updateAt by id** — event 有 id locator + 其他 fields 要更新：
```swift
        guard let i = readModel.<col>.firstIndex(where: { $0.<idField> == event.<idField> }) else { return }
        readModel.<col>[i].<f> = event.<f>
```

**assignList Set<X>** — event 有 `<arr>: [X]` 對應 readModel.<setField>: Set<X>：
```swift
        readModel.<setField> = Set(event.<arr>)
```

### Pattern detection 失敗 → exit 3

無 pattern 對應、或 append struct 涉及 payload-missing-field（collection elem 有 field 不在 event payload 需 default 如 OC `uniqueCode: nil, traits: []`）、或需 reorder via Dictionary、insert-at-position、cross-event 條件、custom type wrap → **exit 3**：
`event <E>: no matching mutation pattern (or payload-missing-field for append); manual hand-fill required`

整次 abort（已填的 method 不 rollback；未填的 exit 3 後留 stub）。

## Phase 5 — Report

印每 method 結果：`filled <EventTypeName> (<pattern>)` / `skipped <EventTypeName> (already filled)` / `failed <EventTypeName> (no pattern match)`，並提醒 `swift build` 驗 plugin-generated event types 對 emitted body 符合。

## Framework constraints（沿用）

- `ReadModelType` 由 projector typealias 推導；event payload struct 由 plugin 從 event.yaml 生成。
- `package` access modifier 須一致；本 skill 不改 method signature。
- 既有 imports（`DDDCore`、`EventSourcing`、`KurrentSupport`、`{Ctx}Shared`）不動。

## 與其他 skills 的關係

- 上游：`/readmodel`（建 readModel + event refs in bundle）+ `/presenter`（建 presenter）+ `genesis new`（Phase 1.g + 1.k.2 codegen projector scaffold）。
- sibling：`/api`（write-side fill）/ `/presenter-fill`（read-side AS body fill）。本 skill 是第三個 in-place fill。
- 不重疊：projector 的 type signature / framework wiring（典 1.g 範疇）；ReadModel.swift 結構（`/readmodel` 範疇）。
