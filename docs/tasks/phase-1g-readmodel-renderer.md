# Phase 1.g — Genesis ReadModel renderer (codegen side, per-aggregate v1 scope)

## 來源

討論：`docs/discussions/2026-05-18-phase-1g-readmodel-renderer.md`
Audit：Codex external review (2026-05-18) 回 6H+4M+2L，全部已套修 → spec v2。

Ground truth refs：
- OC canonical per-aggregate readmodel：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/AuditQuotingAggregate/Usecase/Projector/GetAccountingType/`
- OC canonical JS projection：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/projections/OC_GetAccountingTypeProjection.js`
- Gemini facts report 2026-05-18（cached in /readmodel skill discussion §1）
- /readmodel skill v1 bundle schema：`docs/tasks/2026-05-18-readmodel-skill.md`
- Phase 1.e aggregate template：`Sources/GenesisCore/Resources/Templates/v0.1/Aggregate/*.template`
- Event upper-camel normalization：`Sources/GenesisCore/CaseTransformer.swift` + `AggregateRenderer.swift:99-100,252`

## 目標

擴 Genesis codegen 路徑讓 `genesis new` 在處理含**per-aggregate** `readModels[]` 的 bundle 時，per readmodel entry 自動產 3 個 OC-canonical 檔（projection-model.yaml entry 由既有 `ProjectionModelRenderer` cover）：

1. `Sources/{A}Aggregate/Usecase/Projector/Get{Noun}/{Noun}ReadModel.swift`
2. `Sources/{A}Aggregate/Usecase/Projector/Get{Noun}/Get{Noun}Presenter.swift`（empty `when()` body + TODO；**scaffold-once，不 overwrite existing**）
3. `projections/{ProjectionStreamPrefix}Get{Noun}Projection.js`

外加既有 `ProjectionModelRenderer` 用 normalized event names 寫 yaml entry（per-aggregate yaml，既有路徑不動）。

**Scope narrow（per audit H4/H5）**：
- **v1 只支援 per-aggregate readmodel**（`aggregateRef = <某 aggregate name>`）
- 遇到 `aggregateRef == "<context-level>"` → renderer throws `bundleInvalid` + 提示「Phase 1.g.2 待開」
- 跨 aggregate codegen（新 `{Context}` SwiftPM target + import 多 aggregate）defer 到 Phase 1.g.2

**真 e2e 驗收**：對含 readmodel 的 IAM bundle 跑 `genesis new` → output project `swift build` PASS（SwiftPM ModelGeneratorPlugin 生 protocol，Presenter empty body 滿足 conformance）。

---

## 介面合約（Interface Contract）

### 新增 type / file

| File | 性質 |
|---|---|
| `Sources/GenesisCore/ReadModelRenderer.swift` | NEW；公開 `render(bundle:contextName:adapter:existingPresenterPaths:) throws -> [(path,content,role)]` |
| `Sources/GenesisCore/Resources/Templates/v0.1/Projector/ReadModel.swift.template` | NEW |
| `Sources/GenesisCore/Resources/Templates/v0.1/Projector/Presenter.swift.template` | NEW |
| `Sources/GenesisCore/Resources/Templates/v0.1/Projector/Projection.js.template` | NEW |

### 修改既有 file

| File | 修改內容 |
|---|---|
| `Sources/GenesisCore/ProjectionModelRenderer.swift` | events list 走 normalized upper-camel；scope 過濾改用 `aggregateRef == aggregate.name` (new schema) fallback `aggregateSpecId` for legacy |
| `Sources/GenesisCore/AggregateRenderer.swift` | 同上 propagate；context-level entries 不再 propagate 到 per-aggregate yaml |
| `Sources/Genesis/Commands/NewCommand.swift` | 在 SharedTargetRenderer 之後加 ReadModelRenderer 呼叫；先掃 existing Presenter paths（per H6 scaffold-once）後傳入 |
| `Sources/GenesisCore/Version.swift` | bump to `0.1.0-phase1g` |

### ReadModelRenderer 公開介面

```swift
public enum ReadModelRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPresenterPaths: Set<String>  // for scaffold-once semantics (audit H6)
    ) throws -> [(path: String, content: String, role: String)]
}
```

行為：
- 遍歷 `bundle.readModels`
- 對每 entry：**驗證** `key` non-nil + `eventRefs` non-empty 帶 sourceAggregate (per audit H3)；違反 → throw
- 對 `aggregateRef == "<context-level>"` → throw `bundleInvalid` with hint「Phase 1.g.2 待開支援 cross-aggregate codegen」
- 依 normalized event type names（per audit H2，走 `CaseTransformer.upperCamel`）套版
- 依 entry 內 `key` / `storedFields` / `events` 推導 placeholders
- **Presenter scaffold-once（per audit H6）**：若 `Sources/{A}Aggregate/Usecase/Projector/Get{Noun}/Get{Noun}Presenter.swift` 已存在 → **skip Presenter emission**（不 overwrite，保留 user 手填的 mutation logic），仍 emit ReadModel.swift 跟 JS file
- 回傳 `[(path, content, role)]`

### Placeholder 表 (canonical, full)

| Placeholder | Source / derivation |
|---|---|
| `{ContextName}` | bundle.context (e.g. `IAMContext`) |
| `{SharedImport}` | `import {ContextName}Shared` |
| `{ProjectionStreamPrefix}` | streamPrefix resolution (D9, terminal `_` included, e.g. `IAM_`) |
| `{SourceCategoryPrefix}` | streamPrefix resolution **WITHOUT trailing `_`**（per audit M1，e.g. `IAM`）。OC source streams 是 `$ce-OCAuditQuoting` 不是 `$ce-OC_AuditQuoting`，two prefixes are different concepts |
| `{Name}` | entry.name (e.g. `GetAccountingType`) |
| `{Noun}` | entry.name strip `Get` (e.g. `AccountingType`) |
| `{ReadModelTypeName}` | `{Noun}ReadModel` |
| `{PresenterTypeName}` | entry.name + `Presenter` |
| `{KeyField}` | entry.key.field |
| `{KeyType}` | entry.key.type |
| `{FromEventPayload}` | entry.key.fromEventPayload |
| `{AggregateName}` | entry.aggregateRef (validated non-context-level in v1) |
| `{StoredFieldDeclarations}` | derived storedFields (D8) |
| `{StoredFieldDefaults}` | derived (D8) |
| `{WhenMethods}` | one per **normalized** event name with empty TODO body |
| `{SourceStreamList}` | `["$ce-{SourceCategoryPrefix}{AgName1}", ...]` from unique sourceAggregate set，**without** trailing `_` |
| `{HandlerLines}` | per **normalized** event name: `    {EventTypeName}: handleEvent,` |

### ReadModel.swift template (per audit H1 — add backing key field)

```swift
import EventSourcing
{SharedImport}

package class {ReadModelTypeName}: ReadModel {
    package var id: {KeyType} { {KeyField} }
    package var {KeyField}: {KeyType}
{StoredFieldDeclarations}

    package init({KeyField}: {KeyType}) {
        self.{KeyField} = {KeyField}
{StoredFieldDefaults}
    }
}
```

**Audit fix**：原 spec 漏 `package var {KeyField}: {KeyType}` 宣告，會 compile fail。OC `AccountingTypeReadModel.swift` 明確帶 backing field。

### Presenter.swift template

```swift
import DDDCore
import EventSourcing
import KurrentSupport
{SharedImport}

package struct {Name}Input: CQRSProjectorInput {
    package let id: {KeyType}

    package init({KeyField}: {KeyType}) {
        self.id = {KeyField}
    }
}

package struct {PresenterTypeName}: {Name}ProjectorProtocol {
    package typealias Input = {Name}Input
    package typealias StorageCoordinator = KurrentStorageCoordinator<Self>
    package typealias ReadModelType = {ReadModelTypeName}
    package static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "{ProjectionStreamPrefix}") }

    package var coordinator: KurrentStorageCoordinator<{PresenterTypeName}>

    package init(coordinator: KurrentStorageCoordinator<{PresenterTypeName}>) {
        self.coordinator = coordinator
    }

    package func buildReadModel(input: Input) throws -> {ReadModelTypeName}? {
        return .init({KeyField}: input.id)
    }
{WhenMethods}
}
```

每 `when()` (per normalized event name):

```swift

    package func when(readModel: inout ReadModelType, event: {EventTypeName}) throws {
        // TODO(Phase 1.g): mutation logic not yet codegen'd. Hand-fill below, or wait
        // for /readmodel-mutation v2 skill. Plugin requires this method to satisfy
        // {Name}ProjectorProtocol; current body intentionally no-op.
        _ = readModel
        _ = event
    }
```

### JS projection template (per audit M1 — split prefix concepts)

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
        linkTo("{ProjectionStreamPrefix}{Name}-" + event.body["{FromEventPayload}"], event);
    }
}
```

**Audit fix M1**：`$ce-{Source...}` 不帶底線（OC: `$ce-OCAuditQuoting`），`linkTo("{Projection...}{Name}-...")` 帶底線（OC: `OC_GetAccountingType-...`）。Two distinct prefixes derived from same source but with/without trailing `_`.

### Stored fields default value derivation (per audit M3 — robust v2)

```swift
let defaultExpr: String = try {
    if let explicit = field.defaultValue { return explicit }
    if field.type.hasSuffix("?") { return "nil" }
    if field.type.hasPrefix("Optional<") && field.type.hasSuffix(">") { return "nil" }
    if field.type.hasPrefix("Set<") && field.type.hasSuffix(">") { return "Set()" }
    if field.type.hasPrefix("Array<") && field.type.hasSuffix(">") { return "[]" }
    if field.type.hasPrefix("Dictionary<") && field.type.hasSuffix(">") { return "[:]" }
    // Bracket syntax: distinguish [Element] (array) vs [Key: Value] (dictionary) by top-level ':'.
    if field.type.hasPrefix("[") && field.type.hasSuffix("]") {
        let inner = String(field.type.dropFirst().dropLast())
        // top-level colon detection — bracket-depth-aware to avoid mistaking [String: Int]? for array
        var depth = 0
        var hasTopColon = false
        for c in inner {
            if c == "<" || c == "[" || c == "(" { depth += 1 }
            else if c == ">" || c == "]" || c == ")" { depth -= 1 }
            else if c == ":" && depth == 0 { hasTopColon = true; break }
        }
        return hasTopColon ? "[:]" : "[]"
    }
    // Non-optional non-collection type without explicit default — throw actionable error
    throw GenesisError.bundleInvalid(
        reason: "readModel storedField '\(field.name)' type '\(field.type)' has no inferrable default; add `default` in bundle entry"
    )
}()
```

### Cross-aggregate handling (v1 explicit reject)

```swift
if entry.aggregateRef == "<context-level>" {
    throw GenesisError.bundleInvalid(
        reason: "readModel '\(entry.name)' has aggregateRef '<context-level>'; cross-aggregate codegen 待 Phase 1.g.2"
    )
}
```

### Schema validation (per audit H3)

```swift
guard let key = entry.key else {
    throw GenesisError.bundleInvalid(reason: "readModel '\(entry.name)' missing 'key'; run /readmodel skill to update")
}
guard !entry.eventRefs.isEmpty else {
    throw GenesisError.bundleInvalid(
        reason: "readModel '\(entry.name)' missing 'events[].sourceAggregate'; run /readmodel skill to update (legacy minimal shape unsupported by Phase 1.g)"
    )
}
```

### Event type name normalization (per audit H2)

對每 `eventRef.name`（bundle 可能存 lower-camel `userAccessProfileCreated`）：
```swift
let eventTypeName = CaseTransformer.upperCamel(eventRef.name)
```

**用於**：Presenter `when(... event: <T>)`、JS `<T>: handleEvent,`、projection-model.yaml entry events list — **三處共用同一 normalization**，確保 plugin protocol / Presenter conformance / yaml 三者對齊（audit H2 揭露：原 spec 三處沒對齊會 compile fail）。

### Stream prefix resolution (per audit M2 — drop adapter override v1)

**v1 簡化**：去掉 adapter override 機制（Adapter struct 尚無 `streamPrefix` 欄位）。precedence 改：

1. **Deterministic fallback**：
   - strip suffix `"Context"` from `contextName`
   - 套 alias map：`Opportunity → OC`（單一硬寫 v1，可擴）
   - else: upper-snake (`IAM → IAM_`、`Billing → BILLING_`、`MyApp → MY_APP_`)

範例（per audit L2 — 增加 edge case 覆蓋）：

| contextName | strip | alias | result |
|---|---|---|---|
| `OpportunityContext` | `Opportunity` | hit → `OC` | `OC_` |
| `IAMContext` | `IAM` | miss | `IAM_` |
| `BillingContext` | `Billing` | miss | `BILLING_` |
| `OrderContext` | `Order` | miss | `ORDER_` |
| `MyContext` | `My` | miss | `MY_` |
| `MyApp` | `MyApp` (no strip) | miss | `MY_APP_` |
| `Context` | `` (empty strip) | error | exit 1 with hint |
| `XMLAPIContext` | `XMLAPI` | miss | `XMLAPI_` (digits/all-caps preserved) |

實作（純函式）：

```swift
public static func streamPrefix(contextName: String) throws -> (projection: String, sourceCategory: String) {
    let stripped: String = {
        if contextName.hasSuffix("Context") {
            return String(contextName.dropLast("Context".count))
        }
        return contextName
    }()
    if stripped.isEmpty {
        throw GenesisError.bundleInvalid(reason: "contextName must not equal 'Context' alone; cannot derive stream prefix")
    }
    let aliases: [String: String] = ["Opportunity": "OC"]
    let core = aliases[stripped] ?? upperSnake(stripped)
    return (projection: "\(core)_", sourceCategory: core)
}
```

`upperSnake` helper：camel/Pascal → UPPER_SNAKE。例：`MyApp` → `MY_APP`、`XMLAPI` → `XMLAPI`（不 split all-caps run，stays `XMLAPI`）。

**Adapter override 留 Phase 1.h follow-up**：若未來要支援，加 `Adapter.streamPrefix: String?` + parser key + override precedence in same function。

**Spec implication**：adapter `streamPrefix` 不在 v1 acceptance；Adapter struct 不改。

### NewCommand step ordering (revised)

```
1. parse bundle
2. AdapterApplier
3. AggregateRenderer loop（per-aggregate yaml entries 用 new schema）
4. ContextLevelRenderer
5. SharedTargetRenderer
6. [NEW] 掃 outputDir for existing Presenter paths → set
7. [NEW] ReadModelRenderer.render(bundle, contextName, adapter, existingPresenterPaths)
8. PackageRenderer / ManifestRenderer
9. SourceWriter.plan / commit
10. swift package resolve
11. swift build (gated by --skip-build)
```

### Output file roles

| Role | Used by |
|---|---|
| `readmodel` | new — ReadModel.swift |
| `presenter` | new — Presenter.swift (only when not existing per H6) |
| `projection` | new — JS file |
| `projectionModel` | existing — per-aggregate yaml |

---

## 驗收標準（Acceptance Criteria）

### A1 — Renderer file exists
```
test -f Sources/GenesisCore/ReadModelRenderer.swift
```

### A2 — 3 template files exist (per-aggregate scope; context-level template defer to 1.g.2)
```
test -f Sources/GenesisCore/Resources/Templates/v0.1/Projector/ReadModel.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Projector/Presenter.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Projector/Projection.js.template
```

### A3 — Version bump
```
grep -F '0.1.0-phase1g' Sources/GenesisCore/Version.swift
! grep -F '0.1.0-phase1f' Sources/GenesisCore/Version.swift
```

### A4 — Template content (per OC canonical + audit fixes)
```
grep -F 'package class {ReadModelTypeName}: ReadModel' Sources/GenesisCore/Resources/Templates/v0.1/Projector/ReadModel.swift.template
grep -F 'package var {KeyField}: {KeyType}' Sources/GenesisCore/Resources/Templates/v0.1/Projector/ReadModel.swift.template
grep -F 'CQRSProjectorInput' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Presenter.swift.template
grep -F 'KurrentStorageCoordinator' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Presenter.swift.template
grep -F 'TODO(Phase 1.g)' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Presenter.swift.template
grep -F 'linkTo' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Projection.js.template
grep -F 'fromStreams' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Projection.js.template
grep -F '{ProjectionStreamPrefix}' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Projection.js.template
grep -F '{SourceCategoryPrefix}' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Projection.js.template
! grep -F '$ce-{ProjectionStreamPrefix}' Sources/GenesisCore/Resources/Templates/v0.1/Projector/Projection.js.template
```
> 最後一條：JS source streams 不可用 projection prefix（per audit M1）

### A5 — Unit tests pass
```
swift test --filter ReadModelRendererTests
```

涵蓋：
- happy-path-per-aggregate（3 outputs paths + content keys）
- contextLevelEntryThrows（per H4 v1 reject）
- missingKeyThrows
- missingEventRefsThrows
- eventNameNormalizedUpperCamel (per audit H2 — bundle `userAccessProfileCreated` → emits `UserAccessProfileCreated`)
- streamPrefixAliasOpportunity (`OpportunityContext` → `OC_` projection / `OC` source)
- streamPrefixFallbackUpperSnake (`IAMContext` → `IAM_` / `IAM`; `MyApp` → `MY_APP_` / `MY_APP`)
- streamPrefixContextOnlyThrows (`Context` 單字 → throw)
- presenterScaffoldOnceSkipsExisting (per audit H6 — existing path 不 overwrite)
- storedFieldsDefault: ? → nil, [] → [], [:] → [:], Set<> → Set(), Array<> → [], Dictionary<> → [:], Optional<> → nil
- storedFieldsNonOptionalNoDefaultThrows (per audit M3)
- jsSourceStreamsUseSourceCategoryPrefix (per audit M1 — no trailing `_`)

### A6 — Full test suite green
```
swift test  # 既有 152+ tests still PASS + 新增 ~12 個 ReadModelRendererTests
```

### A7 — Integration: NewCommand 產 readmodel files (per audit L1 — new fixture)
```
test -f Tests/GenesisIntegrationTests/Fixtures/iam-readmodel-bundle.json
swift test --filter NewCommandTests/testReadmodelFilesGenerated
```

assertions：
- `Sources/UserAccessProfileAggregate/Usecase/Projector/Get<Noun>/<Noun>ReadModel.swift` 存在
- `Sources/UserAccessProfileAggregate/Usecase/Projector/Get<Noun>/Get<Noun>Presenter.swift` 存在
- `projections/IAM_Get<Noun>Projection.js` 存在
- per-aggregate yaml 含 `Get<Noun>:` entry

> 既有 `iam-bundle.json` 不動（per audit L1）；新 fixture 為 Phase 1.g 專用。

### A8 — Real e2e swift build (per audit M4 — 用既有 env var)
```
GENESIS_RUN_E2E_BUILD=1 swift test --filter NewCommandTests/testReadmodelE2EBuild
```

預期：build complete pass，plugin generates protocols，Presenter empty body 滿足 conformance。

### A9 — Spec ratification entries
```
grep -F 'Phase 1.g' docs/decisions.md
grep -F 'ReadModelRenderer' docs/architecture.md
grep -F 'Projector/' docs/architecture.md
```

### A10 — Presenter scaffold-once integration

對 e2e fixture：跑 `genesis new` 兩次（同 outputDir，第二次先 manual-edit Presenter `when()` body 加註解 `// USER_EDIT`），assert 第二次後 Presenter 內仍有 `// USER_EDIT`。

### A11 — Empty when() body compile-safe

Unit test `testPresenterEmptyWhenBodyCompiles`：
- 每 event 對應一個 `when(readModel: inout ReadModelType, event: <UpperCamel>) throws` (per H2 normalized)
- body 含 `_ = readModel; _ = event`
- TODO 註解 present

### A12 — `bundleInvalid` 錯誤訊息精確 (per audit H3 hint)
Unit test：
- missing key → reason 含 `"missing 'key'"` 字串
- missing eventRefs → reason 含 `"missing 'events[].sourceAggregate'"`
- context-level entry → reason 含 `"Phase 1.g.2"`
- contextName="Context" → reason 含 `"must not equal 'Context'"`

---

## 失敗路徑（Failure Modes）

| 場景 | Renderer 行為 |
|---|---|
| bundle.readModels[] 為空 | renderer 回 [] 空 outputs；NewCommand 跑通 |
| readmodel entry 沒 `key` | throw `bundleInvalid` with hint「run /readmodel skill to update」(per H3) |
| readmodel entry `eventRefs` 為空 (legacy `events: [{name}]` 沒 sourceAggregate) | throw `bundleInvalid` with hint (per H3) |
| `aggregateRef == "<context-level>"` | throw with hint「Phase 1.g.2 待開」(per H4 defer) |
| `aggregateRef` 不在 bundle.aggregates[] | throw `bundleInvalid` "unknown aggregateRef" |
| Existing Presenter file at output path | skip Presenter emission (per H6 scaffold-once); still emit ReadModel + JS |
| `storedFields[].type` 是 non-optional non-collection 無 default | throw with hint「add `default` in bundle entry」(per M3) |
| contextName == "Context" alone | throw "cannot derive stream prefix" (per L2 edge case) |
| 同 entry 重 plan path collision | SourceWriter same-run duplicate detection catches → throw |

---

## 已知限制（Known Limitations）

1. **Cross-aggregate codegen defer Phase 1.g.2**（per audit H4/H5）：v1 reject + 提示。1.g.2 需加 PackageRenderer 新 `{Context}` SwiftPM target + plugin + event.yaml + event-generator-config.yaml + multi-aggregate imports
2. **Adapter `streamPrefix` override 不在 v1**（per audit M2）：Adapter struct 不改；只走 deterministic fallback。Future Phase 1.h 可加
3. **Plugin 連動是黑箱信任**：若 SwiftPM cache 走樣需 `touch` template + clean rebuild
4. **Empty when() body 非 functional**：必須 user 手填或等 v2 mutation skill
5. **Presenter scaffold-once = idempotent re-run protection**（per audit H6）：existing file 不 overwrite；user 編輯不會被洗掉；trade-off: 若 user 重命名 readmodel 或改 events，需手動刪舊 Presenter
6. **`+Query.swift` extension 不在 codegen**
7. **Manifest version preflight**：bump 到 `0.1.0-phase1g`；舊 manifest 會被 reject
8. **storedFields default heuristic v1**：cover `?` / `Optional<>` / `[]` / `[:]` / `Array<>` / `Dictionary<>` / `Set<>`；其他類型（user-defined struct, tuple optionals like `(Int, String)?`）→ throw 要求 explicit `default`
9. **streamPrefix alias map** v1 hardcode `Opportunity → OC`；user-extendable 待 Phase 1.h
10. **JS file deploy** 不在 codegen 範圍；用既有 `scripts/projection.sh`

---

## 實作步驟（for /pickup）

1. **3 個 templates** in `Sources/GenesisCore/Resources/Templates/v0.1/Projector/`
2. **`Sources/GenesisCore/ReadModelRenderer.swift`** — render fn + streamPrefix helper + storedFields default heuristic + cross-aggregate-reject + scaffold-once detection (set lookup)
3. **`Sources/GenesisCore/CaseTransformer.swift`** — verify `upperCamel` 既有；若缺加 `upperSnake` helper (audit L2)
4. **修改 `ProjectionModelRenderer.swift`** — events 走 normalized upper-camel；scope 改 aggregateRef
5. **修改 `AggregateRenderer.swift`** — propagate change
6. **修改 `NewCommand.swift`** — 掃 existing Presenter paths + 新 step
7. **修改 `Version.swift`** — bump `0.1.0-phase1g`
8. **新 fixture `iam-readmodel-bundle.json`**（per audit L1）— 對齊 iam-bundle.json + 加 1 個 per-aggregate readmodel entry (events `["userAccessProfileCreated", "permissionGranted"]`, key auto-derive)
9. **`ReadModelRendererTests.swift`** ~12 tests (per A5)
10. **`NewCommandTests.swift` 新 case** — `testReadmodelFilesGenerated` + `testReadmodelE2EBuild` (gated by `GENESIS_RUN_E2E_BUILD=1`) + `testPresenterScaffoldOnce`
11. **docs/decisions.md** — Phase 1.g ratification 條目 (含 audit findings 摘要)
12. **docs/architecture.md** — §3 path layout + 新 §10.5 ReadModel codegen flow
13. **跑 spec A1-A12 全 acceptance 檢核**
14. **Real e2e build** (env-gated)

---

## 後續任務 (post-Phase-1g landing)

- **Phase 1.g.2** — cross-aggregate codegen: new `{Context}` SwiftPM target + plugin + event.yaml + multi-aggregate imports
- **Phase 1.h** — Adapter `streamPrefix` override + extensible alias map
- **`/presenter` skill** — design ApplicationService 轉換
- **`/readmodel-mutation` skill (v2)** — 自動填 when() body
- **Bundle schema 加 `aggregate.events[].payload`** — 消除 useCases-join 依賴

---

## Audit findings resolution (v2 spec, post-Codex audit)

| ID | Severity | Issue | Fix applied |
|---|---|---|---|
| H1 | high | ReadModel template missing backing key declaration | Added `package var {KeyField}: {KeyType}` after computed id; A4 grep gate; OC alignment |
| H2 | high | Event names lower-camel→UpperCamel not normalized | All event refs go through `CaseTransformer.upperCamel`; used uniformly in Presenter `when()`, yaml, JS handler keys; A5 unit test |
| H3 | high | BundleParser fallback may leave eventRefs empty | Renderer strictly validates `key` non-nil + `eventRefs` non-empty; explicit throw with hint; A12 |
| H4 | high | Cross-aggregate needs SwiftPM `{Context}` target + plugin setup | v1 scope narrow: reject `<context-level>` with Phase 1.g.2 hint; defer impl |
| H5 | high | Cross-aggregate Presenter needs `import {AggName}Aggregate` per source | Defer same as H4 (1.g.2 will add `{AggregateImports}` placeholder) |
| H6 | high | Presenter regenerate destroys user-filled when() body | Scaffold-once: existingPresenterPaths Set; renderer skips if exists; A10 integration test |
| M1 | medium | JS uses same prefix for source ($ce-) and projection (linkTo), but OC differs | Split `{ProjectionStreamPrefix}` (with `_`) vs `{SourceCategoryPrefix}` (without `_`); A4 grep guard |
| M2 | medium | Adapter has no streamPrefix field | Drop adapter override from v1; deterministic fallback only; Phase 1.h follow-up noted |
| M3 | medium | storedFields default heuristic incomplete (tuple, Optional<>, dict bracket vs array, user types) | Robust heuristic table; explicit throw for non-optional non-collection without default; A5 test |
| M4 | medium | env var naming inconsistent with existing GENESIS_RUN_E2E_BUILD | A8 uses existing env var name |
| L1 | low | Fixture mutation risk | New dedicated fixture `iam-readmodel-bundle.json`; A7 test uses it; iam-bundle.json untouched |
| L2 | low | streamPrefix edge cases under-tested | Added 8-row example table covering `Context` alone (throw), all-caps, Snake conversion; A5 streamPrefix tests |

---

## Sign-off requirements

- [ ] write-spec output reviewed (this doc, v2)
- [ ] audit-spec pass 1 (internal consistency) — 10 known limits 不與 acceptance 衝突
- [ ] audit-spec pass 2 (Codex external) — done 2026-05-18, 6H+4M+2L resolved
- [ ] decisions.md ratification entry added
- [ ] registry entry status: draft → ready

---

## Spec self-check (4b 通用規則)

- [x] 無 line 錨點
- [x] Goals / Non-goals 互斥（per-aggregate v1 為 scope；context-level + adapter override defer）
- [x] Agent / Human 分段（A1-A9, A11, A12 = Agent runnable；A8 env-gated；A10 manual two-pass integration）
- [x] 無 ≥N counts（3 templates / 12 unit tests / 8 streamPrefix examples 為設計常數）
- [x] depends_on 透明：phase-1f-context-shared-infra (DONE) + 2026-05-18-readmodel-skill (DONE)

## Spec self-check (5b 內部一致性)

- [x] H1 fix ↔ A4 grep gate ↔ §ReadModel.swift template 同步
- [x] H2 normalization ↔ A5 testEventNameNormalizedUpperCamel ↔ §Event type name normalization 同步
- [x] H3 schema validation ↔ A12 error message grep ↔ §Schema validation 同步
- [x] H4/H5 cross-agg reject ↔ §Cross-aggregate handling ↔ A12 ↔ §限制 #1 同步
- [x] H6 scaffold-once ↔ A10 ↔ §NewCommand step ordering #6 ↔ §限制 #5 同步
- [x] M1 split prefix ↔ A4 last grep guard ↔ §JS template + §placeholder table 同步
- [x] M2 drop adapter override ↔ §streamPrefix resolution + §限制 #2 同步
- [x] M3 robust heuristic ↔ §Stored fields default value derivation 程式碼 ↔ A5 storedFields test ↔ §限制 #8
- [x] M4 GENESIS_RUN_E2E_BUILD ↔ A8 command
- [x] L1 new fixture ↔ A7 test + §實作步驟 #8
- [x] L2 edge cases ↔ §streamPrefix examples table ↔ A5 streamPrefix tests
