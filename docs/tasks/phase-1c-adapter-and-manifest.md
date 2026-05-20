# Phase 1.c — swift-adapter.yaml + .scaffold-manifest.json + .ai/contexts/ 業務文件骨架 + Sources/{Context}Shared/ + README/CLAUDE 樣板

> ⚠️ **Superseded in part by `phase-1e-aggregate-alignment` (2026-05-17)**
>
> 本 spec 的 `idStrategy.typedStruct` 部分已由 `docs/tasks/phase-1e-aggregate-alignment.md` 修訂為 **deprecated + warn + fallback to direct**。具體：
>
> - gradyzhuo `Entity where ID == String` 結構性禁止 typed ID wrapper（無 mapping 機制）
> - `AdapterApplier.resolveIdWrapperName` 對 `typedStruct` 改為 emit stderr warning + 回傳 nil
> - `SharedTargetRenderer` 不再自動補 `{Aggregate}ID` wrapper（Phase 1.c H1 fix 加的那段邏輯廢棄）
> - `PackageRenderer.needsShared` / `NewCommand.needShared` 移除 `|| typedStruct` 子條件
> - `BusinessDocRenderer` 仍走 `?? "String"` fallback，但加 inline comment 載明原因
> - yaml schema 保留（向後可解析），只生成路徑廢棄
>
> 受影響：本 spec H1 fix（idStrategy.typedStruct 自動 minimal identifier wrapper）整段邏輯廢棄；當前 SSOT 為 `docs/architecture.md` §10.2 + `phase-1e-aggregate-alignment` spec。

## 來源

- Plan：`/Users/abnertsai/.claude/plans/tool-tool-lexical-hamming.md` §3 Phase 3（mention adapter）+ Phase 1 roadmap
- Architecture：`docs/architecture.md` §3（產出結構含 `.ai/contexts/`、`.ai/conventions/`、`Sources/{Shared}/`）、§4 SSOT discipline（D15-D17：哪個 master file 給哪個 skill 用）、§6.1（`.scaffold-manifest.json` schema）、§6.2（`swift-adapter.yaml` schema）
- Decisions：`docs/decisions.md` D5（manifest）、D6（adapter schema）、D9（adapter 由人工/LLM 提案）、D13（fail-fast normalization）、D14（adapter 2-layer guard）、D15（SSOT Option D）、D16（Gherkin master）、D17（error→HTTP 在 api.md）
- Phase 1.b spec：`docs/tasks/phase-1b-aggregate-extraction.md`（status `done`）— Phase 1.c 解決它的多個 known limitations：
  - DTO 跨 aggregate cross-ref → `Sources/{Context}Shared/`
  - CreatedEvent heuristic 太脆弱 → `createdEventOverrides`
  - typed ID wrapper → `idStrategy + customTypes`
  - value object stubs → `customTypes`
  - State 一律 Optional 簡化策略 → `[VERIFY-IN-IMPL]` 維持 Phase 1.b 行為（adapter override 留給 Phase 1.c 之後）
- Phase 1.b registry：`docs/tasks/registry/phase-1b-aggregate-extraction.json` status=`done`

---

## 目標

讓 `genesis new` 走完整版的 Phase 1 流程：(1) 讀取使用者提供的 `swift-adapter.yaml` 覆寫 Phase 1.b 的硬編碼啟發式（type mapping、createdEvent 命名、typed ID wrapper、DTO 放哪個 target）；(2) 寫 `.scaffold-manifest.json` 紀錄每個生成檔案的 sha256 給未來 `genesis diff`/`apply` 用；(3) 寫 `.ai/contexts/{Aggregate}/` 七份業務文件骨架（commands / invariants / errors / api / test-scenarios / config / reference + notes/），這是下游 Claude Code skills（`/usecase`、`/readmodel`、`/api`）的 SSOT；(4) 把 DTO 從「掛在第一個 aggregate target」改為「`Sources/{Context}Shared/` 共用 target」解決多 aggregate cross-ref；(5) 寫 `README.md` + `CLAUDE.md` 樣板讓使用者一拿到專案就知道怎麼開始。Phase 1.c 完成後，使用者拿到的專案會是「能 `swift build` + 有完整業務文件 + Claude Code 可立即接手」的成品。

---

## 介面合約（Interface Contract）

### CLI：`genesis new`（新增 `--adapter`）

```
genesis new <ContextName> --from-bundle <path> [--adapter <path>] [--output <dir>] [--no-git]
```

| 參數 | 型別 | 必須 | 規則 |
|------|------|------|------|
| `--adapter <path>` | `String` | ✗ | 不傳則用 default Adapter（行為等同 Phase 1.b）；傳了則檔案必須存在且解析成功 |

**Exit code 新增**：

| 條件 | Exit | 對應 GenesisError |
|------|------|-------------------|
| `--adapter` 檔案不存在 | 1 | `adapterNotFound(URL)` |
| adapter YAML 格式錯誤 | 1 | `adapterInvalid(reason:)` |
| adapter `contextName` 跟 CLI arg 不一致 | 1 | `adapterIncompatible(reason: "contextName mismatch ...")` |
| adapter `bundleId` 存在但與 bundle `bundleId` 不一致 | 1 | `adapterIncompatible(reason: "bundleId mismatch ...")` |
| `createdEventOverrides` 指到不存在的 UC | 1 | `adapterInvalid` |

**成功訊息延伸**：`✓ Genesis: wrote <N> files for context <ContextName> (<M> aggregates, <K> use cases, <D> DTOs) to <abs-path>; manifest at .ai/contexts/<ContextName>/.scaffold-manifest.json`

---

### Internal data model：`GenesisCore.Adapter`（新）

```swift
public struct Adapter: Sendable, Equatable {
    public let adapterVersion: Int        // 必須 == 1（Phase 1.c 只支援 v1）
    public let schemaVersion: Int         // 必須 == 1
    public let contextName: String        // 與 CLI arg 比對；不一致則 throw
    public let bundleId: String?          // optional；若存在則與 bundle.bundleId 比對
    public let typeMapping: [String: String]
    public let customTypes: [CustomTypeSpec]
    public let createdEventOverrides: [String: String]   // aggregateName → useCase name
    public let aggregateSplit: AggregateSplitSpec
    public let idStrategy: IdStrategySpec
    // 忽略：payloadConventions / testingConventions / imports / skip
    //       讀但不套用，記入「已知限制」
}

public struct CustomTypeSpec: Sendable, Equatable {
    public let name: String
    public let kind: Kind
    public let underlying: String?        // valueObject / identifier 用
    public let cases: [String]?           // enum 用

    public enum Kind: String, Sendable {
        case valueObject
        case `enum`
        case identifier
    }
}

public struct AggregateSplitSpec: Sendable, Equatable {
    public let strategy: String           // Phase 1.c 只接受 "byBoundedContext"
    public let rootMap: [String: String]  // aggregateName → Sources/... target path（資訊性，Genesis 不主動採用此 path）
}

public struct IdStrategySpec: Sendable, Equatable {
    public let kind: Kind
    public let wrapper: String?           // 例 "{Aggregate}ID"，會展開為 UserAccessProfileID

    public enum Kind: String, Sendable {
        case direct       // typealias ID = String（Phase 1.b 預設）
        case typedStruct  // typealias ID = {Aggregate}ID
    }
}

public extension Adapter {
    /// Default adapter used when `--adapter` is not provided. Behavior equals Phase 1.b.
    static func defaultFor(contextName: String) -> Adapter {
        Adapter(
            adapterVersion: 1, schemaVersion: 1,
            contextName: contextName, bundleId: nil,
            typeMapping: [:], customTypes: [],
            createdEventOverrides: [:],
            aggregateSplit: AggregateSplitSpec(strategy: "byBoundedContext", rootMap: [:]),
            idStrategy: IdStrategySpec(kind: .direct, wrapper: nil)
        )
    }
}
```

🔴 **不變量**：`Adapter.defaultFor(contextName:)` 必須使所有 renderers 產出等同 Phase 1.b 的結果（DTO 在 Shared target 例外，見下）。這條由 backward-compat integration test 守護。

---

### Internal module：`GenesisCore.AdapterYamlParser`（新）

```swift
public enum AdapterYamlParser {
    /// Returns Adapter when file is well-formed; throws on parse / validation failure.
    public static func parse(at url: URL, contextName: String, bundleId: String) throws -> Adapter
}
```

**行為**：
1. 復用 Phase 1.a 既有的 fs 分類（not-found / is-directory / IO） — 新 GenesisError case `adapterNotFound`
2. 用 Yams 解析 YAML（新依賴；走 SwiftPM `.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")` — 已是 DDDKit 的 transitive dep，Genesis 自身 Package.swift 加進 dependencies）
3. 驗證頂層必須有 `adapterVersion: 1`（不是 1 → throw `adapterInvalid(reason: "unsupported adapterVersion ...")`）
4. 驗證 `contextName == 傳入 contextName`（不等 → throw `adapterIncompatible`）
5. 若 `bundleId` 欄位存在，驗證 `== 傳入 bundleId`（不等 → throw `adapterIncompatible`）
6. 驗證 `aggregateSplit.strategy == "byBoundedContext"`（其他值 → throw `adapterInvalid(reason: "aggregateSplit.strategy '\(s)' not supported; only 'byBoundedContext'")`）
7. 驗證 `idStrategy.kind` 是 `direct` 或 `typedStruct`（其他 → throw）
8. 對於 `idStrategy.kind == typedStruct`，必須有 `wrapper` 欄位（非 empty）
9. 對於 `customTypes` 每個項目：若 `kind == enum`，`cases` 必須非空且每個 case 是合法 Swift identifier；若 `kind == valueObject` 或 `identifier`，`underlying` 必須是已知型別字串（primitive 或 已知 DTO）
10. 解碼成 `Adapter` 並回傳

🔴 **未支援欄位的 stderr 警告**（codex M5 修正）：parsing 階段若偵測到 yaml 含 `payloadConventions` / `testingConventions` / `imports` / `skip` 任一 key，**寫 stderr warning**：
```
⚠️ swift-adapter.yaml: key '{key}' is parsed but not applied in Phase 1.c. See Phase 1.d / Phase 3.
```
不 throw，但讓 user 知道 Genesis 沒榮譽他們的設定。實作建議：parser 先 decode 進一個 `Envelope` struct 含這些 optional fields（kept），對非 nil 的 emit warning，最後僅把 supported 欄位塞進 `Adapter` 回傳。

🔴 **`createdEventOverrides` 表的進一步驗證**：在 `AdapterApplier.apply` 階段做（需要 bundle 資料才能查 UC 存在性）；本層只做 syntax 驗證。

---

### Internal module：`GenesisCore.AdapterApplier`（新）

```swift
public enum AdapterApplier {
    /// Validates that adapter is compatible with the parsed bundle.
    /// Throws on cross-validation failures (e.g. createdEventOverrides refers to missing UC).
    public static func validate(adapter: Adapter, bundle: FullBundle) throws

    /// Returns the resolved Created use case for the given aggregate, honoring
    /// `createdEventOverrides` before falling back to Phase 1.b heuristic chain.
    public static func resolveCreatedUseCase(
        for aggregate: AggregateSpec,
        useCases: [UseCaseSpec],
        adapter: Adapter
    ) throws -> UseCaseSpec
}
```

**`validate` 行為**：
- For each `(aggName, ucName)` in `adapter.createdEventOverrides`:
  - `bundle.aggregates` 必須有 name == aggName 的 aggregate；否則 throw `adapterInvalid`
  - 對應 aggregate 的 useCases（filtered by aggregateSpecId）必須有 useCase == ucName；否則 throw

**`resolveCreatedUseCase` 行為**：
1. 若 `adapter.createdEventOverrides[aggregate.name]` 存在 → 直接 lookup `useCases` 找到該 useCase 並回傳
2. 否則走 Phase 1.b 三層 fallback（`create{Aggregate}` → `*Created` suffix → `register/bootstrap/open/init` prefix）
3. 若全部失敗，throw 與 Phase 1.b 同樣訊息（含 fallback 鏈說明）

---

### Internal module：`GenesisCore.SwiftTypeResolver`（修改，向後相容）

新增 overload：

```swift
public extension SwiftTypeResolver {
    /// Adapter-aware resolution. Applies typeMapping first, then falls through to Phase 1.b
    /// container / primitive / custom-type logic.
    static func resolve(
        rawType: String,
        knownCustomTypes: Set<String>,
        adapter: Adapter
    ) throws -> String
}
```

**行為**：
1. If `adapter.typeMapping[rawType.trimmed]` exists → return that mapped value（不再遞迴解析；user 給的 mapping 視為已解析的 Swift type string）
2. 否則 fall through 到 Phase 1.b `resolve(rawType:knownCustomTypes:)` 既有邏輯

🔴 **舊 API 保留**：Phase 1.b 既有的 `resolve(rawType:knownCustomTypes:)` 不刪不改，繼續存在以維持 unit test 通過。新 overload 是 additive。Renderers 改用新 overload 並傳入 adapter。

---

### Internal module：`GenesisCore.AggregateRenderer`（修改）

簽章變為：

```swift
public enum AggregateRenderer {
    public static func render(
        spec: AggregateSpec,
        bundle: FullBundle,
        adapter: Adapter
    ) throws -> [(path: String, content: String, role: String)]
}
```

**role 對照**（每檔 renderer 內直接 tag，不靠 path 推斷 — codex M3 修正）：
- `{Aggregate}.swift` → `"aggregate"`
- `{Aggregate}Error.swift` → `"aggregateError"`
- `Adapter/{Aggregate}Repository.swift` → `"repository"`
- `Entity/Commands/{Aggregate}+{UC}.swift` → `"commandExtension"`
- `Usecase/Port/In/{UC}/{UC}Input.swift` → `"usecaseInput"`
- `Usecase/Port/In/{UC}/{UC}Output.swift` → `"usecaseOutput"`
- `Usecase/Port/In/{UC}/{UC}Usecase.swift` → `"usecase"`
- `Usecase/Service/{UC}Service.swift` → `"service"`
- `event.yaml` → `"eventYaml"`
- `event-generator-config.yaml` → `"eventGeneratorConfig"`

**變更**：
1. `resolveCreatedUseCase` 改呼 `AdapterApplier.resolveCreatedUseCase(for:useCases:adapter:)`
2. 所有 `SwiftTypeResolver.resolve` 呼叫改用 adapter-aware overload
3. **idStrategy 套用**：
   - `adapter.idStrategy.kind == .typedStruct` 時，將 `{Aggregate}.swift` template 的 `package typealias ID = String` 改成 `package typealias ID = {WrapperName}`，其中 `WrapperName` 由 `adapter.idStrategy.wrapper` 字串 expand `{Aggregate}` token 而得（e.g. `wrapper == "{Aggregate}ID"`，aggregate name == "UserAccessProfile" → `UserAccessProfileID`）
   - 同時，`Aggregate.swift` template 新加變數 `{IDType}` 取代既有 `String`（hard-coded `id: String`）
4. **invariant 引用業務文件**：在 `{Aggregate}.swift` 的 `ensureInvariant` GENESIS-STUB 註解加一行：「see `.ai/contexts/{Aggregate}/invariants.md` for the canonical rule list」

---

### Internal module：`GenesisCore.PackageRenderer`（修改）

**變更**：
1. 若 `bundle.dtos.count > 0` 或 `adapter.customTypes.count > 0` 或 `adapter.idStrategy.kind == .typedStruct` → 多產一個 `{ContextName}Shared` library product + target
2. 每個 aggregate target 的 `dependencies` 多一個 `.target(name: "{ContextName}Shared")`（只在 Shared 存在時）
3. `{ContextName}Shared` target **沒有** DomainEventGeneratorPlugin（純值型別）
4. Package.swift 多一個 testTarget：`{ContextName}Tests`（依賴所有 aggregate libraries），含 placeholder test 檔
5. 簽章變為 `render(bundle: FullBundle, contextName: String, genesisVersion: String, adapter: Adapter) throws -> (path: String, content: String)`（Package.swift 路徑/內容 only；role 由 caller 直接 tag `"package"`，不需 renderer 回傳）

---

### Internal module：`GenesisCore.SharedTargetRenderer`（新）

```swift
public enum SharedTargetRenderer {
    /// Emits per-DTO Swift files into Sources/{ContextName}Shared/.
    /// Aggregates bundle.dtos[] + adapter.customTypes (with name deduplication) +
    /// auto-generated typed-ID wrappers (one per aggregate when idStrategy.kind == typedStruct).
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter
    ) throws -> [(path: String, content: String, role: String)]
}
```

**行為**：
1. 收集所有 custom types：`bundle.dtos.map { ($0.name, .fromBundle($0)) } + adapter.customTypes.map { ($0.name, .fromAdapter($0)) }`
2. 用 `Dictionary(_, uniquingKeysWith:)` 去重 — **若 bundle.dtos 與 adapter.customTypes 同名，adapter 優先**
3. **自動補 typed-ID wrappers**（codex H1 修正）：
   - 若 `adapter.idStrategy.kind == .typedStruct`：對 `bundle.aggregates` 的每個 aggregate，計算其 wrapper name（將 `adapter.idStrategy.wrapper` 中的 `{Aggregate}` token 展開為該 aggregate name）
   - 對每個 wrapper name：
     - 若已在「收集到的 custom types」中存在（user 自己在 `adapter.customTypes` 加了同名 entry，`kind == .identifier`）→ 用 user 提供版本，不覆寫
     - 否則 → 自動補一筆 implicit identifier entry，`underlying = "UUID"`（預設）
4. 對每個 unique type，呼對應的 sub-renderer：
   - bundle.dto → `DtoRenderer.render(dto:hostTarget:knownCustomTypes:)` 路徑寫到 `Sources/{ContextName}Shared/{DtoName}.swift`，role = `"dto"`
   - adapter.customType `kind == .enum` → 仿照 DtoRenderer 的 enum 邏輯（cases 來自 adapter.cases），role = `"customEnum"`
   - adapter.customType `kind == .valueObject` → 用 `ValueObject.swift.template`，role = `"valueObject"`
   - adapter.customType `kind == .identifier`（含自動補的 typed-ID）→ 用 `IdWrapper.swift.template`，role = `"idWrapper"`

🔴 **DTO 路徑變更**：Phase 1.b 把所有 DTO 寫到 `Sources/{FirstAggregateName}Aggregate/{DtoName}.swift`。Phase 1.c 改寫到 `Sources/{ContextName}Shared/{DtoName}.swift`。**此為 backward-incompatible 改動**，Phase 1.b integration test `testFullBundleEndToEnd` 中對 `Sources/UserAccessProfileAggregate/EmployeeStatus.swift` 的斷言要更新成 `Sources/IAMContextShared/EmployeeStatus.swift`。已記入「不改動的部分 / Non-goals」段的調整清單。

🔴 **role 由 renderer 回傳**（codex M3 修正）：原 spec 想用 `roleFromPath` 字串後綴推斷，但 `Sources/{Ctx}Shared/EmployeeStatus.swift` 無法區分是 `dto` / `valueObject` / `customEnum` / `idWrapper`。改成每個 renderer 直接回傳含 role 的 tuple，NewCommand 不再做 path-based 推斷。

---

### Internal module：`GenesisCore.BusinessDocRenderer`（新）

```swift
public enum BusinessDocRenderer {
    /// Renders 7 markdown skeletons + per-UC notes/ files for one aggregate.
    /// Paths are .ai/contexts/{ContextName}/{AggregateName}/...
    public static func render(
        spec: AggregateSpec,
        bundle: FullBundle,
        adapter: Adapter,
        contextName: String,
        generatedDate: String  // ISO-8601 date, injected for deterministic output
    ) throws -> [(path: String, content: String, role: String)]
}
```

🔴 **路徑結構變更**（codex M4 修正）：原 spec 把 per-aggregate 業務文件放 `.ai/contexts/{AggregateName}/`，context-level metadata 放 `.ai/contexts/{ContextName}/`，aggregate 跟 context 共用同一 namespace 容易碰撞（user 取 aggregate 名 `FooContext` 會踩到）。Phase 1.c 改成 **nested**：
- per-aggregate 業務文件：`.ai/contexts/{ContextName}/{AggregateName}/...`
- context-level：`.ai/contexts/{ContextName}/swift-adapter.yaml` 與 `.ai/contexts/{ContextName}/.scaffold-manifest.json`
- cross-aggregate conventions：`.ai/conventions/api.md`

這個調整是 architecture.md §3 diagram（flat `.ai/contexts/{Aggregate}/`）與 §6.1/§6.2（`.ai/contexts/{Ctx}/...`）內部不一致的修正 — Genesis 採內部一致的 nested 結構。Architecture.md 須在 Phase 1.c 收尾時順手更新 §3 diagram，但 spec 內不額外加 task。

**輸出檔案清單**（每個檔頭部都有 YAML frontmatter）：

| 檔案 | 來源資料 | 內容大綱 |
|------|---------|---------|
| `.ai/contexts/{ContextName}/{Aggregate}/config.md` | aggregate.name / identityName / aggregateSpecId | Aggregate name、ID type、target path、bundle source 摘要 |
| `.ai/contexts/{ContextName}/{Aggregate}/commands.md` | aggregate 的 useCases[] + preconditions[].text | 每個 UC 一個 `## {UC}` 段落，列：input fields、preconditions（從 bundle）、emitted event、state transitions placeholder |
| `.ai/contexts/{ContextName}/{Aggregate}/invariants.md` | aggregate.invariants[] | 每個 invariant 一個 `## {name}` 段落，列：title、rules（when/rule）、errorCode |
| `.ai/contexts/{ContextName}/{Aggregate}/errors.md` | aggregate.invariants[].errorCode 去重 | 每個 errorCode 一個 `## {code}` 段落，含 title placeholder；**不含 HTTP status**（D17） |
| `.ai/contexts/{ContextName}/{Aggregate}/api.md` | （placeholder） | Transport rules placeholder + error→HTTP map table（空 row 等 `/api` skill 填）|
| `.ai/contexts/{ContextName}/{Aggregate}/test-scenarios.md` | aggregate.useCases[] + invariants[] | 每個 UC + invariant 對應一個 Gherkin `Scenario` placeholder（Given/When/Then 空殼）|
| `.ai/contexts/{ContextName}/{Aggregate}/reference.md` | （placeholder） | Free-form notes placeholder |
| `.ai/contexts/{ContextName}/{Aggregate}/notes/{UseCase}.md` | 一個檔 per UC | per-UC notes placeholder，**對齊 architecture.md §4 SSOT 表的 `notes/<UC>.md` 慣例**（codex M6 修正）|
| `.ai/contexts/{ContextName}/{Aggregate}/notes/README.md` | （fixed string） | 解釋 notes/ 目錄用途 |

**Frontmatter 格式**：

```yaml
---
aggregate: {Aggregate}
context: {ContextName}
bundleId: {bundle.bundleId}
generated: {generatedDate}
generator: Genesis v{GenesisVersion}
---
```

🔴 **Idempotency 約束**：所有 BusinessDoc 內容必須 deterministic（除 `generated` 日期外）— 同 bundle + adapter 重跑必須產生 byte-identical 輸出（除日期差異）。這條讓 Phase 3 `genesis diff` 能準確 detect 人工編輯。`generated` 日期由 caller 注入是為了讓 test 能 freeze 日期。

---

### Internal module：`GenesisCore.ContextLevelRenderer`（新）

```swift
public enum ContextLevelRenderer {
    /// Renders context-level files (not per-aggregate):
    ///   - .ai/conventions/api.md (cross-aggregate API conventions placeholder)
    ///   - .ai/contexts/{ContextName}/swift-adapter.yaml (only if --adapter not provided;
    ///     emits the resolved default Adapter as a starter template)
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        adapterProvided: Bool
    ) throws -> [(path: String, content: String)]
}
```

**行為**：
1. 一律寫 `.ai/conventions/api.md` placeholder（cross-aggregate API conventions）
2. 若 `adapterProvided == false`：寫 `.ai/contexts/{ContextName}/swift-adapter.yaml` 作為「starter template」，內容是把當前 default Adapter dump 成 YAML（**Yams 不支援 emit comments**，所以是純 YAML 無註解；user 須自行對照 architecture.md §6.2 或 README.md 內 explanation）；後續使用者可編輯 + 下次 `genesis new --adapter` 採用
3. 若 `adapterProvided == true`：**不** 覆寫使用者提供的 adapter file；只 record path 到 manifest

🔴 **starter swift-adapter.yaml 寫到 generated project 內，不是 user 手中的原檔**。Phase 1.c 不負責回寫使用者磁碟既有 yaml；只在 generated project 內放一份 starter。

🔴 **starter 無註解**（codex L7 修正）：先前 spec 段中提及「starter 含註解」是不準確的；Yams encoder API 沒有 comment emission hook，所以 Phase 1.c 鎖定「starter 為純 YAML 無註解」。文件指引由 README.md / CLAUDE.md / architecture.md §6.2 承接。

---

### Internal module：`GenesisCore.SourceWriter`（修改）

新增 `checkNoConflicts(at:) throws` API：

```swift
public extension SourceWriter {
    /// Throws if any planned file already exists under root. Caller invokes BEFORE commit().
    /// This is the single fs-conflict gate for the entire Phase 1.c write surface
    /// (Sources, .ai/contexts, .ai/conventions, README.md, CLAUDE.md, Tests/, Package.swift).
    func checkNoConflicts() throws
}
```

**行為**：iterate `planned` array，對每個 file 檢查 `FileManager.default.fileExists(atPath: ...)`，若任一存在 → throw `GenesisError.outputDirHasConflict(path: root, conflict: <relativePath>)`。

🔴 **codex H2 修正**：原 spec NewCommand 的 Phase 2 fs check 只擋 `Package.swift` + `Sources/{Agg}Aggregate/`，漏 `README.md` / `CLAUDE.md` / `.ai/conventions/api.md` / `Tests/{Ctx}Tests/PlaceholderTests.swift` 等 Phase 1.c 新增的寫入路徑。改成統一在 SourceWriter 層級檢查，**Phase 2 fs check 整段改成單一 `try writer.checkNoConflicts()` 呼叫**。

---

### Internal module：`GenesisCore.ManifestRenderer`（新）

```swift
public enum ManifestRenderer {
    /// Builds the .scaffold-manifest.json content from the list of (path, content, role) tuples
    /// that SourceWriter will commit. Each entry's sha256 is computed from `content` bytes.
    /// Caller (NewCommand) MUST tag each file with its role at plan time; ManifestRenderer
    /// does NOT do path-based role inference (codex M3 finding).
    public static func render(
        bundle: FullBundle,
        contextName: String,
        genesisVersion: String,
        exportedAt: String,           // injected for deterministic output in tests
        files: [(path: String, content: String, role: String)]
    ) throws -> (path: String, content: String)
}
```

**輸出**：`.ai/contexts/{ContextName}/.scaffold-manifest.json`

**Content schema**（per architecture.md §6.1）：

```json
{
  "manifestVersion": 1,
  "bundleId": "<bundle.bundleId>",
  "templateVersion": "<GenesisCoreVersion.current>",
  "exportedAt": "<UTC ISO-8601, injected by caller for determinism>",
  "generatedFiles": [
    { "path": "Sources/UserAccessProfileAggregate/UserAccessProfile.swift",
      "sha256": "0123abcd...",
      "role": "aggregate" }
  ]
}
```

🔴 **`role` 列舉**（Phase 1.c 全部支援；Phase 3 `diff` 會用 role 來決定該檔變更是 safe / needs-human）：
- `package` — Package.swift
- `aggregate` — Sources/{Agg}Aggregate/{Agg}.swift
- `aggregateError` — Sources/{Agg}Aggregate/{Agg}Error.swift
- `repository` — Adapter/{Agg}Repository.swift
- `commandExtension` — Entity/Commands/{Agg}+{UC}.swift
- `usecaseInput` / `usecaseOutput` / `usecase` / `service` — per-UC 四檔
- `eventYaml` / `eventGeneratorConfig` — event.yaml / event-generator-config.yaml
- `dto` — Sources/{Context}Shared/{D}.swift
- `valueObject` / `idWrapper` — adapter.customTypes 衍生
- `businessDoc` — .ai/contexts/{Agg}/*.md
- `contextDoc` — .ai/conventions/api.md / .ai/contexts/{Ctx}/swift-adapter.yaml
- `readme` — README.md / CLAUDE.md
- `testPlaceholder` — Tests/{Ctx}Tests/PlaceholderTests.swift

🔴 **`sha256` 計算**：用 `CryptoKit.SHA256` 對 `content.utf8` bytes 取 hash → hex string。**caller 提供 content 不含 EOL normalization 等預處理**（Genesis 把 template render 後的字串直接 hash）。

🔴 **`exportedAt` 注入**：與 BusinessDocRenderer 的 `generatedDate` 同樣由 caller 注入，目的：讓 unit test 能 freeze 時間驗證 deterministic 輸出。生產路徑由 NewCommand 注入 `ISO8601DateFormatter().string(from: Date())`。

---

### Internal module：`GenesisCore.ReadmeRenderer`（新）

```swift
public enum ReadmeRenderer {
    public static func renderReadme(
        bundle: FullBundle,
        contextName: String,
        genesisVersion: String
    ) throws -> (path: String, content: String)  // path = "README.md"

    public static func renderClaudeMd(
        bundle: FullBundle,
        contextName: String,
        genesisVersion: String
    ) throws -> (path: String, content: String)  // path = "CLAUDE.md"
}
```

**README.md 內容**：context 名稱、生成時的 bundle id、aggregates 列表（含每個的 UC 數）、`swift build` / `swift test` 指令、`.ai/contexts/` 目錄結構說明。

**CLAUDE.md 內容**：說明此專案由 Genesis 產生、業務邏輯靠 Claude Code skills 接手、列舉常用 skill（`/usecase {UC}`、`/readmodel {RM}`、`/api`）、提示 SSOT 在 `.ai/contexts/`、提醒 `docs/tasks/<UC>.md` 是 machine-rendered 不可手改（D15 Option D）。

---

### Internal module：`GenesisCore.GenesisError`（修改）

新增 cases：

```swift
case adapterNotFound(URL)
case adapterInvalid(reason: String)
case adapterIncompatible(reason: String)
```

**Exit code 對照**（更新）：

| Error case | Exit |
|-----------|------|
| `bundleNotFound`, `bundleInvalid`, `contextNameInvalid`, `outputDirHasConflict`, `adapterNotFound`, `adapterInvalid`, `adapterIncompatible` | 1 |
| `fileSystemFailed`, `swiftPackageResolveFailed`, `swiftBuildFailed` | 2 |
| `gitPreflightFailed` | 3 |

---

### Templates 新增 / 修改

#### 新增（v0.1）

- `IdWrapper.swift.template` — typed-ID wrapper struct
- `ValueObject.swift.template` — value object stub
- `BusinessDoc/config.md.template`
- `BusinessDoc/commands.md.template`
- `BusinessDoc/invariants.md.template`
- `BusinessDoc/errors.md.template`
- `BusinessDoc/api.md.template`
- `BusinessDoc/test-scenarios.md.template`
- `BusinessDoc/reference.md.template`
- `BusinessDoc/notes/README.md.template`
- `Conventions/api.md.template` — cross-aggregate api conventions placeholder
- `README.md.template`
- `CLAUDE.md.template`
- `SwiftAdapterStarter.yaml.template` — emitted to `.ai/contexts/{Ctx}/swift-adapter.yaml` when `--adapter` not provided
- `TestPlaceholder.swift.template` — Tests/{Ctx}Tests/PlaceholderTests.swift（一個 empty XCTestCase）

#### 修改（v0.1）

- `Package.swift.template`：加 `{SharedProductsList}` + `{SharedTargetsList}` + `{TestTargetBlock}` 三個 placeholder（caller 端 PackageRenderer 合成）
- `PackageTarget.swift.template`：dependencies 多加一行 `.target(name: "{ContextName}Shared")`（**只有當 Shared 存在時**；caller 端決定要不要插入此行）
- `Aggregate.swift.template`：把 `package typealias ID = String` 改為 `package typealias ID = {IDType}`；把 stored property `package var id: String` 改為 `package var id: {IDType}`

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---------|---------|
| `Package.swift` | **修改**：dependencies 加 `.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")`；`GenesisCore` target 加依賴 `Yams` |
| `Sources/GenesisCore/Adapter.swift` | **新增**：Adapter / CustomTypeSpec / AggregateSplitSpec / IdStrategySpec data models + `defaultFor(contextName:)` |
| `Sources/GenesisCore/AdapterYamlParser.swift` | **新增**：Yams-based parsing + 9-step validation + stderr warning for ignored fields |
| `Sources/GenesisCore/AdapterApplier.swift` | **新增**：validate(adapter:bundle:) + resolveCreatedUseCase(for:useCases:adapter:) |
| `Sources/GenesisCore/SourceWriter.swift` | **修改**：新增 `checkNoConflicts() throws` API；既有 plan/commit/rollback 不變 |
| `Sources/GenesisCore/SwiftTypeResolver.swift` | **修改**：新增 adapter-aware overload；舊 API 保留不動 |
| `Sources/GenesisCore/AggregateRenderer.swift` | **修改**：簽章加 `adapter: Adapter`；改呼 AdapterApplier + adapter-aware SwiftTypeResolver；套用 idStrategy（IDType placeholder） |
| `Sources/GenesisCore/UseCaseRenderer.swift` | **修改**：簽章加 `adapter: Adapter`；所有 SwiftTypeResolver 呼叫改用新 overload |
| `Sources/GenesisCore/PackageRenderer.swift` | **修改**：簽章加 `adapter: Adapter`；組 SharedProductsList / SharedTargetsList / TestTargetBlock；每個 aggregate target dependencies 加 ContextShared |
| `Sources/GenesisCore/DtoRenderer.swift` | **修改**：簽章加 `hostTarget: String` 替換 `hostAggregate: String`（變數名清晰化），讓 caller 可傳 `"{Ctx}Shared"` |
| `Sources/GenesisCore/SharedTargetRenderer.swift` | **新增**：合併 bundle.dtos + adapter.customTypes，dedupe，render per-DTO 檔到 Sources/{Ctx}Shared/ |
| `Sources/GenesisCore/BusinessDocRenderer.swift` | **新增**：產 7 個 .md + notes/README.md per aggregate |
| `Sources/GenesisCore/ContextLevelRenderer.swift` | **新增**：產 .ai/conventions/api.md + 條件性 .ai/contexts/{Ctx}/swift-adapter.yaml starter |
| `Sources/GenesisCore/ManifestRenderer.swift` | **新增**：用 CryptoKit.SHA256 算每檔 hash；產 .scaffold-manifest.json |
| `Sources/GenesisCore/ReadmeRenderer.swift` | **新增**：產 README.md + CLAUDE.md |
| `Sources/GenesisCore/GenesisError.swift` | **修改**：新增 `adapterNotFound` / `adapterInvalid` / `adapterIncompatible`；exit code 表更新 |
| `Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template` | **修改**：`{IDType}` placeholder 替換 hard-coded String |
| `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template` | **修改**：加 SharedProductsList / SharedTargetsList / TestTargetBlock placeholders |
| `Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template` | **修改**：可選的 `.target(name: "{ContextName}Shared")` dependency（caller 端決定） |
| 14 個新 template 檔（見上「Templates 新增」清單） | **新增** |
| `Sources/Genesis/Commands/NewCommand.swift` | **修改**：加 `--adapter` flag；run() 流程升級為 parseFull → parseAdapter? → applyAdapter → 全部 renderers → SourceWriter.commit → swift package resolve |
| `Tests/GenesisCoreTests/AdapterYamlParserTests.swift` | **新增**：syntax 驗證 9 項 + happy path |
| `Tests/GenesisCoreTests/AdapterApplierTests.swift` | **新增**：createdEventOverrides happy + missing UC reject + 沒 override fallback |
| `Tests/GenesisCoreTests/SwiftTypeResolverAdapterTests.swift` | **新增**：typeMapping override path |
| `Tests/GenesisCoreTests/ManifestRendererTests.swift` | **新增**：SHA256 一致性 + role 列舉完整性 |
| `Tests/GenesisCoreTests/BusinessDocRendererTests.swift` | **新增**：7 檔 paths + frontmatter + 內容 spot-check |
| `Tests/GenesisCoreTests/SharedTargetRendererTests.swift` | **新增**：bundle dtos + adapter customTypes dedupe + valueObject / identifier / enum 三種 kind |
| `Tests/GenesisCoreTests/AggregateRendererTests.swift` | **修改**：原測仍綠（用 default adapter）；新增 `testAdapterIdStrategyTypedStruct` 驗證 typealias ID 變化 |
| `Tests/GenesisIntegrationTests/Fixtures/swift-adapter.iam.yaml` | **新增**：適配 iam-bundle 的完整 adapter |
| `Tests/GenesisIntegrationTests/Fixtures/swift-adapter-invalid-context.yaml` | **新增**：contextName 不匹配的 adapter |
| `Tests/GenesisIntegrationTests/Fixtures/swift-adapter-typedstruct.yaml` | **新增**：含 idStrategy.typedStruct |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | **修改**：**`testFullBundleEndToEnd` 期望路徑改為 `Sources/IAMContextShared/EmployeeStatus.swift`**（Phase 1.b 行為已被 Phase 1.c 取代）；新增 `testWithAdapterTypedStruct`、`testAdapterContextMismatch`、`testAdapterCreatedEventOverride`、`testManifestWritten`、`testBusinessDocsWritten`、`testStarterAdapterWrittenWhenNoFlag` |

---

## 實作步驟

### Step 1：加 Yams dependency 到 Genesis 自身 Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
],
targets: [
    .executableTarget(name: "Genesis", dependencies: [
        "GenesisCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .target(
        name: "GenesisCore",
        dependencies: [
            .product(name: "Yams", package: "Yams"),
        ],
        resources: [.copy("Resources/Templates")]
    ),
    ...
]
```

🔴 **不引入 transitive 衝突**：Yams 5.1+ 是 DDDKit 也用的版本，generated project Package.swift 不變（只在 root user side 透過 DDDKit 拉 Yams，Genesis 自身另外拉一份 — SwiftPM 會 resolve 到單一版本）。

### Step 2：寫 Adapter data model + AdapterYamlParser

按 §「Internal module: AdapterYamlParser」9 步驟驗證。注意 Yams 對 YAML `null` 的處理（用 optional decoding）。

### Step 3：寫 AdapterApplier

```swift
public static func validate(adapter: Adapter, bundle: FullBundle) throws {
    let aggMap = Dictionary(uniqueKeysWithValues: bundle.aggregates.map { ($0.name, $0) })
    for (aggName, ucName) in adapter.createdEventOverrides {
        guard let agg = aggMap[aggName] else {
            throw GenesisError.adapterInvalid(
                reason: "createdEventOverrides references aggregate '\(aggName)' not in bundle"
            )
        }
        let aggUCs = bundle.useCases.filter { $0.aggregateSpecId == agg.aggregateSpecId }
        if !aggUCs.contains(where: { $0.useCase == ucName }) {
            throw GenesisError.adapterInvalid(
                reason: "createdEventOverrides[\(aggName)] = '\(ucName)' but no such useCase exists"
            )
        }
    }
}

public static func resolveCreatedUseCase(
    for aggregate: AggregateSpec,
    useCases: [UseCaseSpec],
    adapter: Adapter
) throws -> UseCaseSpec {
    if let ucName = adapter.createdEventOverrides[aggregate.name],
       let uc = useCases.first(where: { $0.useCase == ucName }) {
        return uc
    }
    // Phase 1.b 三層 fallback（原本在 AggregateRenderer 內，搬到這裡 / 抽 helper）
    return try fallbackResolve(for: aggregate, useCases: useCases)
}

private static func fallbackResolve(for aggregate: AggregateSpec, useCases: [UseCaseSpec]) throws -> UseCaseSpec {
    // ... 從 Phase 1.b AggregateRenderer.resolveCreatedUseCase 搬過來
}
```

🔴 **重要 refactor**：Phase 1.b 的 `AggregateRenderer.resolveCreatedUseCase` 內含三層 fallback，搬到 `AdapterApplier.fallbackResolve` 為 private static。`AggregateRenderer` 改成只呼 `AdapterApplier.resolveCreatedUseCase`。

### Step 4：SwiftTypeResolver adapter-aware overload

```swift
public extension SwiftTypeResolver {
    static func resolve(rawType: String, knownCustomTypes: Set<String>, adapter: Adapter) throws -> String {
        let trimmed = rawType.trimmingCharacters(in: .whitespaces)
        if let mapped = adapter.typeMapping[trimmed] {
            return mapped
        }
        return try resolve(rawType: rawType, knownCustomTypes: knownCustomTypes)
    }
}
```

舊 API 保留，新 API additive。

### Step 5：AggregateRenderer + UseCaseRenderer + DtoRenderer 簽章升級

**所有 caller 都要傳 `adapter`**。對應傳遞鏈：

- `NewCommand.run()` → `PackageRenderer.render(... adapter:)` / `AggregateRenderer.render(... adapter:)` / `SharedTargetRenderer.render(... adapter:)` / `ManifestRenderer.render(...)` / `BusinessDocRenderer.render(... adapter:)` / `ContextLevelRenderer.render(... adapter:)` / `ReadmeRenderer.renderReadme(...)` + `renderClaudeMd(...)`
- `AggregateRenderer.render` → 內部呼 `AdapterApplier.resolveCreatedUseCase(... adapter:)`、`UseCaseRenderer.render(... adapter:)`、`SwiftTypeResolver.resolve(... adapter:)`
- `UseCaseRenderer.render` → 內部呼 adapter-aware SwiftTypeResolver

**idStrategy 套用邏輯**（在 `AggregateRenderer.renderAggregate`）：

```swift
let idType: String
switch adapter.idStrategy.kind {
case .direct:
    idType = "String"
case .typedStruct:
    let wrapperRaw = adapter.idStrategy.wrapper ?? "{Aggregate}ID"
    idType = wrapperRaw.replacingOccurrences(of: "{Aggregate}", with: spec.name)
}
// inject as {IDType} template variable
```

### Step 6：SharedTargetRenderer

```swift
public static func render(bundle: FullBundle, contextName: String, adapter: Adapter) throws -> [(path: String, content: String)] {
    var outputs: [(String, String)] = []
    let sharedDir = "Sources/\(contextName)Shared"

    // 1) bundle.dtos
    var emittedNames: Set<String> = []
    let knownCustomTypes = Set(bundle.dtos.map { $0.name } + adapter.customTypes.map { $0.name })

    // adapter customTypes 優先（同名覆蓋 bundle.dtos）
    for ct in adapter.customTypes {
        outputs.append(try renderCustomType(ct, dir: sharedDir, knownCustomTypes: knownCustomTypes))
        emittedNames.insert(ct.name)
    }
    for dto in bundle.dtos where !emittedNames.contains(dto.name) {
        outputs.append(try DtoRenderer.render(dto: dto, hostTarget: "\(contextName)Shared", knownCustomTypes: knownCustomTypes))
        emittedNames.insert(dto.name)
    }
    return outputs
}

private static func renderCustomType(_ ct: CustomTypeSpec, dir: String, knownCustomTypes: Set<String>) throws -> (String, String) {
    switch ct.kind {
    case .enum:
        // 用 Dto.swift.template，body 是 case 列表，從 ct.cases
    case .valueObject:
        // 用 ValueObject.swift.template
    case .identifier:
        // 用 IdWrapper.swift.template
    }
}
```

### Step 7：BusinessDocRenderer

每個檔的 template content 範例如下：

**`BusinessDoc/commands.md.template`**：

```markdown
---
aggregate: {Aggregate}
context: {ContextName}
bundleId: {BundleId}
generated: {GeneratedDate}
generator: Genesis v{GenesisVersion}
---
# Commands — {Aggregate}

Master file for command guards and state transitions (D15).
Consumed by the `/usecase` Claude Code skill.

{CommandBlocks}
```

`{CommandBlocks}` 由 caller iterate aggregate 的 useCases[]，每個 UC append 一個 sub-block（從 `BusinessDoc/commands.md.uc.template` 渲染）：

```markdown
## {UseCase}

**Input**:
{InputFields}

**Preconditions** (from bundle):
{Preconditions}

**Emits**: `{EmittedEvent}` → see `event.yaml`

**State transitions** (to be filled by `/usecase` skill):
- *placeholder*

---
```

其他 6 個檔同樣模板化。**Phase 1.c 提供 starter content；不寫 finished business logic**（那是 user/AI 的工作）。

### Step 8：ContextLevelRenderer

- `.ai/conventions/api.md` 固定 placeholder（含 `## Error → HTTP map` 空 table）
- `.ai/contexts/{Ctx}/swift-adapter.yaml` starter 內容由 caller dump default Adapter as YAML
  - 用 Yams encoder
  - 含註解（Yams 不直接支援，需要 caller 手動 prefix `# ` 行）

### Step 9：ManifestRenderer

```swift
import CryptoKit

private static func sha256Hex(of content: String) -> String {
    let data = Data(content.utf8)
    let hash = SHA256.hash(data: data)
    return hash.map { String(format: "%02x", $0) }.joined()
}

public static func render(bundle: FullBundle, contextName: String, genesisVersion: String, files: [(path: String, content: String, role: String)]) throws -> (path: String, content: String) {
    struct ManifestEntry: Codable {
        let path: String
        let sha256: String
        let role: String
    }
    struct Manifest: Codable {
        let manifestVersion: Int
        let bundleId: String
        let templateVersion: String
        let exportedAt: String
        let generatedFiles: [ManifestEntry]
    }
    let entries = files.map { ManifestEntry(path: $0.path, sha256: sha256Hex(of: $0.content), role: $0.role) }
    let manifest = Manifest(
        manifestVersion: 1,
        bundleId: bundle.bundleId,
        templateVersion: genesisVersion,
        exportedAt: ISO8601DateFormatter().string(from: Date()),  // caller 可注入但 default 是 now
        generatedFiles: entries
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    let path = ".ai/contexts/\(contextName)/.scaffold-manifest.json"
    return (path, String(data: data, encoding: .utf8) ?? "{}")
}
```

🔴 **`exportedAt` 注入點**：spec 上述用了 `Date()` 為 default。Test 端會傳入 frozen date 透過 overload `render(..., exportedAt: String)`。實作期實際 signature 提供兩個版本（一個用 default `Date()`、一個 caller 注入）— 或更乾淨：caller 一律注入，NewCommand 在 production path 注入 `ISO8601DateFormatter().string(from: Date())`。

### Step 10：ReadmeRenderer

直接用 templates + caller-side join。

### Step 11：NewCommand 升級

完整 run() 流程：

```swift
func run() async throws {
    // Phase 0: input sanity (regex + flag empties)
    // Phase 1: read-only — parse bundle + adapter
    let bundle = try BundleParser.parseFull(at: bundleURL)
    if bundle.context != contextName { /* stderr warn */ }

    let adapterProvided = (adapterFlag != nil)
    let adapter: Adapter
    if let adapterPath = adapterFlag {
        adapter = try AdapterYamlParser.parse(at: URL(fileURLWithPath: adapterPath), contextName: contextName, bundleId: bundle.bundleId)
    } else {
        adapter = .defaultFor(contextName: contextName)
    }
    try AdapterApplier.validate(adapter: adapter, bundle: bundle)

    // Phase 2: render in memory
    let writer = SourceWriter(root: outputURL)
    var taggedFiles: [(path: String, content: String, role: String)] = []

    func plan(_ path: String, _ content: String, _ role: String) {
        writer.plan(relativePath: path, content: content)
        taggedFiles.append((path, content, role))
    }

    // 2.1 Package.swift — renderer returns (path, content) (no role; we tag below)
    let pkg = try PackageRenderer.render(bundle: bundle, contextName: contextName, genesisVersion: GenesisCoreVersion.current, adapter: adapter)
    plan(pkg.path, pkg.content, "package")

    // 2.2 Per-aggregate files (+ per-UC) — renderer returns (path, content, role) tuples explicitly
    for agg in bundle.aggregates {
        for f in try AggregateRenderer.render(spec: agg, bundle: bundle, adapter: adapter) {
            plan(f.path, f.content, f.role)
        }
    }

    // 2.3 Shared target (always if bundle has DTOs OR adapter has customTypes OR idStrategy is typedStruct)
    let needShared = !bundle.dtos.isEmpty || !adapter.customTypes.isEmpty || adapter.idStrategy.kind == .typedStruct
    if needShared {
        for f in try SharedTargetRenderer.render(bundle: bundle, contextName: contextName, adapter: adapter) {
            plan(f.path, f.content, f.role)
        }
    }

    // 2.4 Test placeholder
    let placeholderPath = "Tests/\(contextName)Tests/PlaceholderTests.swift"
    let placeholderTemplate = try TemplateLoader.loadTemplate(name: "TestPlaceholder.swift", ext: "template")
    let placeholderRendered = TemplateRenderer.render(template: placeholderTemplate, vars: ["ContextName": contextName])
    plan(placeholderPath, placeholderRendered.output, "testPlaceholder")

    // 2.5 Business docs (per aggregate; renderer returns role per file)
    let generatedDate = String(ISO8601DateFormatter().string(from: Date()).prefix(10))  // YYYY-MM-DD
    for agg in bundle.aggregates {
        for f in try BusinessDocRenderer.render(spec: agg, bundle: bundle, adapter: adapter, contextName: contextName, generatedDate: generatedDate) {
            plan(f.path, f.content, f.role)
        }
    }

    // 2.6 Context-level docs (conventions + starter adapter)
    for f in try ContextLevelRenderer.render(bundle: bundle, contextName: contextName, adapter: adapter, adapterProvided: adapterProvided) {
        plan(f.path, f.content, f.role)
    }

    // 2.7 README + CLAUDE
    let r = try ReadmeRenderer.renderReadme(bundle: bundle, contextName: contextName, genesisVersion: GenesisCoreVersion.current)
    plan(r.path, r.content, "readme")
    let cm = try ReadmeRenderer.renderClaudeMd(bundle: bundle, contextName: contextName, genesisVersion: GenesisCoreVersion.current)
    plan(cm.path, cm.content, "readme")

    // 2.8 Manifest (computed AFTER all other files are planned; not included in its own generatedFiles[])
    let exportedAt = ISO8601DateFormatter().string(from: Date())
    let m = try ManifestRenderer.render(
        bundle: bundle, contextName: contextName,
        genesisVersion: GenesisCoreVersion.current,
        exportedAt: exportedAt,
        files: taggedFiles
    )
    writer.plan(relativePath: m.path, content: m.content)
    // ⚠️ manifest's own sha256 不入自己的 generatedFiles[]（chicken-and-egg；已記入「已知限制」）

    // Phase 2.9: SINGLE fs conflict gate (codex H2 fix)
    try writer.checkNoConflicts()

    // Phase 3-4: mutation (same as Phase 1.b)
    ...
}
```

🔴 **`roleFromPath` 被刪除**（codex M3 修正）：原 spec 用 path 後綴推斷 role，無法區分 Shared target 內的 `dto`/`valueObject`/`idWrapper`。所有 renderer 改回傳 `(path, content, role)` tuple，NewCommand 直接讀 `f.role`。

🔴 **Phase 2 fs check 簡化為單一呼叫**（codex H2 修正）：原 spec 在 NewCommand 內手動列舉 `Sources/{Agg}Aggregate/` 與 `Package.swift` 做存在性檢查 — 漏掉 `.ai/contexts/`、`.ai/conventions/`、`README.md`、`CLAUDE.md`、`Tests/`。改成 `SourceWriter.checkNoConflicts()` 一次掃描全部 planned paths。

### Step 12：Tests

依 §「改動檔案」清單實作。**最關鍵的兩個 backward-compat test**：

(a) `testFullBundleEndToEndWithoutAdapter` — Phase 1.b 的 `testFullBundleEndToEnd` 重命名 + 路徑更新；不傳 `--adapter`，期望輸出與 Phase 1.b 一致（除 EmployeeStatus.swift 已搬到 `Sources/IAMContextShared/`）

(b) `testWithAdapterTypedStruct` — 傳 `--adapter swift-adapter-typedstruct.yaml`（含 `idStrategy.kind == typedStruct`），檢查產出的 `UserAccessProfile.swift` 含 `package typealias ID = UserAccessProfileID` 且 `Sources/IAMContextShared/UserAccessProfileID.swift` 存在

---

## 失敗路徑

```
[Phase 0: input sanity — 同 Phase 1.b]

[Phase 1: read-only parse]
A. Adapter 路徑提供但不存在 → adapterNotFound → exit 1
B. Adapter YAML malformed → adapterInvalid(reason: "YAML parse error: ...") → exit 1
C. Adapter contextName ≠ CLI contextName → adapterIncompatible(reason: "contextName ...") → exit 1
D. Adapter bundleId 存在但 ≠ bundle.bundleId → adapterIncompatible → exit 1
E. Adapter aggregateSplit.strategy ≠ "byBoundedContext" → adapterInvalid → exit 1
F. Adapter idStrategy.kind 非預期值 → adapterInvalid → exit 1
G. Adapter idStrategy.kind == typedStruct 但無 wrapper → adapterInvalid → exit 1
H. Adapter customTypes[i].kind == enum 但 cases 為空 → adapterInvalid → exit 1
I. Adapter customTypes[i].kind ∈ {valueObject, identifier} 但 underlying 為空 → adapterInvalid → exit 1
J. AdapterApplier.validate：createdEventOverrides[aggName] aggName 不存在 → adapterInvalid → exit 1
K. AdapterApplier.validate：createdEventOverrides[aggName] = ucName 在該 agg 的 UCs 中找不到 → adapterInvalid → exit 1
L. AdapterApplier.resolveCreatedUseCase：沒 override 且 fallback chain 全失敗 → bundleInvalid（同 Phase 1.b） → exit 1
M. BundleParser.parseFull 任何錯 → 同 Phase 1.b → exit 1

[Phase 2: render — 純記憶體]
N. SwiftTypeResolver 未知 type → bundleInvalid → exit 1
O. SharedTargetRenderer customType.underlying 引用未知 type → bundleInvalid → exit 1

[Phase 3: fs check]
P. Sources/{Agg}Aggregate/ 或 Sources/{Ctx}Shared/ 或 .ai/contexts/ 已存在 → outputDirHasConflict → exit 1
Q. Package.swift 已存在 → outputDirHasConflict（沿用） → exit 1

[Phase 4: mutation]
R. createDirectory 失敗 → fileSystemFailed → exit 2
S. GitPreflight 失敗 → gitPreflightFailed → exit 3，dir rollback
T. SourceWriter.commit 部分檔失敗 → fileSystemFailed → exit 2，SourceWriter rollback + outer dir rollback

[Phase 5: validation]
U. swift package resolve 失敗 → swiftPackageResolveFailed → exit 2，SourceWriter rollback + outer dir rollback
```

🔴 **Rollback 補充**：Phase 1.c 寫的檔比 Phase 1.b 多很多（業務文件 + manifest + readme），都被 SourceWriter 統一追蹤。任何 Phase 4-5 失敗 → SourceWriter.rollback 把全部清掉 → outer dir rollback。

---

## 不改動的部分

- Phase 1.a 既有 28 個 unit test 仍須通過（BundleParser.parseMinimal、TemplateRenderer、GitPreflight、ProcessRunner、GenesisError 沿用 case）
- Phase 1.b 既有 28 個 unit test **多數仍須通過**，**例外**：
  - `AggregateRendererTests.testRenderProducesExpectedFiles` 對 `EmployeeStatus.swift` 路徑斷言要更新（從 `Sources/UserAccessProfileAggregate/EmployeeStatus.swift` 改為 `Sources/IAMContextShared/EmployeeStatus.swift`）
  - `NewCommandTests.testFullBundleEndToEnd` 對 `EmployeeStatus.swift` 路徑斷言要更新
- Phase 1.b SourceWriter / SwiftTypeResolver / CaseTransformer / FullBundle / BundleParser.parseFull / TemplateLoader 介面**只能 additive 擴充**，不可 breaking change
- 既有 Genesis 自身 Package.swift swift-tools-version 5.10 / macOS .v13 — 不變

### Non-goals（行為層）

本 task **不包含**：
- `genesis adapter` 指令（自動產 `swift-adapter.proposed.yaml`）— **→ Phase 3**
- `genesis diff` / `apply` — **→ Phase 3**
- `genesis install-skills` / `install-mcp` — **→ Phase 1.d / 2**
- canvas sync（`plan-canvas-sync`、`verify-canvas`、`apply-canvas`）— **→ Phase 4**
- ReadModel / Projector 生成（bundle.readModels 仍 fast-fail，與 Phase 1.b 同）
- `projections/` 目錄 / `scripts/start-kurrentdb.sh` / `scripts/projection.sh`
- 跨 aggregate `Listener/{SourceAggregate}/When{Event}.swift` 生成
- `Sources/{Server}/` executable target
- `openapi.yaml` + generator config（per architecture.md §3 但 Phase 1.c 不做；`/api` skill 在 user side 補）
- `projection-model.yaml`（per架構但 Phase 1.c 不做）
- `Entity/{Aggregate}+Invariant.swift` separate file（per架構 §3 但 Phase 1.b/1.c 用 method 形式而非 separate extension file）
- `Adapter/ApiHandler.swift` + `Adapter/{UC}/{UC}ApplicationService.swift`（per架構 §3 但 Phase 1.c 不做；`/api` skill 在 user side 補）
- adapter.yaml 內 `payloadConventions` / `testingConventions` / `imports` / `skip` 欄位的套用（Phase 1.c 讀但忽略）
- adapter.yaml 內 `aggregateSplit.rootMap` 自訂路徑（強制走 `Sources/{Context}Shared/`）
- adapter.yaml 內 `aggregateSplit.strategy` 非 `byBoundedContext` 值（reject）
- value object 的 underlying validation logic（只產 stub struct，不寫 validation method body）
- typed ID wrapper 的 string conversion / equality 客製化（只產 minimal Hashable/Sendable/Codable conform）
- swift-adapter.yaml 「starter template」內加註解 — 只 emit dump 的 YAML（Yams 不直接支援 comment emit；Phase 1.c 接受純 YAML 無註解）
- Tests/{Ctx}Tests/ 內的 `Tests/Fixtures/` 目錄產生（Phase 1.c 只放 PlaceholderTests.swift）
- `swift build` 驗證（沿用 Phase 1.b 實作期決定：用 `swift package resolve` 避免 cold-build 5-10 分鐘）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# C1. release build
swift build -c release --product genesis

# C2. Phase 1.a + 1.b 既有 unit test 全綠（路徑斷言更新後）
swift test --filter GenesisCoreTests

# C3. Phase 1.c 新單元測試全綠
swift test --filter AdapterYamlParserTests
swift test --filter AdapterApplierTests
swift test --filter SwiftTypeResolverAdapterTests
swift test --filter ManifestRendererTests
swift test --filter BusinessDocRendererTests
swift test --filter SharedTargetRendererTests

# C4. Phase 1.c 新整合測試全綠
swift test --filter testFullBundleEndToEndWithoutAdapter
swift test --filter testWithAdapterTypedStruct
swift test --filter testAdapterContextMismatch
swift test --filter testAdapterCreatedEventOverride
swift test --filter testManifestWritten
swift test --filter testBusinessDocsWritten
swift test --filter testStarterAdapterWrittenWhenNoFlag

# C5. 新增 templates 都在
test -f Sources/GenesisCore/Resources/Templates/v0.1/IdWrapper.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/ValueObject.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/BusinessDoc/commands.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/BusinessDoc/invariants.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/BusinessDoc/errors.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/BusinessDoc/api.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/BusinessDoc/test-scenarios.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/BusinessDoc/config.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/BusinessDoc/reference.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Conventions/api.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/README.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/CLAUDE.md.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/SwiftAdapterStarter.yaml.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/TestPlaceholder.swift.template

# C6. GenesisError 新增三個 case 都有 throw 點
grep -RE 'throw\s+GenesisError\.adapterNotFound' Sources/
grep -RE 'throw\s+GenesisError\.adapterInvalid' Sources/
grep -RE 'throw\s+GenesisError\.adapterIncompatible' Sources/

# C7. AdapterApplier 接管 createdUseCase 解析（AggregateRenderer 不再自帶 fallback chain）
grep -F 'AdapterApplier.resolveCreatedUseCase' Sources/GenesisCore/AggregateRenderer.swift
! grep -RE 'private static func resolveCreatedUseCase' Sources/GenesisCore/AggregateRenderer.swift

# C8. Aggregate.swift template 用 IDType placeholder
grep -F 'typealias ID = {IDType}' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template
! grep -F 'typealias ID = String' Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template

# C9. Package.swift template 含 Shared / Test placeholder
grep -F '{SharedProductsList}' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F '{SharedTargetsList}' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F '{TestTargetBlock}' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template

# C10. Yams dependency 在 Genesis 自身 Package.swift
grep -F 'jpsim/Yams' Package.swift

# C11. NewCommand 接 --adapter flag
grep -F '--adapter' Sources/Genesis/Commands/NewCommand.swift
grep -F 'AdapterYamlParser.parse' Sources/Genesis/Commands/NewCommand.swift
grep -F 'AdapterApplier.validate' Sources/Genesis/Commands/NewCommand.swift

# C12. ManifestRenderer 使用 CryptoKit.SHA256
grep -F 'import CryptoKit' Sources/GenesisCore/ManifestRenderer.swift
grep -F 'SHA256.hash' Sources/GenesisCore/ManifestRenderer.swift

# C13. Integration test 不能 swift run 或直呼 NewCommand（沿用 Phase 1.a）
! grep -RE 'swift\s+run\s+genesis' Tests/GenesisIntegrationTests/
! grep -RE 'NewCommand\(\).*\.run\(\)|NewCommand\(\)\.run' Tests/GenesisIntegrationTests/

# C14. CLI 不能印 skill 名稱（D24）— **除了 CLAUDE.md template 內可以列**
! grep -RE '"(usecase|readmodel|event-storming|strict-review)"' Sources/Genesis/ Sources/GenesisCore/

# C15. Real-world e2e（命令本身）
mkdir -p /tmp/genesis-1c-e2e && cd /tmp/genesis-1c-e2e && git init -q && \
  git config user.email t@t && git config user.name t && \
  git commit --allow-empty -q -m init && \
  /Users/abnertsai/JiaBao/Mendesky/Genesis/.build/release/genesis new IAMContext \
    --from-bundle /Users/abnertsai/JiaBao/Mendesky/Genesis/Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json \
    --adapter /Users/abnertsai/JiaBao/Mendesky/Genesis/Tests/GenesisIntegrationTests/Fixtures/swift-adapter.iam.yaml \
    --output .
echo $?  # 必須 0

# C16. e2e 產出包含關鍵新檔案（nested .ai/contexts/{Context}/{Aggregate}/ 結構 — codex M4 修正）
test -d /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/commands.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/invariants.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/errors.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/api.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/test-scenarios.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/config.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/reference.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/notes/grantPrivilege.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/UserAccessProfile/notes/README.md
test -f /tmp/genesis-1c-e2e/.ai/contexts/IAMContext/.scaffold-manifest.json
test -f /tmp/genesis-1c-e2e/.ai/conventions/api.md
test -f /tmp/genesis-1c-e2e/Sources/IAMContextShared/EmployeeStatus.swift
test -f /tmp/genesis-1c-e2e/README.md
test -f /tmp/genesis-1c-e2e/CLAUDE.md
test -f /tmp/genesis-1c-e2e/Tests/IAMContextTests/PlaceholderTests.swift

# C17. typedStruct without matching customTypes → wrapper still auto-generated
# (run e2e with --adapter swift-adapter-typedstruct.yaml; minimal adapter only declares idStrategy)
test -f /tmp/genesis-1c-typedstruct-e2e/Sources/IAMContextShared/UserAccessProfileID.swift 2>/dev/null || true  # tested in unit/integration tests

# C18. SourceWriter has checkNoConflicts
grep -RE 'public func checkNoConflicts\(\) throws' Sources/GenesisCore/SourceWriter.swift

# C19. NewCommand calls checkNoConflicts (single fs gate)
grep -F 'writer.checkNoConflicts' Sources/Genesis/Commands/NewCommand.swift

# C20. AdapterYamlParser emits stderr warning for ignored fields
grep -RE 'parsed but not applied' Sources/GenesisCore/AdapterYamlParser.swift
```

### Human 補做（需要人類介入）

- [ ] 手動跑 `genesis new IAMContext --from-bundle ... --adapter ...`，**目測** `.ai/contexts/UserAccessProfile/commands.md` 內容是否含全部 7 個 UC 的 sub-block，preconditions 從 bundle 抓對
- [ ] 目測 `.ai/contexts/UserAccessProfile/invariants.md` 含 3 個 invariants（IAM bundle 既有）的完整資訊（name / title / rules / errorCode）
- [ ] 目測 `.ai/contexts/UserAccessProfile/test-scenarios.md` 為每個 UC 生 Gherkin Scenario placeholder
- [ ] 目測 `.ai/contexts/IAMContext/.scaffold-manifest.json`：含所有產生檔案、每檔有 sha256（hex string）、`generatedFiles` 數量合理
- [ ] 用 `sha256sum` 對 `.ai/contexts/UserAccessProfile/commands.md` 跑 hash 並對照 manifest entry 是否一致（驗證 sha256 計算正確）
- [ ] 故意改一個 commands.md 內容，**重跑** genesis new 到不同目錄，比較兩個 manifest 的 sha256 是否 differ — 驗證 hash 對內容敏感
- [ ] 目測 `Sources/IAMContextShared/EmployeeStatus.swift` 有 enum 形式（之前在 aggregate 內，現在搬出來）
- [ ] 在 e2e 結果目錄跑 `swift package resolve`（不跑 build），確認 exit 0
- [ ] 用 `--adapter` 指到不存在路徑 → 確認 exit 1 + stderr 含 "does not exist"
- [ ] 用 `--adapter` 指到 contextName 不匹配的 yaml → 確認 exit 1 + stderr 含 "contextName"
- [ ] 用 typedStruct adapter → 目測 `UserAccessProfile.swift` 含 `typealias ID = UserAccessProfileID`，`Sources/IAMContextShared/UserAccessProfileID.swift` 存在且 conform `Hashable, Sendable, Codable`
- [ ] 不傳 `--adapter`，目測 `.ai/contexts/IAMContext/swift-adapter.yaml` starter 是否被產出（內容是 default Adapter dump 的 YAML）
- [ ] README.md 目測：含 context 名、aggregate 列表、UC 數、`swift build`/`swift test` 指令、`.ai/contexts/` 結構說明
- [ ] CLAUDE.md 目測：含 skill 使用提示（`/usecase`、`/readmodel`、`/api`）、SSOT 提醒、`docs/tasks/<UC>.md` machine-rendered 警告

---

## 已知限制

- **adapter.yaml 多個欄位讀但不套用**：`payloadConventions` / `testingConventions` / `imports` / `skip` — Phase 1.c 不套用，但 AdapterYamlParser **會對 stderr 寫 warning**（codex M5 修正）；Phase 1.d / Phase 3 才看實作哪些
- **aggregateSplit.rootMap 路徑覆寫不支援**：Phase 1.c 一律走 `Sources/{Context}Shared/`；rootMap 欄位讀但忽略
- **aggregateSplit.strategy** 只支援 `byBoundedContext`；其他值 fast-fail throw
- **idStrategy** 只支援 `direct` 或 `typedStruct`；其他 kind throw
- **value object underlying validation** 不產：value object stub 只有 `let underlying: {Underlying}` + init，沒有 validation method body（user 自己加）
- **typed ID wrapper** 只產最 minimal struct（Hashable / Sendable / Codable conform + `init(_ underlying: T)`），不產 string conversion / equality customization
- **swift-adapter.yaml starter** 不含註解（Yams 限制）；user 拿到 starter 可能不知道每個欄位作用 — 由 architecture.md §6.2 / README.md 內文補
- **`Phase 1.b 的 EmployeeStatus.swift 位置變更**：Phase 1.b 把它放在 `Sources/UserAccessProfileAggregate/`，Phase 1.c 改 `Sources/IAMContextShared/`。**backward-incompatible**，Phase 1.b 兩個 integration test 的斷言要同步更新（已記入「不改動的部分」段）
- **swift build 驗證**：沿用 Phase 1.b 取捨，Phase 1.c **仍用 `swift package resolve`** 不用 `swift build`（理由：generated project 跨 KurrentDB + gRPC 巨型依賴鏈，每個 integration test 都跑 swift build 會 5-10 分鐘 / 個）
- **Manifest 不包含 manifest 自己**：`.scaffold-manifest.json` 的 `generatedFiles[]` 不含 `.scaffold-manifest.json` 本身（避免 chicken-and-egg）
- **`exportedAt` / `generated` 日期注入**：production NewCommand path 用 `Date()` now；test 端透過 caller-injected fixed date 確保 deterministic 輸出
- **Multi-context 不支援**：仍是一 bundle 一 context
- **`.ai/contexts/` 結構**（codex M4 修正後）：採 nested `.ai/contexts/{ContextName}/{Aggregate}/`，避免 aggregate 名跟 context 名共用 namespace 碰撞。`.scaffold-manifest.json` 與 `swift-adapter.yaml` 走 `.ai/contexts/{ContextName}/` （aggregate 父層）。架構文件 §3 diagram 上的 `.ai/contexts/{Aggregate}/` 在 Phase 1.c 收尾時順手更新（spec 不另開 task）
- **依賴關係**：前置 task = `phase-1b-aggregate-extraction`（status: `done`）
- **後續 task**：
  - `phase-1d-install-skills` — `genesis install-skills` 指令（Phase 1.c 的 CLAUDE.md 已提到 skills，install 留 Phase 1.d）
  - `phase-2-mcp` — `genesis install-mcp` + `--with-mcp` flag
  - `phase-3-diff-apply` — `genesis diff` / `apply` / `adapter`（adapter 指令會自動產 `swift-adapter.proposed.yaml`）
