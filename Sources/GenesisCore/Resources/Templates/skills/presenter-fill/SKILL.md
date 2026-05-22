---
name: presenter-fill
description: Genesis fill-in skill for the read-side API (sibling of /api). Inside a Genesis-bootstrapped project, /presenter-fill <presenterName> fills the single fatalError TODO body left by Phase 1.k in a read-side ApplicationService — fetching the read model via the plugin-generated Presenter (projector) + kdbClient and mapping it to Output. It only fills that one execute() body; it never generates files, never touches the already-codegen'd ApiHandler read method, and never touches type signatures / imports / framework.
argument-hint: [presenterName]
disable-model-invocation: true
allowed-tools: Read, Edit, Glob, Grep
---

# /presenter-fill — Fill read-side ApplicationService execute() body

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

在 Genesis-bootstrapped project 內，對一個 read-side presenter 填 Phase 1.k 留下的**唯一一處**
`fatalError("TODO(/presenter-fill skill)")` —— `{Name}ApplicationService.swift` 的 `execute()` body。
透過 plugin-generated 的 `{R}Presenter`（projector）+ `kdbClient` 抓 readModel，依 output kind map 到 Output。

### 絕對約束（不可違反）

- **只動該一個 read-side AS 的 execute() body**，只替換 fatalError；不動 type signature / Input/Output struct / imports / init。
- **不動 ApiHandler read method** —— 它已被 Phase 1.k 完整 codegen，本 skill 完全不碰。
- **不寫 openapi.yaml** / event.yaml / Package.swift / 任何 *.yaml；不動 projector（Presenter/ReadModel）。
- **一次一 presenter** per invocation；不生成任何新檔。

### v1 scope（per-aggregate only）

只支援 readModel 與 presenter 同 aggregate 的 case（projector 與 read-side AS 同 module，無 import、無循環依賴）。
**cross-aggregate**（readModel.aggregateRef = `<context-level>`，projector 在 `Sources/<Context>/Projector/`）→ exit 3，
因為 read-side AS 在 `{A}Aggregate` 要 import context target 會造成 `Context → {A}Aggregate → Context` 循環依賴；需 **Phase 1.k.2** 先把 AS 搬到 context target 才可填。

## 輸入解析

`$ARGUMENTS` = read-side AS / presenter 名（e.g. `GetUserAccessProfileRoles`）。空 → exit 1，hint 用法。
設 `presenterName = $ARGUMENTS`。

## Phase 0 — arg 檢查

空 arg → exit 1：`usage: /presenter-fill <presenterName>`。

## Phase 1 — Locate read-side AS

`Glob Sources/*Aggregate/Adapter/<presenterName>/<presenterName>ApplicationService.swift`：

- 0 match → exit 1：`prerequisite missing: <presenterName>ApplicationService.swift not found; run genesis new`
- ≥2 match（同名 presenter 跨多 aggregate）→ exit 4：`ambiguous presenter <presenterName> in aggregates [...]; use /presenter-fill <Aggregate>.<Presenter> (v2)`
- 1 match → 取 `<A>` = aggregate 名（`Sources/<A>Aggregate/...`）。確認 `Sources/<A>Aggregate/<A>Error.swift` 存在，否則 exit 1。

## Phase 2 — Idempotent structural invariant（**先於 parse**）

先抽 `package func execute(input: Input)` 的 body block，所有判定只在此 block 內（避免 comment / 其他 method 字串誤判）：

- **已完整填**：含 `let presenter =` + `coordinator: .init(client: kdbClient` + `try await presenter.execute(input:` + `readModel` + `return`，且**無** `fatalError`、**無** `TODO(/presenter-fill skill)` → **exit 0 skip**（`nothing to do — execute body already filled`）。
- **未填**：block 含 `fatalError("TODO(/presenter-fill skill)` → 續 Phase 3。
- **半填**：兩者皆非 → exit 4：`partial fill detected in <file>; manual repair needed`。

> idempotent **必須先於 parse**：已填 body 的 TODO 註解已被移除，若先 parse 會誤判半填而 exit 4。

## Phase 3 — Parse 未填 scaffold

從 read-side AS scaffold 取（用語意錨點，勿用行號）：

- **AS Input fields**：>1 field（key + filter 等）→ exit 3（`multi-field presenter input (filter logic) not auto-fillable in v1`）。projector Input 只 wrap 單一 key，多出的 filter 是 domain 邏輯無法自動填。恰 1 field → `keyField` = 該 field 名。
- **Output type**：取 `typealias Output = ` 後字串，trim + 去 trailing comment 得 `raw`。`raw.hasSuffix("?")` → **optional**；`raw.hasPrefix("[") && raw.hasSuffix("]")` → **array**（non-optional）；plain identifier → **non-optional** single/scalar。其他 grammar（`[X]?` / `Array<X>` / 泛型）→ exit 4。
- **TODO 註解** `// TODO(/presenter-fill skill): fetch via <PresenterType> (projector) and map readModel.<elementSource> to Output`：
  - `<PresenterType>` = regex `fetch via (\w+Presenter)`；須 `hasSuffix("Presenter")`。
  - `<elementSource>` = regex `map readModel\.([A-Za-z_][A-Za-z0-9_]*) to Output`；須 single Swift identifier，否則 exit 3。
  - parse 不到 → exit 4（`scaffold integrity check failed; cannot parse projector reference`）。
- 衍生 `<eventMapper>` = `<PresenterType>` 去尾 `Presenter`（hasSuffix 後 dropLast(9)）+ `EventMapper`（**suffix-strip，非全字串 replace**）。

## Phase 4 — Locate projector（cross-aggregate 偵測）

`Glob Sources/<A>Aggregate/**/<PresenterType>.swift`：

- 同 module 找到（≥1）→ 續 Phase 5（per-aggregate clean case）。
- 否則 `Glob Sources/*/Projector/**/<PresenterType>.swift`：
  - exactly 1 match 不在 `<A>Aggregate`（context-level）→ exit 3：`cross-aggregate presenter (<context-level> readModel) not fillable in v1 — needs Phase 1.k.2 to relocate read-side AS to context target`。
  - ≥2 match → exit 4：`ambiguous projector <PresenterType> in [...]`。
- 都沒有 → exit 1：`prerequisite missing: <PresenterType> projector not generated; run /readmodel + genesis new first`。

## Phase 5 — Fill execute() body

ReadModel local var 型別由 `presenter.execute(input:)?.readModel` 推導，不需顯式 naming。
value mapping 一律直接 `readModel.<elementSource>`（D3；per-element `.map` transform defer v2）。

**non-optional output（`X` 或 `[X]`）** —— guard + throw on nil：
```swift
    package func execute(input: Input) async throws -> Output {
        let presenter = <PresenterType>(coordinator: .init(client: kdbClient, eventMapper: <eventMapper>()))
        guard let readModel = try await presenter.execute(input: .init(<keyField>: input.<keyField>))?.readModel else {
            throw ProjectionReadInconsistency(
                cause: "<presenterName>",
                message: "read model not found for \(input.<keyField>)"
            )
        }
        return readModel.<elementSource>
    }
```

**optional output（`X?`）** —— 不 throw：
```swift
    package func execute(input: Input) async throws -> Output {
        let presenter = <PresenterType>(coordinator: .init(client: kdbClient, eventMapper: <eventMapper>()))
        let readModel = try await presenter.execute(input: .init(<keyField>: input.<keyField>))?.readModel
        return readModel?.<elementSource>
    }
```

> **nil 處理（D2）**：non-optional output 在 readModel 為 nil 時 throw `ProjectionReadInconsistency`（Phase 1.f infra，保證 compile）→ `ApiHandler.mapToApiError` 回 nil → 503。read-side ApiHandler 無 404 path；404/422 精確語意需 designated domain notFound case，defer v2。
> **不要** throw `ContextError<{A}Error>(error: .aggregateNotFound)` —— `aggregateNotFound` 只在 ApiError(infra)，**非** domain `{A}Error` case，會 compile fail。

填完印 report：`filled <presenterName>ApplicationService execute() body (<output kind>)`，提醒 user 跑 `swift build`。

## Framework constraints（沿用，不可破壞）

- 型別來自 Phase 1.f `<Ctx>Shared`：`ApplicationService`、`ContextError<E>`、`ProjectionReadInconsistency`。
- `<R>Presenter` / `<R>EventMapper` / `<R>ProjectorProtocol`：plugin-generated（Phase 1.g）。
- `KurrentDBClient` / `KurrentStorageCoordinator`：read-side AS scaffold 已 `import KurrentDB`。
- `presenter.execute(input:)?.readModel` 為 optional（CQRSProjector 行為）。

## 與其他 skills 的關係

- 上游：`/readmodel`（建 readModel）+ `/presenter`（建 presenter）+ `genesis new`（Phase 1.g+1.k codegen scaffold）。
- sibling：`/api`（write-side fill）。本 skill 是其 read-side 對應。
- 不重疊：projector 的 `when()` body 由 `/readmodel-mutation` v2 填，不在本 skill scope。
