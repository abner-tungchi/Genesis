# Phase 1.e — Aggregate template 對齊 gradyzhuo/swift-ddd-kit 0.3.0 的 AggregateRoot 結構

## 來源

- Discussion：`docs/discussions/2026-05-15-phase-1e-aggregate-alignment.md`
- Predecessor (done)：`docs/tasks/dddkit-correction.md`
- Facts report：2026-05-15 由 gemini-agent 跨讀 gradyzhuo 0.3.0 source + OC `AuditQuotingAggregate` + Genesis 現有 template/renderer 完成
- Ground truth 路徑：
  - kit source：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/.build/checkouts/swift-ddd-kit/`（0.3.0）
  - 範例 aggregate：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/AuditQuotingAggregate/`

---

## 目標

`dddkit-correction` 修好了 Genesis 產出 `Package.swift` / `PackageTarget` / `Repository` template 的依賴宣告對齊。但 `Aggregate.swift.template` / `CommandExtension.swift.template` / `AggregateError.swift.template` 仍套用舊 Mendesky fork 的 `AggregateRoot` 形狀，造成產出專案 `swift package resolve` 通過、`swift build` 失敗。

本 task 補完這道牆 — 重寫 aggregate template + AggregateRenderer 流水線 + 新增 ProjectionModelRenderer + 升級 BundleParser 解析 readModels + deprecate typedStruct ID 策略（與 kit `Entity where ID == String` 結構性衝突）+ 改 NewCommand 在 SourceWriter.commit 後跑 `swift build` 自動驗證。完成後 `genesis new <Context> --from-bundle <bundle>` 產出的專案能直接 `swift build -c release` 通過。

---

## 介面合約（Interface Contract）

### gradyzhuo `AggregateRoot` 真實協議簽章（facts report 已實證）

```swift
public protocol AggregateRoot: EventStreamNaming, Entity where ID == String {
    associatedtype DeletedEventType: DeletedEvent
    var metadata: AggregateRootMetadata { set get }

    init?(events: [any DomainEvent]) throws
    func when(happened event: some DomainEvent) throws
    func add(domainEvent: some DomainEvent) throws
    func ensureInvariant() throws
    func markDelete() throws
}
```

**關鍵事實**：

- `Entity where ID == String`：transitively 強制 `ID == String`。任何 `typealias ID = NonStringType` 違反此約束。
- **無 `CreatedEventType` associatedtype**（Mendesky fork 有，gradyzhuo 已移除）
- `EventStreamNaming` 由 `AggregateRoot` 繼承；提供 `static var categoryRule: StreamCategoryRule` + `static var category: String`（default `categoryRule = .fromClass(withPrefix: "")` → category = aggregate class 名）
- Default extension 提供：`markDelete()`, `apply(event:)`, `apply(events:)`, `add(domainEvent:)`, `clearAllDomainEvents()`, `ensureInvariant() throws { }`（empty default）
- **不提供** `init?(events:)` default — 由 plugin-generated `{A}AggregateProtocol` extension 提供

### Plugin 產的 `{A}AggregateProtocol`（由 `ModelGeneratorPlugin` 產出）

```swift
// {AccessLevel} protocol {Aggregate}AggregateProtocol: AggregateRoot
//     where ID == String, DeletedEventType == {Aggregate}Deleted {
//     init?(first createdEvent: {CreatedEventType}, other events: [any DomainEvent]) throws
//     func when(event: {NonCreatedEvent_1}) throws
//     ...
//     func when(event: {Aggregate}Deleted) throws
// }
//
// extension {Aggregate}AggregateProtocol {
//     public init?(events: [any DomainEvent]) throws { /* switch createdEvent → init(first:other:) */ }
//     {AccessLevel} func when(happened event: some DomainEvent) throws { /* switch every event → typed when(event:) */ }
// }
```

**關鍵事實**：

- 由 `ModelGeneratorPlugin` 產出（不是 `DomainEventGeneratorPlugin`）；plugin 強制要求 `event.yaml` + `projection-model.yaml` + `event-generator-config.yaml` 三檔同時存在
- `{A}AggregateProtocol` 名稱由 generator 取 target name 直接加 `Protocol` 後綴 — Genesis 的 aggregate target 名為 `{A}Aggregate`，故生成名為 `{A}AggregateProtocol`
- `init?(first:other:)` 是要求（不是 default）
- `when(event:)` 列表 **明確排除 createdEvent**（generator 邏輯 `AggregateRootGenerator.swift` 行 20/54）；createdEvent 的 payload 須在 init 內處理，不可寄望 `when(event: {Created})` callback
- `when(happened:)` 與 `init?(events:)` 由 plugin 提供 default — aggregate 不可手寫，否則語義衝突

### Genesis 產出的 `{Aggregate}.swift` 形狀（重寫後）

```swift
import DDDKit
import Foundation

package class {Aggregate}: {Aggregate}AggregateProtocol {
    package let id: String
    package var metadata: AggregateRootMetadata = .init()

{StateFieldDecls}

    package static var category: String {
        "{CategoryPrefix}\(Self.self)"
    }

    package init(id: String{CreatedEventInitParams}) throws {
        self.id = id
{CreatedEventStateAssignments}
        // GENESIS-STUB: validate input via ensureInvariant() before emitting createdEvent
        let event = {CreatedEventTypeName}(
            id: UUID(){CreatedEventInvocationList},
            occurred: .now
        )
        try self.apply(event: event)
    }

    package required convenience init?(first createdEvent: {CreatedEventTypeName}, other events: [any DomainEvent]) throws {
        try self.init(
            id: createdEvent.{CreatedEventAliasName}{CreatedEventReplayList}
        )
        try self.apply(events: events)
        try self.clearAllDomainEvents()
    }

    package func ensureInvariant() throws {
        // GENESIS-STUB: validate {Aggregate} invariants; throw {Aggregate}Error.xxx on violation
    }
}
```

**Placeholder 清單**（resolver 在 AggregateRenderer 內）：

- `{Aggregate}` — aggregate name（例：`UserAccessProfile`）
- `{CategoryPrefix}` — `contextName.filter { $0.isUppercase }`（例：IAMContext → `IAMC`、QuotationContext → `QC`、OpportunityContext → `OC`、AuditQuotingContext → `AQC`）
- `{StateFieldDecls}` — 每行 `    package var {field}: {Type}?`（Optional + populated by `when(event:)` in Commands/）；維持 Phase 1.b 慣例。**重要**：來源是 `aggregateSpec.state`（與 Phase 1.b 一致），不是 createdEvent payload
- `{CreatedEventTypeName}` — createdEvent 結構名（從 `event.yaml` 找 `kind: createdEvent` 條目；用 Phase 1.b 的 createdEvent heuristic 三層 fallback）
- `{CreatedEventAliasName}` — createdEvent 的 `aggregateRootId.alias` 值（例：UserAccessProfile 的 createdEvent alias `userAccessProfileId`）
- `{CreatedEventInitParams}` — `, {field1}: {Type1}, {field2}: {Type2}` 串列。**來源**：建立該 aggregate 的 UC（即 `bundle.useCases.first { $0.aggregate == spec.name && $0.emittedEvent == createdEventName }`）的 `eventPayload: [FieldSpec]`（**非 `input`**），過濾掉 `name == createdEventAlias` 的條目（alias 對應 `id` param）。空 eventPayload → 整段為空字串
- `{CreatedEventStateAssignments}` — 每行 `        self.{field} = {field}`（縮排 8 空格）。**來源**：`eventPayload` 過濾 alias 後的每個欄位 ∩ `aggregateSpec.state` 的欄位（**取交集**）。**為什麼必要**：plugin 的 `when(event:)` 列表排除 createdEvent，故 createdEvent 的 payload 不會經 `when(event:)` 回灌到 state；必須在 init body 直接賦值，否則 state 永遠 nil。比對 OC `AuditQuoting.init(id:, ...)` 確認此 pattern。⚠️ **fail-fast 規則**：若 eventPayload 有欄位（filter alias 後）**不在** `aggregateSpec.state` 中（IAM bundle 實證會發生：createdEvent payload `initialPermissions` / `initialRoles` vs state `permissions` / `roles`），AggregateRenderer **必須 throw** `GenesisError.bundleInvalid(reason: "createdEvent payload field '\(name)' has no matching state field in aggregate '\(spec.name)'; adapter mapping required (typedStruct deprecated; no mapping mechanism in Phase 1.e — must add or remove from bundle)")`。**不可** silently emit `self.{nonStateField} = ...`（會生成不存在 property，build fail 但錯誤訊息差）。Adapter 層的 payload-to-state mapping 屬 Phase 1.f 範疇；Phase 1.e 採 fail-fast。
- `{CreatedEventInvocationList}` — 對應 init 內 event 建構，**alias 永遠放第一位**（對齊 kit `EventStructureGenerator` 產的 event init 簽章 + OC `AuditQuotingCreated(quotingId: id, ...)` 慣例）：`,\n            {CreatedEventAliasName}: id,\n            {field1}: {field1},\n            {field2}: {field2}` 串列。**順序固定**：alias-first, 然後 eventPayload 順序（與 plugin 產的 event struct init 簽章順序一致；implementer Step 4 跑 IAM bundle 確認 generated event init 簽章 alias 是否真的在第一位，若不是則 Genesis 用 named args 不依賴順序）
- `{CreatedEventReplayList}` — 對應 convenience init `self.init(id:, ...)` delegation，**alias 不在此（外層已有 `id: createdEvent.{alias}`）**：`,\n            {field1}: createdEvent.{field1},\n            {field2}: createdEvent.{field2}` 串列。每個 `payloadFields` 過濾後欄位皆 emit（不再 filter state — 因若 fail-fast 已過，所有 payloadFields 皆 ∈ state）

### Genesis 產出的 `{Aggregate}+Delete.swift` 形狀（新檔）

```swift
extension {Aggregate} {
    package func when(event: {Aggregate}Deleted) throws {
        self.metadata.delete()
    }
}
```

**為什麼必要**：plugin-generated `{A}AggregateProtocol` 的 `when(event:)` 列表**包含 deletedEvent**（generator 行為已實證；OC `AuditQuoting+Delete.swift` 即此 pattern）。若 Genesis 不產此檔，aggregate 無法 conform `{A}AggregateProtocol`、build fail。

**Path**：`Sources/{A}Aggregate/Entity/Commands/{A}+Delete.swift`

**Placeholder**：僅 `{Aggregate}`。簡單 1-placeholder template。

⚠️ 不需 `markDelete()` command method（gradyzhuo `AggregateRoot` extension 提供 default `markDelete()` 會 build `DeletedEventType` + apply；OC `+Delete.swift` 也只寫 `when(event:)`）。

**為什麼 Aggregate 是非 final `class`**：

- gradyzhuo `Entity: AnyObject` 允許 class（非 struct）
- `required convenience init?(first:other:)` 在非 final class 工作良好且 OC `AuditQuotingAggregate` 即如此
- 非 final 允許 test double 與未來 migration extension；除非有具體理由鎖 final，預設非 final
- ⚠️ 不寫 `package typealias ID = String`：`Entity where ID == String` 已 transitively 鎖定，typealias 是冗餘且當 `{IDType}` resolve 成非 String 時會違約

**為什麼移除手寫 `when(happened:)` switch**：

- plugin-generated `{A}AggregateProtocol` extension 提供 default impl
- 同名實作會 shadow generator default 或產生 ambiguity，與 OC 慣例不符（OC 的 `AuditQuoting` 不寫 `when(happened:)`）

**為什麼 `init?(first:other:)` 帶完整 createdEvent payload delegation**：

- gradyzhuo 不提供 `init?(events:)` default — 由 plugin extension 提供
- plugin 的 default `init?(events:)` 邏輯：switch firstEvent → `try self.init(first: firstEvent, other: events)`
- 故 `init(first:other:)` 必須將 createdEvent 的所有 payload 重新塞回 `init(id:, ...)`，以保持 write path 與 rehydrate path 行為一致（OC `AuditQuoting` 即如此）

### Genesis 產出的 `{Aggregate}Error.swift` 形狀（改後）

```swift
package enum {Aggregate}Error: Error, Equatable {
{ErrorCases}
}
```

- `Error, Equatable` 取代 `Error, Sendable`（OC 慣例；enum 預設 Sendable，無需顯式）
- 不產 `extension ContextError where ErrorType == {A}Error` factory — `ContextError` 屬 context-shared infra（OC 由 `OCShared` 提供），不在 Genesis 範圍；保留給 per-feature `/usecase` skill 補

### Genesis 產出的 `CommandExtension.swift` 形狀（comment cleanup）

```swift
import DDDKit
import Foundation

extension {Aggregate} {
    package func {useCaseCamelCase}({CommandParams}) throws {
        // GENESIS-STUB: 1) call ensureInvariant() preconditions 2) build {EventTypeName} 3) try self.apply(event: ...)
        fatalError("not implemented")
    }

    // Called by the plugin-generated `when(happened:)` dispatch when event matches {EventTypeName}.
    package func when(event: {EventTypeName}) throws {
        // GENESIS-STUB: mutate state from event.<payload-fields>, e.g. `self.foo = event.foo`.
        // ⚠️ this is the file where state actually changes during replay; do NOT mutate in {useCaseCamelCase}().
    }
}
```

- 簽章 + body 與 Phase 1.b 一致
- 註解中「Aggregate.when(happened:) switch dispatch」改寫為「plugin-generated `when(happened:)` dispatch」（事實對齊）
- 沒有 `+Create{A}.swift` 對應檔（createdEvent 在 init 內處理）

### Genesis 產出的 `projection-model.yaml` 形狀（新檔）

```yaml
{ProjectionModelEntries}
```

每個 entry 形狀：

```yaml
{ReadModelName}:
  model: readModel
  events:
    - {Event1}
    - {Event2}
```

**邏輯**：

- 若 `bundle.readModels[]` 非空：將每個 ReadModelSpec 渲染為一個 entry。`ReadModelSpec.name` → entry key；`ReadModelSpec.eventNames` → events list
- 若 `bundle.readModels[]` 為空：emit 1 個 fallback entry 確保 plugin 有東西可吃：
  ```yaml
  Get{Aggregate}Existence:
    model: readModel
    events:
      - {CreatedEventTypeName}
  ```
  Fallback 對「每個 aggregate」執行 — ProjectionModelRenderer 是 per-aggregate render（Step 3 確認），故每個 aggregate 都自帶一個 fallback entry，使用該 aggregate 的 createdEvent 作為 trigger
- ⚠️ Plugin tolerance：實作期實測 `ModelGeneratorPlugin` 對「至少 1 entry」是充分條件（OC `AuditQuoting` 有 15 entries 全 pass；空 yaml 未實測，故採保底 fallback 而非空檔）

### `PackageTarget.swift.template` 改動（加 plugin）

```diff
            plugins: [
                .plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit"),
+               .plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit"),
            ]
```

- Plugin 名 `ModelGeneratorPlugin`（facts report 從 gradyzhuo `Package.swift` 行 41-43 確認）
- 不加 `GenerateKurrentDBProjectionsPlugin`（command plugin，非 build-time codegen，留 Phase 1.f）

### Path layout（OC 對齊）

| Phase 1.b 路徑 | Phase 1.e 路徑 |
|---|---|
| `Sources/{A}Aggregate/{A}.swift` | `Sources/{A}Aggregate/Entity/{A}.swift` |
| `Sources/{A}Aggregate/Adapter/{A}Repository.swift` | `Sources/{A}Aggregate/Usecase/Port/Out/{A}Repository.swift` |
| `Sources/{A}Aggregate/{A}Error.swift` | （不變，aggregate flat dir） |
| `Sources/{A}Aggregate/event.yaml` | （不變） |
| `Sources/{A}Aggregate/event-generator-config.yaml` | （不變） |
| `Sources/{A}Aggregate/Entity/Commands/{A}+{UC}.swift` | （不變，Phase 1.b 已對位） |
| — | `Sources/{A}Aggregate/projection-model.yaml`（**新**） |

對齊 OC `Sources/AuditQuotingAggregate/` 觀察的 canonical layout（facts report §2）。

### `event.yaml` deletedEvent 形狀改動

Phase 1.b 一律輸出：

```yaml
{A}Deleted:
  kind: deletedEvent
  aggregateRootId:
    alias: {alias}
  properties: []
```

Phase 1.e 改為：

```yaml
{A}Deleted:
  kind: deletedEvent
```

對齊 OC `AuditQuoting` event.yaml 中 `AuditQuotingDeleted:\n  kind: deletedEvent`。其他 createdEvent / domainEvent 條目 yaml 不變。

### AdapterApplier `typedStruct` 處理（deprecation）

```swift
// Sources/GenesisCore/AdapterApplier.swift
public static func resolveIdWrapper(for aggregate: AggregateSpec, adapter: Adapter) -> String? {
    guard adapter.idStrategy.kind == .typedStruct else { return nil }
    // ⚠️ Phase 1.e deprecation: gradyzhuo/swift-ddd-kit 0.3.0 enforces `Entity where ID == String`,
    // which makes typed-struct ID wrappers structurally incompatible. Emit warning + fall back.
    FileHandle.standardError.write(Data(
        "⚠️ idStrategy.typedStruct is deprecated in Genesis (gradyzhuo kit enforces ID == String). Falling back to .direct for \(aggregate.name).\n"
            .utf8
    ))
    return nil
}
```

`SharedTargetRenderer.makePlanForCustomTypes` 對 `typedStruct` 觸發的自動 wrapper 生成 → 改為 noop（Aggregate 端不再需要 wrapper；如 user 自家 DTO 需要 `{A}ID` wrapper，留 per-feature 範疇）。

### `NewCommand` 加 `swift build` 驗證

```
[NewCommand.run] (after SourceWriter.commit)
    ProcessRunner.run(executable: "swift", args: ["build", "-c", "release"], cwd: outputDir)
    → exit code:
        0 → success path（既有 manifest write + manifest path stdout）
        非 0 → throw GenesisError.swiftBuildFailed(stderr) → exit 2
            → SourceWriter.rollback（刪所有 generated files）
            → 若 dirCreatedByThisRun && empty → 刪 output dir
            → git stash pop / branch restore（既有 GitPreflight 邏輯）
```

⚠️ 為了讓 resolve 失敗 vs build 失敗對應到不同 GenesisError，本 task 採「先顯式 `swift package resolve` 再顯式 `swift build`」兩階段（詳見 Step 9）。Resolve 階段抓 kit 巨型依賴鏈，冷跑約 5-10 分鐘；build 階段冷跑約 5-10 分鐘。timeout 各設 10 / 15 分鐘。

---

## 改動檔案

| 檔案 | 改動描述 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template` | 全面 rewrite — conform `{A}AggregateProtocol`、`let id: String`、init 包 createdEvent payload、移除 `when(happened:)` switch、加 `category` prefix |
| `Sources/GenesisCore/Resources/Templates/v0.1/AggregateError.swift.template` | `Error, Sendable` → `Error, Equatable` |
| `Sources/GenesisCore/Resources/Templates/v0.1/CommandExtension.swift.template` | 註解中「Aggregate.when(happened:) switch dispatch」改寫為「plugin-generated `when(happened:)` dispatch」 |
| `Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template` | plugins list 加 `ModelGeneratorPlugin` |
| `Sources/GenesisCore/Resources/Templates/v0.1/projection-model.yaml.template` | **新檔** — 整檔僅含 `{ProjectionModelEntries}` placeholder |
| `Sources/GenesisCore/Resources/Templates/v0.1/projection-model.yaml.entry.template` | **新檔** — per-entry sub-template |
| `Sources/GenesisCore/Resources/Templates/v0.1/DeleteCommandExtension.swift.template` | **新檔** — `extension {A} { func when(event: {A}Deleted) throws { self.metadata.delete() } }` |
| `Sources/GenesisCore/AggregateRenderer.swift` | 多項改動：path 改 `Entity/` + `Usecase/Port/Out/`、deletedEvent yaml 特例化、call `ProjectionModelRenderer`、render `+Delete.swift`、createdEvent 萃取進 init params（**用 `UseCaseSpec.eventPayload`，不是 `input`**）、render `{CreatedEventStateAssignments}`、用 contextName 推 categoryPrefix、id 永遠 String |
| `Sources/GenesisCore/ProjectionModelRenderer.swift` | **新檔** — 從 `bundle.readModels[]` 或 fallback 規則產 yaml |
| `Sources/GenesisCore/FullBundle.swift` | 加 `public struct ReadModelSpec` + `readModels: [ReadModelSpec]` field 到 `FullBundle` |
| `Sources/GenesisCore/BundleParser.swift` | 移除 `readModels not supported` reject 路徑；解析 envelope.readModels 為 `ReadModelSpec` |
| `Sources/GenesisCore/AdapterApplier.swift` | `resolveIdWrapperName` 對 `typedStruct` 改為 warning + 回傳 nil |
| `Sources/GenesisCore/SharedTargetRenderer.swift` | 對 `typedStruct` 觸發的 auto-wrapper 生成 → noop（保留 customTypes-driven wrapper） |
| `Sources/GenesisCore/PackageRenderer.swift` | `needsShared` 計算移除 `|| adapter.idStrategy.kind == .typedStruct` 條件（與 typedStruct deprecation 連動） |
| `Sources/Genesis/Commands/NewCommand.swift` | (1) `needsShared` 計算移除 typedStruct 條件；(2) SourceWriter.commit 後加 `swift package resolve` + `swift build` 驗證 + rollback |
| `Sources/GenesisCore/BusinessDocRenderer.swift` | `let idType = AdapterApplier.resolveIdWrapperName(...) ?? "String"` 註解為 typedStruct deprecated 後一律 fallback to `"String"`；行為仍正確（因 resolveIdWrapperName 對 typedStruct return nil） |
| `Sources/GenesisCore/ProcessRunner.swift` | `run(executable:args:cwd:)` 加 optional `timeout: TimeInterval?` 參數；timeout 觸發時 kill process + 回 timeout exit code |
| `Sources/GenesisCore/GenesisError.swift` | **無 schema 改動**（Phase 1.b 已加 `case swiftBuildFailed(stderr: String)` + `exitCode` + `errorDescription` 分支）；本 task 補的是該 case 的 throw site |
| `Tests/GenesisCoreTests/AggregateRendererTests.swift` | path / content 斷言全面更新對齊新 layout + 新 placeholder |
| `Tests/GenesisCoreTests/ProjectionModelRendererTests.swift` | **新檔** — unit tests for ProjectionModelRenderer（含 fallback path）|
| `Tests/GenesisCoreTests/BundleParserFullTests.swift` | 加 readModels 解析測試（含空陣列、非空陣列、缺欄位三種情境）|
| `Tests/GenesisCoreTests/AdapterApplierTests.swift` | 加 typedStruct deprecation warning 測試（stderr 含預期字串、回傳 nil） |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | `testFullBundleEndToEnd` path 斷言更新；加 `testEndToEndSwiftBuild`（e2e build pass） |
| `Tests/GenesisIntegrationTests/Fixtures/iam-bundle-with-readmodels.json` | **新檔** — 含 readModels[] 的 fixture（用於 ProjectionModelRenderer 整合測試） |
| `docs/tasks/phase-1b-aggregate-extraction.md` | 加 partial-supersede banner（aggregate template / paths）+ inline 標記 |
| `docs/tasks/phase-1c-adapter-and-manifest.md` | 加 partial-supersede 註記（typedStruct deprecation） |
| `docs/decisions.md` | 加 Phase 1.e ratification entry |
| `docs/architecture.md` | §3 path layout 更新；§10.1 Repository 路徑改 Usecase/Port/Out/、新增 §10.2 ModelGeneratorPlugin / `{A}AggregateProtocol` 說明 |

**已確認不需改動**（write-spec step 3b 已逐一檢視）：

- `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template`（不變；dddkit-correction 已對齊）
- `Sources/GenesisCore/Resources/Templates/v0.1/Repository.swift.template`（不變；dddkit-correction 已是 struct + KurrentStorageCoordinator）
- `Sources/GenesisCore/UseCaseRenderer.swift`（不變；產 Port/In/、Service/、Adapter/{UC}/ApplicationService.swift 已對位）
- `Sources/GenesisCore/DtoRenderer.swift`、`ContextLevelRenderer.swift`、`ManifestRenderer.swift`、`ReadmeRenderer.swift`（無 aggregate 結構耦合）
  - ⚠️ **`PackageRenderer.swift`**：Step 2 改動其 `needsShared` 計算（移除 `|| typedStruct` 子條件），不算「不需改動」
  - ⚠️ **`SharedTargetRenderer.swift`**：Step 2 移除其 typedStruct auto-wrapper 分支
  - ⚠️ **`BusinessDocRenderer.swift`**：Step 2 加 inline comment + 既有 fallback 邏輯自動正確（resolveIdWrapperName 返 nil → "String"）
- `event.yaml.template`、`event.yaml.event.template`、`event-generator-config.yaml.template`（除 deletedEvent 邏輯特例化在 renderer 端，template 不變）
- `AdapterYamlParser.swift`（schema 不變，typedStruct yaml 仍可 parse）

---

## 實作步驟

### Step 1 — BundleParser + FullBundle 加 ReadModelSpec

1. `Sources/GenesisCore/FullBundle.swift` 加：
   ```swift
   public struct ReadModelSpec: Sendable, Equatable {
       public let readModelSpecId: String
       public let aggregateSpecId: String?  // optional: bundle may scope readModel to specific aggregate; nil = context-level
       public let name: String
       public let eventNames: [String]
       public init(readModelSpecId: String, aggregateSpecId: String?, name: String, eventNames: [String]) { ... }
   }
   ```
   並加 `public let readModels: [ReadModelSpec]` 到 `FullBundle`（含 init param + initializer 體）
2. `Sources/GenesisCore/BundleParser.swift`：
   - 移除 `if let rm = envelope.readModels, !rm.isEmpty { throw .bundleInvalid(reason: "readModels are not supported in Phase 1.b; planned for Phase 1.c+") }`
   - 新增 `parseReadModels(envelope.readModels)` private helper：
     - 對每個 JSON 條目，取 `readModelSpecId: String`、`aggregateSpecId: String?`（optional）、`name: String`、`eventNames: [String]`
     - **JSON 欄位名假設**（spec 寫作時 IAM bundle 只見空陣列；實作期 Step 1 必須從 Cosmogony 取非空 readModels 範例 cross-check）：
       - 預設嘗試 `eventNames` → 若不存在 fallback 嘗試 `events`（兩種命名都常見）
       - `aggregateSpecId` 可能存在 / 不存在 — 不在 envelope 則設 nil
     - 缺必填欄位（readModelSpecId、name、events/eventNames 至少一個）→ throw `bundleInvalid(reason: "readModel.<field> missing")`
   - `parseFull` 回傳 `FullBundle(...)` 時 `readModels: readModelSpecs`
3. 測試：`BundleParserFullTests` 加：
   - `testReadModelsEmpty`：bundle `"readModels": []` → parseFull 後 `bundle.readModels.isEmpty`
   - `testReadModelsParsedWithEventNames`：custom bundle 含 1 readModel 用 `eventNames` 欄位 → parseFull 後 `bundle.readModels.count == 1`、name/eventNames 正確
   - `testReadModelsParsedWithEvents`：custom bundle 用 `events` 欄位（fallback）→ 仍正確解析
   - `testReadModelMissingField`：缺 `name` → throw `bundleInvalid`，reason 含 `readModel.name`
   - `testReadModelWithAggregateScope`：bundle 含 `aggregateSpecId` 欄位 → ReadModelSpec.aggregateSpecId 非 nil
   - `testReadModelWithoutAggregateScope`：bundle 不含 `aggregateSpecId` → ReadModelSpec.aggregateSpecId == nil

⚠️ **JSON schema 風險**：Cosmogony 真實 export 的 readModel 條目 schema 在 spec 寫作時無法驗證（IAM bundle 為空）。Step 1 第一個動作就是取一個 Cosmogony 含 readModels 的 bundle export 確認欄位名。若 schema 不符上述假設，調整 parser + 回填 spec + 加 status_history note；不阻擋進行，只需局部修正。

### Step 2 — typedStruct full deprecation（5 個檔案）

**目標**：所有 codebase 中對 `idStrategy.kind == .typedStruct` 的處理改為 fallback to direct + warning。覆蓋下列 4 個檔案：

1. `Sources/GenesisCore/AdapterApplier.swift` `resolveIdWrapperName`：
   - 若 `adapter.idStrategy.kind == .typedStruct`：
     - `FileHandle.standardError.write` 一行 warning（具體訊息見「介面合約」段）
     - 回傳 nil（讓下游當作 `.direct` 處理）
   - 既有 `.direct` 路徑不變
2. `Sources/GenesisCore/SharedTargetRenderer.swift`：
   - 移除 `if adapter.idStrategy.kind == .typedStruct { ... }` 分支對 missing wrapper 的 auto-补 邏輯（Phase 1.c H1 fix 加的那段）→ noop
   - 既有 customTypes-driven Shared target 邏輯維持（user 手動在 yaml 列 customTypes 仍會生成）
3. `Sources/GenesisCore/PackageRenderer.swift` `needsShared` 計算：
   - 從 `let needsShared = !bundle.dtos.isEmpty || ... || adapter.idStrategy.kind == .typedStruct || ...` 移除 `|| adapter.idStrategy.kind == .typedStruct` 子條件
   - 其他 needsShared 觸發條件不變
4. `Sources/Genesis/Commands/NewCommand.swift` `needsShared` 計算（同 PackageRenderer 鏡像值，避免兩處不一致）：
   - 從含 `|| adapter.idStrategy.kind == .typedStruct` 移除該子條件
5. `Sources/GenesisCore/BusinessDocRenderer.swift`：
   - 既有 `let idType = AdapterApplier.resolveIdWrapperName(for: spec, adapter: adapter) ?? "String"` 行為**自動正確**（resolveIdWrapperName 對 typedStruct 已 return nil → fallback to "String"）
   - 在該行加 inline comment 記載「typedStruct deprecated; always falls back to String」

**測試**：
   - `AdapterApplierTests.testTypedStructEmitsWarningAndReturnsNil`：捕捉 stderr，assert 含 `idStrategy.typedStruct is deprecated`，回傳 nil
   - `AdapterApplierTests.testDirectReturnsNil`：既有 `.direct` 行為不變
   - `SharedTargetRendererTests.testTypedStructDoesNotEmitAutoWrapper`：給 typedStruct adapter + 空 customTypes → output 不含 `{A}ID` wrapper file（既有 Phase 1.c testWithAdapterTypedStruct 改測此 inverted 行為）
   - `PackageRendererTests.testTypedStructDoesNotForceSharedTarget`：給 typedStruct adapter + 空 dtos + 空 customTypes → output 不含 `IAMContextShared` library
   - `NewCommandTests.testAdapterTypedStructFallback`（既有 Phase 1.c 測試 inverted）：給 typedstruct adapter → exit 0、stderr 含 deprecation warning、不產 `{A}ID.swift`

### Step 3 — ProjectionModelRenderer + sub-templates

1. 新檔 `Sources/GenesisCore/Resources/Templates/v0.1/projection-model.yaml.template`：
   ```
   {ProjectionModelEntries}
   ```
2. 新檔 `Sources/GenesisCore/Resources/Templates/v0.1/projection-model.yaml.entry.template`：
   ```
   {ReadModelName}:
     model: readModel
     events:
   {EventList}
   ```
   其中 `{EventList}` 每行 `    - {EventName}`
3. 新檔 `Sources/GenesisCore/ProjectionModelRenderer.swift`：
   ```swift
   public enum ProjectionModelRenderer {
       public static func render(
           aggregateName: String,
           aggregateSpecId: String,
           aggregateEventNames: Set<String>,  // events declared in this aggregate's event.yaml
           createdEventTypeName: String,
           readModels: [ReadModelSpec]
       ) throws -> (path: String, content: String, role: String) {
           // Scope: include only readModels whose aggregateSpecId matches OR is nil (context-level → opt-in for every aggregate).
           // Additionally filter event references to those declared in this aggregate's event.yaml,
           // because plugin's projection-model reference resolution requires the events to exist in same target.
           let scopedReadModels = readModels
               .filter { $0.aggregateSpecId == nil || $0.aggregateSpecId == aggregateSpecId }
               .map { rm in
                   ReadModelSpec(
                       readModelSpecId: rm.readModelSpecId,
                       aggregateSpecId: rm.aggregateSpecId,
                       name: rm.name,
                       eventNames: rm.eventNames.filter { aggregateEventNames.contains($0) }
                   )
               }
               .filter { !$0.eventNames.isEmpty }  // drop entries with no matching events after scope filter
           
           let entries: [String]
           if scopedReadModels.isEmpty {
               entries = [makeFallbackEntry(aggregateName: aggregateName, createdEventTypeName: createdEventTypeName)]
           } else {
               entries = scopedReadModels.map { makeEntry(name: $0.name, events: $0.eventNames) }
           }
           let content = TemplateRenderer.render(template: template, vars: ["ProjectionModelEntries": entries.joined(separator: "\n\n")])
           return ("Sources/\(aggregateName)Aggregate/projection-model.yaml", content, "projection-model")
       }
       
       private static func makeFallbackEntry(aggregateName: String, createdEventTypeName: String) -> String {
           // emits:
           //   Get{Aggregate}Existence:
           //     model: readModel
           //     events:
           //       - {CreatedEventTypeName}
           ...
       }
       
       private static func makeEntry(name: String, events: [String]) -> String { ... }
   }
   ```
4. 測試 `ProjectionModelRendererTests`：
   - `testRenderEmptyReadModelsEmitsFallback`：空 list → output 含 `Get{A}Existence` entry，events list 為 createdEvent
   - `testRenderNonEmptyReadModelsScopedToAggregate`：給 3 readModel（2 屬於 aggregate A、1 屬於 aggregate B）→ 對 aggregate A render 只含 2 entries（B 的被 filter 掉）
   - `testRenderContextLevelReadModelIncludedInAllAggregates`：給 1 readModel `aggregateSpecId == nil` → 對任何 aggregate render 都含此 entry
   - `testRenderFiltersUnknownEvents`：readModel 引用不在當前 aggregate event.yaml 內的 event → 該 event 從 entry 中過濾
   - `testRenderDropsEntryAfterFilteringAllEvents`：readModel 引用的 events 全不在當前 aggregate → 該 entry 整個被 drop（若 drop 後 0 entries 則 fallback）
   - `testRenderPathIsExpected`：path == `Sources/{A}Aggregate/projection-model.yaml`，role == `projection-model`
   - `testEventListIndentation`：events 縮排正確（2-space indent yaml）

### Step 4 — Aggregate.swift.template rewrite + AggregateRenderer

1. 改寫 `Aggregate.swift.template`（完整內容見「介面合約 > Genesis 產出的 `{Aggregate}.swift` 形狀」）
2. `AggregateRenderer.renderAggregate(...)` 改動：
   - 從 `bundle.aggregates[i]` + `bundle.useCases` 找該 aggregate 的 createdEvent name（沿用 Phase 1.b 既有 createdEvent heuristic）
   - 從 `event.yaml` 內 createdEvent 的 `properties` 萃取出 createdEvent payload fields：`[(name: String, type: String)]`（沿用 Phase 1.b 既有 properties resolver）
   - 從 `event.yaml` 內 createdEvent 的 `aggregateRootId.alias` 取 alias name
   - 計算 `categoryPrefix = contextName.filter { $0.isUppercase }`
   - **Fail-fast**：在 placeholder dict 建構**前**，驗證 `payloadFields ⊆ aggregateSpec.state`：
     ```
     let stateFieldNames = Set(spec.state.map { $0.name })
     let orphanFields = payloadFields.filter { !stateFieldNames.contains($0.name) }
     if !orphanFields.isEmpty {
         throw GenesisError.bundleInvalid(
             reason: "createdEvent payload field(s) \(orphanFields.map { $0.name }) have no matching state in aggregate '\(spec.name)'; adapter mapping required (not supported in Phase 1.e)"
         )
     }
     ```
   - 建構 placeholder dict：
     ```
     Aggregate: spec.name
     CategoryPrefix: categoryPrefix
     StateFieldDecls: spec.state.map { "    package var \($0.name): \($0.resolvedType)?" }.joined("\n")
     CreatedEventTypeName: createdEventName
     CreatedEventAliasName: alias
     CreatedEventInitParams: payloadFields.map { ", \($0.name): \($0.type)" }.joined("")
     CreatedEventStateAssignments: payloadFields.map { "        self.\($0.name) = \($0.name)" }.joined("\n")
     CreatedEventInvocationList: ",\n            \(alias): id" + payloadFields.map { ",\n            \($0.name): \($0.name)" }.joined("")
     CreatedEventReplayList: payloadFields.map { ",\n            \($0.name): createdEvent.\($0.name)" }.joined("")
     ```
   - return `("Sources/\(spec.name)Aggregate/Entity/\(spec.name).swift", content, "aggregate")` ← **新路徑**
3. ⚠️ Pseudocode 完整 createdEvent payload extraction（含 alias 對齊；source of truth = `UseCaseSpec.eventPayload`）：
   ```
   func extractCreatedEventInfo(spec: AggregateSpec, bundle: FullBundle, adapter: Adapter) throws -> (
       typeName: String,
       alias: String,
       payloadFields: [(name: String, type: String)]
   ) {
       let createdEventName = resolveCreatedEventName(for: spec, useCases: bundle.useCases)  // Phase 1.b heuristic
       // alias = aggregate identity name as authored in bundle (NO case transform — bundle's identityName
       // is already the desired alias e.g. "userAccessProfileId"; transforming may drift from event.yaml alias).
       let alias = spec.identityName
       // Source of truth = the create UseCase's eventPayload (NOT `input`!).
       // - input = what user supplies to the UC (may map to multiple events)
       // - eventPayload = the canonical payload shape for the emitted event
       // Plugin's `init(first createdEvent:)` signature uses event property names exactly,
       // so we MUST match eventPayload field names (not input).
       guard let createUC = bundle.useCases.first(where: {
           $0.aggregate == spec.name && $0.emittedEvent == createdEventName
       }) else {
           throw GenesisError.bundleInvalid(reason: "No use case emits createdEvent \(createdEventName) for aggregate \(spec.name)")
       }
       let payloadFields = createUC.eventPayload
           .filter { $0.name != alias }  // alias maps to `id` param, not a separate payload field
           .map { (name: $0.name, type: SwiftTypeResolver.resolve($0.rawType, adapter: adapter)) }
       return (createdEventName, alias, payloadFields)
   }
   ```
   ⚠️ Edge case：若 createUC.eventPayload **沒有** alias field（e.g., bundle 把 `userAccessProfileId` 列在 input 但不在 eventPayload），仍把 alias 視為「來自 `id` param」OK；但 plugin event init 簽章會依 eventPayload + alias 順序 — implementer 須測試 alias 是否必須在 payload 首位。實作期 Step 4 跑一次 IAM bundle 確認 generated event init 簽章。
4. 測試 `AggregateRendererTests`：
   - `testAggregateConformsToGeneratedProtocol`：output 含 `class UserAccessProfile: UserAccessProfileAggregateProtocol`
   - `testAggregateHasLetIdString`：output 含 `package let id: String`，不含 `typealias ID = ` / `typealias CreatedEventType = `
   - `testAggregateHasCategoryPrefix`：contextName=`IAMContext` → output 含 `"IAMC\(Self.self)"`
   - `testAggregateHasNoWhenHappened`：output 不含 `when(happened` 字串
   - `testAggregateInitHasCreatedEventPayload`：給有 3 payload field 的 createdEvent → init 簽章含 3 params
   - `testAggregateConvenienceInitDelegates`：output 含 `try self.init(\n            id: createdEvent.` 串列
   - `testAggregatePath`：path == `Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift`
   - **`testCreatedEventStateAssignmentsSkipNonStatePayload`**（high-priority defense）：給 createdEvent payload 含 `initialPermissions` 但 state 只有 `permissions` → AggregateRenderer.render throws `GenesisError.bundleInvalid` 且 reason 含 `initialPermissions` + `no matching state`。**否則 IAM bundle 的 orphan field bug 會 silently 生成不存在 property、build fail 但訊息差**
   - **`testCreatedEventInvocationIncludesAliasFirst`**（high-priority defense）：output 含 `\(alias): id` 在 event 建構 args 第一位（位於 `id: UUID()` 後第一個非 id arg）；對齊 OC `AuditQuotingCreated(quotingId: id, ...)` 慣例
   - `testCreatedEventPayloadZeroFields`：createdEvent 無 payload（除 alias）→ `{CreatedEventInitParams}` / `{CreatedEventStateAssignments}` / `{CreatedEventReplayList}` 皆空字串，`{CreatedEventInvocationList}` 只含 alias 行
   - `testCreatedEventPayloadFiveFields`：5 payload field → 各 placeholder 各產 5 行/條目，排版正確（逗號、縮排）

### Step 5 — AggregateError shape change

1. `AggregateError.swift.template` body 第一行：
   ```
   package enum {Aggregate}Error: Error, Equatable {
   ```
   （取代 `Error, Sendable`）
2. 測試 `AggregateRendererTests.testErrorEnumShape`：output 含 `: Error, Equatable {`，不含 `Sendable`

### Step 6 — PackageTarget 加 ModelGeneratorPlugin

1. `PackageTarget.swift.template` plugins list：
   ```diff
                .plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit"),
   +            .plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit"),
            ]
   ```
2. 測試 `PackageRendererTests`：
   - 加 `XCTAssertTrue(result.content.contains("ModelGeneratorPlugin"))`
   - 加 `XCTAssertTrue(result.content.contains(".plugin(name: \"ModelGeneratorPlugin\", package: \"swift-ddd-kit\")"))`

### Step 7 — AggregateRenderer 路徑改 Entity/、Usecase/Port/Out/

1. `renderAggregate` return path：`Sources/{A}Aggregate/Entity/{A}.swift`（見 Step 4 已包含）
2. `renderRepository` return path：`Sources/{A}Aggregate/Usecase/Port/Out/{A}Repository.swift`（取代既有 `Sources/{A}Aggregate/Adapter/{A}Repository.swift`）
3. 測試 `AggregateRendererTests`：
   - `testRepositoryPath`：path == `Sources/.../Usecase/Port/Out/UserAccessProfileRepository.swift`
   - `testAggregatePath`：（Step 4 重用）path == `Sources/.../Entity/UserAccessProfile.swift`
4. 測試 `NewCommandTests.testFullBundleEndToEnd`：對應 path 斷言更新

### Step 8 — deletedEvent yaml 特例化

1. `AggregateRenderer.renderEventBlock`（或 EventYamlRenderer 對應位置）：
   - 若 `event.kind == "deletedEvent"`：output 僅 `{EventName}:\n  kind: deletedEvent`，**不**追加 aggregateRootId block + properties block
   - 其他 kind（createdEvent / domainEvent）邏輯不變
2. 測試：
   - `AggregateRendererTests.testEventYamlDeletedEventShape`：output 含 `UserAccessProfileDeleted:\n  kind: deletedEvent` block；該 block 內**不**含 `aggregateRootId:` / `properties:` 字串
   - `AggregateRendererTests.testEventYamlCreatedEventStillHasAlias`：createdEvent block 仍含 `aggregateRootId:\n    alias:` （regression test）

### Step 9 — NewCommand: ProcessRunner timeout + swift package resolve + swift build validation

**為什麼分兩步跑 resolve + build**：
- 顯式跑 `swift package resolve` 先驗依賴 → 失敗 → `swiftPackageResolveFailed`（exit 2）
- 顯式跑 `swift build -c release` → 失敗 → `swiftBuildFailed`（exit 2）
- 兩 case 對應到不同 GenesisError 與不同 stderr，使用者收到的 message 對應正確類別（不再依賴 stderr-pattern 啟發式）

1. `Sources/GenesisCore/ProcessRunner.swift`：加 optional `timeout: TimeInterval?` 參數：
   - 簽章：`public static func run(executable: String, args: [String], cwd: URL? = nil, timeout: TimeInterval? = nil) -> ProcessResult`
   - timeout 邏輯（**SIGTERM grace + SIGKILL fallback**，不可只 `terminate()`）：
     ```
     guard let timeout else { /* existing behavior unchanged */ return run(...) }
     let timeoutFlag = Atomic<Bool>(false)
     DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
         guard process.isRunning else { return }
         timeoutFlag.store(true)
         process.terminate()  // SIGTERM
         // Grace: 3s for stubborn children that ignore SIGTERM
         DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
             if process.isRunning {
                 kill(process.processIdentifier, SIGKILL)  // hard kill
                 // Optional: kill process group via -pid if Swift Process spawned shell wrappers
             }
         }
     }
     process.waitUntilExit()
     if timeoutFlag.load() {
         return ProcessResult(exitCode: -1, stdout: "...", stderr: "[timeout after \(timeout)s; sent SIGTERM, then SIGKILL after 3s grace]\n" + capturedStderr)
     }
     ```
   - **process group 策略**：直接 child kill 即可；不主動 process-group kill（kill -pid 需 setpgid 設定 child 為 process group leader，Swift `Process` 未必如此設定）。已知限制記入 spec。
   - 既有 callers（無 timeout）行為不變（timeout nil = 等同舊 behavior）
2. `Sources/GenesisCore/GenesisError.swift`：無 schema 改動（既有 `case swiftBuildFailed(stderr: String)` + `case swiftPackageResolveFailed(stderr: String)` + exitCode + errorDescription 全部已就位）。Step 9 只是補 throw site。
3. `Sources/Genesis/Commands/NewCommand.swift`：在 SourceWriter.commit 完成後（manifest 寫入後），在既有的 outer `do { ... } catch { writer.rollback(); ... }` 內加：
   ```
   // Phase 1: resolve (let outer catch handle rollback + dir cleanup)
   let resolveResult = ProcessRunner.run(
       executable: "swift",
       args: ["package", "resolve"],
       cwd: outputURL,
       timeout: 600  // 10 min (cold dependency fetch)
   )
   if resolveResult.exitCode != 0 {
       throw GenesisError.swiftPackageResolveFailed(stderr: resolveResult.stderr)
   }
   
   // Phase 2: build
   let buildResult = ProcessRunner.run(
       executable: "swift",
       args: ["build", "-c", "release"],
       cwd: outputURL,
       timeout: 900  // 15 min
   )
   if buildResult.exitCode != 0 {
       throw GenesisError.swiftBuildFailed(stderr: buildResult.stderr)
   }
   ```
   **Rollback 邏輯**：依賴 NewCommand 既有的 outer `do { ... } catch` 區塊（含 `writer.rollback()` + `if dirCreatedByThisRun && contentsEmpty { remove outputURL }` + git stash pop）。throw 即觸發 outer catch — **不需新增 `rollbackAll` helper**（Codex 2nd-pass 發現該 helper 不存在於現行 codebase）。如有現行 catch 對 GenesisError 之外的錯誤吞掉的情況，Step 9 需確認 GenesisError throw 能順利 propagate（既有 `writer.rollback()` catch 即正確處理）。
4. 測試：
   - `ProcessRunnerTests.testTimeoutKillsProcess`：跑 `sleep 30` + timeout=1 → exit code 非 0 + stderr 含 `timeout` 字串
   - `ProcessRunnerTests.testRunWithoutTimeoutBackwardCompat`：既有 callers behavior 不變
   - `NewCommandTests.testEndToEndSwiftPackageResolveAndBuild`：跑 `genesis new IAMContext --from-bundle <IAM bundle> --output <tmp>` → exit 0 + `<tmp>/.build/release/<...>` 存在
   - ⚠️ 此測試會跑真 resolve + build 8-15 min；標 `try XCTSkipIf(ProcessInfo.processInfo.environment["GENESIS_RUN_E2E_BUILD"] == nil, "Set GENESIS_RUN_E2E_BUILD=1 to enable")` 避免日常 CI 太慢

### Step 10 — DeleteCommandExtension render

1. 新檔 `Sources/GenesisCore/Resources/Templates/v0.1/DeleteCommandExtension.swift.template`：
   ```
   extension {Aggregate} {
       package func when(event: {Aggregate}Deleted) throws {
           self.metadata.delete()
       }
   }
   ```
2. `AggregateRenderer.swift` 加 `renderDeleteCommand(aggregateName:dir:)` -> `("Sources/\(name)Aggregate/Entity/Commands/\(name)+Delete.swift", content, "command-extension")`
3. `AggregateRenderer.render` main loop 對每個 aggregate 呼叫此 renderer
4. 測試：
   - `AggregateRendererTests.testDeleteCommandPath`：path == `Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+Delete.swift`
   - `AggregateRendererTests.testDeleteCommandContent`：output 含 `package func when(event: UserAccessProfileDeleted) throws` + `self.metadata.delete()`

### Step 11 — Fresh-output-only enforcement + manifest migration guard

**為什麼**：本 task 改變產出 layout（aggregate 進 `Entity/`、Repository 進 `Usecase/Port/Out/`）。對 Phase 1.b/1.c 已產的舊 dir 重跑 `genesis new` 會：
- 寫新 path 但舊 path 還在（`Adapter/{A}Repository.swift` 殘留）
- `.scaffold-manifest.json` 不一致

`genesis new` 既有 `outputDirHasConflict` preflight 對非空 dir 已 reject；本 step 顯式加 layout-version sanity check。

1. `Sources/Genesis/Commands/NewCommand.swift` 既有 preflight 段：
   - 在現有「output dir conflict」檢查後加：若 dir 內已有 `.ai/contexts/.../.scaffold-manifest.json` 且 manifest 的 `templateVersion` < 此 Genesis 版本（或不存在版本欄位）→ throw `outputDirHasConflict(reason: "pre-existing manifest from incompatible template version; remove dir or use --force (TBD)")`
   - 既有 conflict path 仍 cover「dir 已含 `Sources/` etc.」
2. `.scaffold-manifest.json` 寫入時帶 `"templateVersion": "0.1.0"`（或 Genesis 版本，沿用 Phase 1.c 已有的 templateVersion 欄位）
3. 測試 `NewCommandTests.testRerunOnExistingManifestRejects`：模擬 prior manifest from "Phase 1.b" → exit 非 0、stderr 含 incompatible-template hint

### Step 12 — Tests 全面更新

詳見 Steps 1, 3, 4, 5, 6, 7, 8, 9, 10 各自的測試小節。整體新增/修改清單：

| 測試檔 | 新增測試 | 修改測試 |
|---|---|---|
| `AggregateRendererTests` | 13+ 個新（見 Steps 4/5/7/8/10）含 `testDeleteCommandPath` / `testDeleteCommandContent` / **`testCreatedEventStateAssignmentsSkipNonStatePayload`**（high）/ **`testCreatedEventInvocationIncludesAliasFirst`**（high）/ `testCreatedEventPayloadZeroFields` / `testCreatedEventPayloadFiveFields` | `testAggregateSwiftHasCanonicalShape`（全面 rewrite 對齊新 template）、`testAdapterIdStrategyTypedStruct`（改測「typedStruct fallback to direct + warning」） |
| `ProjectionModelRendererTests` | 8 個全新（見 Step 3）含 `testRenderNonEmptyReadModelsScopedToAggregate` / `testRenderContextLevelReadModelIncludedInAllAggregates` / `testRenderFiltersUnknownEvents` / `testRenderDropsEntryAfterFilteringAllEvents` 等多 aggregate scoping 測試 | — |
| `BundleParserFullTests` | 5 個新（見 Step 1）| 既有 `testParseEmptyReadModels` 改為 `testParseEmptyReadModelsReturnsEmpty`（不再 throw） |
| `AdapterApplierTests` | 1 個新（見 Step 2）| 既有 `testResolveIdWrapperTypedStruct`（改測「fallback to nil + warning」） |
| `PackageRendererTests` | 1 個 ModelGeneratorPlugin assertion + 1 個 `testTypedStructDoesNotForceSharedTarget`（Step 2）| — |
| `SharedTargetRendererTests` | 1 個 `testTypedStructDoesNotEmitAutoWrapper`（Step 2）| 既有 typedStruct auto-wrapper 測試（Phase 1.c 加的）invert |
| `BusinessDocRendererTests` | 1 個新 `testTypedStructFallsBackToString`（Step 2 H4 coverage 補完）| — |
| `ProcessRunnerTests` | 3 個新（Step 9）：`testTimeoutKillsProcess`（用 `sleep`）、`testTimeoutKillsStubbornChild`（**deterministic**：用 `trap '' TERM; sleep 30` 模擬忽略 SIGTERM 子程序，驗 SIGKILL fallback 在 grace 後 fire）、`testRunWithoutTimeoutBackwardCompat` | — |
| `NewCommandTests`（resolve/build 失敗驗證）| 2 個新：`testResolveFailureThrowsSwiftPackageResolveFailed`（mock ProcessRunner 讓 resolve exit 非 0 → 驗 throw `swiftPackageResolveFailed`）、`testBuildFailureThrowsSwiftBuildFailed`（mock build exit 非 0 → 驗 throw `swiftBuildFailed`）| — |
| `NewCommandTests` | 2 個新：`testEndToEndSwiftPackageResolveAndBuild`（Step 9，env-gated）+ `testRerunOnExistingManifestRejects`（Step 11） | `testFullBundleEndToEnd`（path 斷言更新）、`testAdapterTypedStructFallback`（invert） |

### Step 13 — Docs + decisions

1. `docs/decisions.md`：加 Phase 1.e ratification entry（仿 D24 / Phase 0 Q1 修訂格式），載明：
   - typedStruct deprecation（理由 + Phase 1.c partial supersede）
   - projection-model.yaml 必須存在（plugin 強制）+ fallback 規則
   - category prefix 鎖死 `contextName.filter { $0.isUppercase }`
   - Aggregate conform `{A}AggregateProtocol`（plugin-generated），不直接 conform AggregateRoot
   - 影響範圍：Phase 1.b（aggregate template / paths）、Phase 1.c（typedStruct）
2. `docs/architecture.md`：
   - §3 path layout：`Sources/{A}Aggregate/Entity/{A}.swift` / `Usecase/Port/Out/{A}Repository.swift` / `projection-model.yaml`（取代 Phase 1.b 流出的 flat 描述）
   - §10.1 Repository placement：改 `Usecase/Port/Out/`（非 `Adapter/`）
   - 新增 §10.2 ModelGeneratorPlugin：`{A}AggregateProtocol` 由 plugin 產出、`projection-model.yaml` 必存在、category prefix 規則
3. `docs/tasks/phase-1b-aggregate-extraction.md`：加 partial-supersede banner（指 Phase 1.e 修訂 aggregate template + paths），inline ⚠️ 標記在：
   - `Aggregate.swift.template` code sample 段
   - Repository 放 `Adapter/` 的段
   - 「hand-written `when(happened:)` switch」描述
   - `package final class` 描述
   - typealias `CreatedEventType` 描述
4. `docs/tasks/phase-1c-adapter-and-manifest.md`：加 partial-supersede 註記 `idStrategy.typedStruct deprecated`，inline ⚠️ 標記在「typedStruct auto-wrapper」相關段（per Phase 1.c spec H1 修正段）

---

## 失敗路徑

新增：

- 產出專案 `swift package resolve` 失敗（Step 9 Phase 1）→ `GenesisError.swiftPackageResolveFailed(stderr: ...)`（exit 2）
- 產出專案 `swift build` 失敗（Step 9 Phase 2）→ `GenesisError.swiftBuildFailed(stderr: ...)`（exit 2）
  - **觸發條件**：plugin codegen 錯誤、template 渲染後語法錯誤、kit 依賴解析失敗（網路）、user 提供異常 bundle 導致型別不一致
  - **處理**：SourceWriter.rollback 刪所有 generated files；若 dirCreatedByThisRun && empty 則刪 output dir；既有 GitPreflight stash pop 邏輯
- BundleParser 解析 readModel 缺欄位 → `GenesisError.bundleInvalid(reason: "readModel.<field> missing")`（exit 1，既有 case 沿用）

既有失敗路徑不變：

- `bundleNotFound` (exit 1)
- `bundleInvalid` (exit 1) — 涵蓋 readModel 解析失敗
- `gitPreflightFailed` (exit 3)
- `swiftPackageResolveFailed` (exit 2) — swift build 內部會 resolve，失敗時可能落這條而非 swiftBuildFailed；Step 9 內部需區分（看 stderr 含 `error: failed to resolve dependencies` vs 其他）
- `fileSystemFailed` (exit 2)
- `outputDirHasConflict` (exit 1)

---

## 不改動的部分

- BundleParser 對 aggregates / useCases / dtos / invariants 解析邏輯（除 readModels reject 路徑外）
- SourceWriter plan/commit/rollback API（path 由 renderer 給，SourceWriter 不感知 layout）
- UseCaseRenderer 所有產物（`Usecase/Port/In/`、`Usecase/Service/`、`Adapter/{UC}/`）
- DtoRenderer / ContextLevelRenderer / ManifestRenderer 計算邏輯 / ReadmeRenderer（**BusinessDocRenderer 改在 Step 2 — 從此 list 移除**）
- Package.swift.template（dddkit-correction 已對齊）
- Repository.swift.template（dddkit-correction 已對齊）
- event.yaml.template / event.yaml.event.template / event-generator-config.yaml.template（除 deletedEvent block 邏輯在 renderer 端特例化）
- swift-adapter.yaml schema（typedStruct 保留 schema，只 deprecate 生成路徑）
- `.scaffold-manifest.json` schema 結構 + Phase 1.c 之 manifest 內容計算邏輯（**Step 11 加 preflight 對 pre-existing manifest `templateVersion` 做 sanity check，但不改 schema 或計算邏輯**）
- CLI flags、ArgumentParser usage、Genesis 自身 Package.swift
- skill installer / `genesis install-skills` 行為（Phase 1.d）

### Non-goals（行為層）

- 本 task 不包含實作 `genesis diff` / `genesis apply` / `genesis adapter` 等 Phase 2 指令
- 本 task 不包含 OpenAPI plugin 整合（Phase 1.f 或更晚）
- 本 task 不包含 `ContextError` factory layer / context-shared infra
- 本 task 不包含 `Entity/{A}+Invariant.swift` 獨立檔（OC 把 invariants 寫在 `Aggregate.swift` extension；本 task 留 `ensureInvariant()` 空殼 in Aggregate.swift body）
- 本 task 不包含 state field Optional vs non-optional+default 的 OC 慣例對齊（維持 Phase 1.b 的 Optional 慣例，business default 由 `/usecase` skill 補）
- 本 task 不包含為 typedStruct 提供完整替代方案（hard deprecate；user-side `{A}ID` wrapper 屬 per-feature 範疇）
- 本 task 不包含 `streamCategoryPrefix` adapter override（用 contextName 大寫縮寫鎖死）
- 本 task 不包含 KurrentDB cluster setup / projection script 部署（`GenerateKurrentDBProjectionsPlugin` 屬 command plugin，Phase 1.f 或更晚）
- 本 task 不包含 ModelGeneratorPlugin 對 `projection-model.yaml` 空檔（zero entry）的 tolerance 驗證 — 採保底 fallback entry 策略避開此疑問
- 本 task 不包含 SwiftPM CI gate 對產出專案 `swift build` 的 PR-blocking 配置（CI 啟用評估留 Phase 1.f）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# A1. Genesis 自身能編譯
swift build -c release --product genesis

# A2. 全部 unit + integration tests（不含 E2E build）通過
swift test

# A3. Aggregate.swift.template 鎖定值
grep -F '{Aggregate}AggregateProtocol' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
grep -F 'package let id: String' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
grep -F '{CategoryPrefix}' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
grep -F 'required convenience init?(first createdEvent:' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
! grep -F 'typealias ID = ' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
! grep -F 'typealias CreatedEventType' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
! grep -F 'when(happened' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
! grep -F 'package final class' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template

# A4. AggregateError.swift.template 鎖定值
grep -F 'Error, Equatable' Sources/GenesisCore/Resources/Templates/v0.1/AggregateError.swift.template
! grep -F 'Error, Sendable' Sources/GenesisCore/Resources/Templates/v0.1/AggregateError.swift.template

# A5. CommandExtension.swift.template 註解對齊
grep -F 'plugin-generated' Sources/GenesisCore/Resources/Templates/v0.1/CommandExtension.swift.template
! grep -F 'Aggregate.when(happened:) switch dispatch' Sources/GenesisCore/Resources/Templates/v0.1/CommandExtension.swift.template

# A6. PackageTarget.swift.template ModelGeneratorPlugin 有掛
grep -F '.plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit")' Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template

# A7. 新 templates 存在
test -f Sources/GenesisCore/Resources/Templates/v0.1/projection-model.yaml.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/projection-model.yaml.entry.template

# A8. Renderer / FullBundle / BundleParser 鎖定點
grep -F 'public enum ProjectionModelRenderer' Sources/GenesisCore/ProjectionModelRenderer.swift
grep -F 'public struct ReadModelSpec' Sources/GenesisCore/FullBundle.swift
grep -F 'public let readModels: [ReadModelSpec]' Sources/GenesisCore/FullBundle.swift
! grep -F 'readModels are not supported in Phase 1.b' Sources/GenesisCore/BundleParser.swift

# A9. Path layout 鎖定（用具體 return-path patterns，不用 loose 'Entity/'）
# Aggregate return path 必須含 Entity/
grep -F '/Entity/\(spec.name).swift' Sources/GenesisCore/AggregateRenderer.swift
# Repository return path 必須含 Usecase/Port/Out/
grep -F '/Usecase/Port/Out/\(aggregateName)Repository.swift' Sources/GenesisCore/AggregateRenderer.swift
# Repository 絕對不能再用 Adapter/ 路徑（Phase 1.b 舊路徑）
! grep -F '/Adapter/\(aggregateName)Repository.swift' Sources/GenesisCore/AggregateRenderer.swift
# DeleteCommandExtension 路徑
grep -F '+Delete.swift' Sources/GenesisCore/AggregateRenderer.swift

# A10. typedStruct deprecation — 5 個檔案聯動
grep -F 'idStrategy.typedStruct is deprecated' Sources/GenesisCore/AdapterApplier.swift
grep -F 'FileHandle.standardError.write' Sources/GenesisCore/AdapterApplier.swift
# PackageRenderer needsShared 不再含 typedStruct
! grep -F 'adapter.idStrategy.kind == .typedStruct' Sources/GenesisCore/PackageRenderer.swift
# NewCommand needsShared 同步
! grep -F 'adapter.idStrategy.kind == .typedStruct' Sources/Genesis/Commands/NewCommand.swift
# SharedTargetRenderer 不再自動補 missing wrapper for typedStruct
! grep -F 'if adapter.idStrategy.kind == .typedStruct' Sources/GenesisCore/SharedTargetRenderer.swift
# BusinessDocRenderer 邏輯不變但加 inline note
grep -F 'typedStruct deprecated; always falls back to String' Sources/GenesisCore/BusinessDocRenderer.swift

# A10b. ProcessRunner timeout
grep -F 'timeout: TimeInterval?' Sources/GenesisCore/ProcessRunner.swift

# A11. swift package resolve + swift build 接通 NewCommand
grep -F 'GenesisError.swiftBuildFailed' Sources/Genesis/Commands/NewCommand.swift
grep -F 'GenesisError.swiftPackageResolveFailed' Sources/Genesis/Commands/NewCommand.swift
grep -F 'case swiftBuildFailed' Sources/GenesisCore/GenesisError.swift
grep -F 'package", "resolve"' Sources/Genesis/Commands/NewCommand.swift  # explicit resolve step
grep -F 'build", "-c", "release"' Sources/Genesis/Commands/NewCommand.swift  # explicit build step

# A11b. DeleteCommandExtension renderer
grep -F 'renderDeleteCommand' Sources/GenesisCore/AggregateRenderer.swift
test -f Sources/GenesisCore/Resources/Templates/v0.1/DeleteCommandExtension.swift.template

# A12. e2e — genesis new 產出檔案位置 + swift build pass（注意：genesis new 內部已跑 build，A12 不需要再跑）
rm -rf /tmp/phase-1e-e2e && mkdir /tmp/phase-1e-e2e
( cd /tmp/phase-1e-e2e && git init -q )
BIN="$(swift build -c release --product genesis --show-bin-path)/genesis"
"$BIN" new IAMContext --from-bundle "/Users/abnertsai/Downloads/IAM Context Bundle.json" --output /tmp/phase-1e-e2e
# 上面 genesis new 已內含 swift package resolve + swift build；exit 0 即驗證通過

# Path layout 對齊
test -f /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift
test -f /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/Usecase/Port/Out/UserAccessProfileRepository.swift
test -f /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+Delete.swift
test -f /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/projection-model.yaml
! test -f /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/Adapter/UserAccessProfileRepository.swift
! test -f /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/UserAccessProfile.swift  # flat path no longer used
# Aggregate.swift 內容對齊
grep -F 'class UserAccessProfile: UserAccessProfileAggregateProtocol' /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift
grep -F 'package let id: String' /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift
grep -F '"IAMC\(Self.self)"' /tmp/phase-1e-e2e/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift
# .build/release output（genesis 內部 build 已產生）
test -d /tmp/phase-1e-e2e/.build/release

# A13. 重複 build 應為 cache hit（健全性）— 不再算正面驗證；省略以節時

# A14. docs 修訂
grep -F 'phase-1e' docs/tasks/phase-1b-aggregate-extraction.md
grep -F 'phase-1e' docs/tasks/phase-1c-adapter-and-manifest.md
grep -F 'Phase 1.e' docs/decisions.md
grep -F 'ModelGeneratorPlugin' docs/architecture.md
grep -F 'Usecase/Port/Out' docs/architecture.md
```

### Human 補做（需要人類介入）

- [ ] 跑 `swift-adapter-typedstruct.yaml` 範例（Phase 1.c 的 typedStruct fixture）→ 確認 stderr warning 訊息對使用者友善（內容清楚指出 deprecation 理由 + fallback 行為）；產出專案仍能 bootstrap + swift build pass
- [ ] 視覺檢視 generated `Entity/UserAccessProfile.swift` 在不同 createdEvent payload sizes（0、1、5 fields）下的排版（換行、縮排、placeholder 留白）— 用 IAM bundle + 2 個自訂測試 bundle 觀察
- [ ] 跑 IAM bundle e2e（`swift build`）後檢查 `Package.resolved` 含 `swift-ddd-kit` 0.3.0 + `swift-kurrentdb` 2.0.3 transitive；用 `swift package show-dependencies` 確認無 conflict 鏈
- [ ] 跑一個含非空 `readModels[]` 的自訂 bundle，確認 `projection-model.yaml` 內容正確、`{A}AggregateProtocol` 由 plugin 順利產出、`when(event:)` 在 Commands/ 內 dispatch 成功（單元測試之外的 e2e ergonomic check）

---

## 已知限制

1. **First-ever 產出專案 `swift build` 驗證**：本 task 把 `swift build` 納入 NewCommand 流程，冷編譯約 5-10 分鐘（kit 依賴鏈含 gRPC + NIO + Postgres-NIO + KurrentDB）。本 task 啟用「genesis new 內 build」+ 「`testEndToEndSwiftPackageResolveAndBuild` 受環境變數控制 `GENESIS_RUN_E2E_BUILD=1`」；CI PR-gating 留 Phase 1.f 評估。**Phase 3 實作期 deviation**：加 `--skip-build` flag（spec 原本是 open question #2 的 future option）以讓既有 6 個 happy-path 整合測試不被 build 拖慢；spec 寫的「永遠跑 swift build」實際被 `--skip-build` 弱化為「`--skip-build` 未設時跑 build」。Tests 全部 pass `--skip-build`；CLI default behavior 仍是「跑 build」。
12. **Phase 1.e Gemini Review 後 cleanup**（2026-05-17）：補上 3 個 minor drift —（a）`CommandExtension.swift.template` 註解「Aggregate.when(happened:) switch dispatch」→「plugin-generated when(happened:) dispatch」；（b）`BundleParser.decodeReadModelSpec` 對 readModel 缺 events/eventNames 兩鍵改為 throw `bundleInvalid` 而非 silently set 為 `[]`（與 spec § Step 1 fail-fast 對齊）；（c）`ProcessRunner` stderr prefix 拆分 SIGTERM-only vs SIGTERM+SIGKILL 兩 branch（避免 overclaim「then SIGKILL after 3s grace」當 SIGKILL 未實際 fire 時）。三項皆 low/medium severity，不阻擋實作完成。
13. **真 e2e build 揭露 3 個 spec 未涵蓋的 compile error**（2026-05-18，由 `swift build` against generated IAM project 揭露；Phase 1.b/1.c 既有 latent bug + Phase 1.e 缺漏）：
    - **(a)** `UsecaseInput.swift.template`：`: Input` → `: UseCaseInput`（Phase 1.b 用了不存在的 `Input` 協議名；gradyzhuo 真實協議是 `UseCaseInput`）
    - **(b)** `UsecaseOutput.swift.template`：`: Output` → `: UseCaseOutput`（同上；且 `UseCaseOutput: Codable` 要求是 `Usecase<I, O>` 編譯失敗的 root cause — `Self.Output : Decodable/Encodable` 約束無法滿足）
    - **(c)** `event-generator-config.yaml.template` + 多個 aggregate-target Swift template 缺 `import {ContextName}Shared`：plugin-generated `generated-event.swift` 與 hand-written `Aggregate.swift` / `CommandExtension.swift` / `UsecaseInput.swift` 都引用 DTO/customType identifiers（住在 `{Ctx}Shared`），無 import 就「cannot find type」。修補：(i) `event-generator-config.yaml.template` 加 `{Dependencies}` placeholder + AggregateRenderer 注入 `dependencies:\n  - {Ctx}Shared`；(ii) Aggregate/CommandExtension/UsecaseInput/DeleteCommandExtension template 加 `{SharedImport}` placeholder + AggregateRenderer/UseCaseRenderer 注入 `import {Ctx}Shared`（needsShared = true 時）。
    教訓：**`swift package resolve` 不足以 catch protocol-conformance / import-scope error**；只有真 `swift build` 才能。Phase 1.e 之後產出專案 build verification 必須是 end-of-spec acceptance 的真實 gate，不可省略。13 是首次跑真 e2e build 的成果。
2. **typedStruct 是 hard deprecation**：現有 `swift-adapter-typedstruct.yaml` 範例仍可解析但會 fallback to direct + 警告；`{A}ID` wrapper 不再自動生成。Phase 1.c 加的 typedStruct auto-wrapper test 部分 `XCTSkip` 或改測 fallback 行為。
3. **`state` fields 維持 Optional + populated-by-when**：與 OC 的 `var ... = default` 慣例不完全一致；business default 由 per-feature `/usecase` skill 補。
4. **category prefix 鎖死規則**：`contextName.filter { $0.isUppercase }` 不可在 swift-adapter.yaml override。若日後需在多 context cluster 下手動指定 prefix，加 adapter schema field 屬 Phase 1.f 範疇。
5. **projection-model fallback 非 zero-config**：`bundle.readModels[]` 空 → emit `Get{A}Existence` placeholder。下游使用者下次跑 `/readmodel` skill 可能想刪除/重寫此 placeholder；目前不影響 build。
6. **`ContextError` factory layer 缺**：OC 的 AggregateError 有 `extension ContextError where ErrorType == ...` factory；Genesis 不產此層（需 context-shared infra）。產出專案直接用 `throw {A}Error.xxx` 即可 build，但與 OC ergonomic 不同。
7. **`Entity/{A}+Invariant.swift` 不獨立**：OC 把 invariants 寫在 `Aggregate.swift` 內 `extension {A} { func ensureInvariant() throws { ... } }`；本 task 留 `ensureInvariant()` 空殼在 Aggregate.swift body，invariant rules 由 per-feature `/usecase` skill 補。
8. **ReadModel JSON shape 不確定**：本 spec 寫作時只見 IAM bundle 的 `"readModels": []` 空陣列。實作期 Step 1 需從 Cosmogony export 取一個非空 readModels 範例 cross-check `name` / `eventNames` 等欄位名；若欄位名不符預期，調整 parser 並回填 spec。
9. **`{A}AggregateProtocol` 命名規則對 target 名敏感**：plugin 取 target 名加 `Protocol` 後綴 — Genesis 的 aggregate target 名為 `{A}Aggregate`（per Phase 1.b SSOT），故 protocol 名 `{A}AggregateProtocol`。若日後改 target 命名規則，protocol 名隨之改變，Aggregate.swift.template 需同步更新。
10. **路徑遷移：fresh output only**：本 task 改變 layout（aggregate 進 `Entity/`、Repository 進 `Usecase/Port/Out/`）。對「先前由 Phase 1.b/1.c 產出的 dir」**不做 in-place migration** — NewCommand 既有 `outputDirHasConflict` 對非空 dir 已 reject；Step 11 加強 manifest-version 檢查讓錯誤訊息對使用者更清楚（提示「remove dir or use `genesis migrate` (Phase 2)」）。`genesis migrate` 不在本 task 範圍。Workaround：刪 dir 重跑 `genesis new` 或人工搬檔。
11. **依賴關係**：本 task `depends_on: ["dddkit-correction"]`（已 done）。**partial supersedes**：
    - `phase-1b-aggregate-extraction`（aggregate template / paths / `when(happened:)` switch / repository placement / deletedEvent yaml）
    - `phase-1c-adapter-and-manifest`（typedStruct deprecation）
    兩個 supersedee 維持 `status: done`，只加 banner + inline 標記不改 registry status。
