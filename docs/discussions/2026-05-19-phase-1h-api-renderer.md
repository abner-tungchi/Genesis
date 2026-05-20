# Phase 1.h — Genesis ApiRenderer codegen + DTO mapper extension

**Date**: 2026-05-19
**Status**: decisions locked, ready for write-spec
**Facts source**: Gemini agent investigation 2026-05-19 (`a5cb9099bc4ce000c`)；OC Adapter pattern 完整 12-section report
**Related**:
- `2026-05-18-api-skill.json` (status: ready, soon to be superseded → revise as AI-fill-only)
- `phase-1f-context-shared-infra.json` (done — `{Ctx}Shared/ApplicationService.swift` provides protocol)
- `phase-1g-readmodel-renderer.json` (done — pattern parallel for "codegen + AI fill" split)

---

## 1. Position vs existing /api skill spec

```
旧 model (2026-05-18-api-skill v2, status: ready):
  /api skill (all-AI)
    → 讀 7 個 inputs → fully write 4 個 Adapter files via template substitution

新 model (this Phase 1.h + revised /api skill v3):
  Phase 1.h ApiRenderer (codegen, Genesis CLI)
    → 讀 Service.swift + openapi.yaml + Error.swift + bundle.dtos[]
    → emit 4 個 scaffolds with TODO body markers
  ↓
  /api skill v3 (AI fill, ~100 lines SKILL.md, 從 200 縮)
    → 讀 既有 scaffold + 同樣 inputs
    → 只填 TODO body (execute() / payload conversion / error mapping)
```

---

## 2. OC facts highlights (per Gemini investigation)

詳見 `docs/discussions/2026-05-19-phase-1h-api-renderer-facts.md`（單獨存）或直接讀 agent transcript。要點：

### 2.1 ApplicationService 兩 variants

- **Variant A (simple)**：`EditEstimatedRevenueApplicationService.swift` — 無 payload extension；ApiHandler 內 inline 解 payload。AuditQuoting 26 個、QCG 19 個、CRQ 2 個。
- **Variant B (complex)**：`AddAccountingApplicationService.swift` — `extension XInput { init(from payload:) throws }` — 解 ISO8601 / Decimal / oneOf；ApiHandler `catch is Iso8601ParsingError`。AuditQuoting 19、CRQ 21、QCG 0。

**何時用 B**：openapi schema 有 throwable parsing (ISO8601 / Decimal string / oneOf union)。

### 2.2 No identifier DTO

OC 完全沒用 `typealias QuotingIdDto = String` 或 `struct QuotingId { let value }` — 所有 ID 都是 bare `String`。**Phase 1.h v1 沿用**：不 codegen identifier DTO 類型。

### 2.3 ApiHandler 跨 aggregate 不一致

| Aggregate | `<Storage>` generic? | `mapToApiError` branches |
|---|---|---|
| AuditQuoting (has multipart) | Yes | 1 (`<AuditQuotingError>`) |
| QCG (has multipart) | Yes | 1 |
| CRQ (no multipart) | No | 1 |
| Quotation (cross-agg reads) | No | 2 (`<QuotationError>` + `<QuotingCaseGroupingError>`) |

→ Codegen 需 conditional：multipart UC 偵測 → `<Storage>` generic；cross-agg domain error reachable → 多 branch。

**v1 scope decision**: 只支援 single-aggregate `<XError>` + no `<Storage>` generic (Variant A only)。Multipart + cross-agg defer v2.

### 2.4 ApiComponents+XApiError 模式

兩 inits：
- `init(from: ContextError<X>)` non-failable，fallback `.undefinedDomainError`
- `init?(from: X)` failable，exhaustive switch
  - 1:1 name match → `case .x: self = .x` (codegen)
  - 名字不同 OR 結構上永不觸發 → `case .x: return nil  // TODO(/api skill): confirm trigger` (codegen scaffold, AI fill comment)

### 2.5 Repository `private var` (computed)

每 handler call 重建 Repository — 不 cache。Codegen 必須用 `private var` 不是 `private let`。

### 2.6 `{A}AggregateEventMapper` is plugin-generated

Codegen 引用 `AuditQuotingAggregateEventMapper()` 但不 emit 此 type — 由 SwiftPM `ModelGeneratorPlugin` 在 build 時生。

### 2.7 DTO 三類

| 類 | 例 | codegen vs AI fill |
|---|---|---|
| Simple enum (no payload) | `AccountingTypeDto` 4 cases | **全 codegen**（case 對齊 + bi-directional mapper） |
| Composite struct (flat fields) | `CustomizedReportDto { id, name, description }` | **codegen 結構**；mapper body TODO (Date/Decimal/optional 判斷) |
| Discriminated union (oneOf) | `AccountingWorkItemDto` 11 cases with associated values | **defer v2** (complex `value1/value2` 解構)  |

---

## 3. Decisions

### D1 — Phase 1.h scope: Variant A + simple DTO codegen only

**Decision**: v1 covers：
- Variant A ApplicationService scaffold (no `init(from payload:)` extension)
- Simple ApiHandler skeleton (no `<Storage>` generic, single `mapToApiError` branch)
- ApiComponents+XApiError exhaustive switch (1:1 name match + TODO for diverged)
- Simple enum DTO mapper (full codegen)
- Composite struct DTO scaffold (mapper body TODO)

**Defer to Phase 1.h.2 or v2**:
- Variant B (`init(from payload:)` extension) — needs openapi schema parsing for ISO8601/Decimal/oneOf detection
- Multipart upload (`<Storage>` generic, `.created` response, `multipartForm` switch)
- Read UCs (`ContextError<XQueryError>`)
- Cross-aggregate `mapToApiError` branches (Quotation pattern)
- Discriminated union DTO (oneOf with `value1/value2`)
- API↔domain ID rename (`customizedReportingId` ↔ `reportId`)
- AS file bridge extensions (PriceServiceItems pattern)

**Rationale**:
- 矩陣分析 OC 各 aggregate 數量：Variant A 47 個、B 40 個。50/50 但 A 較簡單。
- Variant A scaffold 就足以 cover 大部分 simple write UC 場景
- v1 + v2 sequential，避免一次性吃完所有 audit findings

### D2 — Source of truth (per UC)

對每個 `Sources/<A>Aggregate/Usecase/Service/*Service.swift`，codegen 讀：

| Input | Source | 用途 |
|---|---|---|
| UC name | filename strip `Service.swift` | `{UC}`/`{ucCamel}`/`{ucPascal}` placeholders |
| Aggregate name | dirname (`<A>Aggregate/`) | `{A}` placeholder |
| Service Input fields | parse `<UC>Input.swift` (sibling at `Port/In/<UC>/`) | `{INPUT_FIELDS}`、AS Input fields |
| Aggregate ID field name | parse `<A>Aggregate/event.yaml` `aggregateRootId.alias` (any event) | `{AGG_ID_NAME}` (audit H2 fix in /api spec) |
| Endpoint operationId | parse `<A>Aggregate/openapi.yaml` paths → operations → operationId == ucCamel | `Operations.{ucCamel}.Input/Output` |
| Error cases | parse `<A>Aggregate/<A>Error.swift` enum cases | ApiComponents exhaustive switch |
| Context name | `bundle.context` | `{Ctx}` |

**Skip codegen if**:
- `<UC>Service.swift` 缺 → skip this UC（user 還沒跑 /usecase）
- `<UC>` matches `^Get` / `^List` / `^Find` → skip (read UC, v2)
- `openapi.yaml` 缺 / 沒對應 operationId → emit ApplicationService.swift but skip ApiHandler method (warn)
- `openapi.yaml` request body content type 含 `multipart/form-data` → skip ApiHandler method, emit warning + TODO file

### D3 — ApiHandler 同步創建 (audit H4 對齊)

**Decision**: First-invocation Phase 1.h emit 同 aggregate `Adapter/` 下：
1. `Adapter/<UC>/<UC>ApplicationService.swift` (per UC)
2. `Adapter/ApiHandler.swift` (per aggregate，含所有 UC 的 method)
3. `Adapter/ApiComponents/ApiComponents+<Ctx>ApiError.swift` (per aggregate)

**三者同步 emit** — 跟 /api skill v2 的 audit H4 fix 一樣（避免 ApiHandler 引用未存在的 `Components.Schemas.{Ctx}ApiError.init`）。

### D4 — Scaffold-once semantics (per Phase 1.g audit H6 pattern)

**Decision**: Same as Phase 1.g：
- `Adapter/<UC>/<UC>ApplicationService.swift` existing → skip (preserves AI-filled execute body)
- `Adapter/ApiHandler.swift` existing → 偵測 method 是否已存在；不存在則 append before marker；存在則 skip + warn
- `Adapter/ApiComponents/+XApiError.swift` existing → 偵測 case 是否在 switch；不存在則 insert；存在則 skip

NewCommand 掃 existing paths Set，傳入 ApiRenderer。

### D5 — DTO mapper codegen split

**Decision**: 擴 `DtoRenderer.swift`：
- 既有：bundle.dtos[] kind=enum / struct → emit basic type
- 新加：對每 enum DTO，emit `extension XDto { init(from: Domain) }` + reverse `extension Domain { init(from: XDto) }` (assume case names 1:1)
- 對每 struct DTO，emit `extension XDto { init(from: Domain) }` skeleton with `// TODO(/api skill): map field-by-field` body

**Cross-aggregate placement** (per OC §5.5)：
- bundle.dtos[] entries default 走 `Sources/<A>Aggregate/Adapter/Dto/` (per-aggregate)
- 若 bundle.dtos[].context-shared = true → `Sources/{Ctx}Shared/` (cross-aggregate)
- v1 default per-aggregate；context-shared 為 explicit opt-in

### D6 — bundle.dtos[] schema extension

**Decision**: 加 fields:

```json
{
  "dtoSpecId": "...",
  "name": "AccountingTypeDto",
  "kind": "enum",                    // existing: "enum" | "struct" (new: "union" defer v2)
  "fields": [...],                   // existing for struct
  "cases": ["auditCertification", ...],  // NEW for enum
  "domainTypeName": "AccountingType", // NEW: domain type for mapper generation
  "isContextShared": false,          // NEW: placement signal
  "needsThrowingMapper": false       // NEW: hint for cross-agg or unsafe cases (rare; v1 default false)
}
```

`isContextShared`: 預設 false (per-aggregate `Adapter/Dto/`)；true 時 emit 到 `{Ctx}Shared/`，但 mapper 限 simple enum (因 OCShared 不能依賴 aggregate types per §5.5 question 2)。

### D7 — Output file paths (canonical)

```
Sources/<A>Aggregate/Adapter/<UC>/
├── <UC>ApplicationService.swift                    # per UC
└── (DTO files if needed, e.g. AccountingTypeDto.swift)

Sources/<A>Aggregate/Adapter/Dto/
├── <X>Dto.swift                                    # per-aggregate DTO
└── <X>Dto+Domain.swift                             # domain↔DTO mapper (Phase 1.h codegen)

Sources/<A>Aggregate/Adapter/ApiComponents/
└── ApiComponents+<Ctx>ApiError.swift               # per-aggregate error mapping

Sources/<A>Aggregate/Adapter/
└── ApiHandler.swift                                # per-aggregate handler (含所有 UC method)

Sources/{Ctx}Shared/
└── <X>Dto.swift                                    # context-shared DTO (isContextShared=true 時)
```

### D8 — Template variable contract

| Placeholder | Source |
|---|---|
| `{Ctx}` | bundle.context |
| `{A}` | aggregate.name |
| `{UC}` | ucPascal |
| `{ucCamel}` | ucCamel |
| `{AGG_ID_NAME}` | event.yaml aggregateRootId.alias (1 event 取，全 event 應一致) |
| `{INPUT_FIELDS}` | parsed Service Input fields (excluding operatorId, ID) |
| `{ERROR_CASES_EXHAUSTIVE}` | parsed Error.swift cases，1:1 emit 或 TODO comment |
| `{ENUM_CASES}` | (for DTO) bundle.dtos[].cases |
| `{DOMAIN_TYPE_NAME}` | bundle.dtos[].domainTypeName |

### D9 — TODO marker format

統一格式（per Phase 1.g style）：
```swift
// TODO(/api skill): {what to fill}
```

Inserted in：
- `execute()` body of ApplicationService
- Inside ApiHandler method `try service.execute(input: <TODO>)` (placeholder for AS Input construction)
- ApiHandler method `.ok(.init(body: .json(.init(<TODO>))))` (placeholder for response field mapping)
- ApiComponents `case .x: return nil  // TODO(/api skill): confirm trigger`
- DTO struct mapper body

### D10 — Acceptance + real e2e

跟 Phase 1.g 同 pattern：
- Unit tests for ApiRenderer + DtoRenderer extension
- Integration test with fixture iam-api-bundle.json (含 Service.swift + openapi.yaml + Error.swift sources)
- **Real e2e swift build** — 對含 simple write UC bundle 跑 `genesis new` → output project 必須 compile pass (即使 TODO body 含 `fatalError("TODO")` 或 type-correct stub)

**TODO body 必須是 valid Swift**：codegen scaffold compile pass，AI 後續 fill。Choose `fatalError("TODO(/api skill): {message}")` 為佔位 — type-erase 滿足 any return type。

### D11 — Version bump

`0.1.0-phase1g2` → `0.1.0-phase1h`

### D12 — Known limitations

1. **Variant B defer v2**: 19/45 AuditQuoting UCs 需 `init(from payload:)`，v1 skip 這些（emit `// TODO(/api v2): payload extension for throwable parsing`）
2. **Multipart UC defer v2**: v1 偵測 `multipart/form-data` → skip method emit + warn
3. **Read UC defer v2**: `^Get|^List|^Find` → skip
4. **Cross-agg `mapToApiError` branches defer v2**: v1 single-branch
5. **Discriminated union DTO defer v2**: bundle.dtos[].kind == "union" → skip emit
6. **API↔domain ID rename defer v2**: 假設 same name
7. **AS bridge extensions defer v2**: 不 emit cross-context bridge code
8. **`<Storage>` generic 不在 v1 scaffold**: 等 multipart 在 v2 加進來時統一 refactor
9. **Hand-edited convention violations** (rawValue fallback in editAccountingType etc.) v1 不嘗試 codegen — emit baseline，user 自改
10. **`{A}AggregateEventMapper` 假設存在**: plugin 自動生；若 user 未配 plugin → swift build fail with explicit message
11. **bundle.context.streamPrefix 推導**: 跟 Phase 1.g `streamPrefix` resolution 共用 (含 alias map)

### D13 — Compatibility with existing /api skill v2

**Decision**: Phase 1.h ship 後立刻 supersede `2026-05-18-api-skill` (status ready → superseded)，再開新 `2026-05-19-api-skill-fill` (status: draft → spec) 改 AI fill scope。

或者：直接 in-place revise `2026-05-18-api-skill` (status ready → draft，重做 v3)。

**Lean**: in-place revise，保留 history。Phase 1.h depends_on 不含 /api skill（並行不相干）。

---

## 4. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | v1 scope = Variant A + simple DTO；defer B / multipart / read / union | 矩陣分析；scope discipline |
| D2 | Per-UC SSOT 7 個 input sources | mirror OC; deterministic |
| D3 | 3 files first-invocation synchronous (audit H4 對齊) | avoid build fail |
| D4 | Scaffold-once for all 3 files | Phase 1.g H6 pattern |
| D5 | DTO mapper codegen split (enum full vs struct scaffold) | 90% codegenable |
| D6 | bundle.dtos[] 加 4 個 fields | enable mapper generation |
| D7 | 4 output dirs canonical layout | mirror OC §5.5 |
| D8 | 9 template placeholders | covers v1 |
| D9 | Unified TODO marker | discoverability |
| D10 | Real e2e build acceptance | plugin invariant |
| D11 | Version → 0.1.0-phase1h | manifest convention |
| D12 | 11 known limits | honest scope |
| D13 | Revise /api skill v2 in place | preserve history |

---

## Next step

→ `/write-spec` Phase 1.h using above decisions.
