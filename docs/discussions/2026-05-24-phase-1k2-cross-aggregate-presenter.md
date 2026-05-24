# Phase 1.k.2 — Cross-aggregate presenter + 連帶修正（facts + 待決策，2026-05-24）

## 任務定位

Phase 1.k.2 是 Phase 1.k 的「修補包」。/presenter-fill 開發過程沿路抓到 3 個 Phase 1.k 遺留：

- **A. cross-aggregate presenter 架構錯位** → read-side AS 與 projector 不同 module → circular dep → /presenter-fill exit 3 defer。
- **B. scalar + collection elementType openapi 錯配** → `Set<String>` 之類的 scalar output 在 OpenApiYamlRenderer.yamlType 走 array 分支，與 AS Output 型別錯配 → build fail。
- **C. read-side AS TODO 註解 hardcode per-agg projector path** → context-level 時 Reference 路徑指錯（人類誤導，不會 build fail，因 /presenter-fill 不依賴此行）。

## Facts gathered

### F1. OC ground truth — context-level 有完整 Adapter

`Sources/OpportunityContext/Adapter/` 內結構：

- write-side AS（CreateEstablishingQuotingCaseGrouping、AddQuotingCaseWorkflow、AddEstablishedQuotingCase、UploadEmbeddedImage、DownloadFile、QuotationHTML、GetQuotationPdf 等）
- read-side AS（GetTemplateVariables、GetAccountingSetup、GetQuotingCases、GetServiceScope、GetServiceItemsByQuotingBundleId、GetServiceItemDetail、GetPaymentSummary、GetBusinessClientAssistance、GetCustomerInfo）
- 完整的 `ApiHandler.swift`
- 完整的 `ApiComponents/` 目錄
- 完整的 `openapi.yaml`

→ **OC pattern：每 aggregate + 一個 context-level 各有獨立完整的 Adapter / ApiHandler / ApiComponents / openapi.yaml**。Genesis Phase 1.k.2 應對齊此 pattern。

### F2. 「cross-aggregate」其實有兩種 case（重要區分）

| Case | `presenter.aggregateRef` | `readModel.aggregateRef` | Phase 1.k 現行行為 | 問題 |
|---|---|---|---|---|
| **X** | `<context-level>` | `<context-level>` | PresenterRenderer 第 23 行 `if == "<context-level>" continue` → **silently skip**，AS 完全不生 | 一致但無法 serve cross-agg read |
| **Y** | `<A>`（per-agg） | `<context-level>` | 不 skip，AS 生在 `Sources/<A>Aggregate/Adapter/`，projector 在 `Sources/{Context}/Projector/` | **語意矛盾 + circular dep**：AS 在 {A}Aggregate 要 import context target 才能用 projector，但 context target 反過來依賴各 aggregate target → `Context → {A}Aggregate → Context` 循環 → SwiftPM 拒絕 |

iam-presenter-bundle 是 **Case Y**（GetUserAccessSummary 的 presenter.aggregateRef=UserAccessProfile，readModel.aggregateRef=<context-level>）。Phase 1.k e2e「build pass」只因 fatalError scaffold 不在可編譯碼 reference projector。

### F3. Genesis 端 4 個 renderer 現狀

| renderer | 當前行為 | 改動需求 |
|---|---|---|
| **PresenterRenderer** | Case X skip / Case Y 走 per-agg path（line 31） | 重設分流：依 `readModel.aggregateRef` 決定 AS 路徑（context-level → `Sources/{Context}/Adapter/`；per-agg → 維持原樣） |
| **ApiHandlerRenderer** | per-aggregate loop only，無 context-level handler | 新增 context-level emit（當 bundle 有 cross-agg presenter 時） |
| **OpenApiYamlRenderer** | per-aggregate loop only；scalar 分支對 collection elementType 走 array（line 219 `yamlType` 把 `Set<>`/`[`/`Array<` 都 map "array"）→ scalar+collection 錯配 | 新增 context-level openapi emit；scalar 對 collection elementType 改處理（reject vs auto-map） |
| **PackageRenderer** | context target 只配 projector resources（event.yaml / projection-model.yaml / event-generator-config.yaml） | context target 加 Adapter / ApiHandler / ApiComponents / openapi.yaml resources + OpenAPIGenerator plugin（當有 cross-agg presenter 時） |

### F4. TODO 註解 hardcode path（C）

`Templates/v0.1/Api/PresenterApplicationService.swift.template` line 25：

```
// Reference: Sources/{A}Aggregate/Usecase/Projector/{Name}/{Name}Presenter.swift
```

per-agg 正確，context-level 應為 `Sources/{Context}/Projector/`。修法：PresenterRenderer 傳 `{ProjectorRefPath}` placeholder 取代 hardcode `Sources/{A}Aggregate/Usecase/Projector/`。

### F5. {Context}Error 缺口

Phase 1.i 的 ApiComponents+<A>ApiError.swift 依賴 `{A}Error.swift`（domain error enum）。context-level 沒有對應的 {Context}Error。Phase 1.k.2 需新增 `{Context}Error.swift`（domain error enum），以使 `ApiComponents+{Context}ApiError.swift` 編得過。

實務上 context-level read 多半只 throw `ProjectionReadInconsistency`（不映射 domain error → 503），所以 {Context}Error 可為 empty enum（保留未來擴充空間）。

### F6. /presenter-fill v2 連動

Phase 1.k.2 把 cross-agg AS 搬到 `Sources/{Context}/Adapter/` 後，/presenter-fill 的 Phase 4（locate projector）邏輯：

- 現行：Glob `Sources/<A>Aggregate/**/<PresenterType>.swift`（同 module）→ Glob `Sources/*/Projector/**/<PresenterType>.swift`（context-level）→ exit 3。
- v2：context-level AS 路徑是 `Sources/{Context}/Adapter/`，與 `Sources/{Context}/Projector/` 同 module → 同 module 邏輯自動覆蓋 → exit 3 移除（cross-agg 變 happy path）。

→ /presenter-fill 改動很小（移除 cross-agg defer 分支 + 同 module 偵測 generalize），但 SKILL.md / known limits / fixture 需同步更新。

## 待決策

### D1（gating）：cross-agg 一致性規則 — Case Y 怎麼處理？

`presenter.aggregateRef = <A>` 但 `readModel.aggregateRef = <context-level>`（語意矛盾的組合）：

- **A. 強一致性（reject Case Y）**：BundleParser 或 /presenter skill 校驗 `presenter.aggregateRef` 須等於 `readModel.aggregateRef`。Case Y 拒絕，user 必須改 presenter.aggregateRef 為 `<context-level>`。乾淨、無歧義；但 break iam-presenter-fill-bundle 現有 fixture（需修 fixture）。
- **B. 寬鬆（auto-route）**：PresenterRenderer 依 readModel.aggregateRef 決定 AS 路徑（覆寫 presenter.aggregateRef 的意圖）。維持既有 bundle 相容，但 presenter.aggregateRef 字段「假性」失去意義（per-agg 值會被 readModel 改寫）。

### D2：{Context}Error.swift 形狀

- **A. empty enum**：`package enum {Context}Error: Error, Equatable {}` — 編得過，ApiComponents+{Context}ApiError 的 switch 為空（empty exhaustive → `default: return nil`，與 Phase 1.i 空 invariants 同模式）。為未來預留擴充。
- **B. 完全不生 {Context}Error + 不生 ApiComponents+{Context}ApiError**：context-level ApiHandler 不做 ContextError<E> 映射，所有 error 走 `default → .serviceUnavailable` 503。最小骨架，但 read-side AS 若 throw 任何 ContextError 將 silently 503（無 mapToApiError 中介），future 加 domain error 時要回頭補。

### D4：openapi scalar 配 collection elementType 怎麼處理？

- **A. reject in validation**：PresenterRenderer / OpenApiYamlRenderer 偵測 `output.kind=scalar` + elementType 是 collection（`Set<>` / `Array<>` / `[` prefix / `Dictionary<>`） → throw bundle invalid。user 必須用 `kind=array` 或改 elementType。簡單明確；break iam-presenter-fill-bundle 若 user 真想出 Set。
- **B. auto-map Set<X> → array + uniqueItems:true**：OpenApiYamlRenderer 對 scalar+Set 特例輸出 `type: array, items: ..., uniqueItems: true`，AS Output 保留 Set<X>。需驗 OpenAPIGenerator plugin 是否支援這對應（可能仍視為 `[X]` Swift type → 與 Set<X> Output 型別錯配）。風險高。
- **C. defer — v1 不修 B**：保留現狀錯配，known limit 寫明「scalar 不可配 collection elementType」。最保守，但與 Phase 1.k.2「修補包」定位不符。

### D-aux（直接定，無需問）

- **D3 Server target Hummingbird wire-up**：**out of scope**（Phase 1.i 既有 defer 持續），維持「emit handler，user 自接 Server」。
- **D5 TODO 註解 path fix**：**直接修**（trivial）。
- **D6 /presenter-fill v2 連動**：**順手修**（exit 3 移除 + same-module 邏輯 generalize + non-optional nil 升級 QueryError 404），SKILL.md 跟著改。

---

## 第二輪 OC 深探（2026-05-25）— 補抓 QueryError 雙軌制

User 質疑「是否有完整參考 OC」，回頭做第二輪實證探勘，發現 OC 真正的 read-side error pattern 比 v1 認知豐富：

### F7. OC error 雙軌制（per-agg + context-level 都有）

| OC 真實 | per-aggregate | context-level |
|---|---|---|
| domain error（invariants） | `{A}Error.swift`（write-side） | **無**（OC 沒有 context-level domain error） |
| **query error（read-side not-found）** | **`{A}QueryError.swift`** — `AuditQuotingQueryError`、`QuotingCaseGroupingQueryError`、`QuotingCaseQueryError`（一個 aggregate 可多個） | **`{Context}QueryError.swift`** — `OpportunityContextQueryError` |
| handler 404 catch | `catch ContextError<{A}Error> where ... .{notFound} → .notFound`（domain notFound case 也用）+ `catch ContextError<{A}QueryError> where ...` | `catch ContextError<{Context}QueryError> where ...` |

### F8. /presenter-fill v1 known limit #2 的根因

v1 用 `ProjectionReadInconsistency → 503` 是因為當時：
- Genesis 沒生 `{A}QueryError`（per-agg）也沒生 `{Context}QueryError`（context-level）
- Phase 1.k codegen 的 read method 沒有 404 catch

→ 「無 404 path」實則是 Phase 1.k codegen 缺口，不是 OC 限制。Phase 1.k.2 補齊後 /presenter-fill v2 可升級 throw QueryError → 404。

---

## 決策（user 2026-05-25）

- **D1 = A 強一致性 reject Case Y**（OC 隱含 co-location 規則）。BundleParser 校驗 `presenter.aggregateRef == readModel.aggregateRef`，不符 throw bundle invalid。
- **D2 = 完整對齊 OC（full QueryError 雙軌制）**。Phase 1.k.2 一次到位：
  - emit per-agg `{A}QueryError.swift`（aggregate 有 read presenter 時）+ context-level `{Context}QueryError.swift`（bundle 有 cross-agg presenter 時），各預設 `case notFound`。
  - emit context-level `ApiComponents+{Context}ApiError.swift`（含 init?(from error: {Context}QueryError) + init?(from error: {A}Error) per-agg overloads，OC pattern）。
  - ApiHandlerReadMethod template 加 `catch ContextError<{X}QueryError> where ... .notFound → .notFound` 404 catch（先於 mapToApiError catch-all）。
  - /presenter-fill v2：non-optional nil 升級為 `throw ContextError<{X}QueryError>(error: .notFound, ...)`（per-agg → `{A}QueryError`、context-level → `{Context}QueryError`），取代 ProjectionReadInconsistency。known limit #2 解除。
- **D4 = A reject scalar+collection elementType**（OC AS Output 一律 openapi 可表達型別，無 Set<X> 直出）。BundleParser 或 OpenApiYamlRenderer 校驗。

---

## Phase 1.k.2 完整 scope（locked）

1. **Bundle schema 校驗**：`presenter.aggregateRef == readModel.aggregateRef` 必須一致（D1）；scalar output elementType 禁 collection（D4）。
2. **PresenterRenderer**：AS 路徑依 readModel.aggregateRef 路由 — per-agg → `Sources/{A}Aggregate/Adapter/`；context-level → `Sources/{Context}/Adapter/`。TODO Reference path 條件化（per-agg / context-level 不同 path）。
3. **QueryError emission**（新）：
   - per-aggregate：`Sources/{A}Aggregate/{A}QueryError.swift`（aggregate 有 read presenter 時），預設 `case notFound`。
   - context-level：`Sources/{Context}/{Context}QueryError.swift`（bundle 有 cross-agg presenter 時），預設 `case notFound`。
4. **ApiHandlerRenderer**：emit context-level `ApiHandler.swift` + `ApiComponents+{Context}ApiError.swift`（後者 multi-branch import 各 aggregate target、做 per-agg error overloads + QueryError overload）。
5. **ApiHandlerReadMethod template**：在 mapToApiError catch-all 前插入 `catch ContextError<{X}QueryError> where error.error == .notFound { return .notFound(...) }` 404 catch。{X} 依 handler 所在 module 選 per-agg 或 context-level。
6. **OpenApiYamlRenderer**：emit context-level `Sources/{Context}/openapi.yaml` + config（含 cross-agg GET endpoints + ApiError schema with 404）；reject scalar+collection elementType；新增 `.notFound` 到 openapi ApiError enum + response codes。
7. **PackageRenderer**：context target 加 Adapter 子樹 resources（openapi.yaml / config / ApiHandler / ApiComponents） + OpenAPIGenerator plugin（bundle 有 cross-agg presenter 時）。
8. **/presenter-fill v2**：cross-agg exit 3 移除；non-optional nil throw `ContextError<{X}QueryError>(error: .notFound, ...)` 取代 ProjectionReadInconsistency；known limit #2 解除；SKILL.md 與 acceptance 同步。
9. **Fixture**：iam-presenter-bundle.json 修 presenter.aggregateRef 為 `<context-level>` 對齊 D1；新增 cross-agg e2e fixture。
10. **Tests**：新 renderer tests、BundleParser validation tests、/presenter-fill regression。
11. **Real e2e**：cross-agg presenter end-to-end → `swift build` PASS + 驗證 404 path works。

下一步：write-spec → audit-spec → pickup。預估 spec 規模類似 Phase 1.h+1.i 合併。
