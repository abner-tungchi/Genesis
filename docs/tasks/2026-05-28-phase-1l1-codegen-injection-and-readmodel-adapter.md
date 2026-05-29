# Phase 1.l.1 — Codegen aggId/operatorId 注入 fix + BundleParser ReadModel adapter

## 來源

討論：`docs/discussions/2026-05-28-cosmogony-bundle-schema-mismatch.md`（三輪 Cosmogony / Genesis sign-off）

依賴 Phase（全 done）：phase-1l（Usecase Input OC alignment）、phase-1n（type ownership routing）、phase-1o-hygiene、phase-1o.1（identity-mapper fix）。

對應 Cosmogony 端：v19 schema（已 ship，含 scope/usage/aggregateRef/readModelRef/perReadModel），v20+ 後續分階段對齊。

合 dogfood findings：F8（2026-05-28 — Cosmogony 新 bundle 撞 `readModels[0] missing required key 'name'`，深入後揭露 4 個 ReadModel schema gap + Phase 1.l create-UC aggId 注入錯誤）。

## 目標

讓 Genesis 對以下兩種 bundle 都能成功 `genesis new` + `swift build`：

1. **舊 hand-crafted IAM bundle**（`~/Downloads/IAM Context Bundle.json`）— input 含 `operatorId`、含 aggId、ReadModel 用既有 `name`/`events`/`key`/`storedFields` schema
2. **新 Cosmogony v19 bundle**（`~/Downloads/Cosmogony IAMContext bundle.json`）— input **不**含 `operatorId`、**不**含 aggregateId、ReadModel 用 `queryName`/`parameters`/`returnType`/`links` 新 schema

實現「bundle = pure domain spec，framework concerns 由 Genesis codegen 注入」的分工原則（Cosmogony 三輪 sign-off）。

**順手修一個 latent bug**：當前 Phase 1.l `UseCaseRenderer.renderInput` 對 create UC 也注入 aggId（位置：`UseCaseRenderer.swift:65-68` `canonicalFields = [aggIdField] + businessFields + [operatorIdField]`），但 OC create UC 慣例的 domain Input 不含 aggId（aggregate id 由 Service `UUID()` 生成）。Phase 1.l.1 順道修正。

---

## 介面合約（Interface Contract）

### 修改 1：`BundleParser.swift` — ReadModel `queryName` alias

`RawReadModel.CodingKeys` 加入 `queryName` 作為 `name` 的 alias，decode 時優先 `name`、fallback `queryName`。

```swift
private struct RawReadModel: Decodable {
    let readModelSpecId: String?
    let aggregateSpecId: String?
    let aggregateRef: String?
    let name: String?
    let queryName: String?  // ← Phase 1.l.1: Cosmogony alias
    // ... existing fields ...

    private enum CodingKeys: String, CodingKey {
        case readModelSpecId, aggregateSpecId, aggregateRef, name, queryName,
             events, eventNames, key, parameters, returnType, links,
             storedFields, comment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ... existing decodes ...
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.queryName = try c.decodeIfPresent(String.self, forKey: .queryName)
        // ... existing decodes ...
    }
}
```

`decodeReadModelSpec` 內：
```swift
let resolvedName: String
if let n = raw.name, !n.isEmpty {
    resolvedName = n
} else if let qn = raw.queryName, !qn.isEmpty {
    resolvedName = qn
} else {
    throw GenesisError.bundleInvalid(
        reason: "readModels[\(idx)] missing required key 'name' (or 'queryName' Cosmogony alias)"
    )
}
```

### 修改 2：`BundleParser.swift` — ReadModel `links` → `events` derive

當 raw bundle 既無 `events` 也無 `eventNames`、但有 `links` 含 outbound `DomainEvent` 時，從 `links` 自動 derive `events: [{name, sourceAggregate}]`。

`sourceAggregate` 從 `aggregates[].events[].name` cross-ref 反查（同名 event 屬於哪個 aggregate）。

新 RawReadModelLink struct：
```swift
private struct RawReadModelLink: Decodable {
    let direction: String?    // "outbound" | "inbound"
    let targetType: String?   // "DomainEvent" | "Aggregate" | ...
    let targetName: String?
    let targetSpecId: String?
}
```

Derive 邏輯放在 `parseFull` 內 post-decode pass（要 cross-ref `aggregates`，decodeReadModelSpec 拿不到）：
```swift
// After all aggregates + readModels decoded:
let aggregates = ...  // decoded
var readModels = readModels  // mutable
for i in readModels.indices where readModels[i].eventNames.isEmpty {
    let rawLinks = envelope.readModels?[i].links ?? []
    let outboundEvents = rawLinks.filter {
        $0.direction == "outbound" && $0.targetType == "DomainEvent"
    }
    if !outboundEvents.isEmpty {
        let derivedRefs: [ReadModelEventRef] = try outboundEvents.compactMap { link in
            guard let eventName = link.targetName else { return nil }
            // Cross-ref: find which aggregate declares this event
            guard let agg = aggregates.first(where: {
                $0.eventNames.contains(eventName)
            }) else {
                throw GenesisError.bundleInvalid(
                    reason: "readModels[\(i)] ('\(readModels[i].name)') links to event "
                          + "'\(eventName)' but no aggregate declares it in events[]"
                )
            }
            return ReadModelEventRef(name: eventName, sourceAggregate: agg.name)
        }
        readModels[i] = ReadModelSpec(  // re-construct with eventRefs filled
            ...
            eventNames: derivedRefs.map(\.name),
            ...
            eventRefs: derivedRefs,
            ...
        )
    }
}
```

### 修改 3：`BundleParser.swift` — ReadModel `parameters` → `key` derive

當 raw bundle 既無 `key` 也無 parameters fallback、但有 `parameters[]`（Cosmogony schema）時，從 `parameters[0]` derive `key`：

```swift
private struct RawReadModelParameter: Decodable {
    let name: String?
    let type: String?
}
// Add to RawReadModel:
let parameters: [RawReadModelParameter]?
```

decodeReadModelSpec 內：
```swift
let key: ReadModelKey?
if let rawKey = raw.key, /* existing populated check */ {
    key = ReadModelKey(...)  // existing path
} else if let params = raw.parameters, let first = params.first,
          let fName = first.name, !fName.isEmpty,
          let fType = first.type, !fType.isEmpty {
    // Phase 1.l.1: Cosmogony derive from parameters[0]
    FileHandle.standardError.write(Data(
        "⚠ ReadModel '\(resolvedName)': derived key from parameters[0] '\(fName)'; "
      + "verify fromEventPayload assumption (parameter name == event payload field name)\n".utf8
    ))
    key = ReadModelKey(
        field: fName,
        type: fType,
        fromEventPayload: fName  // assumption: API param name == event payload field name
    )
} else {
    key = nil  // existing behavior — legacy fixtures unaffected
}
```

### 修改 4：`BundleParser.swift` — ReadModel `returnType.fields` → `storedFields` flatten

當 raw bundle 既無 `storedFields` 也走 fallback 無、但有 `returnType.fields[]`（Cosmogony schema）時，flatten 進 `storedFields`：

```swift
private struct RawReadModelReturnType: Decodable {
    let shape: String?  // "object" | ...
    let fields: [RawReadModelReturnField]?
}
private struct RawReadModelReturnField: Decodable {
    let name: String?
    let type: String?
    let dtoSpecRef: String?  // Cosmogony stable id, Genesis ignores
}
// Add to RawReadModel:
let returnType: RawReadModelReturnType?
```

decodeReadModelSpec 內：
```swift
let storedFields: [ReadModelStoredField]
if let raw_sf = raw.storedFields, !raw_sf.isEmpty {
    storedFields = raw_sf.compactMap { ... }  // existing path
} else if let rt = raw.returnType, let rtFields = rt.fields, !rtFields.isEmpty {
    // Phase 1.l.1: Cosmogony derive — flatten returnType.fields → storedFields
    storedFields = rtFields.compactMap { f -> ReadModelStoredField? in
        guard let n = f.name, !n.isEmpty else { return nil }
        guard let t = f.type, !t.isEmpty else { return nil }
        return ReadModelStoredField(name: n, type: t, defaultValue: nil)
    }
} else {
    storedFields = []
}
```

### 修改 5：`UseCaseRenderer.swift` — create UC 不注入 aggId

替換 `renderInput` 內 `canonicalFields` 構造邏輯（`UseCaseRenderer.swift:63-68`），加入 create UC 判定：

```swift
private static func renderInput(
    uc: String,
    fields: [FieldSpec],
    aggIdName: String,
    isCreateUseCase: Bool,  // ← Phase 1.l.1: 新參數
    adapter: Adapter,
    knownCustomTypes: Set<String>,
    sharedImport: String,
    dir: String
) throws -> (String, String, String) {
    let businessFields = fields.filter { $0.name != aggIdName && $0.name != "operatorId" }
    let operatorIdField = FieldSpec(name: "operatorId", rawType: "String")

    // Phase 1.l.1: create UC 不注入 aggId（aggregate id 由 Service UUID() 生成）
    let canonicalFields: [FieldSpec]
    if isCreateUseCase {
        canonicalFields = businessFields + [operatorIdField]
    } else {
        let aggIdField = FieldSpec(name: aggIdName, rawType: "String")
        canonicalFields = [aggIdField] + businessFields + [operatorIdField]
    }
    // ... rest unchanged ...
}
```

判定規則（在 `render` 內計算後傳入）：

```swift
// UseCaseRenderer.render(...)
let ucCamel = CaseTransformer.lowerCamel(useCase.useCase)
// Phase 1.l.1: create UC heuristic — name prefix "create" or "establish"
// (matches /usecase skill convention; 100% of OC/IAM dogfood UC follow this)
let isCreateUseCase = ucCamel.hasPrefix("create") || ucCamel.hasPrefix("establish")
```

### Framework 備註

- BundleParser 改動全部為「向後相容 derive」：raw bundle 若已有對應欄位（`name`/`events`/`key`/`storedFields`），保持既有行為；只在缺失時 fall back 到 Cosmogony schema fields。舊 IAM bundle 不受影響。
- `_suggested_*` / `kind` / `dtoSpecRef` / `methods[]` 等 Cosmogony 中介層欄位繼續 silent ignore（不在 RawReadModel CodingKeys 內 → JSONDecoder 自動忽略）。
- `links` 中 inbound 或 non-DomainEvent target 繼續 silent ignore（只 derive outbound DomainEvent）。
- create UC 判定走 prefix heuristic（`create` / `establish`），跟 `/usecase` skill 一致。不引入新概念。

---

## 改動檔案

### Source（2 個，~70 行）

| File | Change |
|---|---|
| `Sources/GenesisCore/BundleParser.swift` | 4 個 ReadModel 相容修改（修改 1-4）：`queryName` alias / `links→events` derive / `parameters→key` derive / `returnType→storedFields` flatten。其中 events derive 為 post-decode pass（需要 aggregates cross-ref） |
| `Sources/GenesisCore/UseCaseRenderer.swift` | 修改 5：renderInput 增 `isCreateUseCase` 參數、create UC 時跳過 aggId 注入。`render` 內計算 isCreateUseCase 並傳入 |

### Test（3 個，~120 行）

| File | Change |
|---|---|
| `Tests/GenesisCoreTests/BundleParserTests.swift` | 加 4 個 unit test：`testReadModelQueryNameAlias` / `testReadModelLinksToEventsDerive` / `testReadModelParametersToKeyDerive` / `testReadModelReturnTypeFlatten` |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | 加 2 個 E2E test：`testCosmogonyBundleEndToEnd` / `testCreateUseCaseInputOmitsAggId` |
| `Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json` | **新檔**：從 `~/Downloads/Cosmogony IAMContext bundle.json` copy，修 3 處 user typo（`getPromissions`→`getPermissions`、`permissionDTP`→`permissionDto`、`permissionDto`→`PermissionDto`） |

### Affected call sites（非改動，但受影響）

- `BundleParser.parseFull` 內加 post-decode pass for events derive（不算單獨 file change，屬於修改 2 的一部分）
- 既有 `BundleParserFullTests` 既有 case 確認**仍 pass**（向後相容）

---

## 實作步驟

### Step 1：新 fixture — `iam-cosmogony-bundle.json`

1. Copy `~/Downloads/Cosmogony IAMContext bundle.json` 到 `Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json`
2. 修 3 處 typo：
   - `readModels[0].queryName`：`getPromissions` → `getPermissions`
   - `readModels[0].returnType.fields[1].type`：`permissionDTP` → `permissionDto`
   - `dtos[1].name`：`permissionDto` → `PermissionDto`
   - 對應 `readModels[0].returnType.fields[1].type` 也改 `permissionDto` → `PermissionDto`（一致）
3. 不修其他內容（含 `queryName`/`parameters`/`returnType`/`links` 這些 Genesis 等下要 adapter parse 的 fields）

### Step 2：`BundleParser.swift` — 加 RawReadModel 新欄位 + decode 邏輯

1. 加 `RawReadModelLink` / `RawReadModelParameter` / `RawReadModelReturnType` / `RawReadModelReturnField` 4 個 struct
2. `RawReadModel.CodingKeys` 加 `queryName, parameters, returnType, links`
3. `RawReadModel.init(from:)` 加對應 `decodeIfPresent`
4. `decodeReadModelSpec` 內：
   - name resolve：先 `name`、後 `queryName`
   - key fallback：先既有 `raw.key`、後 `raw.parameters[0]` derive（含 stderr warning）
   - storedFields fallback：先既有 `raw.storedFields`、後 `raw.returnType.fields` flatten

### Step 3：`BundleParser.swift` — `parseFull` post-decode pass for events derive

1. 在 readModels 全部 decode 後加 pass：
   ```swift
   var mutableReadModels = readModels
   for i in mutableReadModels.indices where mutableReadModels[i].eventNames.isEmpty {
       let rawLinks = envelope.readModels?[i].links ?? []
       let outboundEvents = rawLinks.filter {
           $0.direction == "outbound" && $0.targetType == "DomainEvent"
       }
       // derive eventRefs from outboundEvents + aggregates cross-ref
       // re-construct ReadModelSpec with filled eventNames + eventRefs
   }
   ```
2. cross-ref 找不到 owning aggregate → throw `bundleInvalid`
3. 替換 `readModels` 為 mutableReadModels 後續傳給 `validatePresentersAgainstReadModels` 等

### Step 4：`UseCaseRenderer.swift` — create UC 判定 + 跳過 aggId 注入

1. `renderInput` signature 加 `isCreateUseCase: Bool` 參數
2. body 內依 `isCreateUseCase` 構造 canonicalFields（不注入 aggId 若 create）
3. `render` 內計算 `isCreateUseCase = ucCamel.hasPrefix("create") || ucCamel.hasPrefix("establish")`
4. 傳給 `renderInput`

### Step 5：BundleParserTests — 4 個 unit test

```swift
func testReadModelQueryNameAlias() throws {
    // bundle 用 queryName instead of name → parse 成功，resolved name == queryName
}

func testReadModelLinksToEventsDerive() throws {
    // bundle 含 links outbound DomainEvent + 對應 aggregates events → eventNames derive 對齊
}

func testReadModelParametersToKeyDerive() throws {
    // bundle 含 parameters but 無 key → key derive 自 parameters[0]，
    // stderr 含 'derived key' warning
}

func testReadModelReturnTypeFlatten() throws {
    // bundle 含 returnType.fields but 無 storedFields → storedFields flatten 自 returnType.fields
}
```

### Step 6：NewCommandTests — 2 個 E2E test

```swift
func testCosmogonyBundleEndToEnd() throws {
    // 用 iam-cosmogony-bundle.json 跑 genesis new，assert:
    // - GrantPrivilegeInput.swift 內含 'useraccessprofileId'（首）+ 'operatorId'（末）
    // - CreateUserAccessProfileInput.swift 含 'operatorId' 但 NOT 'useraccessprofileId'
    // - swift build 對 output 專案 PASS
}

func testCreateUseCaseInputOmitsAggId() throws {
    // 既有 iam-bundle.json fixture（含 operatorId+aggId）：
    // - CreateUserAccessProfileInput.swift 應 NOT 含 'useraccessprofileId'
    //   (即使 bundle 給了 — Phase 1.l.1 認為 create UC 不該有 aggId)
    // - 其他 UC Input 保持 OC 慣例（有 aggId）
}
```

### Step 7：本地 verify

```bash
swift build  # 0 warning, 0 error
swift test   # 全 pass，含既有 224+ tests

# 真實 bundle dogfood
rm -rf /tmp/genesis-cosmogony-test && mkdir /tmp/genesis-cosmogony-test
swift run genesis new IAMContext \
    --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json \
    --output /tmp/genesis-cosmogony-test --no-git --skip-build
cd /tmp/genesis-cosmogony-test && swift build  # PASS

# 既有 bundle 向後相容
rm -rf /tmp/genesis-iam-test && mkdir /tmp/genesis-iam-test
swift run genesis new IAMContext \
    --from-bundle ~/Downloads/"IAM Context Bundle.json" \
    --output /tmp/genesis-iam-test --no-git --skip-build
cd /tmp/genesis-iam-test && swift build  # 仍 PASS（向後相容）
```

---

## 失敗路徑

### `BundleParser` 報錯（all 為 `GenesisError.bundleInvalid`）

| 條件 | Error message |
|---|---|
| ReadModel 既無 `name` 也無 `queryName` | `readModels[\(idx)] missing required key 'name' (or 'queryName' Cosmogony alias)` |
| ReadModel 從 `links` derive events，event name cross-ref 找不到 owning aggregate | `readModels[\(idx)] ('\(name)') links to event '\(eventName)' but no aggregate declares it in events[]` |
| ReadModel 既無 `key` 也無 `parameters` 也走不到 storedFields 補完 → 既有行為（key = nil，下游 Presenter validator 視情況報錯） | 既有 |

### `UseCaseRenderer` 行為

- create UC 不注入 aggId（不算 error，是預期行為）
- 若 bundle.aggregates 不含對應 aggregateSpecId → 既有 Phase 1.l `bundleInvalid` 報錯保留

### `parameters → key` derive stderr warning（非 error）

每 ReadModel 走此 path 印 1 行 warning 到 stderr：
```
⚠ ReadModel '<name>': derived key from parameters[0] '<fieldName>'; verify fromEventPayload assumption (parameter name == event payload field name)
```

User 看到 warning 應檢查 ReadModel 是否該升級為 explicit key 結構（Cosmogony v22+）。

---

## 不改動的部分

### Renderer 系列

- `Sources/GenesisCore/AggregateRenderer.swift`
- `Sources/GenesisCore/ApiRenderer.swift` — 包括 `renderApplicationService` 不改 — **ApplicationServiceInput** 仍含 aggId 給所有 UC（含 create UC）。Phase 1.l.1 acceptance 只覆蓋 `<UC>Input.swift`（domain Input），AS Input 保持既有 Phase 1.l 行為
- `Sources/GenesisCore/SharedTargetRenderer.swift`
- `Sources/GenesisCore/DtoRenderer.swift` / `DtoRouter` 等 Phase 1.p 相關 — 不存在
- `Sources/GenesisCore/ReadModelRenderer.swift` — derive 後的 ReadModelSpec shape 不變，下游不感知
- `Sources/GenesisCore/TypeOwnershipResolver.swift`
- `Sources/GenesisCore/PresenterRenderer.swift` / `ContextLevelRenderer.swift` / `ProjectionModelRenderer.swift` / `ContextProjectionModelRenderer.swift`
- `Sources/GenesisCore/ApiHandlerRenderer.swift`

### Template 系列

全不動。Genesis Renderer 注入 fields 後 template 的 `{InputFieldDecls}` / `{INPUT_FIELDS}` 佔位符自然認新 shape。

### Orchestration / CLI

- `Sources/Genesis/Commands/NewCommand.swift`
- `Sources/GenesisCore/Adapter.swift` / `AdapterApplier.swift` / `AdapterYamlParser.swift`

### Bundle schema

- `Sources/GenesisCore/FullBundle.swift` — `UseCaseSpec` / `ReadModelSpec` struct 既有 shape 保留。RawReadModel 是 BundleParser 內部 decode struct，不影響公開 spec。

### Cosmogony bundle 本身

- Genesis 不要求 Cosmogony 改 wire format
- Genesis 不 fix Cosmogony schema typo（user typo 在 fixture 內手動修一次）

### Phase 1.p 相關

- DTO scope/usage 路由邏輯 — Phase 1.p 範疇，本 task 不碰
- `perReadModel` scope 處理 — Phase 1.p D3 補 lock 後處理，本 task 「不 reject」即可（BundleParser 只關心 ReadModel parse，DTO scope 不解析）
- `manifestVersion: 2` 嚴格 gate — Cosmogony v22 ship 後再做，本 task 不依賴

### Non-goals（行為層）

- **不**改 ApplicationServiceInput 結構（AS Input 仍含 aggId 給 create UC，與 domain Input 一致性留給 Phase 1.l.2 或 1.p）
- **不**支援 Cosmogony 跨 context ReadModel link（schema 已 rule out）
- **不**支援 composite key（單欄 key 為現階段約定，composite 升 Phase 1.q+）
- **不**改現有 BundleParserFullTests 既有 case（向後相容驗證）
- **不**新增 CLI flag / subcommand
- **不**改 stderr warning 格式對非 Phase 1.l.1 引入的 warning（既有 DtoRouter / Phase 1.n warning 保持原樣）

---

## 已知限制

- **Create UC 判定靠 name prefix `create`/`establish`**：100% 覆蓋 OC + IAM dogfood，但理論上若未來 UC 命名違反慣例（如 `initialize`/`bootstrap` 開頭）會誤判為 non-create UC。**緩解**：與 `/usecase` skill 同規則，違反慣例本身就會在 skill 階段被擋。
- **`parameters → key` derive 假設 `parameters[0].name == eventPayload field name`**：dogfood 階段 100% 成立，但若違反會產生 garbage `fromEventPayload`，下游 ReadModelRenderer 可能 emit 不可 build 的 projection。**緩解**：stderr warning 顯式提示 user 檢查，Cosmogony v22 explicit key UI 後可移除此 derive。
- **`links` derive 不處理 inbound / non-DomainEvent target**：Genesis 假設 ReadModel 只訂閱（outbound to DomainEvent），不感知其他 link 類型。**緩解**：silent ignore 不是 error，未來新 link semantic 出現再 escalate。
- **AS Input 跟 Domain UC Input 不一致**：create UC 的 ApplicationServiceInput 仍含 aggId、Domain UC Input 不含。**緩解**：AS execute body 內 service.execute 呼叫時不傳 aggId（因為 UC Input 沒這 field），編譯期會抓到不一致；如果 ApiRenderer 真的 emit 不一致呼叫 → Phase 1.l.2 補。
- **不依賴 Cosmogony v20/v22**：本 task 在 Cosmogony 任何 schema 演進前可獨立 ship。

### 依賴關係

- 前置（hard depends_on）：無 hard 阻塞（Phase 1.l/1.m/1.n/1.o 全 done）
- 軟相依（soft depends_on，已 done）：
  - `phase-1l-usecase-input-oc-alignment`（既有 renderInput 注入邏輯，Phase 1.l.1 改其 create UC 行為）
  - `2026-05-27-phase-1o-hygiene`（Service struct + Usecase where-clause shape，Phase 1.l.1 不改）
  - `2026-05-26-phase-1n-type-ownership-routing`（Phase 1.l.1 不改 routing）
- 後續（unblocks）：
  - **Phase 1.p impl**：等 Cosmogony v20 ship `aggregateRef` required 後可開跑（Phase 1.l.1 BundleParser adapter 是前置條件）
- 並行（parallel separate task，不阻塞）：
  - Phase 1.p spec update（reopen D3 加 `perReadModel`、D11 改用 `manifestVersion`）— 純 spec 工作，跟 Phase 1.l.1 impl 平行可做

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# Build + 全 test suite
swift build 2>&1 | tail -5
# 期望: "Build complete!"

swift test 2>&1 | tail -10
# 期望: "Test Suite ... passed" 0 failures

# 修改 1：BundleParser queryName alias
grep -qE 'queryName.*name|name.*queryName|case queryName' Sources/GenesisCore/BundleParser.swift

# 修改 2：BundleParser links → events derive
grep -q 'links.*DomainEvent\|outbound.*DomainEvent\|targetType == "DomainEvent"' Sources/GenesisCore/BundleParser.swift

# 修改 3：BundleParser parameters → key derive
grep -q 'parameters\[0\]\|parameters\.first\|raw\.parameters' Sources/GenesisCore/BundleParser.swift

# 修改 4：BundleParser returnType → storedFields flatten
grep -q 'returnType\.fields\|rt\.fields\|returnType' Sources/GenesisCore/BundleParser.swift

# 修改 5：UseCaseRenderer create UC skip aggId
grep -q 'isCreateUseCase' Sources/GenesisCore/UseCaseRenderer.swift
grep -q 'hasPrefix("create")\|hasPrefix("establish")' Sources/GenesisCore/UseCaseRenderer.swift

# Fixture 存在
test -f Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json
grep -q '"queryName"' Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json

# E2E：跑 Cosmogony fixture 產出專案
TMPDIR=$(mktemp -d)
swift run genesis new IAMContext \
    --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json \
    --output "$TMPDIR" --no-git --skip-build 2>&1 | tail -3

# Non-create UC 注入 aggId + operatorId
INPUTFILE="$TMPDIR/Sources/UserAccessProfileAggregate/Usecase/Port/In/GrantPrivilege/GrantPrivilegeInput.swift"
test -f "$INPUTFILE"
grep -q 'package let userAccessProfileId: String' "$INPUTFILE"
grep -q 'package let operatorId: String' "$INPUTFILE"

# Create UC：含 operatorId、不含 aggId
CREATEINPUTFILE="$TMPDIR/Sources/UserAccessProfileAggregate/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileInput.swift"
test -f "$CREATEINPUTFILE"
grep -q 'package let operatorId: String' "$CREATEINPUTFILE"
! grep -q 'package let userAccessProfileId: String' "$CREATEINPUTFILE"

# Cosmogony bundle 產出專案實際可 build
cd "$TMPDIR" && swift build 2>&1 | tail -3
# 期望: "Build complete!"
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# 既有 IAM bundle 向後相容
TMPDIR2=$(mktemp -d)
swift run genesis new IAMContext \
    --from-bundle ~/Downloads/"IAM Context Bundle.json" \
    --output "$TMPDIR2" --no-git --skip-build 2>&1 | tail -3
cd "$TMPDIR2" && swift build 2>&1 | tail -3
# 期望: "Build complete!"
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# 向後相容：既有 fixture 即使含 operatorId/aggId 也不 double-emit
LEGACY_INPUTFILE="$TMPDIR2/Sources/UserAccessProfileAggregate/Usecase/Port/In/GrantPrivilege/GrantPrivilegeInput.swift"
test -f "$LEGACY_INPUTFILE"
[ "$(grep -c 'package let useraccessprofileId: String' "$LEGACY_INPUTFILE")" = "1" ]
[ "$(grep -c 'package let operatorId: String' "$LEGACY_INPUTFILE")" = "1" ]

# Cleanup
rm -rf "$TMPDIR" "$TMPDIR2"
```

### Human 補做（需要人類介入）

- [ ] 拿真實 Cosmogony bundle (`~/Downloads/Cosmogony IAMContext bundle.json`，未修 typo 版本) 跑一次，確認：
  - 不該 fail 在 typo（typo 在 ReadModel name 是 `getPromissions`、DTO 是 `permissionDto`）— Genesis parse 應該過、產出 swift 應該也過（typo 不阻 build，只是命名怪）
  - 但 swift build 可能因為 `permissionDTP` typo（return type 引用不存在類型）fail，這是 user data error 不是 Genesis bug — 提示 user 在 canvas 修
- [ ] 跟 Cosmogony 端 sync：Phase 1.l.1 ship 後告知，並確認 Cosmogony v20 計畫（aggregateRef derive from links + canvas soft warning）排程
- [ ] 把分工原則寫進 Genesis `CLAUDE.md`（Cosmogony 三輪討論結論）：
  ```markdown
  ## Cosmogony / Genesis 分工原則
  Cosmogony Event Storming Tool 是上游 modeling tool，schema 以 modeling clarity 為主軸。
  Genesis 是下游 codegen tool，bundle 適配層在 BundleParser 內處理。
  Framework concerns（operatorId、aggregateId positioning、HTTP path 結構）由 Genesis codegen 注入，
  不污染 bundle。Bundle = pure domain spec。
  ```
