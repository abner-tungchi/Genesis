# Phase 1.g.2 — Cross-aggregate ReadModel codegen

## 來源

討論：`docs/discussions/2026-05-19-phase-1g2-cross-aggregate.md`

Ground truth refs：
- OC OpportunityContext target：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Package.swift`（target definition + resources + plugins）
- OC cross-aggregate Presenter：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/OpportunityContext/Projector/GetSelectedServiceItems/GetSelectedServiceItemsPresenter.swift`
- OC context-level resources：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/OpportunityContext/{event,projection-model,event-generator-config}.yaml`
- Phase 1.g spec：`docs/tasks/phase-1g-readmodel-renderer.md`（reject path 待解除）

## 目標

擴 Phase 1.g codegen path 支援 cross-aggregate readmodel（`aggregateRef = "<context-level>"`）：

1. **PackageRenderer 條件式 emit `{Context}` SwiftPM target** — 當 bundle 有任何 context-level readmodel
2. **新 `ContextProjectionModelRenderer`** emit 3 個 context-level yaml resources（`event.yaml`、`projection-model.yaml`、`event-generator-config.yaml`）
3. **`ReadModelRenderer` 解除 cross-aggregate reject** — Swift files 走 `Sources/{Context}/Projector/Get{Noun}/`，Presenter 加 multi-aggregate imports
4. **Version bump → `0.1.0-phase1g2`**

**真 e2e 驗收**：對含 cross-aggregate readmodel 的 bundle 跑 `genesis new` → output project `swift build` PASS。

---

## 介面合約（Interface Contract）

### 新增 type / file

| File | 性質 |
|---|---|
| `Sources/GenesisCore/ContextProjectionModelRenderer.swift` | NEW；public `render(bundle:contextName:)` |
| `Sources/GenesisCore/Resources/Templates/v0.1/Context/event.yaml.template` | NEW；content = `{}` |
| `Sources/GenesisCore/Resources/Templates/v0.1/Context/event-generator-config.yaml.template` | NEW |
| `Sources/GenesisCore/Resources/Templates/v0.1/PackageContextTarget.swift.template` | NEW；SwiftPM context target block |

### 修改既有 file

| File | 修改 |
|---|---|
| `Sources/GenesisCore/ReadModelRenderer.swift` | 解除 cross-aggregate reject；加 `{AggregateImports}` 渲染；分歧 path 計算 per-agg vs context-level |
| `Sources/GenesisCore/PackageRenderer.swift` | 條件式 emit context target；產品線新增 `{Context}` library product |
| `Sources/GenesisCore/Resources/Templates/v0.1/Projector/Presenter.swift.template` | 加 `{AggregateImports}` placeholder（per-agg 為空、context-level 多行） |
| `Sources/Genesis/Commands/NewCommand.swift` | call 新 ContextProjectionModelRenderer 在 ReadModelRenderer 後 |
| `Sources/GenesisCore/Version.swift` | bump `0.1.0-phase1g2` |

### 觸發條件

```
hasContextLevel = bundle.readModels.contains { $0.aggregateRef == "<context-level>" }
```

`PackageRenderer` 跟 `ContextProjectionModelRenderer` 都依此判斷 emit。

### ReadModelRenderer dispatch (revised)

```swift
let projectorDir: String
let aggregateImports: String

if aggRef == "<context-level>" {
    projectorDir = "Sources/\(contextName)/Projector/\(entry.name)"
    let uniqueSources = Array(Set(entry.eventRefs.map(\.sourceAggregate))).sorted()
    aggregateImports = uniqueSources
        .map { "import \($0)Aggregate" }
        .joined(separator: "\n")
} else {
    projectorDir = "Sources/\(aggRef)Aggregate/Usecase/Projector/\(entry.name)"
    aggregateImports = ""  // per-aggregate readmodel 不需 multi-import
}
```

Placeholder substitution：Presenter template 加 `{AggregateImports}`。

### Context target template (canonical shape per OC)

```swift
.target(name: "{ContextName}",
        dependencies: [
{AggregateDepLines}
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

`{AggregateDepLines}`：每 aggregate `            .target(name: "{Agg}Aggregate"),` 一行。

### Product line addition (conditional)

```swift
.library(name: "{ContextName}", targets: ["{ContextName}"]),
```

只在 hasContextLevel 時加；否則跳過。

### ContextProjectionModelRenderer outputs

```
[
    ("Sources/{Context}/event.yaml", "{}\n", "contextEventYaml"),
    ("Sources/{Context}/projection-model.yaml", <entries>, "contextProjectionModel"),
    ("Sources/{Context}/event-generator-config.yaml", <deps>, "contextGeneratorConfig"),
]
```

當無 context-level readmodels → 回空 [] 不 emit。

### Context projection-model.yaml entries

對 bundle.readModels 過濾 `aggregateRef == "<context-level>"` 後對每個 emit:

```yaml
{Name}:
  model: readModel
  events:
{EventList}
```

`{EventList}` 用 normalized UpperCamel event names + sourceAggregate hint as comment（可選）。

### event-generator-config.yaml content

```yaml
accessModifier: package
dependencies:
{AggregateDepsList}
  - {ContextName}Shared
```

`{AggregateDepsList}`：每 aggregate `  - {Agg}Aggregate` 一行；全 bundle aggregates。

---

## 驗收標準（Acceptance Criteria）

### A1 — New renderer + 3 templates exist
```
test -f Sources/GenesisCore/ContextProjectionModelRenderer.swift
test -f Sources/GenesisCore/Resources/Templates/v0.1/Context/event.yaml.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Context/event-generator-config.yaml.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/PackageContextTarget.swift.template
```

### A2 — Version bump
```
grep -F '0.1.0-phase1g2' Sources/GenesisCore/Version.swift
! grep -F '0.1.0-phase1g\b' Sources/GenesisCore/Version.swift  # exact phase1g without -2 suffix
```

### A3 — ReadModelRenderer no longer rejects cross-aggregate
```
! grep -F 'Phase 1.g.2 待開' Sources/GenesisCore/ReadModelRenderer.swift
# Validates the v1 reject branch removed
```

### A4 — Presenter template has AggregateImports placeholder
```
grep -F '{AggregateImports}' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Presenter.swift.template
```

### A5 — Package context target template content
```
grep -F '.target(name: "{ContextName}"' Sources/GenesisCore/Resources/Templates/v0.1/PackageContextTarget.swift.template
grep -F 'ModelGeneratorPlugin' Sources/GenesisCore/Resources/Templates/v0.1/PackageContextTarget.swift.template
grep -F 'event-generator-config.yaml' Sources/GenesisCore/Resources/Templates/v0.1/PackageContextTarget.swift.template
```

### A6 — Unit tests
```
swift test --filter ReadModelRendererTests
swift test --filter ContextProjectionModelRendererTests
swift test --filter PackageRendererTests
```

涵蓋：
- testCrossAggregateGoesToContextDir (lifted)
- testCrossAggregateAggregateImports
- testContextProjectionModelYaml
- testContextEventGeneratorConfigYaml
- testPackageRendererEmitsContextTargetWhenContextLevelReadmodel
- testPackageRendererSkipsContextTargetWhenNoCrossAgg
- testContextLevelReadModelInProjectorDir

### A7 — Full test suite green
```
swift test  # 170+ tests still PASS + 新增測試
```

### A8 — Integration test
```
test -f Tests/GenesisIntegrationTests/Fixtures/iam-readmodel-cross-bundle.json
swift test --filter NewCommandTests/testCrossAggregateReadmodelGenerated
```

assertions：
- `Sources/IAMContext/Projector/Get<Noun>/` 目錄存在
- `Sources/IAMContext/Projector/Get<Noun>/<Noun>ReadModel.swift` 存在
- `Sources/IAMContext/Projector/Get<Noun>/Get<Noun>Presenter.swift` 存在
- Presenter 含 `import {Agg1}Aggregate` + `import {Agg2}Aggregate`
- `Sources/IAMContext/event.yaml` 存在 (= `{}`)
- `Sources/IAMContext/projection-model.yaml` 存在 + 含 entry
- `Sources/IAMContext/event-generator-config.yaml` 存在 + 含 dependencies
- `Package.swift` 含 `.target(name: "IAMContext"`

### A9 — Real e2e swift build
```
GENESIS_RUN_E2E_BUILD=1 swift test --filter NewCommandTests/testCrossAggregateE2EBuild
```
or manual via `genesis new` + `swift build` on /tmp/phase1g2-e2e。

### A10 — Conditional emission
Unit test：bundle 無 context-level readmodel → PackageRenderer 不 emit context target、ContextProjectionModelRenderer 回空 [] 。

### A11 — Schema integrity preserved
ReadModelRenderer 仍 throw on：
- missing `key`
- empty `eventRefs`
- unknown `aggregateRef`（不在 bundle.aggregates[] 也不是 `<context-level>`）
- cross-agg event 的 sourceAggregate 不在 bundle

### A12 — docs ratification
```
grep -F 'Phase 1.g.2' docs/decisions.md
grep -F '{Context}' docs/architecture.md  # context target mention
grep -F 'ContextProjectionModelRenderer' docs/architecture.md
```

---

## 失敗路徑

| 場景 | 行為 |
|---|---|
| bundle 無 context-level readmodel | ContextProjectionModelRenderer 回 []，PackageRenderer 不 emit context target |
| cross-agg entry sourceAggregate 不在 bundle.aggregates[] | throw `bundleInvalid` (per Phase 1.g 既有) |
| cross-agg entry key.fromEventPayload 不在 events payload 共用 | throw（per /readmodel skill strict）|
| Existing context Presenter file | scaffold-once skip emit (per Phase 1.g H6) |

---

## 已知限制

1. **Context-level OpenAPIGenerator + openapi.yaml defer** — 不在 v1.g.2，留 future phase
2. **Phase 1.e ContextLevelRenderer 既有 file** (`{Context}ListenerError.swift`) 現屬 context target（會被 SwiftPM compile）— 應該無衝突，但需驗證
3. **Conditional emit 對既有 Phase 1.e files**：若 bundle 無 cross-agg readmodel，現有 `{Context}/{Context}ListenerError.swift` 是 orphan（無 target）— **pre-existing issue**；future cleanup
4. **`{AggregateDeps}` 列全 aggregates 不過濾**：保守做法，避免 event-yaml 解析複雜度。最壞情況：context target 多依賴幾個 unused aggregate。
5. **Package product line** 加 `{Context}` library — 確認跟既有 product list 不衝突

---

## 實作步驟

1. **3 templates** in `Sources/GenesisCore/Resources/Templates/v0.1/Context/` + 1 in `Templates/v0.1/`
2. **Modify `Templates/v0.1/Projector/Presenter.swift.template`** — 加 `{AggregateImports}` placeholder
3. **新 `ContextProjectionModelRenderer.swift`** — 3 output files
4. **修改 `ReadModelRenderer.swift`** — 解除 reject + dispatch path + AggregateImports
5. **修改 `PackageRenderer.swift`** — conditional context target + library product
6. **修改 `NewCommand.swift`** — call ContextProjectionModelRenderer 在 ReadModelRenderer 後
7. **bump Version.swift** → `0.1.0-phase1g2`
8. **新 fixture `iam-readmodel-cross-bundle.json`** — 兩個 aggregates (UserAccessProfile + 第二個 simple aggregate) + 一個 cross-agg readmodel
9. **新 `ContextProjectionModelRendererTests.swift`**
10. **擴 `ReadModelRendererTests.swift`** — flip `testContextLevelEntryThrows` → `testContextLevelGoesToContextDir`
11. **擴 `PackageRendererTests.swift`** — testEmitsContextTarget / testSkipsWhenNoCrossAgg
12. **擴 `NewCommandTests.swift`** — testCrossAggregateReadmodelGenerated
13. **bump existing version tests** if needed
14. **docs/decisions.md** + **docs/architecture.md** update
15. **Real e2e build** verification

---

## Sign-off requirements

- [ ] write-spec output reviewed
- [ ] audit-spec pass 1 (internal consistency)
- [ ] audit-spec pass 2 (Codex external)
- [ ] decisions.md ratification entry
- [ ] registry status: draft → ready → done

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals (cross-agg codegen) ↔ Non-goals (OpenAPI defer) 互斥
- [x] depends_on 透明: phase-1g (DONE)
- [x] 全 acceptance gates 可 grep / swift-test
- [x] Codex audit 可 focus on OC ground truth alignment
