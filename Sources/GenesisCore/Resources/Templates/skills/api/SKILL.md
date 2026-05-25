---
name: api
description: Genesis fill-in skill for the write-side API. Inside a Genesis-bootstrapped project, /api <useCaseName> fills the fatalError TODO bodies left by Phase 1.h+1.i scaffolds — ApplicationService execute(), ApiHandler AS Input construction, and DTO struct toDomain mapper. It only fills bodies; it never generates files, never touches type signatures / imports / framework shape, and leaves ApiComponents untouched.
argument-hint: [useCaseName]
disable-model-invocation: true
allowed-tools: Read, Edit, Glob, Grep, Bash
---

# /api — Fill TODO bodies in Phase 1.h+1.i write-side scaffolds

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

在 Genesis-bootstrapped project 內，對一個 write use case **只填** Phase 1.h+1.i scaffold 留下的
`fatalError("TODO(/api skill): ...")` body。**3 個 fill categories + 1 個 NO-OP**：

1. **category 1** — `Adapter/<UC>/<UC>ApplicationService.swift` 的 `execute(input:)` body
2. **category 2** — `Adapter/ApiHandler.swift` 內 `{ucCamel}(_:)` method 的 AS Input 構造
3. **category 3** — `Adapter/Dto/<X>Dto+Domain.swift` 的 `init(from dto:) throws` mapper body（僅 DTO 涉及時）
4. **category 4** — `Adapter/ApiComponents/ApiComponents+<A>ApiError.swift` = **v1 NO-OP**（見 Phase 5）

### 絕對約束（D18，不可違反）

- **只動 Adapter/ 子樹**，且只替換 fatalError body，不動 type signature / imports / catch ladder / struct 殼
- **不寫 openapi.yaml** / event.yaml / Service.swift / Package.swift / 任何 *.yaml
- **不讀 invariants.md**（reachability 判定不靠它）
- **一次一 UC** per invocation
- 不生成任何新檔；scaffold 由 `genesis new` 產出，本 skill 只 in-place edit

## 輸入解析

`$ARGUMENTS` = 一個 lower-camel useCaseName（e.g. `editEstimatedRevenue`）。空 → exit 1，hint 用法。

設 `ucCamel = $ARGUMENTS`、`ucPascal = UpperCamel(ucCamel)`。

## Phase 0 — Read-UC 偵測

把 `ucCamel` lowercased，若以 `get` / `list` / `find` 開頭 → **exit 2**：
`read UCs not supported in /api v3; only fills write UC scaffolds.`
（read-side 由未來 `/presenter-fill` 處理。）

## Phase 1 — Locate workspace + aggregate

`Glob Sources/*Aggregate/Usecase/Service/{ucPascal}Service.swift`：

- 0 match → **exit 1**：`use case <UC> not found in any aggregate; check name or run genesis new`
- ≥2 match（同名 UC 跨多 aggregate）→ **exit 4**：
  `ambiguous use case <UC> in aggregates [...]; use /api <Aggregate>.<useCase> (v2) or disambiguate`
- 1 match → 從路徑取 `<A>` = aggregate 名（`Sources/<A>Aggregate/...`）

## Phase 2 — Prerequisite check

確認以下檔案都存在，缺任一 → **exit 1**（印缺的具體 path）：

- `Sources/<A>Aggregate/Adapter/<ucPascal>/<ucPascal>ApplicationService.swift`
- `Sources/<A>Aggregate/Adapter/ApiHandler.swift`
- `Sources/<A>Aggregate/openapi.yaml`
- `Sources/<A>Aggregate/<A>Error.swift`
- `Sources/<A>Aggregate/Usecase/Service/{ucPascal}Service.swift`

檔案存在但 marker / block shape 不符（找不到預期的 fatalError 或 method block）→ **exit 4**：
`scaffold integrity check failed; manual repair needed`。

## Phase 3 — Parse inputs

Read 並解析（用語意錨點，勿用行號）：

- **AS Input struct**（在 `<ucPascal>ApplicationService.swift`）→ 取每個 field 的 **name + Swift 型別**（這是 Variant B 判定的 truth source）
- **Service Input**（`{ucPascal}Service.swift` 的 `execute(input:)` Input + `Usecase/Port/In/<ucPascal>/<ucPascal>Input.swift`）→ field list
- **payload schema**（`openapi.yaml` 該 UC 的 requestBody）→ 只用來確認**欄位存在性**
- **`<A>Error` enum cases**（`<A>Error.swift`）
- **ApiHandler method block**（`ApiHandler.swift` 內 `package func {ucCamel}(_`）
- category 3 涉及時：DTO scaffold + 對應 **domain type declaration**（`Glob Sources/<A>Aggregate/**/{DomainTypeName}.swift`）→ 取 stored property target types

`{aggIdName}` 從既有 AS scaffold / handler 既有 `input.path.{aggIdName}` 讀出，**不要**自己猜 field order。

## Phase 4 — Drift check + Variant A/B 偵測

**Drift（→ exit 3）**：令 `payloadProps` = openapi requestBody properties；
`asBodyFields` = AS Input fields **排除** `{aggIdName}`(path param)、`operatorId`(header)、server-generated ID。
若 `asBodyFields` ≠ `payloadProps` →
`drift between AS Input and payload schema; resolve before /api`。
若某 AS field 的 target type 無法由 payload Swift type 支援 →
`AS Input field <f> type <T> not derivable from payload; resolve before /api`。

**Variant 偵測（以 AS Input 欄位 Swift 型別為 truth）**：

- **Variant A** — AS field 型別皆 plain（`String`/`Int`/`Bool`/Optional…）→ payload 1:1 pass-through
- **Variant B** — AS field 型別含 `Decimal` 或 `Date` → 需 inline 解析（見 category 2）

**server-generated ID 偵測**：Service Input 有一個 `String` field 名為 `*Id`（lowercased 比 suffix `id`）
但 AS Input **無**此 field → server-generated case，用 `UUID().uuidString` 生（見 category 1）。

## Phase 5 — Fill categories 1-3（category 4 NO-OP）

每 category 填前先驗 **structural invariant** 判斷狀態（idempotent）：

| category | 已完整填（→ skip） | 半填（→ exit 4） |
|---|---|---|
| 1 | 含 `service.execute(` + 合法 `return .init(` 且無 fatalError | fatalError 消失但缺 `service.execute` 或 `return` |
| 2 | 無 `_ = payload` 殘留 + `let asInput = <UC>ApplicationServiceInput(` 直接構造 | fatalError 消失但 `_ = payload` 仍在或 asInput 仍 closure |
| 3 | 每 domain stored property 都有 `self.<f> =` 且無 fatalError | fatalError 消失但缺 assignment |

半填 → **exit 4**：`partial fill detected in <file>; manual repair needed before /api`。

### category 1 — ApplicationService execute()（v6 — Phase 1.l OC pass-through）

**Phase 1.l 後 `<UC>Input` ≡ AS Input**（含 aggId + 業務欄位 + operatorId）。pass-through 全部 fields：

Edit 替換 `fatalError("TODO(/api skill): execute body ...")` 整段為（依各 struct 實際欄位）：

```swift
        let service = <UC>Service(repository: repository)
        _ = try await service.execute(input: .init(
            <每個 <UC>Input 宣告的 field>: input.<field>
        ))
        return .init(<每個 AS Output 宣告的 field>: input.<field>)
```

> 實例（createUserAccessProfile, Phase 1.l 後）：`<UC>Input` = `{useraccessprofileId, userId, department, jobTitle, operatorId}` → execute body 為
> `service.execute(input: .init(useraccessprofileId: input.useraccessprofileId, userId: input.userId, department: input.department, jobTitle: input.jobTitle, operatorId: input.operatorId))` + `return .init(useraccessprofileId: input.useraccessprofileId)`。

**Stale v4 fill 偵測（audit M5）**：category 1 idempotent invariant 改成 parse 已填 body `.init(...)` 的 argument labels 與**當前** `<UC>Input` 宣告的 fields 比對。若 labels 缺 aggId 或 operatorId → **exit 4 stale v4 fill detected**，hint：「Phase 1.l 後 v4 fill 缺新欄位；manual unfill + 重跑 /api v6」。

**server-generated ID（Variant）**：若 `<UC>Input` 有 `*Id` field 但 AS Input 無 → `let <idField> = UUID().uuidString` 先 emit，填進 `<UC>Input.init`。AS Output 維持原 shape。

### category 2 — ApiHandler AS Input 構造

把 `_ = payload` / `_ = <aggIdName>` / `_ = operatorId` 與 closure-form
`let asInput = { fatalError(...) }()` 整段替換為直接構造：

```swift
        let asInput = <UC>ApplicationServiceInput(
            <aggIdName>: <aggIdName>,
            <plain field>: payload.<field>,
            operatorId: operatorId
        )
```

**Variant B-Date short-form（Phase 1.j v5）**：若 AS file grep 得 `extension <UC>ApplicationServiceInput { init(from payload:` 且純 Date（無 Decimal），category 2 emit 短形 `try <UC>...Input(from: payload, <aggIdName>:, operatorId:)` 用 do-block + `catch is Iso8601ParsingError → .invalidDateFormat`。否則 inline form（v4 path）。

**Variant B（型別轉換以 AS Input 欄位型別為 truth，不看 openapi schema）**：

- AS field 型別 `Decimal` → 在 asInput 前加 guard，`Decimal(string:)` 解析：

```swift
        guard let <f> = Decimal(string: payload.<f>) else {
            return .unprocessableContent(.init(body: .json(.init(error: <DECIMAL_ERROR_CASE>))))
        }
```

  `<DECIMAL_ERROR_CASE>`（audit H4）：grep `openapi.yaml` 的 `<A>ApiError` enum，
  有 domain-specific `.invalid<Field>` 則用之，**否則 fallback `.invalidPayload`**（infra case，保證 compile）。
- AS field 型別 `Date` → `let <f> = try Date.parseIso8601(payload.<f>)`，
  handler catch `Iso8601ParsingError` → `.invalidDateFormat`（infra case 保證存在）。

### category 3 — DTO struct toDomain（僅 DTO 涉及時）

替換 `fatalError("TODO(/api skill): struct DTO toDomain ...")` 為 field-by-field（依 **domain type** 決定轉換）：

- plain / Optional：`self.<f> = dto.<f>`
- `Decimal`：`guard let v = Decimal(string: dto.<f>) else { throw InvalidDecimalStringError(field: "<f>") }` + `self.<f> = v`
- `Date`：`self.<f> = try Date.parseIso8601(dto.<f>)`（throws Iso8601ParsingError）
- nested DTO with throwing init：`self.<f> = try .init(from: dto.<f>)`

domain type declaration 找不到，或遇 array/optional-nested/custom unsupported conversion → **exit 3**：
`cannot resolve domain type for DTO mapper field <f>; manual fill needed`。

### category 4 — ApiComponents = **v1 NO-OP**

**完全不動** `ApiComponents+<A>ApiError.swift`。它是 **aggregate-wide** mapper，被同 aggregate 所有 UC 共用；
per-UC 把 case 改 `return nil` 會害其他 UC 原應回 422 的 domain error 變 503（跨 UC 副作用）。
Phase 1.i emit 的 `case .x: self = .x` 全保留本就 compile-pass 且語意保守。
report 標記 `category 4: skipped (aggregate-wide, defer v2)`。

## Phase 6 — Report

印每 category 結果：`filled` / `skipped (already complete)` / `skipped (not applicable)` /
`skipped (category 4 NO-OP)`，並 warn 任何未對應到的 payload field。
提醒 user 跑 `swift build` 驗證 fill 後仍 compile。

## Framework constraints（沿用，不可破壞）

- 型別來自 Phase 1.f `<Ctx>Shared`：`ApplicationService`、`ContextError<E>`、`Iso8601ParsingError`、`InvalidDecimalStringError`
- `DDDError.aggregateNotFound` 來自 DDDKit（scaffold 已 import）
- `Operations.X.Input/Output` + `Components.Schemas.<A>ApiError` 來自 OpenAPIGenerator plugin（Phase 1.i）

## 與其他 skills 的關係

- 上游：`genesis new`（Phase 1.h+1.i）產 scaffold；本 skill 填 body
- read-side（Get/List/Find）：未來 `/presenter-fill`，不在本 skill scope
