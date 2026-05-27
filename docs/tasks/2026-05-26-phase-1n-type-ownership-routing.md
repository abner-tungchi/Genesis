# Phase 1.n — Custom type ownership routing

## 來源

討論：`docs/discussions/2026-05-26-phase-1n-type-ownership-routing.md`

依賴 Phase（全 done）：phase-1f（ContextShared infra）、phase-1h（DtoSpec.isContextShared field + ApiRenderer per-agg DTO mapper path）。

順手做：F1 validator error message reframe（同 PR ship；F2/F3/F5 留 Phase 1.o hygiene）。

## 目標

Layer 2 dogfood 用 user real IAM bundle 跑 Genesis 時，`EmployeeStatus` enum 被放到 `Sources/IAMContextShared/EmployeeStatus.swift`，但只被 `UserAccessProfile.state.status` 引用 — 應該放 `Sources/UserAccessProfileAggregate/EmployeeStatus.swift`。Genesis 已有 `DtoSpec.isContextShared` field 可標記但 Cosmogony 沒填 → legacy fallback 一律塞 Shared。

本 phase 補 **2-tier ownership decision**：bundle explicit marking 為 SSOT（Tier 1，未來 Cosmogony emit 補完），usage-based auto-detect 為 fallback（Tier 2，warn 教使用者改 bundle）。Adapter 不擔 typeOwnership 角色（per [[feedback-convention-over-configuration]]）。順手做 F1 validator error message reframe 移除誤導的「adapter mapping required」wording。

---

## 介面合約

### 新增：`TypeOwnership` enum

`Sources/GenesisCore/TypeOwnershipResolver.swift`（新檔）：

```swift
public enum TypeOwnership: Sendable, Equatable {
    case contextShared
    case ownedBy(aggregateName: String)
}
```

### 新增：`TypeOwnershipResolver.resolve(...)` 

```swift
public enum TypeOwnershipResolver {
    public static func resolve(
        bundle: FullBundle,
        adapter: Adapter
    ) -> (ownership: [String: TypeOwnership], warnings: [String])
}
```

**輸入**：完整 bundle + parsed adapter。

**輸出**：
- `ownership[<typeName>]` 對 `bundle.dtos` 內每個 DtoSpec 與 `adapter.customTypes` 內每個 CustomTypeSpec 都有對應 entry
- `warnings: [String]` 收集 Tier 2 auto-detect 觸發時的 advisory messages

**Throws**：純 function，不 throw。Invalid state（`aggregateRef` 指向不存在 aggregate、`isContextShared=false` 缺 `aggregateRef` 且 Tier 2 推不出 owner）一律 fallback 到 `.contextShared` + warning，不 fail。

**Routing 邏輯**（per type）：

1. **Tier 1 — explicit marking**（適用 `bundle.dtos` only；`adapter.customTypes` 永遠走 Tier 2）：
   - `dto.isContextShared == true` → `.contextShared`
   - `dto.isContextShared == false` + `dto.aggregateRef != nil`：
     - `aggregateRef` 存在於 `bundle.aggregates` → `.ownedBy(<aggregateRef>)`
     - `aggregateRef` **不**存在 → warning + fallback Tier 2
   - `dto.isContextShared == false` + `dto.aggregateRef == nil` → fallback Tier 2
2. **Tier 2 — usage scan**：對 `<typeName>` 收集 `refs: Set<aggregateName>`：
   - scan: `aggregates[].state[].rawType`、`useCases[].input[].rawType`、`useCases[].eventPayload[].rawType`、`presenters[].input.fields[].type`、`presenters[].output.elementType`、`readModels[].storedFields[].type`、`readModels[].key?.type`、`bundle.dtos[].fields[].rawType`（直接引用 only，**不**遞迴）
   - `refs.count == 0` → `.contextShared`（純 infra / orphan）+ warning `"<name>: no usage detected; defaulted to contextShared"`
   - `refs.count == 1` → `.ownedBy(refs.first!)` + warning `"<name>: ownership auto-detected as <agg>; consider marking explicit (isContextShared: false, aggregateRef: \"<agg>\") in bundle"`
   - `refs.count >= 2` → `.contextShared` + warning `"<name>: auto-shared from <N> aggregates; consider marking explicit (isContextShared: true) in bundle"`

**TypeName 萃取規則**：對每個 `rawType` 字串萃取 base type name 後與 known types 比對 — 必須完全 token boundary 對齊（不可命中 `EmployeeStatusKind` 之類 superstring）。

**注意**：`SwiftTypeResolver.matchContainer` 只處理 `Array[X]` 與 `Set<X>` 兩種形式，**不**覆蓋 `[X]` sugar、`Array<X>`、`Optional<X>`、`X?` 後綴。本 phase 在 `TypeOwnershipResolver` 內**獨立實作** `extractTypeName` helper（不重用 SwiftTypeResolver），明確處理以下 wrapper：
- `[X]` (collection sugar)
- `Array<X>` (collection)
- `Set<X>` (collection)
- `Optional<X>` (optional)
- `X?` (optional sugar)
- bare `X` (no wrapper)

可遞迴剝離後對 known types 比對命中。Unit test 須覆蓋每種 wrapper（見 Step 8 T7）。

**Determinism**：對同一 bundle，輸出 ownership map 與 warnings 順序穩定（按 type name sorted）。

### 修改：`DtoSpec` 加 `aggregateRef` + `isContextShared` 變 optional

`Sources/GenesisCore/FullBundle.swift` 的 `DtoSpec`（**H1 lock**：明確採 `Bool?` optional 路徑，移除 BundleParser fallback）：

```swift
public struct DtoSpec: Sendable, Equatable {
    // ... existing fields ...
    public let isContextShared: Bool?   // Phase 1.n: nil = no explicit marking, resolver Tier 2 介入
    public let aggregateRef: String?    // Phase 1.n: explicit per-agg ownership marker
    public init(
        // ... existing params ...
        isContextShared: Bool? = nil,   // nil → Tier 2 auto-detect
        aggregateRef: String? = nil
    ) { ... }
}
```

**設計鎖定**：`isContextShared` 從 non-optional `Bool` 改為 `Bool?` optional。`nil` 表示「Cosmogony 沒填 / user 沒手填」，resolver Tier 2 處理；非 `nil`（true/false）表示 explicit marking，resolver Tier 1 處理。`dtoKind` **不**作為 ownership signal（純 type kind hint）。

### 修改：`BundleParser.RawDto` + `decodeDtoSpec` 解析 `aggregateRef`

`Sources/GenesisCore/BundleParser.swift`：

```swift
private struct RawDto: Decodable {
    // ... existing fields ...
    let aggregateRef: String?  // Phase 1.n
}

// decodeDtoSpec returns DtoSpec(... aggregateRef: raw.aggregateRef)
```

### 修改：`SharedTargetRenderer.render(...)` 簽名加 `ownership`

```swift
public static func render(
    bundle: FullBundle,
    contextName: String,
    adapter: Adapter,
    ownership: [String: TypeOwnership]   // new
) throws -> [(path: String, content: String, role: String)]
```

由 `NewCommand` 在 `SharedTargetRenderer.render` 之前先呼叫 resolver，把 ownership map 傳入。

**Routing 行為改變**：

- `renderBundleDtosAndCustomTypes` 用 ownership map 決定 emit 目的地：
  - `.contextShared` → 既有 path `Sources/<Context>Shared/<TypeName>.swift`
  - `.ownedBy(X)` → 新 path `Sources/<X>Aggregate/<TypeName>.swift`
- `renderCustomType` / `renderEnum` / `renderValueObject` / `renderIdWrapper` 已接受 `dir: String` 參數，本 phase 不必動函數簽名，只需要 caller 帶入對應 dir。
- `renderInfraFiles` 不受影響（infra 永遠在 Shared）。

### 修改：`ApiRenderer.render(...)` 簽名加 `ownership`

```swift
public static func render(
    bundle: FullBundle,
    contextName: String,
    adapter: Adapter,
    existingPaths: Set<String> = [],
    ownership: [String: TypeOwnership]   // new
) throws -> [(path: String, content: String, role: String)]
```

**Routing 行為改變**：

- Per-DTO mapper emit 條件改為查 ownership：
  - `ownership[dto.name] == .ownedBy(X)` → mapper at `Sources/<X>Aggregate/Adapter/Dto/<dto.name>+Domain.swift`
  - `ownership[dto.name] == .contextShared` → skip（mapper 由 SharedTargetRenderer 既有路徑處理，但目前 Shared 端 mapper 不 emit；本 phase 維持 ApiRenderer 只處理 per-agg，audit M2 in case 後再評估）
- **移除** `guard let firstAggregate = bundle.aggregates.first else { return outputs }` — 改由 ownership 直接指 aggregate name
- **移除** `for dto in bundle.dtos where !dto.isContextShared { ... }` 的條件分支 — 改 iterate ownership map

### 修改：`AggregateRenderer` validator error message（F1 reframe，順手做）

`Sources/GenesisCore/AggregateRenderer.swift` 內 createdEvent payload 對 aggregate state 的 validator（既有的 fail-fast 語意保留，wording 改）：

```swift
let stateFieldNames = Set(spec.state.map { $0.name })
let orphanFields = payloadFields.filter { !stateFieldNames.contains($0.name) }
if !orphanFields.isEmpty {
    throw GenesisError.bundleInvalid(
        reason: "createdEvent payload field(s) \(orphanFields.map { $0.name }) "
            + "have no matching state in aggregate '\(spec.name)'.\n"
            + "Fix: rename the event payload field(s) to match aggregate state names, "
            + "OR add the missing field(s) to aggregate state in bundle. "
            + "Genesis enforces 1:1 naming between createdEvent payload and aggregate state "
            + "(aligned with OC reference); field rename via adapter is not supported."
    )
}
```

同步移除 source 註解內「deferred to Phase 1.f」誤導文字 — Phase 1.f 已 ship 完且未來不會做 adapter rename（per [[feedback-convention-over-configuration]]）。

### Warning 發送 channel

`AdapterApplier.swift` / `AdapterYamlParser.swift` 已使用的 pattern：

```swift
FileHandle.standardError.write(Data("⚠ <message>\n".utf8))
```

`TypeOwnershipResolver` 回傳 warnings array；`NewCommand` 在收到後逐條 write 到 stderr。

**所有權明示**：warning emission **由 NewCommand 負責** — TypeOwnershipResolver 不直接 print（保持為 pure function for testability）；NewCommand 負責 sink → stderr。

### Framework 備註

- 不涉及 ArgumentParser 改動。
- `SwiftTypeResolver.resolve` 已 public，跨檔可用（same module GenesisCore）。
- `DtoSpec` 是 `Sendable` + `Equatable` value type — 新欄位 `aggregateRef: String?` 自動 conform，default value `nil` 保持 backward compat。

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---|---|
| `Sources/GenesisCore/TypeOwnershipResolver.swift` | **新檔** — TypeOwnership enum + resolve(bundle:adapter:) 純 function + 與 SwiftTypeResolver 共享的 type extraction 邏輯 |
| `Sources/GenesisCore/FullBundle.swift` | `DtoSpec` 加 `aggregateRef: String?` 欄位 + init param（default nil 保持 backward compat） |
| `Sources/GenesisCore/BundleParser.swift` | `RawDto` 加 `aggregateRef: String?` decode 欄位；`decodeDtoSpec` 傳遞至 `DtoSpec.init` |
| `Sources/GenesisCore/SharedTargetRenderer.swift` | `render` 簽名加 `ownership` param；`renderBundleDtosAndCustomTypes` 按 ownership 選擇 dir（Shared vs `<X>Aggregate`） |
| `Sources/GenesisCore/ApiRenderer.swift` | `render` 簽名加 `ownership` param；移除「assume firstAggregate」hack；per-agg DTO mapper 用 `ownership[dto.name]` 決定 aggregate |
| `Sources/GenesisCore/AggregateRenderer.swift` | Validator error message reframe（F1 reframe）；移除 "deferred to Phase 1.f" 註解 |
| `Sources/Genesis/Commands/NewCommand.swift` | 在 SharedTargetRenderer 呼叫之前先呼叫 `TypeOwnershipResolver.resolve`；把 ownership 傳給 SharedTargetRenderer 與 ApiRenderer；把 warnings 寫到 stderr |
| `Tests/GenesisCoreTests/TypeOwnershipResolverTests.swift` | **新檔** — resolver unit tests（Tier 1 explicit、Tier 2 auto-detect 三種 refs.count 分支、type extraction、aggregateRef invalid fallback） |
| `Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json` | EmployeeStatus 位置從 IAMContextShared 移到 UserAccessProfileAggregate 後，相關 assertion 更新 |
| `Tests/GenesisIntegrationTests/Fixtures/iam-readmodel-bundle.json` | 同上（若有 customType usage 變更） |
| `Tests/GenesisIntegrationTests/Fixtures/iam-cross-agg-presenter-bundle.json` | 同上 |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | 對受影響的 IAM bundle integration test 更新 expected file path（EmployeeStatus 在 `UserAccessProfileAggregate/` 而非 `IAMContextShared/`） |
| `Tests/GenesisCoreTests/ApiRendererTests.swift` | 每個 `ApiRenderer.render(...)` call site 補 `ownership:` 參數（per Step 10）|
| `Tests/GenesisCoreTests/SharedTargetRendererTests.swift` | 每個 `SharedTargetRenderer.render(...)` call site 補 `ownership:` 參數（per Step 10）|

### Affected call sites（非改動，但受影響）

- `NewCommand.swift` step 2.3 / 2.3.3 — caller 改動已列上
- `OpenApiYamlRenderer.render` — **不受影響**，schemas 自 OpenAPI plugin，不依賴 type 檔案位置
- `BusinessDocRenderer` — **不受影響**

---

## 實作步驟

### Step 1：`TypeOwnershipResolver.swift` 新檔

1. 定義 `public enum TypeOwnership { case contextShared; case ownedBy(aggregateName: String) }`，conform `Sendable` + `Equatable`
2. 定義 `public enum TypeOwnershipResolver` 含 `public static func resolve(bundle:adapter:) -> (ownership: [String: TypeOwnership], warnings: [String])`
3. 實作主體：
   1. 收集所有 customType names（`bundle.dtos.map(\.name)` ∪ `adapter.customTypes.map(\.name)`）
   2. 對每個 type name 按字母排序遍歷（determinism）
   3. **Tier 1 check**（僅對 bundle.dtos 來源，adapter.customTypes 跳過 Tier 1）：
      - 找對應 DtoSpec
      - 若 `isContextShared == true` → record `.contextShared`，continue
      - 若 `isContextShared == false` + `aggregateRef != nil`：
        - 驗證 `aggregateRef` 在 `bundle.aggregates.map(\.name)` 內
        - 是 → record `.ownedBy(aggRef)`，continue
        - 否 → warning「<name>: aggregateRef '<aggRef>' not found in bundle.aggregates; falling back to usage scan」，繼續 Tier 2
      - 若 `isContextShared == false` + `aggregateRef == nil` → 繼續 Tier 2
      - 若 `isContextShared == true`（legacy default）— 走 Tier 2 fallback（**注意**：legacy default `true` 不視為「explicit shared」，因為 Cosmogony 沒填；只有顯式 `dtoKind != nil || isContextShared` field 出現在 raw bundle 才視 Tier 1。需要在 DtoSpec 新增 `hasExplicitOwnership: Bool` 或檢查時對照原 raw 來源）
   4. **Tier 2 — usage scan**：
      - 對每個 type name `T`，掃以下 raw type strings collection：
        - `bundle.aggregates[].state[].rawType` → ref aggregate = `aggregates[].name`
        - `bundle.aggregates[].state` 對應每個 aggregate
        - `bundle.useCases[].input[].rawType` + `eventPayload[].rawType` → ref aggregate = `useCases[].aggregate`
        - `bundle.presenters[].input.fields[].type` + `output.elementType` → ref aggregate = `presenters[].aggregateRef`
        - `bundle.readModels[].storedFields[].type` + `key?.type` → ref aggregate = `readModels[].aggregateRef`（context-level read model 用 `<context-level>` sentinel 不 count）
        - `bundle.dtos[].fields[].rawType` → ref aggregate = 透過遞迴查 DTO 之 ownership（**Phase 1.n 不遞迴**，間接引用視為「無 owner 線索」不計入 refs）
      - 對每個 raw type string，呼叫共享 helper `extractTypeName(rawType:knownTypes:)` 萃取出符合 token boundary 的 customType 名稱
      - 收集 `refs: Set<String>` of unique aggregate names
   5. Tier 2 routing decision per `refs.count`：
      - `== 0`：`.contextShared`，warning「<name>: no usage detected in bundle; defaulted to contextShared」
      - `== 1`：`.ownedBy(refs.first!)`，warning「<name>: ownership auto-detected as <agg>; consider marking explicit (isContextShared: false, aggregateRef: \"<agg>\") in bundle」
      - `>= 2`：`.contextShared`，warning「<name>: auto-shared from <N> aggregates (<comma-list>); consider marking explicit (isContextShared: true) in bundle」
4. 回傳 `(ownership, warnings)`

**關鍵 helper：`extractTypeName`**

從 raw type string（如 `"Set<EmployeeStatus>"`、`"[EmployeeStatus]"`、`"EmployeeStatus?"`、`"EmployeeStatus"`）萃取出 base type name。實作可遞迴剝離 collection wrappers + optional suffix。可借用 `SwiftTypeResolver.resolve` 既有邏輯但只回 inner name（不重生 Swift type 字串）。

```swift
private static func extractTypeName(rawType: String, knownTypes: Set<String>) -> String? {
    var t = rawType.trimmingCharacters(in: .whitespaces)
    while t.hasSuffix("?") { t.removeLast() }
    t = t.trimmingCharacters(in: .whitespaces)
    // Strip "Set<X>", "Array<X>", "Optional<X>" wrappers
    for prefix in ["Set<", "Array<", "Optional<"] {
        if t.hasPrefix(prefix) && t.hasSuffix(">") {
            t = String(t.dropFirst(prefix.count).dropLast())
            return extractTypeName(rawType: t, knownTypes: knownTypes)
        }
    }
    // Strip "[X]" sugar
    if t.hasPrefix("[") && t.hasSuffix("]") {
        t = String(t.dropFirst().dropLast())
        return extractTypeName(rawType: t, knownTypes: knownTypes)
    }
    // Final: match against known types
    return knownTypes.contains(t) ? t : nil
}
```

### Step 2：`FullBundle.swift` — DtoSpec 改 isContextShared 為 optional + 加 aggregateRef

1. `DtoSpec` 既有 `public let isContextShared: Bool` **改為** `public let isContextShared: Bool?`
2. `DtoSpec` 加 `public let aggregateRef: String?`
3. `init` 簽名同步調整：
   - `isContextShared: Bool = false` → `isContextShared: Bool? = nil`
   - 新增 `aggregateRef: String? = nil`

**Resolver Tier 1 判斷規則**：直接看 `dto.isContextShared`：
- `nil` → 沒 explicit marking，fallback Tier 2 auto-detect
- `true` → explicit shared，`.contextShared`
- `false` → explicit per-agg；查 `aggregateRef`：
  - 有效 → `.ownedBy(aggregateRef)`
  - nil 或指向不存在 aggregate → fallback Tier 2 + warning

不需要額外 `hasExplicitOwnership` computed property — `isContextShared != nil` 直接表達 explicit marking。

⚠️ **連帶影響**：此改動使 `SharedTargetRenderer.renderBundleDtosAndCustomTypes` 既有 `dto.isContextShared` 直接 boolean 使用斷裂。Phase 1.n 一併修：改走 ownership map 不直接讀 `dto.isContextShared`。`ApiRenderer` 改寫同理（從 dto.isContextShared 改走 ownership）。所有其他 callers 透過 grep `isContextShared` 確認，更新到走 ownership map。

### Step 3：`BundleParser.swift` — RawDto + decode 改動

1. `RawDto` 加 `let aggregateRef: String?`
2. `decodeDtoSpec` **完全移除** legacy fallback 邏輯（`hasPhase1hSchema` 計算 + `resolvedIsContextShared` ?? fallback 整塊）；改為直接傳遞 `raw.isContextShared`（optional，nil pass-through）+ `raw.aggregateRef` 進 DtoSpec init
3. **不**做 BundleParser-level aggregateRef validation —— 統一交給 `TypeOwnershipResolver` Tier 1 處理：當 `aggregateRef` 指向不存在的 aggregate 時，resolver fallback 到 Tier 2 + warning。理由：與 resolver 整體「ambiguity → warning + 繼續」哲學一致；避免 decode 階段與 resolver 各跑一次 aggregate ref validation。

### Step 4：`SharedTargetRenderer.swift` — 加 ownership 參數 + 改 routing

1. 改 `render(bundle:contextName:adapter:)` → `render(bundle:contextName:adapter:ownership:)`
2. 改 `renderBundleDtosAndCustomTypes`：
   - 簽名加 `ownership: [String: TypeOwnership]`
   - 對每個 emit：先查 `ownership[name]`
     - `.contextShared` → 既有 dir `<contextName>Shared`，path `Sources/<contextName>Shared/<name>.swift`
     - `.ownedBy(X)` → 新 dir `<X>Aggregate`，path `Sources/<X>Aggregate/<name>.swift`
   - call `renderCustomType(... dir: <chosen dir>)` 或 `DtoRenderer.render(... hostTarget: <chosen target>)`
3. `renderInfraFiles` 不變
4. Adapter `customTypes` 也照 ownership map 走（per 共識：Tier 2 fallback 對 adapter.customTypes 同樣套用，多半結果是 `.contextShared` 因為 adapter 定義的多是 cross-cutting）

### Step 5：`ApiRenderer.swift` — 加 ownership 參數 + 改 routing

1. 改 `render` 簽名加 `ownership`
2. 移除「`firstAggregate` guard」hack
3. 改 DTO mapper 迴圈：

```swift
for dto in bundle.dtos {
    guard case .ownedBy(let aggName) = ownership[dto.name] else { continue }
    let dtoKind = resolveDtoKind(dto)
    if dtoKind == "union" { continue }
    let mapperPath = "Sources/\(aggName)Aggregate/Adapter/Dto/\(dto.name)+Domain.swift"
    if existingPaths.contains(mapperPath) { continue }
    // ...
}
```

### Step 6：`AggregateRenderer.swift` — F1 reframe

1. 找到 `let orphanFields = payloadFields.filter { !stateFieldNames.contains($0.name) }` 區塊
2. 改 error message wording（見 §介面合約 完整 diff）
3. 移除上方 comment 內「deferred to Phase 1.f」段落

### Step 7：`NewCommand.swift` — 串 resolver

1. 在 step 2.3 之前加：

```swift
let (ownership, ownershipWarnings) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
for w in ownershipWarnings {
    FileHandle.standardError.write(Data("⚠ \(w)\n".utf8))
}
```

2. 把 `ownership` 傳給 `SharedTargetRenderer.render(...)` 與 `ApiRenderer.render(...)`

### Step 8：Unit tests — `TypeOwnershipResolverTests.swift` 新檔

Test cases 至少覆蓋：

- T1: bundle.dtos with `isContextShared=true` explicit → `.contextShared`（no warning）
- T2: bundle.dtos with `isContextShared=false` + valid `aggregateRef` → `.ownedBy(...)`（no warning）
- T3: bundle.dtos with `isContextShared=false` + invalid `aggregateRef` → fallback Tier 2 + warning
- T4: Tier 2 usage scan, refs.count == 0 → `.contextShared` + warning
- T5: Tier 2 usage scan, refs.count == 1 → `.ownedBy(...)` + warning
- T6: Tier 2 usage scan, refs.count >= 2 → `.contextShared` + warning
- T7: `extractTypeName` 處理 `Set<X>` / `[X]` / `X?` / `Optional<X>`
- T8: `extractTypeName` 不誤命中 substring（`EmployeeStatusKind` 不算 `EmployeeStatus` ref）
- T9: adapter.customTypes 走 Tier 2 routing（即使 adapter 沒 `isContextShared`）
- T10: determinism — 同 bundle 跑兩次，ownership map + warnings 順序一致

### Step 9：Integration test fixtures + expected output 更新

對 `iam-bundle.json` / `iam-readmodel-bundle.json` 等 fixture **不改 DTO ownership 相關 JSON**（保持 legacy 缺省 — `dtos[]` 既沒 `isContextShared` 也沒 `aggregateRef`，由 Tier 2 auto-detect 處理）。

**注意**：fixture 內既有 `readModels[].aggregateRef` / `presenters[].aggregateRef`（包含 `"<context-level>"` 之類值）**保留不動** — 這些不是 DTO ownership 標記，是 ReadModel / Presenter 自己的 aggregate 歸屬欄位，Phase 1.n 不觸碰。

`NewCommandTests.swift` 內既有 assertion `assert EmployeeStatus.swift in IAMContextShared/` 改為 `in UserAccessProfileAggregate/`。同步 assert warning 字串應被 emit 至 stderr。

### Step 10：更新既有 renderer test caller

`ApiRendererTests.swift` 與 `SharedTargetRendererTests.swift` 內每個 `ApiRenderer.render(...)` / `SharedTargetRenderer.render(...)` call site 需補 `ownership:` 參數：

- **選 A — 顯式傳 resolver 結果**（推薦）：在每個 test setup 內呼叫 `let (ownership, _) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)` 後傳入
- **選 B — 傳 empty map**：`ownership: [:]` 表示「無 explicit marking、無 auto-detect refs」→ 所有 type fallback `.contextShared`（保持既有 test 行為）

建議走 **A**，因為它驗證 resolver 整合行為，更接近實際使用情境。test 期望值若因 `EmployeeStatus` 移到 aggregate folder 而需調整，一併更新。

---

## 失敗路徑

主要錯誤傳播鏈：

### Bundle parse fail-fast

`raw.aggregateRef` 指向不存在的 aggregate name：
- `BundleParser.decodeDtoSpec` raise `GenesisError.bundleInvalid`
- → `NewCommand.run` catch → `FileHandle.standardError.write(...)` printer → exit code 1
- 屬不可恢復 — fix bundle 才能 retry

### Resolver Tier 1 invalid → Tier 2 fallback（可恢復）

`isContextShared=false` 缺 `aggregateRef`，或 `aggregateRef` 指向不存在 aggregate（已被 BundleParser fail-fast 攔）：
- TypeOwnershipResolver fallback Tier 2 + warning
- 不 throw；warning sink → stderr

### Tier 2 type extraction 無命中

某 customType `T` 在所有 scanned positions 都查不到引用：
- `refs.count == 0`
- routing → `.contextShared` + warning「no usage detected」
- 不 throw；可能是真的 orphan type（未被 bundle 引用），warning 提示 user 移除或補引用

### F1 validator gate（保留語意，wording 改）

`createUseCase.eventPayload` 含名稱不在 `aggregate.state` 的 field：
- `AggregateRenderer` raise `GenesisError.bundleInvalid` with reframed error message
- → 不可恢復，user 必須改 bundle naming 對齊

---

## 不改動的部分

- `SwiftTypeResolver` — 既有 type resolve 行為不變（本 phase 共享 type extraction 邏輯但新增 helper 在 TypeOwnershipResolver 內，不改 SwiftTypeResolver）
- `OpenApiYamlRenderer` — OpenAPI schema 從 plugin 來，不依賴本 phase 改動
- `BusinessDocRenderer` — 文檔產出不受 ownership routing 影響
- `ContextProjectionModelRenderer` — context-level projection 不受影響
- `ReadModelRenderer` — read model emit 不受影響（ReadModel struct 本來就在 aggregate folder）
- `Adapter` schema — **不**新增 `typeOwnership` 區段（per discussion D2）
- `Adapter.customTypes` 的 `CustomTypeSpec` struct — 不加 `aggregateRef`（adapter 不擔 ownership 責任）

### Non-goals（行為層）

- 本 task **不**支援 adapter typeOwnership override（per [[feedback-convention-over-configuration]]，bundle 為 SSOT）
- 本 task **不**支援「跨 aggregate dup 同名 type」（OC QuotingStatus pattern 視為 OC debt，不對齊）
- 本 task **不**遞迴 DTO 間接引用做 ownership 推算（YAGNI）
- 本 task **不**做 OC scaffold regression test（OC bundle 未轉成 Genesis-compat format，無法跑）
- 本 task **不**改 Cosmogony Event Storming Tool 的 emit 行為（不在 Genesis repo scope）
- 本 task **不**重新設計 `dtoKind` 推斷邏輯（既有 description-based fallback 保留）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
# Build pass
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -5
# 期望: "Build complete!"

# 全 test suite pass
swift test 2>&1 | tail -10
# 期望: "Test Suite ... passed" with 0 failures

# TypeOwnershipResolver 檔案存在
test -f Sources/GenesisCore/TypeOwnershipResolver.swift
test -f Tests/GenesisCoreTests/TypeOwnershipResolverTests.swift

# TypeOwnership enum 定義存在
grep -q "public enum TypeOwnership" Sources/GenesisCore/TypeOwnershipResolver.swift
grep -q "case contextShared" Sources/GenesisCore/TypeOwnershipResolver.swift
grep -q "case ownedBy" Sources/GenesisCore/TypeOwnershipResolver.swift

# resolve 函數簽名存在
grep -q "public static func resolve" Sources/GenesisCore/TypeOwnershipResolver.swift

# SharedTargetRenderer / ApiRenderer 簽名變更
grep -q "ownership: \[String: TypeOwnership\]" Sources/GenesisCore/SharedTargetRenderer.swift
grep -q "ownership: \[String: TypeOwnership\]" Sources/GenesisCore/ApiRenderer.swift

# DtoSpec.aggregateRef 欄位存在
grep -q "public let aggregateRef: String?" Sources/GenesisCore/FullBundle.swift

# BundleParser RawDto.aggregateRef 解析存在
grep -q "let aggregateRef: String?" Sources/GenesisCore/BundleParser.swift

# F1 reframe — 移除誤導 wording
! grep -q "deferred to Phase 1.f" Sources/GenesisCore/AggregateRenderer.swift
! grep -q "not supported in Phase 1.e" Sources/GenesisCore/AggregateRenderer.swift

# F1 reframe — 新 wording 存在
grep -q "Genesis enforces 1:1 naming" Sources/GenesisCore/AggregateRenderer.swift

# NewCommand 串 resolver
grep -q "TypeOwnershipResolver.resolve" Sources/Genesis/Commands/NewCommand.swift
grep -q "ownershipWarnings" Sources/Genesis/Commands/NewCommand.swift

# E2E：對 iam-bundle.json 跑 genesis new 後 EmployeeStatus.swift 應在 aggregate folder
TMPDIR=$(mktemp -d)
swift run genesis new IAMContext \
    --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json \
    --output "$TMPDIR" --no-git --skip-build 2>&1 | tail -3
test -f "$TMPDIR/Sources/UserAccessProfileAggregate/EmployeeStatus.swift"
! test -f "$TMPDIR/Sources/IAMContextShared/EmployeeStatus.swift"

# E2E：跑時應 emit warning 到 stderr
swift run genesis new IAMContext \
    --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json \
    --output "$TMPDIR-warn" --no-git --skip-build 2>&1 1>/dev/null | grep -q "EmployeeStatus.*ownership auto-detected"
rm -rf "$TMPDIR" "$TMPDIR-warn"
```

### Human 補做（需要人類介入）

- [ ] 拿 user real bundle `~/Downloads/IAM Context Bundle.json` 重跑 `genesis new`，目視確認：
  - `Sources/UserAccessProfileAggregate/EmployeeStatus.swift` 存在且內容正確（含 `package enum EmployeeStatus: String, Codable { case activate; case resigned }`）
  - `Sources/IAMContextShared/EmployeeStatus.swift` **不存在**
  - stderr 有 warning：「EmployeeStatus: ownership auto-detected as UserAccessProfile; consider marking explicit (isContextShared: false, aggregateRef: \"UserAccessProfile\") in bundle」
  - 改 bundle 加入 explicit `isContextShared: false` + `aggregateRef: "UserAccessProfile"` 後重跑，warning 不再出現，emit 結果一致
- [ ] 確認 F1 validator error message 修改後，故意把 bundle 改成不對齊命名（例如 `permissions → initialPermissions`）跑 `genesis new`，error message 顯示新 wording：「Genesis enforces 1:1 naming ...」+ fix 建議

---

## 已知限制

- **間接引用不遞迴**：若 DtoSpec A 的 field 引用 DtoSpec B，且 B 只被 A 引用、A 只被某 aggregate 引用，B 不會被推 owned by 該 aggregate（refs.count == 0 fallback Shared）。Workaround：bundle author 顯式設 B 的 `isContextShared: false` + `aggregateRef`。
- **OC dup pattern 不支援**：兩個 aggregate 同時用同名 type 時，Genesis 一律 lift Shared，不 dup（OC 既有 `QuotingStatus.swift` × 2 視為 OC debt，不對齊）。Workaround：bundle 改名（不同 aggregate 用不同 type name 表達語意）。
- **Adapter customTypes 永遠走 Tier 2**：adapter 不擔 ownership 角色，使用者無法在 adapter YAML override ownership。Workaround：定義回 `bundle.dtos` 並設 `isContextShared` + `aggregateRef`。
- **Tier 1 explicit `aggregateRef` 指向不存在 aggregate** → BundleParser fail-fast。Workaround：fix bundle。
- **Warning noise**：大 bundle 多 type 時，stderr 可能 print 多條 warning。Workaround：（追蹤項）未來可加 `--quiet` 旗標壓 warning，本 phase 不做。

### 依賴關係

- 前置：無（Phase 1.h `DtoSpec.isContextShared` 已 ship；Phase 1.f 已 ship）
- 後續：Phase 1.o hygiene phase（F2 TODO marker、F3 Service exec stub、F5 event.yaml map shape）— 本 task 完成後解封
