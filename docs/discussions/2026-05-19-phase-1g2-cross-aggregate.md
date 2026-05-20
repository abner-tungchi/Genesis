# Phase 1.g.2 — Cross-aggregate ReadModel codegen design discussion

**Date**: 2026-05-19
**Status**: decisions locked, ready for write-spec
**Related**:
- `phase-1g-readmodel-renderer.json` (done — established per-aggregate path + identified this scope as defer)
- `2026-05-18-readmodel-skill.json` (done — bundle.readModels[] supports `aggregateRef = "<context-level>"`)
- Phase 1.g audit H4 + H5：完整指出 cross-aggregate 需 `{Context}` SwiftPM target + multi-aggregate imports

---

## 1. OC ground truth (from Phase 1.g audit recon)

OC `OpportunityContext` target 設置：

```swift
.target(name: "OpportunityContext",
        dependencies: [
            "QuotingCaseGroupingAggregate",
            "AuditQuotingAggregate",
            "CompanyRegistrationQuotingAggregate",
            "QuotationAggregate",
            "OCShared",
            .product(name: "DDDKit", package: "swift-ddd-kit"),
            ...
        ],
        resources: [
            .process("event.yaml"),                   // {} 空
            .process("projection-model.yaml"),        // 4 個 cross-agg entries
            .process("event-generator-config.yaml"),  // dependencies 列所有 aggregate
            .process("openapi.yaml"),
            .process("openapi-generator-config.yaml"),
        ],
        plugins: [
            .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            .plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit"),
        ]
)
```

Cross-aggregate Presenter 範例（`Sources/OpportunityContext/Projector/GetSelectedServiceItems/GetSelectedServiceItemsPresenter.swift`）：

```swift
import DDDCore
import EventSourcing
import KurrentSupport
import OCShared
import AuditQuotingAggregate              // ← multi-aggregate import
import CompanyRegistrationQuotingAggregate // ← multi-aggregate import
```

Cross-aggregate `event-generator-config.yaml`:

```yaml
accessModifier: package
dependencies:
  - AuditQuotingAggregate
  - CompanyRegistrationQuotingAggregate
  - QuotingCaseGroupingAggregate
  - OCShared
```

→ `dependencies:` 是必要的：plugin 看 event.yaml 是空 `{}`，需 deps 解 cross-aggregate event types。

---

## 2. Decisions

### D1 — Conditional `{Context}` SwiftPM target

**Decision**: PackageRenderer 在 bundle 有**任何** `aggregateRef = "<context-level>"` readmodel 時，emit 新 `{Context}` SwiftPM target；否則不 emit。

**Rationale**:
- 純 per-aggregate bundle 不需要 context target（避免空 target 污染）
- Conditional 跟 Phase 1.f `needsShared` 不同（Shared 是 universal，Context target 是 opt-in）
- 跟 Phase 1.g 對齊：renderer 不為了 v1.g.2 而 emit context files when not needed

### D2 — Context target resources & plugins

**Decision**：
- Resources: 3 yamls
  - `event.yaml` = `{}`（empty — context target 不發 events）
  - `projection-model.yaml`（所有 context-level entries）
  - `event-generator-config.yaml`（含 dependencies 列所有 aggregate 名 + Shared）
- Plugins: `ModelGeneratorPlugin` only
- Deps: 所有 aggregate targets + `{Context}Shared` + DDDKit

**Defer**:
- OpenAPIGenerator 跟 openapi.yaml 不在 v1.g.2 scope（cross-agg context-level API 是另一塊事，後續 phase 處理）
- 不寫 openapi-generator-config.yaml

**Rationale**:
- Minimum viable: 滿足 ModelGeneratorPlugin 需要的 3 yaml + deps
- OpenAPI 屬於 `/api` skill 領域；context-level API 不是 Phase 1.g.2 焦點

### D3 — Multi-aggregate imports in cross-aggregate Presenter

**Decision**: Renderer 從 `entry.eventRefs[].sourceAggregate` 取 unique set → 每個 emit `import {Agg}Aggregate`。

**Template placeholder**: 新 `{AggregateImports}`（multi-line）。對 per-aggregate readmodel **空字串**；對 cross-aggregate 包含 N 行。

範例：events = `[(AccountingTypeEdited, AuditQuoting), (ServiceItemSelected, QuotingCaseGrouping)]` →

```swift
import AuditQuotingAggregate
import QuotingCaseGroupingAggregate
```

### D4 — Cross-aggregate path layout

**Decision**:

```
Sources/{Context}/Projector/Get{Noun}/
├── {Noun}ReadModel.swift
└── Get{Noun}Presenter.swift
Sources/{Context}/event.yaml                  # {} empty
Sources/{Context}/projection-model.yaml       # all context-level entries
Sources/{Context}/event-generator-config.yaml # deps list
projections/{ProjectionStreamPrefix}Get{Noun}Projection.js
```

**Per Phase 1.f + 1.e 既有**: `Sources/{Context}/{Context}ListenerError.swift` (Phase 1.e) 已存在；新 target 包含此 file（同 dir）。

### D5 — New renderer split

**Decision**: 新增 `Sources/GenesisCore/ContextProjectionModelRenderer.swift` 處理 cross-aggregate yaml 跟其他 context target resources：

```swift
public enum ContextProjectionModelRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String
    ) throws -> [(path: String, content: String, role: String)]
}
```

Outputs（only if has context-level entries）：
- `Sources/{Context}/event.yaml` (= `{}`)
- `Sources/{Context}/projection-model.yaml`（cross-agg entries）
- `Sources/{Context}/event-generator-config.yaml`（deps）

如無 context-level entries → 回空 [] 不 emit。

### D6 — `ReadModelRenderer` 解除 cross-aggregate reject

**Decision**: 改 Phase 1.g 的 `throw` → 走 cross-aggregate dispatch path：
- 路徑 = `Sources/{Context}/Projector/Get{Noun}/`
- `{AggregateImports}` placeholder 填 from unique sourceAggregate set
- 其他 placeholders 跟 per-aggregate 共用

scaffold-once 跟 schema validation 保留不變。

### D7 — `PackageRenderer` 擴展

**Decision**: PackageRenderer 加 conditional context target emission：

1. 偵測 `bundle.readModels.contains { $0.aggregateRef == "<context-level>" }`
2. 若有 → emit `{Context}` target with deps + resources + plugins
3. 加 product line（`.library(name: "{Context}", targets: ["{Context}"])`）— optional，看是否要 expose

**Template**: 新 `PackageContextTarget.swift.template`：

```swift
.target(name: "{ContextName}",
        dependencies: [
{AggregateDeps}
            .target(name: "{ContextName}Shared"),
            .product(name: "DDDKit", package: "swift-ddd-kit"),
        ],
        resources: [
            .process("event.yaml"),
            .process("projection-model.yaml"),
            .process("event-generator-config.yaml"),
        ],
        plugins: [
            .plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit"),
        ]),
```

`{AggregateDeps}` 用 bundle aggregate names 動態填。

### D8 — `event-generator-config.yaml` content

**Decision**: Content for context target：

```yaml
accessModifier: package
dependencies:
  - {Agg1}Aggregate
  - {Agg2}Aggregate
  - ...
  - {Context}Shared
```

`dependencies` 列所有 bundle aggregates + Shared。**不**依 readmodel 實際引用過濾（保守）。

### D9 — Acceptance & e2e

**Decision**: 跟 Phase 1.g 同樣 pattern：
- Unit tests for ReadModelRenderer cross-agg path + ContextProjectionModelRenderer + PackageRenderer context target
- Integration tests with fixture (`iam-readmodel-cross-bundle.json` — 新 fixture 加 cross-agg entry)
- **真 e2e swift build** 驗證 plugin + multi-aggregate Presenter compile

### D10 — Version bump

**Decision**: `0.1.0-phase1g2`（或 `0.1.0-phase1g.2`？— Swift package version 不允許 `.2`，採 `0.1.0-phase1g2`）

### D11 — Known limitations

1. **Context-level OpenAPI defer**: openapi.yaml + OpenAPIGenerator plugin 不在 scope；context-level HTTP handlers 留 `/api` skill 處理 (future)
2. **`{Context}` target 跟 Phase 1.e ContextLevelRenderer 既有 file 衝突風險**: Phase 1.e 寫 `Sources/{Context}/{Context}ListenerError.swift`；新 target 會包含此 file（properly 屬於同 target）— 不衝突，但 ListenerError 改成屬於 context target 而非無 target
3. **Conditional emit**: 若 bundle 無 context-level readmodel，現在 Phase 1.e 的 `{Context}/...` files 仍 orphan（無 target）— **pre-existing issue not in 1.g.2 scope**；future cleanup
4. **Cross-aggregate `aggregateSpecId` 不可推**: ReadModelSpec.aggregateSpecId 是 nil（context-level）；renderer 內部不依賴此 field
5. **Multi-source JS `fromStreams`** 已在 Phase 1.g 處理（unique sourceAggregate set）— 1.g.2 不變

---

## 3. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | Conditional context target emit | Avoid empty target pollution |
| D2 | Minimum resources/plugins (3 yamls + ModelGeneratorPlugin) | Scope discipline; defer OpenAPI |
| D3 | Multi-aggregate imports from sourceAggregate set | Match OC pattern |
| D4 | Path layout `Sources/{Context}/Projector/Get{Noun}/` | Match OC convention |
| D5 | New ContextProjectionModelRenderer split | Single responsibility |
| D6 | Lift Phase 1.g cross-aggregate reject | Implementation goal |
| D7 | PackageRenderer conditional context target | One source of truth for SwiftPM |
| D8 | event-generator-config.yaml deps = all aggregates + Shared | Conservative (plugin needs visibility) |
| D9 | Real e2e build acceptance | Plugin invariant verification |
| D10 | Version → 0.1.0-phase1g2 | Manifest convention |
| D11 | 5 known limits | Honest scope |

→ `/write-spec` next.
