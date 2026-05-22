# /presenter-fill skill — facts + design discussion (2026-05-23)

## 任務定位

`/presenter-fill` 是 `/api` 的 read-side sibling：填 Phase 1.k codegen 留下的 read-side AS `execute()` body 的 `fatalError("TODO(/presenter-fill skill)")`。

## Facts gathered

### F1. scope 比 /api 窄 — 只 1 個 fill category

Phase 1.k 的 `ApiHandlerReadMethod.swift.template` **已完整 codegen**（無 TODO）：construct asInput → service.execute → map output → catch。
唯一 TODO 在 `{Name}ApplicationService.swift` 的 `execute()` body。所以 /presenter-fill 只填這一處。

### F2. canonical OC body pattern（read-side AS execute）

OC ground truth（`GetContractNotes` array / `GetFontSize` scalar）：

```swift
package func execute(input: Input) async throws -> Output {
    let presenter = {Name}Presenter(coordinator: .init(client: kdbClient, eventMapper: {Name}EventMapper()))
    let readModel = try await presenter.execute(input: .init(<keyField>: input.<keyField>))?.readModel
    // ... map to Output
}
```

- `{Name}Presenter` + `{Name}EventMapper()`（plugin-generated）+ `KurrentStorageCoordinator`
- `presenter.execute(input:)?.readModel` → **optional**

### F3. 兩種 nil-readModel 處理（OC 並存）

- **strict**（GetContractNotes）：`guard let readModel = ... else { throw ContextError<{A}Error>(error: .notFound, ...) }` → 404/422
- **lenient**（GetFontSize）：`let readModel = try await ...?.readModel; return .init(field: readModel?.field ?? default)` → fallback，不 throw

### F4. Genesis read-side error infra

`ApiHandler.mapToApiError` 只認 `ContextError<{A}Error>` → ApiError。read method catch → `mapToApiError` → 422，否則 `.serviceUnavailable` 503。
（注意：read method **無** write-side 的 `DDDError.aggregateNotFound → 404` catch，所以 thrown notFound 會走 422 而非 404 — 語意不完美但 compile-pass。）

### F5. 🔴 BLOCKER — 唯一 e2e fixture 是 cross-aggregate，且架構上無法填

`iam-presenter-bundle.json`：presenter `GetUserAccessSummary` 的 `aggregateRef = "UserAccessProfile"`（per-aggregate），
但其 readModel 的 `aggregateRef = "<context-level>"`（cross-aggregate）。結果：

| 產物 | 位置 |
|---|---|
| read-side AS（presenter per-aggregate） | `Sources/UserAccessProfileAggregate/Adapter/GetUserAccessSummary/` |
| projector（Presenter + ReadModel，context-level，Phase 1.g.2） | `Sources/IAMContext/Projector/GetUserAccessSummary/` |

衍生問題：

1. **circular dependency（致命）**：`UserAccessProfileAggregate` target deps = {DDDKit, IAMContextShared, OpenAPIRuntime}，**不**依賴 IAMContext；而 `IAMContext` target 依賴各 aggregate。若 read-side AS 要 `import IAMContext` 用 `GetUserAccessSummaryPresenter` → `IAMContext → UserAccessProfileAggregate → IAMContext` 循環，SwiftPM 拒絕。
2. **AS scaffold TODO 註解路徑錯**：指向 `Sources/UserAccessProfileAggregate/Usecase/Projector/...`，實際在 `Sources/IAMContext/Projector/...`（Phase 1.k 註解 hardcode per-aggregate path 的 bug）。
3. **ReadModel type 名 = `UserAccessSummaryReadModel`**（strip "Get" prefix），非 `GetUserAccessSummaryReadModel`。

→ Phase 1.k 沒處理「per-aggregate presenter 引用 context-level readModel」這個組合。Phase 1.k e2e「build pass」只因 fatalError scaffold 不在可編譯碼裡 reference projector。

### F6. 乾淨 case — per-aggregate readModel + per-aggregate presenter

若 readModel 與 presenter 都 per-aggregate（同一 aggregate），projector（Phase 1.g 產 `{Noun}ReadModel.swift` + `Get{Noun}Presenter.swift`）與 read-side AS **同 module** → 不需 import、無循環依賴 → 可乾淨填。

## 待決策

### D1（gating）：v1 scope — per-aggregate only？還是先修 Phase 1.k.2？

- **A. v1 = per-aggregate only**：readModel + presenter 同 aggregate module，乾淨填。cross-aggregate（context-level readModel）presenter defer，需 Phase 1.k.2 先把 read-side AS 搬到 context target 才可填。
- **B. 先做 Phase 1.k.2**：修 cross-agg presenter 的 AS placement（搬到 `Sources/{Context}/Adapter/`），再讓 /presenter-fill 同時 cover per-agg + context-level。scope 大，/presenter-fill 被 renderer fix 阻塞。
- C. v1 兩者皆 cover via import — **不可行**（circular dep 確認）。

### D2：nil-readModel 處理規則

- Output **optional**（`X?`）→ `return readModel?.<elementSource>`，不 throw（lenient）。
- Output **non-optional** → `guard let readModel else { throw ContextError<{A}Error>(error: .<?>, ...) }` → 需要一個 error case。read-side ApiError 有哪些可用 case？（Phase 1.i 5 個 infra：aggregateNotFound / invalidPayload / invalidDateFormat / undefinedDomainError / serviceUnavailable）→ 用 `.aggregateNotFound`？還是 v1 只支援 optional output + 有 default 的 scalar，non-optional throw defer v2？

### D3：output value mapping per kind

- scalar / single：`readModel.<elementSource>`（直接 field access，型別 = elementType）
- array：`readModel.<elementSource>`（直接，假設 readModel field 已是 `[elementType]`）。OC 的 `.map { Dto(...) }` per-element transform → defer v2？

---

## 決策（user 2026-05-23）

- **D1 = A：v1 per-aggregate only**。cross-aggregate（context-level readModel）presenter → exit with hint「需 Phase 1.k.2 先修 AS placement」。
- ~~**D2 = throw aggregateNotFound**~~ **修正（2026-05-23）**：`aggregateNotFound` 只在 ApiError(infra)，domain `{A}Error` 無此 case（e.g. UserAccessProfileError = {userIdNotExist, permissionNotMatch, employeeNotActive}）→ `ContextError<{A}Error>(error: .aggregateNotFound)` 不 compile。且 read method 無 404 path（只 422 via ContextError<{A}Error> 或 503）。**D2 改 = ProjectionReadInconsistency → 503**：non-optional output nil → `throw ProjectionReadInconsistency(cause: "{Name}", message: "read model not found for \(input.{keyField})")`（Phase 1.f infra，保證存在+compile）→ mapToApiError 回 nil → 503。optional output → `return readModel?.<elementSource>` 不 throw。404/422 精確語意需 designated domain notFound case，defer v2。
- **D3 = 直接 field access**。scalar/single/array 都 `readModel.<elementSource>`；per-element `.map` transform defer v2。

## 確認的 symbol（per-aggregate clean case，from /tmp/rm-e2e）

readModelRef = `R`（presenter.readModelRef，e.g. `GetUserAccessProfileRoles`）：

| symbol | 規則 | 實例 |
|---|---|---|
| Presenter (projector) type | `{R}Presenter` | `GetUserAccessProfileRolesPresenter` |
| ReadModel type | `{stripGet(R)}ReadModel` | `UserAccessProfileRolesReadModel` |
| Presenter Input init | `.init({keyField}: input.{keyField})` | `.init(userId: input.userId)` |
| eventMapper | `{R}EventMapper()`（plugin-gen，pickup real build 驗證） | `GetUserAccessProfileRolesEventMapper()` |
| coordinator | `.init(client: kdbClient, eventMapper: {R}EventMapper())` | |
| readModel 取得 | `try await presenter.execute(input:)?.readModel` | optional |

projector 與 per-aggregate presenter 的 read-side AS **同 module**（`{A}Aggregate`）→ 無 import、無循環依賴。

## v1 execute() body 目標形狀

```swift
package func execute(input: Input) async throws -> Output {
    let presenter = {R}Presenter(coordinator: .init(client: kdbClient, eventMapper: {R}EventMapper()))
    // non-optional output:
    guard let readModel = try await presenter.execute(input: .init({keyField}: input.{keyField}))?.readModel else {
        throw ContextError<{A}Error>(error: .aggregateNotFound, in: .struct({Name}ApplicationService.self, function: #function), message: "...")
    }
    return readModel.{elementSource}
    // optional output 版:
    //   let readModel = try await presenter.execute(input: .init({keyField}: input.{keyField}))?.readModel
    //   return readModel?.{elementSource}
}
```

## Phase 1.k 連帶 bug（記錄，本 task 順帶或 Phase 1.k.2 修）

1. read-side AS scaffold TODO 註解 hardcode `Sources/{A}Aggregate/Usecase/Projector/...`，context-level readModel 時路徑錯。
2. ReadModel type 名是 `{stripGet}ReadModel` 非 `{Name}ReadModel`（TODO 註解若提 type 名要對齊）。

## 下一步

write-spec（per-aggregate only，1 fill category，throw aggregateNotFound，直接 field access）→ audit-spec（Codex）→ pickup（含 per-agg readModel+presenter 新 fixture + real e2e build 驗 eventMapper symbol）。
