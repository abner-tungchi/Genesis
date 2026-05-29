# Phase 1.p — Write-side per-UC DTO support (F7 from dogfood)

## 來源

討論：`docs/discussions/2026-05-27-phase-1p-write-dto.md`（含 2026-05-29 補丁 D19/D20/D21）+ cross-tool `docs/discussions/2026-05-28-cosmogony-bundle-schema-mismatch.md`（v20 sign-off）

依賴 Phase（全 done）：phase-1l（Usecase Input OC alignment）、phase-1l1-codegen-injection-and-readmodel-adapter、phase-1n（type ownership routing）、phase-1o-hygiene（Service struct / Usecase where-clause / event.yaml map shape）。

依賴 Cosmogony（已 ship）：v19（scope/usage/aggregateRef/readModelRef/perReadModel emit）+ v20（aggregateRef derive from outbound Aggregate link）。

合 dogfood findings：F7（Layer 2 re-verify 2026-05-27 — OC `EditBusinessTaxFilingMethod` 含 per-UC DTO 但 Genesis ApplicationService Input 仍走 primitive 型別，未經 DTO 過渡層）。

---

## 目標

關掉 dogfood F7：Genesis codegen 對「Input 含非 primitive 自定型別」的 write UC 應該產出 (1) per-UC DTO 檔案（至少含 `init(from dto:)` 的 domain mapper extension；視 `definitionLocation` 條件加上 DTO 定義段）、(2) ApplicationService Input 把該 field 的型別從 domain type 換成 DTO type、(3) execute body 內加上單行 machine-greppable 的 structured TODO marker 讓未來 Phase 1.p.1 的 `/api` skill 知道在哪插 `init(from:)`。這條 codegen 路徑通了，未來任何 write UC（不限 IAM）只要 Input 帶自定型別就會自動走 OC 對齊的 DTO 過渡層，不再需要 user 手刻。

---

## 介面合約（Interface Contract）

### 新增：`DtoRouter`（單一 type 的 DTO 放置路由）

新檔 `Sources/GenesisCore/DtoRouter.swift`，pure function，無 file I/O：

```swift
public struct DtoRoute: Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable {
        case perUseCase
        case aggregate
        case perReadModel      // D19: Cosmogony v19 4th scope value (cross-tool 2026-05-29)
        case contextShared
    }
    public enum Usage: String, Sendable, Equatable {
        case request
        case response
        case both
    }

    public let scope: Scope
    public let definitionLocation: Scope  // separate stored field; NO computed collapse (D16)
    public let usage: Usage
    public let useCaseRef: String?        // populated when scope == .perUseCase
    public let aggregateRef: String?      // populated when scope == .aggregate / .contextShared with owning agg
    public let readModelRef: String?      // D19: populated when scope == .perReadModel
}

public enum DtoRouter {
    public static func route(
        bundle: FullBundle,
        adapter: Adapter,
        ownership: [String: TypeOwnership]
    ) -> (routes: [String: DtoRoute], warnings: [String])
}
```

合約細則：

- **執行順序**：必須在 `TypeOwnershipResolver.resolve(...)` 之後呼叫；不擴充 `TypeOwnership` enum（D7：`TypeOwnership` 為 binary `.contextShared` / `.ownedBy`，`ApiRenderer` 既有 `guard case .ownedBy(let aggName) = ownership[dto.name]` 對未列舉 case 是 silent skip → 一旦擴增 enum 會 silent drop 新 scope，因此另開 `DtoRouter`）。
- **route key**：`dto.name`（與 `ownership` dict 同 key 空間）。
- **與 `ownership` 的互動**：當 router 對某 type 算出 `scope=.perUseCase`，但 `ownership[type] == .contextShared` 時，**def 留在 contextShared 層**（即 `definitionLocation=.contextShared`），per-UC 檔只放 mapper extension（D3 mapper-only 路徑）。Router 不覆寫 `TypeOwnershipResolver` 的 def 放置決策。
- **scope 推導（D11 inference path）**：bundle 缺 `scope` 欄位（legacy） →
  - `dto.isContextShared == true` → `.contextShared`
  - `dto.aggregateRef != nil` 且解析到 aggregate → `.aggregate`
  - 否則 → `.perUseCase`（需要 router 進一步從 useCases.input 推導 `useCaseRef`；若推不出 → emit warning 並 fallback `.aggregate`/`.contextShared` per `ownership`）
- **usage 推導**：bundle 缺 `usage` 欄位 → 預設 `.both`（D1：default usage=both when missing）。
- **forbidden combinations（Phase 1.p D10 scope 邊界 + D19 perReadModel 補丁）**：以下組合 router 不處理，由 `BundleParser` 在 validation 階段 raise `GenesisError.bundleInvalid`：
  - `perUseCase × response` — 無 OC counterexample，loud-fail
  - `perReadModel × request` — read-side 不應有 request DTO（query 沒 body），loud-fail（D19）
  - `perReadModel × both` — 同上理由，loud-fail（D19）
  - `aggregate × request/response/both` — Phase 1.q 才支援
  - `contextShared × request` — Phase 1.q 才支援

- **supported emission cells（D3 + D19）**：

| scope × usage | emission |
|---|---|
| `perUseCase × request` | `<A>Aggregate/Adapter/<UC>/<X>.swift`（DTO def + domain mapper）— D3 mapper-only default + def 條件 |
| `perReadModel × response` | `<A>Aggregate/Usecase/Projector/<RM>/<X>.swift`（DTO def + domain→DTO mapper）— D19 補 |
| `contextShared × response` | `<Ctx>Shared/<X>.swift`（DTO def，無 mapper — 由各 aggregate 自行 emit `+Domain.swift`） |
| `contextShared × both` | 同上，待 Phase 1.q lift |

- **warnings shape**（D14 volume management）：呼叫端 default 將 warnings 摘要成單行 stderr line（"DtoRouter: inferred N DTO routes from legacy bundle"）；`--verbose` 時逐條印出。鏡像 `TypeOwnershipResolver.warnings` 既有 tuple pattern。

### 新增：`BundleParser` 對 `scope` / `usage` / `useCaseRef` / `readModelRef` 的解析 + reserved-name filter + `manifestVersion` strict gate

`BundleParser.RawDto` 加 4 個 optional field（`scope: String?`, `usage: String?`, `useCaseRef: String?`, `readModelRef: String?` — Phase 1.l.1.1 已加完），轉成 `DtoSpec` 同名 optional fields。**Envelope 用既存的 `manifestVersion` 作為 wire-format version gate（D20 supersede D11）**。

合約細則：

- **`manifestVersion` strict gate（D20，supersedes D11）**：
  - `envelope.manifestVersion >= 2` → 進 strict path，scope/usage/aggregateRef/readModelRef 缺一律 raise `bundleInvalid("dtos[i] missing required key 'scope' under manifestVersion: \(v) strict path")`。Cosmogony v22 ship 時 bump `manifestVersion: 1 → 2`，此時 strict path 啟用。
  - `envelope.manifestVersion == 1`（current Cosmogony v19/v20）→ 進 inference path，由 `DtoRouter` 推導 + emit warnings。
  - `envelope.manifestVersion == nil` → 視為 1（hand-crafted bundle backward compat）。

- **Reserved-name filter（D5）**：任何 `dto.name` match 以下 pattern 即 raise `GenesisError.bundleInvalid(reason: "dtos[i].name '<X>' collides with reserved infra pattern '<pat>'; rename DTO")`：
  - 後綴 `ApiError` （e.g. `UserAccessProfileApiError`）
  - 前綴 `ApiComponents+`
  - 後綴 `+Schema`
  - 後綴 `+Domain`
  - Filter 位置：`BundleParser.decodeDtoSpec` 新增 greenfield check（D5 R3 clarification — 不是 `SourceWriter` 路徑碰撞偵測，是 BundleParser name-pattern check）。

- **`useCaseRef` / `readModelRef` 解析**：若 strict path 含 `useCaseRef`，BundleParser 額外驗證 `useCaseRef ∈ bundle.useCases[].useCase`，否則 raise `bundleInvalid("dtos[i].useCaseRef '<X>' not found in bundle.useCases")`。同理 `readModelRef ∈ bundle.readModels[].name`（D19）— Cosmogony 端 user 可能 typo 的 readModelRef，已由 Phase 1.l.1.1 加的 `canonicalizeDtoReadModelRefs` 用 `dtoSpecRef` cross-ref 修正（保留此 fallback）。

### 修改：`DtoSpec`（`FullBundle.swift`）— 新增 routing-related optional fields（Phase 1.l.1.1 已實裝）

```swift
public struct DtoSpec: Sendable, Equatable {
    // ... existing fields (dtoSpecId, name, description, fields, dtoKind, cases,
    //     domainTypeName, isContextShared, aggregateRef) ...
    public let scope: String?         // "perUseCase" | "aggregate" | "perReadModel" | "contextShared" | nil (legacy)
    public let usage: String?         // "request" | "response" | "both" | nil (default: both)
    public let useCaseRef: String?    // present only when scope=="perUseCase"
    public let readModelRef: String?  // D19: present only when scope=="perReadModel"
}
```

新欄位皆 optional，舊 fixture / fixture-less init call 不受影響。`init` 加同名 default-nil 參數，保持 source-compat。**Phase 1.l.1.1 已 land 4 個欄位**到 `DtoSpec`，Phase 1.p impl 只需要消費它們，不必再新增。

### 修改：`ApiRenderer.render(...)` — per-UC mapper + AS Input DTO 改型 + structured TODO

合約改動：

1. **參數加 `routes: [String: DtoRoute]`**（從 `NewCommand.swift` orchestration 傳入，於 `TypeOwnershipResolver.resolve` 之後 / `SharedTargetRenderer.render` 之前計算 `DtoRouter.route(...)`）。
2. **Per-UC DTO 檔案輸出**：對 routes 中 `route.scope == .perUseCase && route.usage ∈ {.request, .both} && route.useCaseRef == uc.useCase` 的 type，emit：
   - 路徑：`Sources/<A>Aggregate/Adapter/<UC>/<DtoName>Dto.swift`（OC convention — same-file mappers, no `+Domain` suffix per D6）
   - 內容：
     - **conditional definition section**：only if `route.definitionLocation == .perUseCase`（D3 mapper-only by default）
     - **always-present**：`extension <DomainTypeName> { package init(from dto: <DtoName>Dto) throws { ... } }`（identity-mapper case 也走這條 — see identity-mapper collision fix below）
   - role：`"dtoPerUseCaseMapper"`
3. **AS Input 型別替換**：在 `renderApplicationService` 內，對每個 `middleFields` 的 field，若 `routes[resolvedDomainTypeName]?.usage ∈ {.request, .both}` → field type 從 domain type swap 成 `<DtoName>Dto`（D13）。Lookup key 為 resolved domain type name，不靠啟發式。
4. **execute body structured TODO emission**：對每個 DTO-typed field，在 AS execute body 內加單行 marker：

```swift
// genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=<f>, dto=<X>Dto)
```

格式必須完全等於上述字串（D4 R3 lock，含逗號後空格）— Phase 1.p.1 `/api` skill 會 grep `genesis-todo(phase=1.p.1, kind=dto-init-from-input` 找 insertion site。

5. **Identity-mapper collision fix（D8）**：`ApiRenderer.render` 既有 skip：

```swift
if dto.name == domainTypeName(for: dto) { continue }
```

改為 `(useCaseRef?, dto.name)` tuple-keyed 邏輯 — 對 `routes[dto.name]?.scope == .perUseCase` 的 type，per-UC mapper 路徑**不**走此 skip（per-UC 場景不會與 aggregate-shared `+Domain.swift` 路徑共存）。aggregate-shared / contextShared 既有 identity-mapper skip 行為保持不變。

### Framework 備註

- 不涉及 Swift ArgumentParser / SwiftNIO 等 framework 改動。
- DDD-kit `DomainEventGeneratorPlugin` 不讀 per-UC DTO 檔，無 plugin compat 問題。
- 既有 `Adapter.typeMapping` 仍走 `SwiftTypeResolver.resolve(rawType:knownCustomTypes:adapter:)`；DTO 過渡層只影響 ApiRenderer 內 AS Input field 的 codegen 文字，不改 SwiftTypeResolver 行為。
- **OpenAPIGenerator 限制**：Phase 1.p emit 的 per-UC DTO 檔案不涉及 wire schema mapper（`Components.Schemas.<X> ↔ <X>Dto`）— 該層由 Phase 1.p.1+ `/api` skill 在 openapi.yaml schema 補齊後處理（D4 R2）。

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---|---|
| `Sources/GenesisCore/DtoRouter.swift` | **新檔**：`DtoRoute` struct + `DtoRouter.route(...)` pure function，回 `(routes:, warnings:)` tuple |
| `Sources/GenesisCore/FullBundle.swift` | `DtoSpec` 加 `scope`/`usage`/`useCaseRef` 3 個 optional fields（init default-nil）|
| `Sources/GenesisCore/BundleParser.swift` | `RawDto` 加同 3 個 optional + `Envelope` 加 `manifestVersion`；`decodeDtoSpec` 加 reserved-name filter + strict/inference 分流 + forbidden-combination raise |
| `Sources/GenesisCore/ApiRenderer.swift` | `render(...)` 加 `routes:` 參數；per-UC mapper emission；AS Input field 型別替換；execute body structured TODO；identity-mapper skip 改 tuple-keyed |
| `Sources/genesis/Commands/NewCommand.swift` | 在 `TypeOwnershipResolver.resolve` 後、`SharedTargetRenderer.render` 前計算 `DtoRouter.route(...)`；warning 摘要+verbose 輸出；把 `routes` 傳給 `ApiRenderer.render` |
| `Sources/GenesisCore/Resources/Templates/Api/ApplicationService.swift.template` | 加 `INIT_FROM_INPUT_TODOS` placeholder 用於 structured TODO 行注入 execute body |
| `Sources/GenesisCore/Resources/Templates/Api/DtoPerUseCaseMapper.swift.template` | **新 template**：per-UC mapper-only / mapper+def 兩段（def section 由 ApiRenderer 條件式組裝） |
| `tests/GenesisCoreTests/DtoRouterTests.swift` | **新 test 檔**：route 推導 + warning 訊息 + forbidden-combination raise |
| `tests/GenesisCoreTests/ApiRendererTests.swift` | 加 per-UC mapper emission tests（mapper-only + mapper+def 兩條 path）+ AS Input field 型別替換 test + structured TODO 出現 test |
| `tests/GenesisCoreTests/BundleParserTests.swift` 或 `BundleParserFullTests.swift` | 加 reserved-name filter raise test + `manifestVersion:2` strict path test + legacy inference test |
| `tests/GenesisIntegrationTests/Fixtures/iam-write-dto-bundle.json` | **新 hand-crafted fixture**：在 iam-bundle 基礎上加一個 `createUserAccessProfile`-like UC 把 `status: EmployeeStatus` 放進 input（觸發 perUseCase × request mapper-only path）|
| `tests/GenesisIntegrationTests/NewCommandTests.swift` | 加 E2E assertion：跑新 fixture，confirm `Adapter/<UC>/EmployeeStatusDto.swift` 含 mapper extension、無 enum 重宣告、AS Input field 型別 = `EmployeeStatusDto`、execute body 含 structured TODO |

### Affected call sites（非改動，但受影響）

- `Sources/GenesisCore/SharedTargetRenderer.swift` — Phase 1.p **不改動**（per D18 — perUseCase emission 全部在 ApiRenderer；contextShared / aggregate 寫側 mapper 是 Phase 1.q 工作）。
- `Sources/GenesisCore/DtoRenderer.swift` — 僅 emit definitions，不 emit mappers，identity-mapper 修正不影響（per D17）。spec 實作期 grep `DtoRenderer.swift` 驗證確無 `dto.name`-keyed mapper skip 即可。
- `Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md` — Phase 1.p **不改動**；`/api` skill 對 structured TODO 的處理是 Phase 1.p.1 工作。
- `Sources/GenesisCore/TypeOwnershipResolver.swift` — **不擴增 `TypeOwnership` enum**（per D7 約束）。

---

## 實作步驟

### Step 1：`FullBundle.swift` — `DtoSpec` 加 3 個 optional fields

1. 在 `public struct DtoSpec` 既有 `aggregateRef: String?` 之後加：
   ```swift
   public let scope: String?       // Phase 1.p: "perUseCase" | "aggregate" | "contextShared" | nil (legacy → inferred)
   public let usage: String?       // Phase 1.p: "request" | "response" | "both" | nil (default: both)
   public let useCaseRef: String?  // Phase 1.p: present only when scope == "perUseCase"
   ```
2. `init` 簽名末端加同名 default-nil 參數（順序：`scope: String? = nil, usage: String? = nil, useCaseRef: String? = nil`），body 加 `self.scope = scope` 三行。
3. 不改動既存 init call sites（既有 fixture / test default-nil 流入 nil）。

### Step 2：`BundleParser.swift` — `RawDto` validation + `Envelope.manifestVersion` 重用作 strict gate

> **D20 update**：`Envelope.manifestVersion` 早已存在於 BundleParser（既有 wire-format version field）。Phase 1.l.1 + 1.l.1.1 已將 4 個 routing 欄位（scope/usage/useCaseRef/readModelRef）加入 `RawDto` + `DtoSpec`。Phase 1.p impl 只需要消費它們 + 加 strict-path gate 邏輯。

1. `RawDto` 的 scope/usage/useCaseRef/readModelRef 欄位**已存在**（Phase 1.l.1.1 ship）— 不必再加。
2. `Envelope.manifestVersion` 欄位**已存在**（既有）— `parseFull` validate core 已讀取，傳給 decodeDtoSpec 改 signature 加 `manifestVersion: Int` 參數。
3. `decodeDtoSpec` 函數開頭加 **reserved-name filter**（D5）— `name` match 以下任一 pattern → raise `bundleInvalid`：
   - `name.hasSuffix("ApiError")`
   - `name.hasPrefix("ApiComponents+")`
   - `name.hasSuffix("+Schema")`
   - `name.hasSuffix("+Domain")`
   Error message：`"dtos[\(idx)].name '\(name)' collides with reserved infra pattern; rename DTO"`。
4. `decodeDtoSpec` 加 **strict/inference 分流**（D20）：
   - 若 `manifestVersion >= 2` 且 `raw.scope == nil` → raise `bundleInvalid("dtos[\(idx)] missing required key 'scope' under manifestVersion: \(v) strict path")`。
   - 否則接受 nil scope（DtoRouter 端推導）。
5. `decodeDtoSpec` 加 **`useCaseRef` validation**（strict path 才檢）：
   - 若 `raw.scope == "perUseCase"` 且 `raw.useCaseRef != nil`，pass-through；
   - 若 `raw.scope == "perUseCase"` 且 `raw.useCaseRef == nil` → raise `bundleInvalid("dtos[\(idx)] scope=perUseCase requires useCaseRef")`。
   - `useCaseRef` cross-check（必須 ∈ bundle.useCases[].useCase）放在 `parseFull` 底部 envelope-level validation block（既有 `useCases` aggregateSpecId / emittedEvent cross-check 同位置）。
6. `decodeDtoSpec` 加 **forbidden combination raise**（D9 / D10 + D19 補丁）：
   - `scope=="perUseCase" && usage=="response"` → raise `bundleInvalid("dtos[\(idx)] perUseCase × response is unusual; use contextShared or aggregate response scope, or file an OC counterexample to lift this restriction")`。
   - `scope=="perReadModel" && usage=="request"` → raise `bundleInvalid("dtos[\(idx)] perReadModel × request not supported (queries have no request body); use scope=perUseCase for write-side input DTOs")`（D19）。
   - `scope=="perReadModel" && usage=="both"` → raise `bundleInvalid("dtos[\(idx)] perReadModel × both not supported (queries are response-only); use usage=response")`（D19）。
   - `scope=="aggregate"` 且 usage 任何值 → raise `bundleInvalid("dtos[\(idx)] aggregate × * write-DTO not supported in Phase 1.p; deferred to Phase 1.q")`。
   - `scope=="contextShared" && usage=="request"` → raise `bundleInvalid("dtos[\(idx)] contextShared × request write-DTO not supported in Phase 1.p; deferred to Phase 1.q")`。
7. `decodeDtoSpec` 回傳 `DtoSpec` 時填入 `scope: raw.scope, usage: raw.usage, useCaseRef: raw.useCaseRef, readModelRef: raw.readModelRef`（D19：readModelRef 已 Phase 1.l.1.1 加完）。

### Step 3：`DtoRouter.swift` — 新檔，pure function

1. 宣告 `public struct DtoRoute`（含 `Scope` / `Usage` 巢狀 enum，stored fields `scope`, `definitionLocation`, `usage`, `useCaseRef`, `aggregateRef`，conform Sendable, Equatable）。
2. 宣告 `public enum DtoRouter`，static func `route(bundle:adapter:ownership:) -> (routes: [String: DtoRoute], warnings: [String])`。
3. 邏輯：
   - 對 `bundle.dtos` 每個 `dto`：
     a. **scope 推導**：
        - `dto.scope == "perUseCase"` → `.perUseCase`
        - `dto.scope == "aggregate"` → `.aggregate`
        - `dto.scope == "contextShared"` → `.contextShared`
        - 否則（legacy inference）：
          - `dto.isContextShared == true` → `.contextShared`，warn `"\(dto.name): legacy bundle — inferred scope=contextShared (from isContextShared:true)"`
          - `dto.aggregateRef != nil` 且 ref 解析到 aggregate → `.aggregate`，warn `"\(dto.name): legacy bundle — inferred scope=aggregate (from aggregateRef)"`
          - 否則 → 看 `ownership[dto.name]`：`.ownedBy(aggName)` → `.aggregate` + warn；`.contextShared` 或 nil → `.contextShared` + warn。
     b. **usage 推導**：`dto.usage` ∈ {request, response, both} → 對應；nil → `.both`（D1）。
     c. **definitionLocation 推導**（D3 separate field, NO computed collapse per D16）：
        - 預設 = scope。
        - 若 scope=`.perUseCase` 但 `ownership[dto.name]` 已存在（即既有 contextShared 或 aggregate def site） → `definitionLocation = ownership 對應 scope`，warn `"\(dto.name): per-UC mapper requested but def already lives at \(definitionLocation); emitting mapper-only"`。
     d. **useCaseRef / aggregateRef 填入**：scope=`.perUseCase` 時，`useCaseRef = dto.useCaseRef`（strict path）或從 `bundle.useCases` 反查（哪些 UC 的 input 含 `dto.name` resolved 後 raw type）— legacy inference：若反查唯一命中 → 用該 UC；命中 0 或 >1 → 改 scope 為 `.aggregate`（fallback per ownership）+ warn。`aggregateRef` 對 scope=`.aggregate` / `.contextShared` 由 `ownership[dto.name]` 提供。
4. 回傳 `(routes, warnings)`。

### Step 4：`ApiRenderer.swift` — `render(...)` 簽名 + per-UC emission + AS Input swap + structured TODO

1. **render 簽名加參數**：`routes: [String: DtoRoute]`（緊接 `ownership` 之後）。
2. **AS Input field 型別替換**（per UC 迴圈內）：
   - 既有 `resolvedFields` map 每個 `(name, resolvedType)` 後，多一層 lookup：
     - 從 `bundle.dtos.first { $0.name == resolvedType || domainTypeName(for: $0) == resolvedType }` 取對應 dto（match domain type or DTO name）。
     - 若 dto 找到，且 `routes[dto.name]?.usage ∈ {.request, .both}` → resolved type swap 為 `dto.name`（DTO 名）。
   - swap 後 `inputFields` / `initParamsMid` / `initAssignments` 既有組裝邏輯不變。
3. **execute body structured TODO 注入**：
   - 對每個 swap 過的 field，組裝單行：`"        // genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=\(name), dto=\(dtoName))"`
   - 多行用 `\n` 串接後丟給 `ApplicationService.swift.template` 新加的 `INIT_FROM_INPUT_TODOS` placeholder。
   - template 原 `fatalError("TODO(/api skill): ...")` 行**前一行**插入 `INIT_FROM_INPUT_TODOS` block；無 swap 時該 placeholder 為空字串。
4. **Per-UC DTO emission**（write UC 迴圈內，AS emission 之後）：
   - 對每個 swap 過的 (uc, field) 配對，找 dto = bundle.dtos.first { $0.name == swappedDtoName }。
   - 取 `route = routes[dto.name]`。若 route.scope ≠ `.perUseCase` 或 route.useCaseRef ≠ uc.useCase → skip（其他 scope 由其他 renderer 處理）。
   - 組路徑：`"Sources/\(agg.name)Aggregate/Adapter/\(ucPascal)/\(dto.name).swift"`（OC same-file convention，無 `+Domain` suffix per D6）。
   - 若 `existingPaths` 含此路徑 → skip。
   - 渲染：load `Api/DtoPerUseCaseMapper.swift.template`：
     - `INCLUDE_DEFINITION` block：only if `route.definitionLocation == .perUseCase` → 套既有 `Dto.swift.template` 渲染邏輯（enum / struct）；否則空字串。
     - `INIT_FROM_DTO_BODY` block：對 dto.fields 組 `self.\(field.name) = dto.\(field.name)`（struct）或 `case .X: self = .X`（enum，per `dto.cases` / `dto.fields.map(\.name)` fallback per 既有 `renderEnumMapper` pattern）。
   - role = `"dtoPerUseCaseMapper"`。
5. **Identity-mapper skip 改 tuple-keyed**（D8）：
   - 既有 `if dto.name == domainTypeName(for: dto) { continue }` 改成：
     ```swift
     // Tuple-keyed (useCaseRef?, dto.name) skip:
     // - aggregate / contextShared scope (no useCaseRef): preserve legacy identity-mapper skip.
     // - perUseCase scope: do NOT skip; per-UC mapper has its own file path (same-file, no +Domain).
     if routes[dto.name]?.scope != .perUseCase, dto.name == domainTypeName(for: dto) { continue }
     ```
6. **Verification grep**：實作完成後 grep `Sources/GenesisCore/` 確認無剩餘 `if dto.name ==` 單 key 形式 skip — 若 DtoRenderer 內有同 pattern 也需一併修；per D17 R2 inspection 確認 DtoRenderer 不含此 skip，但實作者仍需 grep 確認。

### Step 5：`NewCommand.swift` — orchestration 接入 `DtoRouter`

1. 找到 `TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)` 既有 call（檔內錨點：`let (ownership, ownershipWarnings) = TypeOwnershipResolver.resolve`）。
2. 在該 call **之後**、`SharedTargetRenderer.render` 之前加：
   ```swift
   let (routes, routeWarnings) = DtoRouter.route(bundle: bundle, adapter: adapter, ownership: ownership)
   // D14: default = one-line summary, --verbose = per-route detail
   if !routeWarnings.isEmpty {
       if isVerbose {
           for w in routeWarnings { FileHandle.standardError.write(Data("⚠ DtoRouter: \(w)\n".utf8)) }
       } else {
           FileHandle.standardError.write(Data(
               "⚠ DtoRouter: inferred \(routeWarnings.count) DTO routes from legacy bundle (run with --verbose for per-DTO detail). Migrate by adding manifestVersion:2 + explicit scope/usage.\n".utf8))
       }
   }
   ```
3. 把 `routes:` 傳給既有 `ApiRenderer.render(...)` call。
4. `isVerbose` 來源：既有 `NewCommand` 若無 `--verbose` flag，加 `@Flag(name: .long) var verbose: Bool = false`（Swift ArgumentParser pattern；參考既有 `--no-git` / `--skip-build` flag declarations）。

### Step 6：Templates — `ApplicationService.swift.template` + 新 `DtoPerUseCaseMapper.swift.template`

1. **ApplicationService.swift.template**：
   - 找到既有 execute body 內 `fatalError("TODO(/api skill): ...")` 的位置（既有錨點）。
   - 該行**前一行**插入 `{INIT_FROM_INPUT_TODOS}` placeholder（無 swap 時為空字串 → 不影響既有 emission shape）。
2. **DtoPerUseCaseMapper.swift.template**（新檔）：
   ```
   import DDDKit
   {SharedImport}

   {INCLUDE_DEFINITION}

   extension {DomainTypeName} {
       package init(from dto: {DtoTypeName}) throws {
   {INIT_FROM_DTO_BODY}
       }
   }
   ```
   - `{INCLUDE_DEFINITION}` 條件填入 enum / struct def block（or 空字串）— 由 ApiRenderer 用既有 `renderEnumMapper` / `renderStructMapper` 邏輯產 def 段。
   - `{INIT_FROM_DTO_BODY}` 由 ApiRenderer 用 dto.kind 分支生 enum self-switch 或 struct 逐欄 assignment。

### Step 7：新 fixture — `iam-write-dto-bundle.json`

1. Copy `tests/GenesisIntegrationTests/Fixtures/iam-bundle.json` → `iam-write-dto-bundle.json`。
2. 找到既有 `UserAccessProfile` aggregate 的 `createUserAccessProfile` UC，把 input 加一個 `{ "name": "status", "type": "EmployeeStatus" }`。
3. 既有 `EmployeeStatus` DTO 條目（dtos[]）加 `"scope": "contextShared"`、`"usage": "both"`、`"manifestVersion": 2`（envelope 層）— 此 fixture 走 strict path 並把 def 留在 contextShared、mapper-only 落在 perUseCase site。
4. 額外加一個 fixture 變體（或在同 fixture 加第二個 UC）走 mapper+def 路徑：新增一個 perUseCase-only DTO（不在其他 UC / aggregate state 用到，scope=perUseCase + useCaseRef=指向某個新 UC），測 def-included 分支。

### Step 8：Tests — DtoRouter + ApiRenderer + BundleParser + E2E

1. **`DtoRouterTests.swift`** 新檔：
   - `testStrictPathReturnsRouteAsDeclared`：manifestVersion=2、dto.scope=perUseCase + usage=request → route 三欄如實回傳，warnings 空。
   - `testLegacyInferenceContextShared`：dto.isContextShared=true、無 scope → route.scope=.contextShared，warnings 含對應 line。
   - `testLegacyInferenceAggregate`：dto.aggregateRef=valid agg、無 scope → route.scope=.aggregate。
   - `testDefinitionLocationDivergence`：scope=perUseCase 但 ownership 已標 contextShared → route.scope=.perUseCase, route.definitionLocation=.contextShared, warning 含 "emitting mapper-only".
   - `testDefaultUsageBothWhenMissing`：dto.usage=nil → route.usage=.both。
2. **`ApiRendererTests.swift`** 加：
   - `testPerUseCaseDtoMapperOnlyEmission`：input 含 `status: EmployeeStatus` + route(perUseCase × request, def at contextShared) → outputs 含 `Adapter/CreateUserAccessProfile/EmployeeStatusDto.swift`，content 含 `extension EmployeeStatus { package init(from dto: EmployeeStatusDto) throws` 但**不**含 `enum EmployeeStatusDto`。
   - `testPerUseCaseDtoIncludesDefinitionWhenLocationIsPerUseCase`：route.definitionLocation=.perUseCase → output 含 `enum <Name>Dto` 或 `package struct <Name>Dto`。
   - `testAsInputFieldTypeSwapsToDto`：AS Input fields 中 status 的型別字串為 `EmployeeStatusDto`（不是 `EmployeeStatus`）。
   - `testExecuteBodyHasStructuredTodoMarker`：AS content 含 `// genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=status, dto=EmployeeStatusDto)`。
   - `testIdentityMapperTupleSkip`：scope=.aggregate + dto.name==domainTypeName → legacy skip 仍生效；scope=.perUseCase + 同條件 → per-UC mapper 照 emit（不被 skip）。
3. **`BundleParserTests.swift`** 加：
   - `testReservedNameFilterRejectsApiErrorSuffix`：dto.name = `FooApiError` → raise `bundleInvalid` 含 "reserved infra pattern"。
   - 同檔加 prefix `ApiComponents+`、suffix `+Schema`、`+Domain` 三案。
   - `testBundleSchemaVersion2RequiresExplicitScope`：v2 + dto.scope=nil → raise。
   - `testLegacyBundleAcceptsMissingScope`：manifestVersion 缺 + dto.scope=nil → 解 OK（DtoRouter warning path 在 router test 驗）。
   - `testForbiddenCombinationsRaise`：perUseCase × response / aggregate × * / contextShared × request 三案 raise `bundleInvalid`。
4. **`NewCommandTests.swift`** 加 E2E：
   - `testGenesisNewWithWriteDtoBundleEmitsPerUcMapperOnly`：跑 `iam-write-dto-bundle.json`，confirm:
     - `Adapter/CreateUserAccessProfile/EmployeeStatusDto.swift` 存在
     - 該檔含 `extension EmployeeStatus`，不含 `enum EmployeeStatusDto`
     - AS Input 區塊含 `package let status: EmployeeStatusDto`
     - AS execute body 含 `// genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=status, dto=EmployeeStatusDto)`
     - context-shared `<Ctx>Shared/EmployeeStatus.swift` 仍照 SharedTargetRenderer emit（不被 perUseCase 路徑取代）

---

## 失敗路徑

主要錯誤傳播鏈：

### Bundle validation fail（`BundleParser`）

- Reserved-name collision：`BundleParser.decodeDtoSpec` raise `GenesisError.bundleInvalid` → `NewCommand` `parseFull` call 不 catch → CLI exit non-zero，print reason 到 stderr。**不可恢復**。
- `manifestVersion:2` 缺 `scope`：同上 raise → exit。**不可恢復**（要 user 補 scope 或拿掉 v2 sentinel）。
- Forbidden combination：`BundleParser` raise → exit。**不可恢復**（要 user 改 bundle scope/usage）。
- `useCaseRef` 不存在：cross-check 階段 raise → exit。**不可恢復**。

### Router warning（`DtoRouter`）

- legacy bundle 缺 scope/usage：router emit warning，**不 raise**，沿用 inference 結果繼續 codegen。`NewCommand` stderr 印 summary（或 verbose 詳列）。**可恢復**（user 看到 warning，未來補 manifestVersion:2 即可消除）。
- `useCaseRef` 反查命中 0 或 >1：router 改 scope 為 `.aggregate`（per ownership）+ warn → 該 type 走 aggregate-shared path（Phase 1.p forbidden combination 觸發 raise 由 BundleParser 階段已擋掉，inference path 不會走到該 forbidden combination 因為 inference 沒有對應 scope marker）。**可恢復**。

### Rendering fail（`ApiRenderer`）

- Template placeholder 漏傳：既有 `TemplateRenderer.render` 的 `precondition(unresolvedVariables.isEmpty)` 觸發 build-time 中止。**不可恢復**（測試覆蓋）。
- `routes[dto.name]` 缺 entry：ApiRenderer 對該 dto 走 legacy path（既有 aggregate / contextShared 邏輯）— 不影響 emission。**可恢復**。
- `SourceWriter.plan` 對 perUseCase mapper path 偵測重複：既有 `outputDirHasConflict` 觸發 → exit。**不可恢復**（user 處理現有檔案）。

### `/api` skill silent-skip（Phase 1.p.1 預期問題）

- Phase 1.p ship 後、Phase 1.p.1 尚未 ship 期間：AS execute body 內 structured TODO 共存於既有 `fatalError("TODO(/api skill): ...")` marker — `/api` skill v1 對 structured TODO comment 行為=忽略（既有 fill 邏輯只看 `fatalError` body）。**Phase 1.p 接受此 transient gap**（per 約束「Phase 1.p.1 must follow promptly」），不需 Phase 1.p 端做防護。**可恢復**：Phase 1.p.1 ship 後 marker 由 `/api` skill 替換為實際 `init(from:)` call。

---

## 不改動的部分

- `Sources/GenesisCore/SharedTargetRenderer.swift` — 既有 generic bundle DTO def emission 行為保留；context-shared / aggregate-shared write-side mapper 是 Phase 1.q 工作（per D18）。
- `Sources/GenesisCore/DtoRenderer.swift` — 僅 emit DTO definitions，不 emit mappers；identity-mapper 修正不涉及此檔（per D17）。
- `Sources/GenesisCore/TypeOwnershipResolver.swift` — `TypeOwnership` enum 仍為 binary `.contextShared` / `.ownedBy`，不擴增（per D7 約束）。
- `Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md` — `/api` skill 對 structured TODO marker 的處理 = **Phase 1.p.1 scope**，不在 Phase 1.p。
- `Sources/GenesisCore/SwiftTypeResolver.swift` `primitives` set — 由 DtoRouter / DtoRouter 引用，本 phase 不修改該 set。
- `OpenApiYamlRenderer.swift`、`ApiHandlerRenderer.swift` — wire schema mapper（`Components.Schemas.<X> ↔ <X>Dto`）emission 留待 Phase 1.p.1+。
- 既有 aggregate-level `Adapter/Dto/<X>Dto+Domain.swift` emission 行為（per D6 cross-cutting 路徑）保持不變。

### Non-goals（行為層）

- 本 task **不**改動 `/api` skill SKILL.md 內容（structured TODO 解析屬 Phase 1.p.1）。
- 本 task **不** emit schema mapper（`<X>Dto ↔ Components.Schemas.<X>`）— 等 Phase 1.p.1 `/api` skill + openapi.yaml schema 完備。
- 本 task **不**支援 `aggregate × request/response/both` 寫側 mapper emission（Phase 1.q）。
- 本 task **不**支援 `contextShared × request` 寫側 mapper emission（Phase 1.q）。
- 本 task **不**支援 `perReadModel × request` / `perReadModel × both`（D19：query 沒 request body，forbid via `bundleInvalid`）。
- 本 task **不**自動把既有 bundle 加 `scope`/`usage`/`useCaseRef`/`readModelRef`（Cosmogony Event Storming Tool 端工作；v19 已 ship）。
- 本 task **不**改動 Cosmogony bundle 輸出 — Genesis 端 Phase 1.p 用 v20 bundle 即可驗證（無 hand-crafted fixture 限制：D21 Phase 1.p 已 unblock）。
- 本 task **不**改變 `TypeOwnership` enum 的二元 case 集合。
- 本 task **不**處理 read-side DTO route 推論（`get*` / `list*` / `find*` UC 仍走既有 read-side path）— 但 perReadModel scope explicit-marked 的 DTO 由 Phase 1.p impl 處理。
- 本 task **不**改變既有 enum DTO 走 `+Domain.swift` 雙向 mapper 的 aggregate-shared 路徑。
- 本 task **不**啟用 strict path（`manifestVersion ≥ 2`）— 等 Cosmogony v22 ship 後再做 strict-path validation gate（小改動，跟 D20 一致）。

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# Build + 全 test suite
swift build 2>&1 | tail -5
# 期望: "Build complete!"

swift test 2>&1 | tail -10
# 期望: "Test Suite ... passed" 0 failures

# D7 — DtoRouter 新檔存在，且 TypeOwnership enum 沒被擴增
test -f Sources/GenesisCore/DtoRouter.swift
grep -q 'public struct DtoRoute' Sources/GenesisCore/DtoRouter.swift
grep -q 'public enum DtoRouter' Sources/GenesisCore/DtoRouter.swift
# TypeOwnership enum 仍維持 binary case
grep -q 'case contextShared' Sources/GenesisCore/TypeOwnershipResolver.swift
grep -q 'case ownedBy(aggregateName: String)' Sources/GenesisCore/TypeOwnershipResolver.swift
! grep -E 'case (perUseCase|aggregate)\b' Sources/GenesisCore/TypeOwnershipResolver.swift

# D11 — manifestVersion sentinel 接入 BundleParser
grep -q 'manifestVersion' Sources/GenesisCore/BundleParser.swift

# D5 — Reserved-name filter 字串在 BundleParser
grep -q 'reserved infra pattern' Sources/GenesisCore/BundleParser.swift

# D8 — Identity-mapper skip 改 tuple-keyed (perUseCase 不再走單 key skip)
grep -q 'routes\[dto.name\]?.scope != .perUseCase' Sources/GenesisCore/ApiRenderer.swift
# DtoRenderer 不應出現 mapper skip pattern
! grep -E 'if dto\.name == .*domainTypeName' Sources/GenesisCore/DtoRenderer.swift

# D4 — structured TODO marker 精確字串可在 ApiRenderer 找到
grep -q 'genesis-todo(phase=1.p.1, kind=dto-init-from-input' Sources/GenesisCore/ApiRenderer.swift

# D6 — per-UC mapper path 為 same-file，無 +Domain suffix
grep -q 'Adapter/.*ucPascal.*Dto.swift' Sources/GenesisCore/ApiRenderer.swift
# (aggregate +Domain path 仍保留作為 cross-cutting scope)

# D16 — DtoRoute 含 scope 與 definitionLocation 兩個 stored fields
grep -q 'public let scope: Scope' Sources/GenesisCore/DtoRouter.swift
grep -q 'public let definitionLocation: Scope' Sources/GenesisCore/DtoRouter.swift

# D9 / D10 + D19 — Forbidden combination raise 字串存在 BundleParser
grep -q 'perUseCase × response is unusual' Sources/GenesisCore/BundleParser.swift
grep -q 'perReadModel × request not supported' Sources/GenesisCore/BundleParser.swift
grep -q 'perReadModel × both not supported' Sources/GenesisCore/BundleParser.swift
grep -q 'aggregate × \* write-DTO not supported in Phase 1.p' Sources/GenesisCore/BundleParser.swift
grep -q 'contextShared × request write-DTO not supported in Phase 1.p' Sources/GenesisCore/BundleParser.swift

# D20 — manifestVersion strict gate (replaces D11 bundleSchemaVersion)
grep -q 'manifestVersion.*>= *2\|manifestVersion >= 2' Sources/GenesisCore/BundleParser.swift

# E2E — 新 fixture 跑 genesis new
TMPDIR=$(mktemp -d)
swift run genesis new IAMContext \
    --from-bundle tests/GenesisIntegrationTests/Fixtures/iam-write-dto-bundle.json \
    --output "$TMPDIR" --no-git --skip-build 2>&1 | tail -3

# Per-UC mapper file 路徑正確 (OC same-file convention)
DTOFILE="$TMPDIR/Sources/UserAccessProfileAggregate/Adapter/CreateUserAccessProfile/EmployeeStatusDto.swift"
test -f "$DTOFILE"

# Mapper-only path: 含 extension 但不含 enum 重宣告 (D3 Gherkin)
grep -q 'extension EmployeeStatus' "$DTOFILE"
grep -q 'init(from dto: EmployeeStatusDto)' "$DTOFILE"
! grep -q 'enum EmployeeStatusDto' "$DTOFILE"

# AS Input field 型別 swap 成 DTO
ASFILE="$TMPDIR/Sources/UserAccessProfileAggregate/Adapter/CreateUserAccessProfile/CreateUserAccessProfileApplicationService.swift"
test -f "$ASFILE"
grep -q 'package let status: EmployeeStatusDto' "$ASFILE"
! grep -q 'package let status: EmployeeStatus$' "$ASFILE"

# AS execute body 含 structured TODO marker (精確字串)
grep -qF '// genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=status, dto=EmployeeStatusDto)' "$ASFILE"

# contextShared EmployeeStatus def 仍由 SharedTargetRenderer emit (def 不被 perUseCase 路徑搶走)
test -f "$TMPDIR/Sources/IAMContextShared/EmployeeStatus.swift"
grep -q 'enum EmployeeStatus' "$TMPDIR/Sources/IAMContextShared/EmployeeStatus.swift"

# DtoRouter legacy-bundle 應在 stderr 顯示 summary warning (跑既有 iam-bundle 不含 scope marker 的場景)
TMPDIR2=$(mktemp -d)
swift run genesis new IAMContext \
    --from-bundle tests/GenesisIntegrationTests/Fixtures/iam-bundle.json \
    --output "$TMPDIR2" --no-git --skip-build 2>&1 | grep -q 'DtoRouter:'

rm -rf "$TMPDIR" "$TMPDIR2"
```

### Human 補做（需要人類介入）

- [ ] 拿 user real bundle `~/Downloads/IAM Context Bundle.json` 重跑 `genesis new IAMContext --from-bundle ... --no-git --skip-build` 目視確認：
  - stderr 應含 `⚠ DtoRouter: inferred N DTO routes from legacy bundle (run with --verbose for per-DTO detail)` 一行 summary。
  - 加 `--verbose` 重跑 → stderr 應印每條 route warning 行（per-DTO detail）。
  - 若 real bundle 未含 write UC 帶自訂型別 input，預期不 emit perUseCase mapper file（路徑下沒有 `Adapter/<UC>/<X>Dto.swift` 出現）— 為「無事可做」的 baseline 場景。
- [ ] 跑 hand-crafted fixture，把 emitted code 拿給人類目視 OC 對齊比對：
  - `Adapter/CreateUserAccessProfile/EmployeeStatusDto.swift` 內 mapper-only 段落結構是否與 OC `Adapter/EditBusinessTaxFilingMethod/BusinessTaxFilingMethodDto.swift` 中 domain-mapper extension 段落 byte-shape 相近（imports / mapper signature / body indent）。
  - `CreateUserAccessProfileApplicationService.swift` 內 execute body 的 structured TODO 是否清楚標示「Phase 1.p.1 即將補 `init(from:)` call」（人類肉眼讀懂、易於後續 grep）。
- [ ] 確認 Phase 1.p.1 ticket 已建（user 確認 `/api` skill update 已 queued），避免 Phase 1.p ship 後 AS execute body 留下 transient empty 狀態超過預期時間。

---

## 已知限制

- **`/api` skill 不在 Phase 1.p scope**：Phase 1.p ship 後到 Phase 1.p.1 ship 前的窗口，AS execute body 內 structured TODO 為 markdown-style comment，`/api` skill v1 不識別 → silent skip。**緩解**：Phase 1.p.1 必須 immediately follow（per D4 約束），且 structured TODO 為 machine-greppable single-line format（`genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=<f>, dto=<X>Dto)`，逗號後含空格），未來 skill 直接 grep 即可定位。
- **`aggregate × *` 與 `contextShared × request` 寫側 mapper 未支援**：Phase 1.p 透過 `bundleInvalid` 顯式 forbid，Phase 1.q 才支援。User 若需此 scope，需暫時走 `contextShared × both`（read+write 共享 def，mapper 由 SharedTargetRenderer 已 emit 的 cross-agg path 處理）或等 Phase 1.q。
- **`perUseCase × response` 不支援**：透過 `bundleInvalid` 顯式 forbid。OC 無 counterexample；若未來出現案例，flip 改為 inference + emit 是 one-line 改動。
- **Cosmogony bundle 仍 emit 舊 schema**：Phase 1.p 不 block on Cosmogony；Genesis 端走 `DtoRouter` inference path + warning 通知 user。Cosmogony schema v2 更新是 parallel separate task。
- **Hand-crafted fixture 為 Phase 1.p 唯一 strict-path 測試**：直到 Cosmogony 更新前，strict-path（manifestVersion:2 + 顯式 scope/usage）只有 fixture 驗證；real bundle dogfood 走 inference path。
- **無 backward compat 包袱**：Phase 1.l/1.m/1.n/1.o 剛 ship，無「舊版生成的 Genesis project」回收問題。Phase 1.p emit 變更直接覆蓋。
- **不支援 Service 多 dependency 變體**：與 Phase 1.o 同等限制；OC 部分 Service 帶 `validator` 不在 Phase 1.p scope。

### 依賴關係

- 前置（hard depends_on）：無 hard 阻塞（Phase 1.l/1.m/1.n/1.o 全 done）。
- 軟相依（soft depends_on，已 done，行為相容）：
  - `2026-05-26-phase-1n-type-ownership-routing`（`TypeOwnershipResolver` + `ownership` dict 入參約定，DtoRouter 必須在其後 run）
  - `2026-05-27-phase-1o-hygiene`（Service struct + Usecase where-clause + event.yaml map shape — Phase 1.p emit shape 對齊新 hygiene）
  - `2026-05-26-usecase-skill`（`/usecase` skill marker convention 對齊 — Phase 1.p 不改 `/usecase` skill，但 Phase 1.p emit 的 AS execute body 含 `fatalError("TODO(/api skill)")` 既有 marker）
- 後續（next phase）：**Phase 1.p.1**（`/api` skill 更新解析 structured TODO + 補 `init(from:)` call insertion + 開始 schema mapper emission）— **must queue immediately**（per D4 約束）。
- 並行（parallel separate task，不阻塞）：Cosmogony Event Storming Tool bundle schema v2 更新（emit `scope` / `usage` / `useCaseRef` + `manifestVersion:2` sentinel）。
