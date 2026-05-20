# Phase 1.g — ReadModel renderer (codegen side) design discussion

**Date**: 2026-05-18
**Status**: decisions locked, ready for write-spec
**Related**:
- `docs/tasks/registry/2026-05-18-readmodel-skill.json` (done — design-side skill that writes bundle entries this renderer consumes)
- `docs/tasks/registry/phase-1e-aggregate-alignment.json` (done — established aggregate template + plugin pattern this renderer extends)
- `docs/tasks/registry/phase-1f-context-shared-infra.json` (done — `{Ctx}Shared` infra `ReadModel` import chain depends on it)
**Facts source**: Gemini agent investigation cached from /readmodel skill discussion (`docs/discussions/2026-05-18-readmodel-skill.md` §1).

---

## 1. Position in Genesis architecture

```
┌────────────────────────────────┐   ┌────────────────────────────────────┐
│ DESIGN side (/readmodel skill) │   │ CODEGEN side (Phase 1.g, this doc) │
│ user → bundle.readModels[]     │ → │ bundle.readModels[] → 4 files      │
└────────────────────────────────┘   └────────────────────────────────────┘
```

Phase 1.g is purely deterministic：input = `bundle.readModels[]` entry (revised D2 schema)，output = 4 OC-canonical files per entry。沒有 user 互動、沒有「智能推斷」、純 template + 變數代換。

---

## 2. OC ground truth (recap from Gemini facts)

每 readmodel 對應 4 human-written files (+ 3 generated-by-plugin)：

| File | Author | Path (per-aggregate) | Path (cross-aggregate) |
|---|---|---|---|
| `{Noun}ReadModel.swift` | human (=Phase 1.g 產) | `Sources/{A}Aggregate/Usecase/Projector/Get{Noun}/` | `Sources/{Context}/Projector/Get{Noun}/` |
| `Get{Noun}Presenter.swift` | human | same dir | same dir |
| `OC_Get{Noun}Projection.js` | human | `projections/` (project root) | `projections/` (same place) |
| `projection-model.yaml` entry | human | embedded in `Sources/{A}Aggregate/projection-model.yaml` | `Sources/{Context}/projection-model.yaml` |
| `Get{Noun}ProjectorProtocol` | plugin generated | `.build/.../generated/` | same |
| `Get{Noun}EventMapper` | plugin generated | same | same |
| `Get{Noun}EventFilter` | plugin generated | same | same |

Genesis Phase 1.g 負責**前 4 個**。後 3 個由 `ModelGeneratorPlugin` 在 SwiftPM build 時自動產出 — 前提是 yaml + event.yaml 對得上。

---

## 3. Decisions

### D1 — Renderer scope: 1 new + 1 modified

**Decision**:
- **新增** `Sources/GenesisCore/ReadModelRenderer.swift` — 每個 bundle.readModels[] entry 產 ReadModel.swift / Presenter.swift / JS file 3 個檔
- **修改** 既有 `ProjectionModelRenderer.swift`：(a) 用新 schema (eventRefs + aggregateRef) 而非 legacy eventNames-only，(b) cross-aggregate (`aggregateRef == "<context-level>"`) entry 改 emit 到 `Sources/{Context}/projection-model.yaml`（不再每 aggregate 都嵌一份）

**Rationale**:
- ReadModel + Presenter + JS 是「per readmodel entry」level — 一份 renderer 看一個 entry 一次出 3 個檔
- projection-model.yaml entry 是「per aggregate」level (entries 是 entries[]) — 既有 renderer 該責任
- 分開職責讓 unit test 好寫 + plan/commit semantics 清楚

### D2 — Per-readmodel output files (deterministic naming)

對 `entry: ReadModelSpec` with `name = "GetAccountingType"`, `aggregateRef = "AuditQuoting"`：

```
Sources/AuditQuotingAggregate/Usecase/Projector/GetAccountingType/AccountingTypeReadModel.swift
Sources/AuditQuotingAggregate/Usecase/Projector/GetAccountingType/GetAccountingTypePresenter.swift
projections/OC_GetAccountingTypeProjection.js
```

對 cross-aggregate (`aggregateRef = "<context-level>"`, name = "GetSelectedServiceItems"):

```
Sources/AuditQuotingContext/Projector/GetSelectedServiceItems/SelectedServiceItemsReadModel.swift
Sources/AuditQuotingContext/Projector/GetSelectedServiceItems/GetSelectedServiceItemsPresenter.swift
projections/OC_GetSelectedServiceItemsProjection.js
```

**Naming derivation (rigid，from /readmodel skill spec §1.7)**:
- entry name `Get<Noun>` → ReadModel type = `<Noun>ReadModel` (strip `Get`)
- Presenter type = `Get<Noun>Presenter`
- Directory = `Get<Noun>/`
- JS file = `<Prefix>Get<Noun>Projection.js` where `<Prefix>` = streamPrefix (default `IAM_` etc.)

### D3 — ReadModel.swift template (per Gemini facts §1.3)

```swift
import EventSourcing
{SharedImport}

package class {ReadModelTypeName}: ReadModel {
    package var id: {KeyType} { {KeyField} }
{StoredFieldDeclarations}

    package init({KeyField}: {KeyType}) {
        self.{KeyField} = {KeyField}
{StoredFieldDefaults}
    }
}
```

**Placeholders**:
- `{SharedImport}` = `import {Context}Shared` (Phase 1.f infra)
- `{ReadModelTypeName}` = entry name strip `Get` (e.g. `AccountingTypeReadModel`)
- `{KeyType}` = `entry.key.type` (String / UUID / Int / Int64)
- `{KeyField}` = `entry.key.field` (e.g. `auditQuotingId`)
- `{StoredFieldDeclarations}` = `\n`.join of `    package var {name}: {type}` for each storedField
- `{StoredFieldDefaults}` = `\n`.join of `        self.{name} = {default}` (default 來自 schema `default` 欄位，nil if optional, else `.empty()` for collections — see D8)

**Rationale**: 對齊 OC canonical `AccountingTypeReadModel.swift` 形狀；key 從 stored field 升頂層 → ReadModel 不在 storedFields[] 裡的 invariant (D2 已驗證)。

### D4 — Presenter.swift template (per Gemini facts §1.4)

```swift
import DDDCore
import EventSourcing
import KurrentSupport
{SharedImport}

package struct Get{Noun}Input: CQRSProjectorInput {
    package let id: {KeyType}

    package init({KeyField}: {KeyType}) {
        self.id = {KeyField}
    }
}

package struct Get{Noun}Presenter: Get{Noun}ProjectorProtocol {
    package typealias Input = Get{Noun}Input
    package typealias StorageCoordinator = KurrentStorageCoordinator<Self>
    package typealias ReadModelType = {ReadModelTypeName}
    package static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "{StreamPrefix}") }

    package var coordinator: KurrentStorageCoordinator<Get{Noun}Presenter>

    package init(coordinator: KurrentStorageCoordinator<Get{Noun}Presenter>) {
        self.coordinator = coordinator
    }

    package func buildReadModel(input: Input) throws -> {ReadModelTypeName}? {
        return .init({KeyField}: input.id)
    }
{WhenMethods}
}
```

`{WhenMethods}` 每個 selected event 一個：

```swift

    package func when(readModel: inout ReadModelType, event: {EventName}) throws {
        // TODO(/readmodel-mutation v2): mutate readModel from event payload
        // For now: hand-fill mutation logic below.
        _ = readModel  // silence "unused" warning until body filled
        _ = event
    }
```

**Rationale**:
- Empty `when()` body but compile-clean (`_ = readModel` 與 `_ = event` 消 warning)
- TODO 註解明確 cite v2 skill 可自動化
- protocol conformance 是 plugin-generated；必須匹配 events list

### D5 — JS projection template (per Gemini facts §1.5)

```js
fromStreams([{SourceStreamList}])
.when({
    $init: function(){
        return {}
    },
{HandlerLines}
});

function handleEvent(state, event) {
    if (event.isJson) {
        linkTo("{StreamPrefix}{Name}-" + event.body["{FromEventPayload}"], event);
    }
}
```

`{SourceStreamList}`：每個 unique `sourceAggregate` 一個 stream，例如：
- per-aggregate readmodel 走 `["$ce-{StreamPrefix}{AggregateName}"]`
- cross-aggregate 走 `["$ce-{StreamPrefix}{Agg1}", "$ce-{StreamPrefix}{Agg2}"]`

`{HandlerLines}`：每個 event 一行 `    {EventName}: handleEvent,`（最後一個無 comma — 或安全起見保留 comma， JS 可接受 trailing comma）

**Rationale**: 對齊 OC `OC_GetAccountingTypeProjection.js` verbatim；JS 跟 Swift Presenter 共用 `{FromEventPayload}` 來自同一 bundle entry — 解 audit M1 footgun。

### D6 — `ProjectionModelRenderer` modification (cross-aggregate fix)

**Current behaviour (bug per OC pattern)**：context-level readmodels (aggregateSpecId nil) embed into **every aggregate**'s projection-model.yaml.

**New behaviour (Phase 1.g)**：
- per-aggregate readmodels → embed in matching aggregate's yaml ✓ (already correct)
- cross-aggregate readmodels (aggregateRef == "<context-level>") → emit a **new file** `Sources/{Context}/projection-model.yaml` 收集所有 cross-aggregate entries (mirror OC `Sources/OpportunityContext/projection-model.yaml`)

**Edge case**: 若沒有 cross-aggregate entry → 不 emit `Sources/{Context}/projection-model.yaml`（不要塞空檔）

**Schema migration impact**：existing `ProjectionModelRenderer.render(aggregateName:, aggregateSpecId:, ...)` 用舊 `eventNames`. 新版改用 `eventRefs[].sourceAggregate` 過濾（如有），fall back to `eventNames` 比對 aggregate (backwards compat with minimal bundle fixture)。

### D7 — NewCommand wiring

Phase 1.g 在 NewCommand 加新 step：

```
[existing] AggregateRenderer (each aggregate, includes per-agg projection-model.yaml)
[existing] ContextLevelRenderer (conventions/api.md, starter adapter)
[existing] SharedTargetRenderer
[NEW Phase 1.g] ReadModelRenderer.render(bundle, contextName, adapter)
  for each readModel in bundle.readModels[]:
    emit (ReadModel.swift, Presenter.swift, OC_*.js) — go to per-agg or context dir based on aggregateRef
  emit Sources/{Context}/projection-model.yaml if any cross-aggregate entries (D6)
[existing] SwiftPM resolve + build
```

Renderer 回傳 `[(path, content, role)]` 跟其他 renderer 一致；NewCommand 用 SourceWriter plan/commit 路徑寫入。

### D8 — Stored fields default value semantics

`storedFields[].default` 欄位是 String? — 表 Swift literal initializer expression。Renderer 不做型別檢查（與 ReadModelBundleAppender 保持一致），直接置入 init body：

```
若 default == nil 且 type 結尾 "?" → init: `self.{name} = nil`
若 default == nil 且 type 結尾 "]" → init: `self.{name} = []`（empty array/dict 假設）
若 default == nil 且 type == "Set<...>" → init: `self.{name} = Set()` (僅當 type startsWith "Set")
若 default 非 nil → init: `self.{name} = {default}` (raw substitution)
```

**Rationale**: OC pattern 顯示 init 只接 key，其餘走 default。Type-based heuristic 涵蓋 90% case；user 可手動 override via bundle entry `default` 欄位。

### D9 — Stream prefix resolution (per /readmodel spec)

`{StreamPrefix}` 取自 streamPrefix resolution chain (per /readmodel skill spec §streamPrefix-resolution)：

1. `<bundle>.adapter.yaml` `streamPrefix` 若有 → 用它
2. `bundle.context.streamPrefix` 若 context 為 object → 用它
3. Deterministic fallback：strip `"Context"` + alias map `Opportunity → OC`，else upper-snake (`IAMContext → IAM_`、`BillingContext → BILLING_`)

Renderer **不問** user；deterministic + adapter override = SSOT。

### D10 — Empty when() body compile-check assumption

**Decision**: Presenter's empty `when()` body **WILL compile** because：
- `Get{Noun}ProjectorProtocol` is plugin-generated (`ModelGeneratorPlugin` based on projection-model.yaml events list)
- Protocol's default `apply(readModel: events:)` extension dispatches on type
- 每個 `when(readModel: inout ReadModelType, event: <EventName>) throws` 在 Presenter 必須存在 — 缺則 compile error
- 我們提供 empty body (just `_ = readModel; _ = event`) — 滿足 conformance + warning-free

**Risk**: 若 bundle entry events 跟 projection-model.yaml events 不同步 → plugin protocol 跟 Presenter when() 不對齊 → compile error。**Mitigation**: ProjectionModelRenderer 跟 ReadModelRenderer 從**同一個 bundle entry 推導**，不會走樣。

### D11 — Acceptance test strategy

**Unit test (`ReadModelRendererTests`)**:
- happy path per-aggregate (1 readmodel, 2 events) → assert 3 outputs paths + content key invariants
- cross-aggregate path → 對 cross-aggregate readmodel，assert ReadModel.swift 在 `Sources/{Context}/Projector/...`
- empty storedFields → ReadModel only has key field
- multiple storedFields → init body correct
- JS projection stream list correct for multi-source
- streamPrefix resolution (alias map vs fallback)

**Integration test (NewCommandTests)**:
- 擴一個 fixture 加 1-2 個 readmodel entries (per-aggregate + cross-aggregate)
- `genesis new` 跑完，assert all 4 file types exist on disk
- **真 e2e `swift build`** assert generated project compile pass（plugin works）— 跟 Phase 1.e e2e 同 pattern

### D12 — Known limitations

1. **Plugin compile assumes events 都在 event.yaml**：若 bundle event name 不在對應 aggregate.events[]，plugin protocol 不會 emit when 方法 → Presenter 缺方法 OR 多方法。Mitigation: ReadModelBundleAppender 已驗證 `events[].name` 在 aggregate.events[] 內（appender 的 unknownEvent 拒絕），所以不會發生。
2. **Cross-aggregate readmodel 不在 Genesis Phase 1.e aggregate 範圍**：context-level Projector 目錄之前沒有 (Phase 1.b/1.c 不產)，Phase 1.g 第一次建 → 要驗證跟 Phase 1.e `Sources/{Context}/...` 既有檔（ListenerError 等）共存無衝突
3. **`+Query.swift` extension 不在 codegen 範圍**：user 後續手寫
4. **Empty when() TODO**：不 actionable until user 手填或 v2 skill；real OC build 跑得通因 plugin 不要求 `when()` body 有實際邏輯
5. **JS file 部署在 KurrentDB 不在 Genesis 範圍**：產出檔案後 user 跑 `scripts/projection.sh`（Phase 1.f 已有此 script template）
6. **Manifest version bump**：Phase 1.g 改 codegen output → 升 `GenesisCoreVersion.current` 到 `0.1.0-phase1g`
7. **Pre-existing test `testInfraFileContentIso8601NoTaipei` etc.** 不受影響（Phase 1.g 只加 Projector files，不動 Shared infra）

---

## 4. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | 1 new `ReadModelRenderer` + modify `ProjectionModelRenderer` | 職責分明，test 好寫 |
| D2 | 4 deterministic output paths (per-agg vs context-level) | mirror OC structure |
| D3 | ReadModel.swift template per OC `package class : ReadModel` | facts §1.3 verbatim alignment |
| D4 | Presenter.swift template empty when() body + TODO | future v2 skill placeholder |
| D5 | JS projection template per OC `linkTo` pattern | facts §1.5 verbatim |
| D6 | Cross-aggregate yaml goes to `Sources/{Context}/projection-model.yaml` | match OC OpportunityContext target |
| D7 | NewCommand 加 ReadModelRenderer step 在 SwiftPM resolve 之前 | plan/commit pattern reuse |
| D8 | storedFields default 走 type-based heuristic | covers OC 90% cases |
| D9 | streamPrefix 走 chain：adapter > bundle.context > fallback alias map | 與 /readmodel skill 一致 |
| D10 | Empty when() body 假設 plugin protocol + bundle events 同步 | appender 已驗證 invariant |
| D11 | Unit + integration + real e2e build acceptance | Phase 1.e 同 pattern |
| D12 | Version bump → `0.1.0-phase1g` | manifest convention |

---

## Next step

→ `/write-spec` for Phase 1.g 使用 above decisions。Output to `docs/tasks/phase-1g-readmodel-renderer.md` + registry entry。
