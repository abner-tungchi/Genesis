# Phase 1.h — Genesis ApplicationService scaffold + DTO mapper codegen (Variant A, narrow v2 scope)

> **Spec v2 — narrowed per Codex audit**. Original v1 scope (AS + ApiHandler + ApiComponents + DTO) required OpenAPIGenerator plugin + openapi.yaml infrastructure that Genesis bootstrap doesn't provide today. Audit H1+H3 揭露此 gap。**Defer ApiHandler + ApiComponents + openapi.yaml infrastructure to Phase 1.i**。

## 來源

討論：`docs/discussions/2026-05-19-phase-1h-api-renderer.md`
Gemini facts (2026-05-19, agent `a5cb9099bc4ce000c`)：OC Adapter 12-section report
Codex audit (2026-05-19, agent `ac4ff62ca58154cc3`)：4H+5M+1L finds — 4 of 5 mediums applied in this v2; HIGHs trigger scope narrow.

Ground truth refs：
- OC Variant A AS canonical：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/AuditQuotingAggregate/Adapter/EditEstimatedRevenue/EditEstimatedRevenueApplicationService.swift`
- OC enum DTO 全 codegen 範例：`OCShared/AccountingTypeDto.swift` + `Adapter/Dto/AccountingTypeDto+Domain.swift`

## 目標

per write UC（非 `^Get|^List|^Find`、bundle 有 useCase）emit Variant A simple ApplicationService scaffold；per bundle.dtos[] entry emit enum 全 mapper / struct scaffold mapper。

**Defer 給 Phase 1.i**：
- ApiHandler.swift / ApiComponents+Error.swift（需 openapi.yaml + OpenAPIGenerator plugin）
- openapi.yaml stub emission
- PackageRenderer 擴 OpenAPIGenerator plugin
- openapi-generator-config.yaml emission

**Real e2e 驗收**：對含 simple write UC + enum DTO 的 bundle 跑 `genesis new` → output project `swift build` PASS（AS scaffold 用 `fatalError("TODO")` 滿足 type）。

---

## 介面合約

### 新 file

| File | 性質 |
|---|---|
| `Sources/GenesisCore/ApiRenderer.swift` | NEW；public `render(bundle:contextName:adapter:existingPaths:) -> [(path,content,role)]`，pure function of bundle (no FileManager reads, 修 audit H2) |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template` | NEW |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/DtoEnumMapper.swift.template` | NEW (enum bi-directional mapper) |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/DtoStructMapper.swift.template` | NEW (struct scaffold) |

### 修改既有 file

| File | 修改 |
|---|---|
| `Sources/GenesisCore/DtoRenderer.swift` | 加 `dtoKind: enum` 路徑（既有 description 推斷保留作 fallback per audit M3）；emit bi-directional mapper for enum；scaffold for struct |
| `Sources/GenesisCore/FullBundle.swift` | DtoSpec 加 `dtoKind: String?` + `cases: [String]?` + `domainTypeName: String?` + `isContextShared: Bool?` (all optional for backwards-compat) |
| `Sources/GenesisCore/BundleParser.swift` | RawDto 加 decoding for 4 new fields；legacy `kind="DtoSpec"` 不衝突（new field 名 `dtoKind`，修 audit M3） |
| `Sources/GenesisCore/SharedTargetRenderer.swift` | **per audit M4**：條件式 emit DTO 到 `{Ctx}Shared` 仅當 `isContextShared==true`；否則 DTO 由 ApiRenderer 走 per-aggregate `Adapter/Dto/` |
| `Sources/Genesis/Commands/NewCommand.swift` | 加 ApiRenderer step 在 ContextProjectionModelRenderer 後 |
| `Sources/GenesisCore/Version.swift` | `0.1.0-phase1h` |

### ApiRenderer 公開介面 (audit H2 fix — pure function)

```swift
public enum ApiRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)]
}
```

**No FileManager reads** during render. All input from bundle (per audit H2 + M2).

行為：
1. 遍歷 `bundle.useCases` 過濾 write UCs (skip `^Get|^List|^Find`)
2. 對每 write UC：
   - 從 bundle 取 Service Input fields = `useCase.input` (excluding operatorId — convention)
   - 從 bundle 取 emitted event fields = `useCase.eventPayload`
   - 從 bundle 取 aggregate identityName = `aggregate.identityName` (修 audit M2 — 不 parse event.yaml；bundle 已含)
3. Scaffold-once: if path in `existingPaths` → skip
4. 對 bundle.dtos[] 各 entry：
   - dtoKind="enum" + cases=[...] → emit type + full bi-directional mapper
   - dtoKind="struct" + fields=[...] → emit type + scaffold mapper (TODO body)
   - dtoKind="union" → skip + warn (defer v2)
   - 缺 dtoKind → legacy description-based inference (existing DtoRenderer behavior)

### Validation rules

| Check | Failure |
|---|---|
| `useCases[].emittedEvent` matches aggregate.events | already enforced by BundleParser |
| Read UC (`^Get|^List|^Find`) | skip emit (silent) |
| bundle.dtos[].dtoKind == "union" | skip emit + warn (defer Phase 1.i.2) |

### `ApplicationService.swift` template (Variant A v1, audit M1 — operatorId LAST per OC)

```swift
import Foundation
{SharedImport}

package struct {UC}ApplicationServiceInput {
    package let {AGG_ID_NAME}: String
{INPUT_FIELDS}
    package let operatorId: String

    package init(
        {AGG_ID_NAME}: String{INIT_PARAMS_MID},
        operatorId: String
    ) {
        self.{AGG_ID_NAME} = {AGG_ID_NAME}
{INIT_ASSIGNMENTS}
        self.operatorId = operatorId
    }
}

package struct {UC}ApplicationServiceOutput {
    package let {AGG_ID_NAME}: String
}

package struct {UC}ApplicationService: ApplicationService {
    package typealias Input = {UC}ApplicationServiceInput
    package typealias Output = {UC}ApplicationServiceOutput

    private let repository: {A}Repository

    package init(repository: {A}Repository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        // TODO(/api skill): construct {UC}Service Input from `input` and call service.execute
        // Service Input fields are at Sources/{A}Aggregate/Usecase/Service/{UC}Service.swift
        fatalError("TODO(/api skill): execute body for {UC}ApplicationService")
    }
}
```

**Placeholder rules**：
- `{INPUT_FIELDS}`: 每 non-ID non-operatorId Service Input field → `    package let <name>: <Type>` (newline-separated)
- `{INIT_PARAMS_MID}`: 逗號開頭 + per non-ID non-operatorId field `, <name>: <Type>`
- `{INIT_ASSIGNMENTS}`: per non-ID non-operatorId field `        self.<name> = <name>`
- `{AGG_ID_NAME}` from bundle aggregate.identityName (audit M2 — bundle SSOT)
- 從 bundle.useCases[].input 取 fields 表 (audit M2 — no Swift parsing)
- 過濾 operatorId（v1 convention：每 AS 都加 operatorId 在 init 最後）

### Enum DTO mapper template (full codegen)

```swift
{SharedImport}

extension {DtoTypeName} {
    package init(from domain: {DomainTypeName}) {
        switch domain {
{ENUM_FROM_DOMAIN_CASES}
        }
    }
}

extension {DomainTypeName} {
    package init(from dto: {DtoTypeName}) {
        switch dto {
{ENUM_TO_DOMAIN_CASES}
        }
    }
}
```

`{ENUM_*_CASES}` per case `        case .{name}: self = .{name}`。

### Struct DTO mapper template (scaffold with TODO)

```swift
{SharedImport}

extension {DtoTypeName} {
    package init(from domain: {DomainTypeName}) {
{STRUCT_FROM_DOMAIN_FIELDS}
    }
}

extension {DomainTypeName} {
    package init(from dto: {DtoTypeName}) throws {
        // TODO(/api skill): map fields with type conversion (Date/Decimal/nested DTO)
        fatalError("TODO(/api skill): struct DTO toDomain for {DomainTypeName}")
    }
}
```

`{STRUCT_FROM_DOMAIN_FIELDS}` per field `        self.{name} = domain.{name}` (name match)。

### bundle.dtos[] schema extension (audit M3 — `dtoKind` not `kind`)

```json
{
  "dtoSpecId": "...",
  "kind": "DtoSpec",                 // existing legacy marker (不衝突 audit M3)
  "name": "AccountingTypeDto",
  "description": "...",
  "fields": [],                      // existing (struct mode)
  "dtoKind": "enum",                 // NEW: "enum" | "struct" | "union"
  "cases": ["foo", "bar"],           // NEW: when dtoKind=enum
  "domainTypeName": "AccountingType", // NEW
  "isContextShared": false           // NEW: false → per-aggregate, true → {Ctx}Shared (no mapper)
}
```

向後相容：
- 缺 `dtoKind` → 走既有 DtoRenderer description-based inference
- 缺 `domainTypeName` → 假設 = stripDtoSuffix(name) (e.g. `AccountingTypeDto` → `AccountingType`)
- 缺 `isContextShared` → false (per-aggregate default)

### Output file paths

```
# Per-aggregate (default)
Sources/<A>Aggregate/Adapter/<UC>/
└── <UC>ApplicationService.swift

Sources/<A>Aggregate/Adapter/Dto/
└── <X>Dto+Domain.swift                # enum mapper or struct scaffold

# Context-shared (isContextShared=true)
Sources/{Ctx}Shared/
└── <X>Dto.swift                       # bare enum/struct, no mapper (OCShared §5.5 rule)
```

**Note (audit M4 — DTO placement migration)**：當前 `SharedTargetRenderer` 把所有 `bundle.dtos[]` 走 `{Ctx}Shared`。Phase 1.h 改：
- `isContextShared==true` → 走 SharedTargetRenderer (既有 path)
- `isContextShared==false || nil` → 走 ApiRenderer per-aggregate (`Adapter/Dto/`)

**Aggregate assignment for per-aggregate DTO**：bundle.dtos[] 無 explicit `aggregateRef`，v1 假設 DTO 對應**全 aggregate**（每 aggregate 都收到一份）。Future v2 可加 `dtoSpec.aggregateRef` 精確 assign。

### Scaffold-once

NewCommand 掃 existing paths（per Phase 1.g.2 H6 pattern 擴）：
- `Sources/<A>Aggregate/Adapter/<UC>/<UC>ApplicationService.swift` existing → skip
- `Sources/<A>Aggregate/Adapter/Dto/<X>Dto+Domain.swift` existing → skip

擴 NewCommand `scanExistingPresenterPaths` → rename `scanExistingScaffoldPaths` 同時掃 Projector + Adapter dirs。

### NewCommand step ordering

```
1. parse bundle
2. AdapterApplier
3. AggregateRenderer loop
4. ContextLevelRenderer
5. SharedTargetRenderer (only emits Shared infra + context-shared DTOs per dtoKind/isContextShared)
6. ReadModelRenderer
7. ContextProjectionModelRenderer
8. [NEW] scan existing Adapter paths
9. [NEW] ApiRenderer.render(bundle, contextName, adapter, existingPaths)
10. PackageRenderer / ManifestRenderer
11. SourceWriter plan / commit
12. swift package resolve + build
```

### Output file roles

| Role | File |
|---|---|
| `applicationService` | `<UC>ApplicationService.swift` |
| `dtoEnumMapper` | `<X>Dto+Domain.swift` (enum, with mapper) |
| `dtoStructMapper` | `<X>Dto+Domain.swift` (struct, scaffold) |

---

## 驗收標準

### A1 — Renderer + 3 templates
```
test -f Sources/GenesisCore/ApiRenderer.swift
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/DtoEnumMapper.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/DtoStructMapper.swift.template
```

### A2 — Version bump
```
grep -F '0.1.0-phase1h' Sources/GenesisCore/Version.swift
! grep -F '0.1.0-phase1g2' Sources/GenesisCore/Version.swift
```

### A3 — Template content (audit M1 — operatorId LAST)
```
grep -F 'package struct {UC}ApplicationServiceInput' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template
grep -F ': ApplicationService' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template
grep -F 'TODO(/api skill)' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template
grep -F 'fatalError' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template
# Verify operatorId LAST in init (per OC)
grep -B1 'operatorId: String$' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template
```

### A4 — Unit tests
```
swift test --filter ApiRendererTests
```

涵蓋：
- testVariantAApplicationServiceShape (operatorId last per OC, fields from bundle.useCases.input)
- testEnumDtoMapperBidirectional (1:1 case names)
- testStructDtoScaffoldHasTodo
- testSkipsReadUC (^Get|^List|^Find)
- testScaffoldOnceSkipsExisting
- testContextSharedDtoGoesToShared (isContextShared=true)
- testPerAggregateDtoGoesToAdapterDto (isContextShared=false/nil)
- testUnionDtoSkippedWithWarn
- testLegacyDtoNoKindFalls Back (audit M3 backwards compat)

### A5 — Full suite green
```
swift test  # 既有 177+ tests + 新增 ~9 ApiRendererTests
```

### A6 — Integration: NewCommand 產 AS + DTO files
```
test -f Tests/GenesisIntegrationTests/Fixtures/iam-api-bundle.json
swift test --filter NewCommandTests/testApiScaffoldGenerated
```

assertions：
- `Sources/UserAccessProfileAggregate/Adapter/<UC>/<UC>ApplicationService.swift` 存在
- `Sources/UserAccessProfileAggregate/Adapter/Dto/EmployeeStatusDto+Domain.swift` 存在含 bi-directional mapper
- TODO markers + fatalError body present
- **不**含 `ApiHandler.swift` / `ApiComponents+Error.swift`（defer Phase 1.i）

### A7 — Real e2e swift build
```
GENESIS_RUN_E2E_BUILD=1 swift test --filter NewCommandTests/testApiE2EBuild
```

預期：codegen 全 compile pass（TODO fatalError 滿足 type system）。**因 narrow scope no openapi.yaml dependency**，不需 OpenAPIGenerator plugin。

### A8 — bundle.dtos[] schema extension
```
swift test --filter BundleParserFullTests/testDtoKindEnumWithCases
swift test --filter BundleParserFullTests/testDtoLegacyNoKindStillParses  # audit M3 compat
```

### A9 — DTO placement migration (audit M4)
Unit test：
- `isContextShared=true` enum DTO → `Sources/{Ctx}Shared/<X>Dto.swift` (bare, no mapper)
- `isContextShared=false` enum DTO → `Sources/<A>Aggregate/Adapter/Dto/<X>Dto+Domain.swift` (with mapper)
- 確認既有 SharedTargetRenderer 不再無條件 emit 所有 DTO 到 Shared

### A10 — docs ratification
```
grep -F 'Phase 1.h' docs/decisions.md
grep -F 'ApiRenderer' docs/architecture.md
```

### A11 — Idempotent re-run (scaffold-once 擴 Adapter dir)
Unit test：existing `Adapter/<UC>/<UC>ApplicationService.swift` → skip emit。

---

## 失敗路徑

| 場景 | 行為 |
|---|---|
| bundle.useCases[] 為空 | renderer 回 [] outputs |
| 全部 useCase 是 read UC | renderer 回 [] outputs |
| bundle.dtos[].dtoKind == "union" | skip emit + warn (defer v2) |
| bundle.dtos[] empty | renderer 不 emit DTO files (still emits AS) |
| existing path in existingPaths | scaffold-once skip emit |

---

## 已知限制（narrow scope v2）

1. **ApiHandler.swift defer Phase 1.i** — 需 OpenAPIGenerator plugin + openapi.yaml infrastructure，Phase 1.h 不處理
2. **ApiComponents+Error.swift defer Phase 1.i** — 同上
3. **openapi.yaml + openapi-generator-config.yaml stub emission defer Phase 1.i**
4. **PackageRenderer OpenAPIGenerator plugin extension defer Phase 1.i**
5. **Variant B (`init(from payload:)`) defer Phase 1.i.2** — v1 simple Variant A only
6. **Multipart UC defer Phase 1.i.2**
7. **Read UC defer Phase 1.i.2**
8. **Discriminated union DTO defer Phase 1.i.2**
9. **DTO 對 aggregate 的精確 assignment defer v2** — v1 假設 DTO 對全 aggregate（每 aggregate 都收一份 mapper）；future 加 `dtoSpec.aggregateRef`
10. **Mapper name 假設 1:1** — domain 跟 DTO case names 一致；name divergence (e.g. `domain.notFound` ↔ `dto.aggregateNotFound`) defer Phase 1.i 加 mapping schema
11. **API↔domain ID rename defer v2** — assume same name (per Phase 1.h v1 design)

---

## 實作步驟

1. 3 templates in `Sources/GenesisCore/Resources/Templates/v0.1/Api/`
2. `Sources/GenesisCore/FullBundle.swift` — DtoSpec 加 4 optional fields
3. `Sources/GenesisCore/BundleParser.swift` — RawDto decoding 加 4 new fields
4. `Sources/GenesisCore/ApiRenderer.swift` (~250 lines)
5. `Sources/GenesisCore/DtoRenderer.swift` 擴 — enum mapper + struct scaffold
6. `Sources/GenesisCore/SharedTargetRenderer.swift` — 條件 emit DTO 仅當 `isContextShared==true`
7. `Sources/Genesis/Commands/NewCommand.swift` — scan extension + ApiRenderer step
8. `Sources/GenesisCore/Version.swift` bump
9. New fixture `iam-api-bundle.json`
10. `ApiRendererTests.swift` (~200 lines, 9 tests per A4)
11. NewCommandTests `testApiScaffoldGenerated`
12. Existing version-pinned tests bump (`0.1.0-phase1g2` → `0.1.0-phase1h`)
13. docs/decisions.md + docs/architecture.md §10.7

---

## Audit findings resolution (v2 spec, post-Codex)

| ID | Severity | Issue | Fix in v2 |
|---|---|---|---|
| H1 | high | OpenAPIGenerator plugin missing → ApiHandler 無法 compile | **Scope narrow**: ApiHandler defer Phase 1.i；v2 emit AS + DTO only (no openapi dep) |
| H2 | high | ApiRenderer 從 FileManager 讀 same-run 未寫入檔案 | **Pure function of bundle** — 所有 inputs 從 bundle 取 (useCases.input, aggregate.identityName)，無 file reads |
| H3 | high | openapi.yaml 不 emit | Defer Phase 1.i 一起做 plugin + stub |
| H4 | high | Error case 1:1 build break | Defer Phase 1.i (ApiComponents 也 defer) |
| M1 | medium | operatorId 位置錯 | Template 改 operatorId LAST per OC verbatim alignment |
| M2 | medium | Service.swift regex 風險 | **Use bundle.useCases[].input** 為 SSOT，no Swift file parsing |
| M3 | medium | DtoSpec 既有 `kind="DtoSpec"` 衝突 new schema | **Rename to `dtoKind`** — 不衝突；legacy `kind` field 保留 (description-based inference fallback) |
| M4 | medium | SharedTargetRenderer 既有把全 DTO 放 Shared | Spec the migration — 條件式 emit based on `isContextShared` |
| M5 | medium | Adapter scan/append 行為矛盾 | **Defer to Phase 1.i** (no ApiHandler emit means no append behavior needed in 1.h) |
| L1 | low | fatalError wording 太廣 | **Narrow A7 wording** — fatalError 只在 AS execute + struct DTO toDomain |

---

## Sign-off requirements

- [ ] write-spec reviewed (this v2)
- [ ] audit-spec pass 1 (internal consistency)
- [ ] audit-spec pass 2 (Codex external) — done 2026-05-19, 4H+5M+1L (3 HIGH defer to 1.i; M1-M4 + L1 applied; M5 defers with H1)
- [ ] decisions.md ratification
- [ ] registry: draft → ready → done

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals (AS + DTO mapper) ↔ Non-goals (ApiHandler / ApiComponents / openapi.yaml / plugin) 互斥
- [x] depends_on: phase-1f (DONE — Shared infra)
- [x] Acceptance A1-A11 全 Agent runnable
- [x] All applicable Codex audit findings resolved or deferred with rationale
