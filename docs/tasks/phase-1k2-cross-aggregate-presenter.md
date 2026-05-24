# Phase 1.k.2 — Cross-aggregate presenter + QueryError 雙軌制（OC-aligned full pattern）

## 來源

討論：`docs/discussions/2026-05-24-phase-1k2-cross-aggregate-presenter.md`

OC ground truth refs：
- context-level Adapter 完整結構：`OpportunityContext/Sources/OpportunityContext/Adapter/`（含 read-side AS / write-side AS / `ApiHandler.swift` / `ApiComponents/` / `openapi.yaml`）
- query error 雙軌制：`OpportunityContextQueryError.swift`（context-level）+ `AuditQuotingQueryError.swift` / `QuotingCaseGroupingQueryError.swift` / `QuotingCaseQueryError.swift`（per-aggregate）
- `init?(from error: {A}Error)` multi-branch overloads：`ApiComponents+OpportunityContextApiError.swift`（context-level，import 各 aggregate target）
- read method 404 catch pattern：OC ApiHandler 中 `catch let error as ContextError<{X}QueryError> where error.error == .{notFound} { return .notFound(...) }`

依賴 Phase（全 done）：phase-1f（ContextShared infra）、phase-1g（per-aggregate ReadModel + Presenter projector codegen）、phase-1g.2（context-level projector + IAMContext target）、phase-1h（ApplicationService + DTO mapper codegen）、phase-1i（OpenAPI infrastructure + ApiHandler/ApiComponents per-agg）、phase-1k（PresenterRenderer per-agg + read-side AS scaffold + ApiHandler read method）、2026-05-23-presenter-fill-skill（/presenter-fill v1）。

## 目標

補完 Phase 1.k 留下的 3 個架構缺口 + 對齊 OC 的 query-side error 雙軌制，讓 Genesis 真正能 codegen 出**跨 aggregate read endpoint** end-to-end 可 serve（含 404 not-found path）。具體包含：

1. **cross-aggregate presenter AS placement**（A）：read-side AS 路徑依 readModel.aggregateRef 路由，context-level AS 進 `Sources/{Context}/Adapter/` 與 projector 同 module，解 circular dependency。
2. **context-level Adapter 基建**：emit context-level ApiHandler + ApiComponents + openapi.yaml + Package target additions，對齊 OC `Sources/OpportunityContext/Adapter/` 結構。
3. **QueryError 雙軌制 + 404 catch**（OC 核心 read-side pattern）：emit per-agg `{A}QueryError.swift` + context-level `{Context}QueryError.swift`，ApiHandlerReadMethod 加 404 catch。
4. **scalar + collection elementType reject**（B）：openapi 不支援 `Set<X>` 直出 scalar，bundle 層 validation 攔截。
5. **TODO comment Reference path 條件化**（C）：per-agg vs context-level 用不同 projector path。
6. **/presenter-fill v2 升級**：cross-agg exit 3 移除；non-optional nil 升級為 `throw ContextError<{X}QueryError>(error: .notFound, ...)` 取代 v1 的 `ProjectionReadInconsistency`，解除 v1 known limit #2（read-side 無 404 path）。

完成後解鎖：bundle 含 cross-agg presenter（如 GetUserAccessSummary） → `genesis new` → `/presenter-fill` → `swift build` → 真正可 serve 跨 aggregate GET endpoint with 404。

---

## 介面合約

### 1. Bundle schema validation（新增）

`BundleParser.parseFull` 增加 validation pass（throw `GenesisError.bundleInvalid(reason:)`），**順序**：

**(a) readModel name uniqueness（audit H1）**：對 `bundle.readModels[]`，若有重名 → throw `duplicate readModel name '<X>'; readModel names must be unique within a bundle`。
**(b) readModelRef must exist（audit H1）**：建 `readModelsByName: [String: ReadModelSpec]` 一次（lookup by `.name`）；對每個 presenter，若 `readModelRef` 不在 lookup → throw `presenter '<name>' references missing readModel '<R>'`。
**(c) D1 consistency**：定義 `resolvedReadModelAggregateRef(_ rm:) -> String`（audit M1）：`rm.aggregateRef != nil` 用之；`rm.aggregateRef == nil` 且 `rm.aggregateSpecId != nil` → 從 aggregateSpecId 解析 aggregates lookup 取 aggregate.name；兩者皆 nil → throw `readModel '<R>' has neither aggregateRef nor resolvable aggregateSpecId; cannot be used by presenter`。對每個 presenter：若 `presenter.aggregateRef != resolved` → throw `presenter '<name>' aggregateRef '<X>' does not match readModelRef '<R>' aggregateRef '<Y>' (must be co-located per Phase 1.k.2 D1)`。
**(d) D4 scalar+collection reject（audit M2 邊界處理）**：抽 helper `isCollectionType(_ raw: String) -> Bool`，先 trim whitespace + strip trailing `?` (optional)，再判定 hasPrefix `[` / `Set<` / `Array<` / `Array[` / `Dictionary<` / `Dictionary[`。若 `presenter.output.kind == .scalar` 且 `isCollectionType(elementType)` → throw `presenter '<name>' scalar output cannot use collection elementType '<type>'; use kind=array or change elementType`。`kind == .single` + collection 列 known limit（v1 不阻擋，user 自負 openapi $ref 風險）。

### 2. PresenterRenderer 改動（routing by readModel.aggregateRef）

`PresenterRenderer.render(bundle:contextName:adapter:existingPaths:)` 重設分流：

- 取得 presenter 對應的 readModel（lookup by `readModelRef`）。
- 若 `readModel.aggregateRef == "<context-level>"` → AS 路徑為 `Sources/{contextName}/Adapter/{presenter.name}/{presenter.name}ApplicationService.swift`；template 變數 `{A}` 為 contextName（用於 `{Context}QueryError` 引用）、`{ProjectorRefPath}` 為 `Sources/{contextName}/Projector/`。
- 否則 → 既有 per-agg 路徑 `Sources/{presenter.aggregateRef}Aggregate/Adapter/...`；`{ProjectorRefPath}` 為 `Sources/{A}Aggregate/Usecase/Projector/`。
- D1 已在 BundleParser reject Case Y，故此處無歧義。

### 3. PresenterApplicationService.swift.template 改動

加新 placeholder：

- `{ProjectorRefPath}`：取代第二行註解 hardcode 的 `Sources/{A}Aggregate/Usecase/Projector/`，由 PresenterRenderer 依路由結果 substitute。

### 4. ApiHandlerReadMethod.swift.template 改動（404 catch）

在現有 catch-all `catch { mapToApiError ... }` **之前**插入 query-error specific 404 catch：

```swift
        } catch let error as ContextError<{QueryErrorType}> where error.error == .notFound {
            return .notFound(.init(body: .json(.init(error: .notFound))))
        } catch {
            ...
        }
```

新增 placeholder：

- `{QueryErrorType}`：per-agg 為 `{A}QueryError`、context-level 為 `{Context}QueryError`，由 ApiHandlerRenderer 依 handler module 決定。

> **`.notFound` ApiError case 預設加入**：OpenApiYamlRenderer 為含 read presenter 的 aggregate（或 context）在 ApiError enum schema 加 `.notFound` case + 404 response code。

### 5. ApiHandlerRenderer 改動（context-level handler emission）

- **共用 placement helper（audit M3）**：新增 `PresenterPlacement` enum + `presenterPlacements(bundle:) -> [(presenter, placement)]`，其中 `placement = .aggregate(name) | .context`，依 readModel.aggregateRef 路由判定。PresenterRenderer / QueryErrorRenderer / ApiHandlerRenderer / OpenApiYamlRenderer / PackageRenderer **全部**呼叫此 helper，避免邏輯散落。
- per-aggregate emit 既有邏輯維持；handler/template 新增 `{QueryErrorType}` substitute 為 `{A}QueryError`（當 aggregate 有 read presenter）。
- 若 bundle 有 context-level presenter（透過 placement helper 判定） → 新增 emit：
  - `Sources/{contextName}/Adapter/ApiHandler.swift`：**用獨立 template** `ApiHandlerContext.swift.template`（audit H3）—— **不含** `repository` property、**不含** `{A}AggregateEventMapper` reference，**只**含 `kdbClient` injection、`mapToApiError`、read methods。mapToApiError multi-branch import 各 source aggregate target（透過 placement helper 收集 cross-agg readModel.events sourceAggregate dedup）。
  - `Sources/{contextName}/Adapter/ApiComponents/ApiComponents+{Context}ApiError.swift`：用 `ApiComponentsContextError.swift.template`，**對齊 per-agg pattern（audit M5）**——含 `init(from error: ContextError<{Context}QueryError>)`（non-optional，fallback `.undefinedDomainError`）+ `init?(from error: {Context}QueryError)` + per source aggregate `init(from error: ContextError<{A}Error>)` + `init?(from error: {A}Error)` overloads（與 per-agg ApiComponents 完整一致）。

### 6. QueryError emission（新 renderer）

新增 `QueryErrorRenderer`（pure function of bundle，**含 scaffold-once，audit M4**）：

簽名：`render(bundle:contextName:existingPaths:) throws -> [(path, content, role)]`。`existingPaths: Set<String>` 由 NewCommand 掃描提供；若目標 path 已存在 → 跳過該檔（user 可能已手動加 cases）。透過 placement helper 判定：

- per-aggregate：若 placement 命中 aggregate（透過 helper）→ emit `Sources/{A}Aggregate/{A}QueryError.swift`，包含 `package enum {A}QueryError: Error, Equatable { case notFound }` + ContextError extension static factory `.notFound(in:message:)`。
- context-level：若 placement 命中 context → emit `Sources/{contextName}/{contextName}QueryError.swift`，同樣含 `notFound` case + factory。

### 7. OpenApiYamlRenderer 改動

- emit context-level openapi.yaml + config（透過 placement helper 判定有 context-level presenter）：路徑 `Sources/{contextName}/openapi.yaml` + `openapi-generator-config.yaml`，內含跨 aggregate GET endpoints + ApiError schema 含 `.notFound` case + 404 response。
- **context-level param 獨立收集（audit M6）**：context-level openapi **不**沿用 per-agg dynamic params 邏輯（不加 `operatorId` header、不加 `{A}Id` aggregate identity schema）。獨立收集 context-level presenter input fields 的 path params；schema 只含 `{Context}ApiError` + response components。
- per-aggregate openapi.yaml 在 `{A}ApiError` enum 加 `.notFound` case + 為含 read presenter 的 endpoint 加 404 response（當 aggregate 有 read presenter）。
- `yamlType(for:)` 不改；scalar+collection 不會走到這裡因 BundleParser 已 reject（D4）。

### 8. PackageRenderer 改動（context target Adapter resources）

`hasContextLevel(bundle:)` 維持為 projector emission 判定；新增 `hasContextLevelPresenter(bundle:)` 判定 context-level Adapter 是否啟用（用 placement helper）。

**openapi top-level package deps 重新計算（audit H4）**：原 `anyAggregateHasWriteUC` 條件改為 `needsOpenApi = any per-agg has write UC OR any per-agg has read presenter OR has context-level presenter`，否則 per-agg presenter-only / context-only 場景會引用 OpenAPIRuntime/plugin 但 Package 沒 package dependency → resolve fail。同理 per-agg target 的 OpenAPIRuntime dep + resources + plugin 條件從 `hasWriteUC` 改為 `hasWriteUC || hasReadPresenter`。

當 `hasContextLevelPresenter` 為 true，context target 加：

- resources：`.process("openapi.yaml")` + `.process("openapi-generator-config.yaml")`
- dependencies：`.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")` + import 各 source aggregate target（用於 ApiHandler error mapping）
- plugins：`.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")`

### 9. /presenter-fill v2 改動

- **Phase 1 locate AS（audit H5，gating fix）**：原 Glob 僅 `Sources/*Aggregate/Adapter/<presenterName>/<presenterName>ApplicationService.swift` 無法定位 context-level AS。改為 Glob **兩種**模式合併：
  - `Sources/*Aggregate/Adapter/<presenterName>/<presenterName>ApplicationService.swift`（per-agg）
  - `Sources/*/Adapter/<presenterName>/<presenterName>ApplicationService.swift`（context target，排除 `*Aggregate` 已涵蓋者）

  從 match 路徑推導 **module 種類**（per-agg vs context-level）；per-agg → `<A>` = aggregate 名 + `{QueryErrorType}` = `<A>QueryError`；context-level → `<A>` = contextName + `{QueryErrorType}` = `<contextName>QueryError`。同時 verify `{QueryErrorType}.swift` 存在於對應 module 根目錄（per-agg：`Sources/<A>Aggregate/`；context-level：`Sources/<contextName>/`），缺 → exit 1 prerequisite missing。
- **Phase 4 same-module projector**：locate projector 邏輯改成 module-agnostic 「same module 含 AS 與 projector 即合法」（per-agg AS+projector 同 `Sources/<A>Aggregate/`；context-level AS+projector 同 `Sources/<contextName>/`）。cross-aggregate exit 3 移除。
- Phase 5 non-optional nil throw 依 Phase 1 推導的 `{QueryErrorType}` emit：
  - per-agg → `throw ContextError<{A}QueryError>(error: .notFound, in: .struct({Name}ApplicationService.self, function: #function), message: ...)`
  - context-level → `throw ContextError<{contextName}QueryError>(error: .notFound, ...)`
- SKILL.md：known limit #2（read-side 無 404 path）改寫為「已由 Phase 1.k.2 解除（適用 Phase 1.k.2 後新填或 manual unfill 後重填的 body；v1 既有 fills 不 retro-upgrade，audit M7）」；body sample 範例更新；exit 3 cross-aggregate 案例移除。
- spec 文件（`2026-05-23-presenter-fill-skill.md`）+ registry 同步更新（status 維持 done，加 v2 note）。

### 10. Bundle fixture 修正

- `Tests/GenesisIntegrationTests/Fixtures/iam-presenter-bundle.json`（Phase 1.k e2e 用）：presenter `GetUserAccessSummary.aggregateRef` 從 `UserAccessProfile` 改 `<context-level>`（對齊 D1）。
- `Tests/GenesisIntegrationTests/Fixtures/iam-presenter-fill-bundle.json`（/presenter-fill v1 e2e 用）：維持原樣（per-agg 一致，符合 D1）。
- 新增 `Tests/GenesisIntegrationTests/Fixtures/iam-cross-agg-presenter-bundle.json`（Phase 1.k.2 e2e fixture）：context-level readModel + context-level presenter（aggregateRef 都是 `<context-level>`）。

---

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/BundleParser.swift` | 加 D1（presenter↔readModel aggregateRef 一致）+ D4（scalar+collection reject）validation |
| `Sources/GenesisCore/PresenterRenderer.swift` | AS 路徑依 readModel.aggregateRef 路由；TODO `{ProjectorRefPath}` placeholder substitute |
| `Sources/GenesisCore/QueryErrorRenderer.swift` | **新檔** — emit `{A}QueryError.swift`（per-agg）+ `{Context}QueryError.swift`（context-level） |
| `Sources/GenesisCore/ApiHandlerRenderer.swift` | per-agg handler/components 加 `{QueryErrorType}`；新增 context-level handler + ApiComponents emission |
| `Sources/GenesisCore/OpenApiYamlRenderer.swift` | context-level openapi emission；per-agg + context-level openapi 加 `.notFound` case + 404 response |
| `Sources/GenesisCore/PackageRenderer.swift` | context target Adapter resources/deps/plugin（when `hasContextLevelPresenter`） |
| `Sources/Genesis/Commands/NewCommand.swift` | 加 QueryErrorRenderer step；scanExistingApiPaths 擴 per-agg `{A}QueryError.swift` + context-level paths |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template` | 第二行註解 `Reference:` path 改 `{ProjectorRefPath}` placeholder |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template` | 在 catch-all 前插入 `catch ContextError<{QueryErrorType}> where ... .notFound → .notFound` |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiComponentsContextError.swift.template` | **新檔** — context-level variant，多 `init?(from error:)` overloads |
| `Sources/GenesisCore/Resources/Templates/v0.1/QueryError.swift.template` | **新檔** — `{A}QueryError` / `{Context}QueryError` template（package enum + ContextError extension factory） |
| `Sources/GenesisCore/Resources/Templates/skills/presenter-fill/SKILL.md` | v2：cross-agg exit 3 移除；non-optional throw 升級 QueryError；known limit #2 解除 |
| `docs/tasks/2026-05-23-presenter-fill-skill.md` | v2 note：known limit #2 解除、body sample 更新 |
| `docs/tasks/registry/2026-05-23-presenter-fill-skill.json` | status_history 加 v2 entry |
| `Tests/GenesisIntegrationTests/Fixtures/iam-presenter-bundle.json` | presenter.aggregateRef 改 `<context-level>`（對齊 D1） |
| `Tests/GenesisIntegrationTests/Fixtures/iam-cross-agg-presenter-bundle.json` | **新檔** — Phase 1.k.2 e2e fixture |
| `Tests/GenesisCoreTests/PresenterRendererTests.swift` | 加 routing test（per-agg vs context-level path）+ TODO ref path test |
| `Tests/GenesisCoreTests/QueryErrorRendererTests.swift` | **新檔** — per-agg + context-level emission tests |
| `Tests/GenesisCoreTests/ApiHandlerRendererTests.swift` | 加 context-level handler emission + 404 catch + multi-branch mapToApiError tests |
| `Tests/GenesisCoreTests/OpenApiYamlRendererTests.swift` | 加 context-level openapi emission + .notFound case + 404 response tests |
| `Tests/GenesisCoreTests/PackageRendererTests.swift` | 加 context target Adapter resources test |
| `Tests/GenesisCoreTests/BundleParserTests.swift` | 加 D1 reject Case Y + readModelRef missing + duplicate readModel name + D4 reject scalar+collection tests |
| `Tests/GenesisCoreTests/PresenterRendererTests.swift` | 既有 `testCrossAggregateSilentSkip` 類測試 **flip 為 reject 或 context-emit**（audit M8）；不能與 Phase 1.k.2 意圖相反 |
| `Sources/GenesisCore/Version.swift` | `0.1.0-phase1k` → `0.1.0-phase1k2` |
| `docs/decisions.md` | Phase 1.k.2 ratification entry |
| `docs/architecture.md` | §10.13 cross-aggregate read flow（含 QueryError 雙軌制 diagram） |
| `docs/tasks/registry/phase-1k2-cross-aggregate-presenter.json` | **新檔**（audit L1）— pickup 時 status ready → done |

---

## 實作步驟

### Step 1 — BundleParser validations（D1 + D4）

1. `parseFull` 解出 presenters[]、readModels[] 後，加 validation pass：
   - 對每個 presenter：lookup readModel via `readModelRef`；若不在 readModels[] → existing behavior（unchanged，由 PresenterBundleAppender 層處理）；若 in，比對 `aggregateRef` —— 不一致 → `throw GenesisError.bundleInvalid(reason: "...")`。
   - 對每個 presenter：若 `output.kind == .scalar`，檢 `output.elementType` 是否含 collection 前綴（`[`、`Set<`、`Array<`、`Dictionary<`） → throw。
2. 兩 validation 在 readModels + presenters 都已 parse 後執行，errors 包含 presenter 名 + 對方資訊 for debugging。

### Step 2 — QueryErrorRenderer（新 renderer）

1. 新檔 `Sources/GenesisCore/QueryErrorRenderer.swift`，pure function of bundle。
2. `render(bundle:contextName:) -> [(path, content, role)]`：
   - per-aggregate loop：若 `bundle.presenters.contains { $0.aggregateRef == aggregate.name }` → emit `Sources/{A}Aggregate/{A}QueryError.swift`。
   - context-level：若 `bundle.presenters.contains { $0.aggregateRef == "<context-level>" }` → emit `Sources/{contextName}/{contextName}QueryError.swift`。
3. 新 template `Templates/v0.1/QueryError.swift.template`：
   ```swift
   import Foundation
   {SharedImport}

   package enum {QueryErrorTypeName}: Error, Equatable {
       case notFound
   }

   extension ContextError where ErrorType == {QueryErrorTypeName} {
       package static func notFound(in source: Source, message: String) -> Self {
           return .init(error: .notFound, in: source, message: message)
       }
   }
   ```
4. NewCommand 在 PresenterRenderer step 前後加 QueryErrorRenderer step；scanExistingApiPaths 擴 query error paths（scaffold-once）。

### Step 3 — PresenterRenderer routing + TODO path

1. 改 `PresenterRenderer.render`：建立 `readModelByName: [String: ReadModelSpec]` lookup table（Dictionary）一次。
2. 對每個 presenter：lookup readModel；確定 `aggregateRef` (D1 已驗一致，安全)：
   - context-level → `path = "Sources/\(contextName)/Adapter/\(presenter.name)/\(presenter.name)ApplicationService.swift"`，`{A}` = contextName，`{ProjectorRefPath}` = `"Sources/\(contextName)/Projector/"`，`{SharedImport}` 不變。
   - per-agg → 既有 path，`{A}` = aggregateRef，`{ProjectorRefPath}` = `"Sources/\(aggregateRef)Aggregate/Usecase/Projector/"`。
3. template render 加 `{ProjectorRefPath}` 變數 substitute。
4. 既有 `if presenter.aggregateRef == "<context-level>" { continue }` skip 移除（D1 已保證 aggregateRef 與 readModel 一致 → context-level presenter 走 context-level path 而非 skip）。

### Step 4 — PresenterApplicationService.swift.template 改

1. 將第二行
   ```
   // Reference: Sources/{A}Aggregate/Usecase/Projector/{Name}/{Name}Presenter.swift
   ```
   改為
   ```
   // Reference: {ProjectorRefPath}{Name}/{Name}Presenter.swift
   ```

### Step 5 — ApiHandlerReadMethod.swift.template 加 404 catch

1. 在 `} catch {` 行**前**插入：
   ```swift
           } catch let error as ContextError<{QueryErrorType}> where error.error == .notFound {
               return .notFound(.init(body: .json(.init(error: .notFound))))
   ```
2. 新 placeholder `{QueryErrorType}` 由 ApiHandlerRenderer 依 handler 所在 module substitute。

### Step 6 — ApiHandlerRenderer context-level emission

1. per-agg handler emit 保留；在 handler render context 加 `{QueryErrorType}` = `{A}QueryError`（aggregate 有 read presenter 時，否則 placeholder 可填佔位無 catch 也不會 fail —— Step 6.5 處理）。
2. **Step 6.5（條件式 404 catch）**：若 aggregate / context 無 read presenter → ApiHandlerReadMethod 不會 emit，無 404 catch 需求。若有 read presenter 但 QueryError 未 emit（理論不會發生，QueryErrorRenderer 同條件 emit） → 走 prerequisite check。
3. 新增 context-level handler emit（hasContextLevelPresenter true 時）：
   - 路徑 `Sources/{contextName}/Adapter/ApiHandler.swift`
   - mapToApiError multi-branch：列出 cross-agg readModel.events 涉及的 source aggregates（透過 readModel.events.sourceAggregate dedup），各為 `if let contextError = error as? ContextError<{A}Error> { return .init(from: contextError.error) }`；加 `ContextError<{Context}QueryError>` branch 對 query error。
   - import：`import {A}Aggregate` per source aggregate（解析 readModel.events.sourceAggregate）。
4. 新 template `ApiComponentsContextError.swift.template`：
   ```swift
   {AggregateImports}
   {SharedImport}

   extension Components.Schemas.{Context}ApiError {
       package init?(from error: {Context}QueryError) {
           switch error {
           case .notFound: self = .notFound
           }
       }
   {PerAggregateErrorOverloads}
   }
   ```
   `{PerAggregateErrorOverloads}` per source aggregate：`init?(from error: {A}Error)` 接每個 source aggregate 的 domain error cases（用該 aggregate.invariants[].errorCode dedup）。
5. ApiComponents+{Context}ApiError 路徑：`Sources/{contextName}/Adapter/ApiComponents/ApiComponents+{contextName}ApiError.swift`。

### Step 7 — OpenApiYamlRenderer 改動

1. per-agg openapi（aggregate 有 read presenter 時）：在 `{A}ApiError` enum schema `enum:` 列表加 `notFound`；為每個 read endpoint 加 404 response（`'404': $ref '#/components/responses/NotFound'` 之類）。
2. 新增 context-level openapi emit（hasContextLevelPresenter true 時）：
   - 路徑 `Sources/{contextName}/openapi.yaml` + `openapi-generator-config.yaml`
   - paths 列出所有 context-level presenter endpoint（已有 dynamic parameters block 邏輯沿用）
   - `{contextName}ApiError` enum 含 `.notFound` + infra cases（aggregateNotFound / invalidPayload / invalidDateFormat / undefinedDomainError / serviceUnavailable）
3. scalar+collection 不會走到這裡（D4 在 BundleParser 攔），但 yamlType 為防禦性可加 assertion or skip。

### Step 8 — PackageRenderer context target Adapter

1. 新增 `hasContextLevelPresenter(bundle:) -> Bool`（在 ContextProjectionModelRenderer 或新處）。
2. 當 true：context target 加：
   - `.process("openapi.yaml")` + `.process("openapi-generator-config.yaml")` resources
   - `.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")` dependency
   - import 各 source aggregate（透過 `dependencies: [.target(name: "{A}Aggregate")]`）— 與 ContextProjectionModelRenderer.uniqueSourceAggregates 同集合
   - `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")`
3. PackageContextTarget.swift.template 加新 placeholder（OpenApiContextDeps / Resources / Plugin），與 Phase 1.i per-agg target conditional emission 風格一致。

### Step 9 — /presenter-fill v2 升級

1. SKILL.md：
   - Phase 4 cross-agg detection 區塊改：「same module」邏輯涵蓋 per-agg AS+projector（`Sources/{A}Aggregate/`）與 context-level AS+projector（`Sources/{contextName}/`）兩種；exit 3 cross-aggregate 條目移除。
   - Phase 5 non-optional throw 範例改：依 AS 路徑判 per-agg vs context-level → throw `ContextError<{A}QueryError>(error: .notFound, ...)` 或 `ContextError<{contextName}QueryError>(error: .notFound, ...)`。
   - 移除 ProjectionReadInconsistency reference（v2 不再用此 type）。
   - 補 D1 一致性說明（presenter.aggregateRef 與 readModel.aggregateRef 必相同，bundle 層已驗）。
2. spec（`docs/tasks/2026-05-23-presenter-fill-skill.md`）：
   - sign-off 加 v2 note：known limit #2 解除（由 Phase 1.k.2 提供 QueryError + 404 path）。
   - known limit #2 改成「已由 Phase 1.k.2 解決」。
3. registry：加 v2 status_history entry，status 維持 done。

### Step 10 — fixtures + tests + e2e

1. fixture 修正：iam-presenter-bundle.json 的 presenter.aggregateRef 改 `<context-level>`。
2. 新 fixture：iam-cross-agg-presenter-bundle.json（context-level readModel + context-level presenter，elementType=String avoid collection）。
3. 各 renderer test 新增（PresenterRendererTests routing、QueryErrorRendererTests、ApiHandlerRendererTests context-level、OpenApiYamlRendererTests context-level、PackageRendererTests context-Adapter、BundleParserTests D1+D4 validation）。
4. Real e2e：
   - 用 iam-cross-agg-presenter-bundle.json 跑 `genesis new` → 確認 cross-agg AS 在 `Sources/IAMContext/Adapter/...`、projector 在 `Sources/IAMContext/Projector/...`、context-level ApiHandler+ApiComponents+openapi.yaml 全 emit。
   - 對 cross-agg AS 跑 `/presenter-fill` → 填入 `throw ContextError<IAMContextQueryError>(error: .notFound, ...)`。
   - `swift build` → Build complete（驗證 plugin 生 `OpenAPIRuntime`、404 catch compile、multi-branch ApiComponents compile）。

### Step 11 — Version + docs

1. `Version.swift`：`0.1.0-phase1k` → `0.1.0-phase1k2`。
2. `docs/decisions.md`：加 Phase 1.k.2 ratification entry。
3. `docs/architecture.md`：§10.13 cross-aggregate read flow，含 QueryError 雙軌制 ASCII diagram。

---

## 失敗路徑

| 場景 | 來源 → 處理 |
|---|---|
| presenter.aggregateRef ≠ readModel.aggregateRef（Case Y） | BundleParser D1 validation → throw `GenesisError.bundleInvalid` |
| presenter scalar output + collection elementType | BundleParser D4 validation → throw `GenesisError.bundleInvalid` |
| cross-agg presenter（D1 合法）→ 生 context-level Adapter | PresenterRenderer 路由 + QueryErrorRenderer + ApiHandlerRenderer context-level + OpenApiYamlRenderer context + PackageRenderer context-Adapter → 全 codegen pass |
| 既有 per-agg presenter（無 cross-agg） | hasContextLevelPresenter == false → context-level emission 全部 skip，per-agg path 維持原樣（backward compat） |
| /presenter-fill v2 對 per-agg AS | throw `ContextError<{A}QueryError>(error: .notFound, ...)` → mapToApiError per-agg → ApiHandler read method 的 query-specific 404 catch → 404 |
| /presenter-fill v2 對 context-level AS | throw `ContextError<{contextName}QueryError>(error: .notFound, ...)` → mapToApiError context-level → ApiHandler context-level read method 的 query-specific 404 catch → 404 |
| Bundle 既有但無 read presenter | QueryErrorRenderer skip 該 aggregate；ApiHandlerReadMethod 不 emit（無 read method）；無 .notFound case 在 openapi |

---

## 不改動的部分

- per-agg write-side codegen（Phase 1.h/1.i ApplicationService / DTO mapper / write-side ApiHandlerMethod）— 不受影響。
- per-agg read-side既有行為（除 ApiHandlerReadMethod 加 404 catch、ApiError enum 加 .notFound 外）— /presenter-fill v1 fill 過的 body 仍 compile（升級 v2 重跑會偵測 v1 body 為「已完整填」exit 0，user 想升級到 QueryError 需手 unfill 或加 `--force` v2 flag — 後者 defer 本 task）。
- ContextProjectionModelRenderer projector emission — 不變。
- Phase 1.f ContextShared infra — 不變。
- Server target Hummingbird wire-up — 仍 defer（Phase 1.i 既有 defer 持續）。

### Non-goals（行為層）

- 本 task **不包含** Server target Hummingbird wire-up（emit handler 為止，user 自接 Server）。
- 本 task **不包含** /presenter-fill v1 既有 body 的「自動升級到 QueryError」回填（v1 body 用 ProjectionReadInconsistency → 503 仍 compile，user 想升級 → manual unfill + 重跑 /presenter-fill v2，或等 `--force` v2 flag）。
- 本 task **不包含** per-element `.map { Dto(...) }` transform（/presenter-fill v1 known limit #1 維持 defer）。
- 本 task **不包含** multi-input-field presenter 自動 fill（/presenter-fill v1 known limit「v1 單一 input field」維持 defer）。
- 本 task **不包含** 自動把 OC 風格 domain `.quotationNotFound` case 加進 per-agg `{A}Error`（D2 選擇統一用 QueryError，per-agg domain error 不擴）。
- 本 task **不包含** ApiComponents per-agg-overloads 自動 audit unreachable case 改 `return nil`（/api skill v4 category 4 NO-OP 範疇，defer）。
- 本 task **不包含** 為 openapi 加 401 / 403 / 5xx 之外的細粒 response codes（v1.k.2 只加 404）。

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
# A1. 新 renderer + template + Version 存在
test -f Sources/GenesisCore/QueryErrorRenderer.swift
test -f Sources/GenesisCore/Resources/Templates/v0.1/QueryError.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiComponentsContextError.swift.template
grep -F '0.1.0-phase1k2' Sources/GenesisCore/Version.swift

# A2. BundleParser D1 + D4 validation 存在（grep raise 點）
grep -F 'presenter ' Sources/GenesisCore/BundleParser.swift | grep -F 'aggregateRef'
grep -F 'scalar output cannot use collection' Sources/GenesisCore/BundleParser.swift

# A3. PresenterApplicationService template 改用 {ProjectorRefPath}
grep -F '{ProjectorRefPath}' Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template
! grep -F 'Sources/{A}Aggregate/Usecase/Projector/' Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template

# A4. ApiHandlerReadMethod template 含 404 catch
grep -F 'ContextError<{QueryErrorType}>' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template
grep -F '.notFound' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template

# A5. /presenter-fill SKILL.md v2 升級
grep -F 'QueryError' Sources/GenesisCore/Resources/Templates/skills/presenter-fill/SKILL.md
! grep -F 'ProjectionReadInconsistency' Sources/GenesisCore/Resources/Templates/skills/presenter-fill/SKILL.md
diff Sources/GenesisCore/Resources/Templates/skills/presenter-fill/SKILL.md ~/.claude/skills/presenter-fill/SKILL.md

# A6. fixture 修正（iam-presenter-bundle Case Y 修為 context-level）
python3 -c "import json; d=json.load(open('Tests/GenesisIntegrationTests/Fixtures/iam-presenter-bundle.json')); assert d['presenters'][0]['aggregateRef'] == '<context-level>'"

# A7. 全 unit + integration tests PASS
swift build
swift test

# A8. install-skills regression（/presenter-fill v2 byte-identical mirror）
mkdir -p /tmp/phase1k2-install-test
./.build/debug/genesis install-skills --scope project --project-dir /tmp/phase1k2-install-test --force
grep -F 'QueryError' /tmp/phase1k2-install-test/.claude/skills/presenter-fill/SKILL.md

# A9. docs updates
grep -F 'Phase 1.k.2' docs/decisions.md
grep -F 'QueryError' docs/architecture.md
```

### Human 補做（需要人類介入）

- [ ] **Cross-agg E2E real swift build**：用 `iam-cross-agg-presenter-bundle.json` 跑 `genesis new` → 生成樹含 `Sources/{Context}/Adapter/<presenter>/<presenter>ApplicationService.swift` + `Sources/{Context}/Adapter/ApiHandler.swift` + `Sources/{Context}/Adapter/ApiComponents/ApiComponents+{Context}ApiError.swift` + `Sources/{Context}/openapi.yaml` + `Sources/{Context}/{Context}QueryError.swift`；對 cross-agg AS 跑 `/presenter-fill` 填 body；`swift build` → **Build complete**。
- [ ] **per-agg + cross-agg 共存 E2E**：合併 fixture（per-agg readModel + per-agg presenter + cross-agg readModel + cross-agg presenter）跑 `genesis new` → 確認 per-agg `{A}QueryError.swift` + context-level `{Context}QueryError.swift` 都 emit；`/presenter-fill` 兩個 AS 都填；build pass。
- [ ] **404 path runtime drill**（optional，需 KurrentDB）：spin up KurrentDB → 對 GET endpoint 用不存在的 key 打 → 確認回 404 + body 含 `.notFound`（而非 503 + serviceUnavailable）。
- [ ] **回歸 /presenter-fill v1 fixture**（per-agg `iam-presenter-fill-bundle.json`）：v2 SKILL.md 對該 fixture 仍能填出 compile-pass 的 body（throw 改用 `{A}QueryError` 而非 ProjectionReadInconsistency；既有 v1 fill 過的 tree 重跑 `/presenter-fill` → exit 0 idempotent）。
- [ ] **D1 reject 案例驗證**：手造 Case Y fixture（presenter.aggregateRef=per-agg + readModel.aggregateRef=context-level）→ `genesis new` 應 fail with bundleInvalid + clear message。
- [ ] **D4 reject 案例驗證**：手造 fixture（presenter scalar + elementType=Set<String>）→ `genesis new` 應 fail with bundleInvalid。

---

## 已知限制

1. **不 retro-upgrade /presenter-fill v1 既有 fills**：v1 用 ProjectionReadInconsistency 填過的 body 重跑 v2 會 exit 0 idempotent（structural invariant 視為「已填」），不會自動改 throw 為 QueryError。user 想升級需手 unfill + 重跑，或等未來 `--force` v2 flag。
2. **per-agg `{A}QueryError` 預設只 `notFound` case**：user 若要加 case（如 OC `AuditQuotingQueryError` 多種 not-applicable cases）需手 edit；future skill 可擴。
3. **`{A}Error` 不擴 notFound case**：D2 選擇統一用 QueryError，per-agg domain error enum 維持原 invariants-driven cases，不加 `.quotationNotFound` 之類（OC 有，Genesis bundle 抽象不保證）。
4. **multi-input-field / per-element transform 仍 defer**：Phase 1.k.2 不擴 /presenter-fill 的 input/output mapping 能力。
5. **OpenAPIArrayContainer scalar+Set 限制**：D4 在 bundle 層 reject，不嘗試 auto-map。user 想出 Set 須改 kind=array + elementType=primitive。
6. **Server wire-up 仍 defer**：context-level handler emit 但 Server 端 protocol 註冊由 user 手接（與 Phase 1.i 一致）。
7. **ApiComponents per-agg overloads 範圍**：context-level ApiComponents 的 `init?(from error: {A}Error)` overloads 涵蓋「在 cross-agg readModel.events 出現的 source aggregates」之 domain errors，不包含其他無關 aggregate（後者若 throw 到 context-level handler 走 fallback 503）。
8. **/presenter-fill v2 backwards compat**：v1 spec(`docs/tasks/2026-05-23-presenter-fill-skill.md`)維持 status=done；v2 為 in-place upgrade，registry status_history 加 entry。
9. **`single + collection elementType` 不阻擋（audit M2）**：D4 只攔 `scalar + collection`；若 user 設 `single + Set<X>` 或 `single + [X]`，OpenApiYamlRenderer 可能生壞 `$ref` 導致 build fail，v1 不主動 reject 此組合，user 自負（典型 single 應該配 DTO/primitive，非 collection）。
10. **`PresenterPlacement` 共用 helper 為單一真理（audit M3）**：所有 renderer 必須走此 helper 判 per-agg vs context-level；新增 renderer / 改動 placement 邏輯時須同步擴此 helper，避免分歧。
11. **依賴關係**：phase-1f / phase-1g / phase-1g.2 / phase-1h / phase-1i / phase-1k / 2026-05-23-presenter-fill-skill（全 done）。

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals（6 個明列）↔ Non-goals（7 條明列）互斥
- [x] depends_on: phase-1f / 1g / 1g.2 / 1h / 1i / 1k / presenter-fill v1（全 DONE）
- [x] A1-A9 Agent runnable；Human E2E 段獨立列（含 cross-agg / per+cross 共存 / 404 runtime / v1 回歸 / D1+D4 reject 五項）
- [x] 9 known limits 不與 acceptance 衝突
- [x] OC 雙軌制與 Genesis 端 4 renderer 改動逐一對齊（F1–F8 facts 全反映於 Step 1–11）
- [x] 「移植/重構」段（context-level Adapter 對齊 OC）已列 OC 真實 file structure 而非「對齊 OC」一句帶過

---

## Audit findings resolution (Codex external 2026-05-25)

4H + 7M + 1L，全套修進 spec：

| ID | 嚴重 | 問題 | 修法 | 反映於 |
|---|---|---|---|---|
| H1 | 高 | readModelRef missing/重名未處理；lookup 契約未定 | BundleParser validation 順序 (a) readModel name uniqueness + (b) readModelRef must exist + (c)(d) D1/D4 | §1 改動檔案 (a)-(d) |
| H2 | 高 | NewCommand path 錯（GenesisCore vs Genesis/Commands） | 全 spec 路徑替換 `Sources/Genesis/Commands/NewCommand.swift` | 改動檔案 / Step 2 等 |
| H3 | 高 | context-level handler 沿用 per-agg template 會帶入 repository / AggregateEventMapper 不存在符號 | 新 template `ApiHandlerContext.swift.template`，不含 repository | §5 / 改動檔案 |
| H4 | 高 | top-level swift-openapi-* deps 只看 anyAggregateHasWriteUC，presenter-only 場景 resolve fail | needsOpenApi 改為 includes read presenter；per-agg target 條件擴 hasWriteUC \|\| hasReadPresenter | §8 |
| H5 | 高 | /presenter-fill v2 Phase 1 glob 只 per-agg 路徑，context-level AS 定不到 | Phase 1 同時 Glob `Sources/*Aggregate/Adapter/` + `Sources/*/Adapter/`；推導 module + verify QueryError 存在 | §9 |
| M1 | 中 | ReadModelSpec.aggregateRef 為 optional 的 legacy 處理 | `resolvedReadModelAggregateRef` helper，nil + aggregateSpecId 解析；兩皆 nil reject | §1(c) |
| M2 | 中 | D4 collection detector 邊界（Array[...], Optional<Set<...>>） | `isCollectionType` helper trim + strip optional + 涵蓋 Array[/Dictionary[ 等 | §1(d) |
| M3 | 中 | per-agg vs context-level 判斷散落多處易分歧 | 共用 `PresenterPlacement` enum + `presenterPlacements(bundle:)` helper，所有 renderer 統一呼叫 | §5 |
| M4 | 中 | QueryErrorRenderer 缺 existingPaths（scaffold-once） | render 簽名加 `existingPaths: Set<String>`，已存在 skip | Step 2 |
| M5 | 中 | ApiComponents context overloads 與 per-agg pattern 不一致 | 加 `init(from error: ContextError<{A}Error>)` non-optional overloads 對齊 per-agg | §5 |
| M6 | 中 | context-level openapi 沿用 per-agg dynamic params 會多 operatorId/{A}Id | context-level openapi 獨立 param 收集，不加 operatorId/aggIdName | §7 |
| M7 | 中 | v2 known limit #2 解除語意需 scope 清楚 | 解除只適用 Phase 1.k.2 後新填或手動 unfill 後重填；v1 既有 fills 不 retro-upgrade | §9 / Non-goals |
| M8 | 中 | iam-presenter-bundle 改 context-level 後既有 testCrossAggregateSilentSkip flip 方向 | 改動檔案明列 PresenterRendererTests 既有測試 flip 為 reject 或 context-emit | 改動檔案 |
| L1 | 低 | spec 缺自己的 registry JSON 入改動檔案 | 改動檔案加 `docs/tasks/registry/phase-1k2-cross-aggregate-presenter.json` | 改動檔案 |

---

## Sign-off

- [x] write-spec output reviewed
- [x] **audit-spec pass — Codex external 2026-05-25**：4H+7M+1L 全套修進 spec。內部 4b/5b 全 PASS（line 錨點、Agent/Human 分段、無 ≥N、7 依賴 phase 皆 done）。
- [x] decisions.md ratification（Phase 1.k.2 條目）+ architecture.md §10.13
- [x] registry status: ready → **done**（實作 + real cross-agg E2E swift build PASS：`/tmp/pk2-e2e` 含 IAMContext.swiftmodule + GetUserAccessSummaryApplicationService.swift.o + GetUserAccessSummaryPresenter.swift.o + Adapter/ApiHandler.swift + ApiComponents+IAMContextApiError.swift + openapi.yaml + IAMContextQueryError.swift 全 compile pass。/presenter-fill v2 升級 SKILL.md byte-identical mirror。212/212 tests PASS（含 flip 後的 testCrossAggregateRoutesToContextAdapter）。）
