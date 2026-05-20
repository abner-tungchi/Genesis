---
topic: Phase 1.e — Aggregate template 對齊 gradyzhuo/swift-ddd-kit 0.3.0 的 AggregateRoot 結構
status: consensus
date: 2026-05-15
origin: inline brief（無多 agent 討論 round）
predecessor: dddkit-correction（已 done）
---

# Phase 1.e — Aggregate template 對齊 gradyzhuo/swift-ddd-kit 0.3.0

## 議題定義

### 背景

`dddkit-correction` task 已完成（2026-05-15）：Genesis 產出的 `Package.swift` / `PackageTarget.swift` / `Repository.swift` template 已對齊 gradyzhuo kit。但 **`Aggregate.swift.template` / `CommandExtension.swift.template` / `AggregateError.swift.template` 仍 conform 舊（Mendesky）`AggregateRoot` 形狀**，造成產出專案 `swift package resolve` 通過、`swift build` 失敗。

具體鴻溝（per dddkit-correction §已知限制）：
1. Aggregate template 仍宣告 `CreatedEventType` associatedtype — gradyzhuo `AggregateRoot` 沒有此 associatedtype
2. Aggregate template 缺 `init?(first:other:)` 顯式實作 — gradyzhuo base extension 不提供 default
3. `KurrentStorageCoordinator<{Aggregate}>` 要求 `{Aggregate}: EventStreamNaming`（經 `AggregateRoot`）；aggregate 對齊前 Repository 無法 build-pass

### 目標

修正 Genesis 產出的 aggregate 結構，使 `genesis new <Context>` 產出的專案能完整 `swift build`。具體：

1. **Aggregate template 對齊 gradyzhuo `AggregateRoot` 真實 protocol 簽章**：移除 `CreatedEventType`、補必要 `init`、對齊 protocol inheritance chain
2. **conform plugin 產的 `{Aggregate}AggregateProtocol`**：`DomainEventGeneratorPlugin` 從 event.yaml 自動產 protocol；aggregate 須 conform 它（取代手寫 `when(happened:)` switch dispatch）
3. **Created-event 處理採 Option B**（per memory `project_dddkit_correction`）：保留 `init(id:)` 簡單 shell + 在 `Entity/Commands/{A}+Create{A}.swift` 提供 createdEvent 的 `when(event:)` 空殼 + `init?(first:)` 顯式呼叫
4. **檔案重組對齊 docs/architecture.md §3 SSOT**：Aggregate 搬到 `Entity/`、Repository 搬到 `Usecase/Port/Out/`、Commands 進 `Entity/Commands/`
5. **掛 `ModelGeneratorPlugin`**（或 gradyzhuo 對應 plugin product 名）：產 `projection-model.yaml` placeholder
6. **驗收上限提升**：本 task 之後 `genesis new` 產出的專案能完整 `swift build`（Phase 1.a-1.d 的 `swift package resolve` 上限至此結束）

### 範圍

#### 討論內

- `Aggregate.swift.template`：移除 `CreatedEventType`、移除手寫 `when(happened:)` switch、補 `init(id:)` shell、state 改 Optional
- `CommandExtension.swift.template`：對齊 gradyzhuo command pattern（具體簽章待 facts report 確認）
- `AggregateError.swift.template`：對齊 OC `AuditQuotingError` 模式（具體待 facts 確認）
- 新增 `CreateCommandExtension.swift.template`（Option B 的 createdEvent `when(event:)` + `init?(first:)` 殼）
- 新增 `ProjectionModel.swift.template`（或 yaml）：placeholder for projection-model
- `Package.swift.template`：可能需新增 `ModelGeneratorPlugin` 條目（待 facts 確認 plugin 是否存在於 gradyzhuo 0.3.0）
- `AggregateRenderer.swift`：路徑配置改 `Entity/`、`Entity/Commands/`、`Usecase/Port/Out/`（與目前的 flat layout 不同）
- 相關 unit tests + integration test 對應更新

#### 討論外（Non-goals — 行為層）

- 本 task 不包含 `--adapter` flag 行為變更（Phase 1.c 範圍）
- 本 task 不包含 skill installer / `genesis install-skills` 行為變更（Phase 1.d 範圍）
- 本 task 不包含 `genesis diff` / `genesis apply` 等 Phase 2+ 指令
- 本 task 不包含 event.yaml schema 改動（gradyzhuo 0.3.0 與 Mendesky 在 event.yaml 上相容，per dddkit-correction §介面合約已驗證）
- 本 task 不包含 `swift-adapter.yaml` schema 改動
- 本 task 不包含改 Genesis CLI 自身的 `Package.swift`、CLI flags、`GenesisError` cases（除非 plugin 引入新失敗路徑，留待 facts report 後評估）

### 約束

1. **OC 是 ground truth**：所有 kit-specific 事實必須依 `gradyzhuo/swift-ddd-kit` 0.3.0（OC `.build/checkouts/swift-ddd-kit/`）+ OC `Sources/AuditQuotingAggregate/` 雙重交叉驗證；禁止再依 Mendesky/DDDKit
2. **驗收 `swift build` 必過**：產出專案在 `genesis new` 後直接 `swift build -c release` exit 0（不依賴 user 端額外修改）
3. **Plugin 行為不可預設**：DomainEventGeneratorPlugin / ModelGeneratorPlugin 在 gradyzhuo 0.3.0 的實際產出（生成什麼 protocol、要 conform 什麼）必須在 spec 寫作的 step 3b 經 facts report 證實，不可基於 Mendesky 經驗推斷
4. **不可整檔 supersede phase-1b**：phase-1b 的 BundleParser / SourceWriter / 14 個 sub-template 大多仍有效，只 aggregate template / CommandExtension / Repository placement / path layout 被覆寫。phase-1b 加 partial-supersede banner + inline 標記，不改其 registry status
5. **依賴 `dddkit-correction` 完成**：Repository.swift.template 的 struct + KurrentStorageCoordinator 已就位（前置條件）

## 決策紀錄

### Decision 1: 採用 Option B 處理 createdEvent

**已 lock**（per memory `project_dddkit_correction`）

- **Option A（已淘汰）**：完全依賴 plugin 產的 `init?(first:)` default — gradyzhuo 0.3.0 不提供 default，行不通
- **Option B（採用）**：最小改動 — Aggregate 主體保留 `init(id:)` 簡單 shell；`Entity/Commands/{A}+Create{A}.swift` 提供 createdEvent 的 `when(event:)` 空殼 + `init?(first:)` 顯式呼叫
- **Option C（淘汰）**：全部展開到 Aggregate.swift — 與 OC 慣例不符（OC 把每個 command 拆 partial extension）

依據：OC `AuditQuotingAggregate` 採類似模式（facts report 須證實具體檔名與 layout）。

### Decision 2: 檔案 layout 對齊 OC

**已 lock**（per docs/architecture.md §3 SSOT）

```
Sources/{Aggregate}Aggregate/
├── event.yaml
├── projection-model.yaml  ← 新增
├── {Aggregate}Error.swift
├── Entity/
│   ├── {Aggregate}.swift   ← 從 flat 搬進來
│   ├── {Aggregate}+Invariant.swift  ← 新增 placeholder（人類補規則）
│   └── Commands/
│       ├── {Aggregate}+Create{Aggregate}.swift  ← 新增（Option B createdEvent shell）
│       └── {Aggregate}+{UC}.swift  ← 從 flat CommandExtension 搬進來
├── Usecase/
│   └── Port/
│       └── Out/
│           └── {Aggregate}Repository.swift  ← 從 flat Adapter/ 搬進來
└── Adapter/
    └── ...（保留 Phase 1.c 配置）
```

對比 Phase 1.b 現況（flat layout）：所有檔案直接放在 `{Aggregate}Aggregate/` 下或 `Adapter/`。

### Decision 3: 驗收上限提升到 `swift build`

**已 lock**

Phase 1.a-1.d + dddkit-correction 的驗收上限是 `swift test` + `swift package resolve`（kit 巨型依賴鏈讓 build 成本高）。Phase 1.e 完成的定義是：

- e2e：`genesis new IAMContext --from-bundle <IAM bundle> --output <dir>` 後，在 `<dir>` 跑 `swift build -c release` exit 0
- 至少一個 aggregate 的 plugin-generated code 通過編譯（DomainEventGeneratorPlugin 從 event.yaml 產的 protocol + types）
- 若 gradyzhuo 0.3.0 有 ModelGeneratorPlugin 等同物：projection-model.yaml 產的程式碼也須通過編譯

CI 成本評估留 spec 寫作時處理（單次 build 約 5-10 分鐘，由 Phase 1.f 或 Phase 2 評估是否導入 release-only CI gate）。

### Decision 4: phase-1b 採 partial-supersede

**已 lock**

- phase-1b 仍 `status: done`，不改 registry status
- 在 phase-1b spec 文件加 banner 指向 phase-1e（type: partial supersede）
- Aggregate 相關段落（`<Aggregate>+Invariant.swift` 路徑、handwritten `when(happened:)` switch dispatch 描述、AggregateRenderer 路徑配置等）加 inline ⚠️ 標記
- phase-1b 的 BundleParser / SourceWriter API / 14 個 sub-template（除 Aggregate / CommandExtension / AggregateError）仍有效

## Facts Report 已完成（2026-05-15 by Gemini）

Step 3b ground-truth facts report 已由 gemini-agent 跨讀 gradyzhuo 0.3.0 + OC + Genesis 現有 template 完成。**原開放問題 1-6 解答** + **新發現 6 個 scope-defining 決策點**：

### 原開放問題解答

1. **`AggregateRoot` 簽章**：`public protocol AggregateRoot: EventStreamNaming, Entity where ID == String { associatedtype DeletedEventType: DeletedEvent; var metadata: AggregateRootMetadata { set get }; init?(events:) throws; func when(happened:) throws; ... }` — **無 `CreatedEventType` associatedtype**；`ID == String` 強制；transitively `EventStreamNaming`。
2. **Plugin output**：`{A}AggregateProtocol` 由 **`ModelGeneratorPlugin`** 產出（非 DomainEventGeneratorPlugin）；plugin 要求 `event.yaml` + `projection-model.yaml` + `event-generator-config.yaml` 三檔皆在，否則 build fail。產出格式 `protocol {A}AggregateProtocol: AggregateRoot where ID == String, DeletedEventType == {A}Deleted { init?(first createdEvent: {CreatedEvent}, other events: ...) throws; func when(event: {Event}) throws; ... }`，**createdEvent 不在 when(event:) 列表**。Plugin 也產 default `init?(events:)` + default `when(happened:)`。
3. **OC `AuditQuotingAggregate` layout**：**沒有 `+Create{A}.swift`** — createdEvent payload 直接在 `init(id:, ...all created-event fields) throws` 內 build + apply；`required convenience init?(first:other:)` 委派給 init(id:...) 然後 replay。Repository 在 `Usecase/Port/Out/`，不在 `Adapter/`。
4. **ModelGeneratorPlugin 存在**於 gradyzhuo 0.3.0 (`Plugins/ModelGeneratorPlugin/`)，產 `generated-projection-model.swift`（含 `{A}AggregateProtocol`）+ `generated-event-mapper.swift` + `generated-event-filter.swift`。`projection-model.yaml` 必須存在才能 build-pass。
5. **`EventStreamNaming` 與 `AggregateRoot`**：`AggregateRoot: EventStreamNaming, Entity` — `EventStreamNaming` 已被 AggregateRoot inherit，無需顯式 conform。default `categoryRule: .fromClass(withPrefix: "")` → 預設 category = aggregate class 名稱。
6. **OC `+{UC}.swift` pattern**：`extension {A} { package func {useCaseCamelCase}(...) throws { /* validate + build event + apply(event:) */ }; package func when(event: {Event}) throws { /* mutate state */ } }` — 跟 Genesis CommandExtension.swift.template 形狀已對得上。

### 新發現 + Decisions（User 2026-05-15 拍板）

7. **typedStruct adapter 結構性衝突 → DEPRECATE**：`Entity where ID == String` 不允許自訂 ID 型別。本 task `AdapterApplier` 對 `idStrategy.typedStruct` 改為 warning + fallback to stringId（或 reject），aggregate `let id: String` 一律。Phase 1.c 加的 typedStruct 邏輯部分退役（不刪 yaml schema，但生成路徑棄用）。
8. **projection-model.yaml 來源 → 從 bundle ReadModels[] 萃取**：Phase 1.b 的 BundleParser 已解析 `readModels[]`；Phase 1.e 新增 `ProjectionModelRenderer` 從 readModels[] 產出 yaml entries（`Get{ReadModelName}: { model: readModel, events: [...] }`）。需確認 bundle readModel 結構是否含 source events list；若不全，部分項目降級為 `events: []` placeholder + 標記 [NEEDS-HUMAN]。
9. **category prefix 規則 → 大寫字母縮寫**：`categoryPrefix = contextName.filter { $0.isUppercase }`。範例：IAMContext → "IAMC"、QuotationContext → "QC"、OpportunityContext → "OC"、AuditQuotingContext → "AQC"。Aggregate 自動加 `package static var category: String { "{Prefix}\(Self.self)" }`。
10. **Aggregate 形狀 → `package class`（非 final）conform `{A}AggregateProtocol`**：跟 OC 一致；非 final 允許 test double + 維持 `required convenience init?` 語意清晰；conform generated protocol（不直接 conform AggregateRoot）。
11. **AggregateError 形狀 → `enum {A}Error: Error, Equatable`**：跟 OC 一致；Equatable 取代 Sendable（enum 預設 Sendable）；不產 ContextError factory extension（需 Shared infra，留 per-feature `/usecase` skill 處理）。
12. **DeletedEvent yaml 形狀 → 省略 aggregateRootId/properties**：跟 OC 一致，僅 `{A}Deleted:\n  kind: deletedEvent`。當前 Genesis 的 `renderEventBlock` 一律輸出 alias + properties 需特例化。
13. **Repository 路徑 → 移到 `Usecase/Port/Out/`**：Phase 1.b 放在 `Adapter/` 是錯位。本 task 改為 `Sources/{A}Aggregate/Usecase/Port/Out/{A}Repository.swift`。
14. **手寫 `when(happened:)` switch → 移除**：generator 已提供 default impl；保留會 shadow/conflict。

### 不在本 task 範圍

- `Entity/{A}+Invariant.swift` 不獨立檔（OC 把 invariants 寫在 Aggregate.swift 內 `extension {A} { func ensureInvariant() {...}; private func checkXxx() {...} }`）— 本 task 留 `ensureInvariant()` 空殼在 Aggregate.swift，invariant rules 由 per-feature `/usecase` 補
- `ContextError` factory extension on AggregateError — 需要 Shared infra（OC 的 `ContextError`），不屬本 task
- `state field` 是否 Optional vs non-optional + default — 維持 Phase 1.b 慣例（Optional + populated by `when(event:)`），跟 OC 的 `var ... = default` 不完全一致但可運作；OC 慣例屬 per-feature 範疇
- `category` adapter override：本 task 鎖死「contextName 大寫縮寫」規則，不開放 swift-adapter.yaml override（YAGNI）

## 後續

spec 寫作流程：

1. **write-spec step 3b（facts report）**：呼叫 gemini-agent 跨讀 OC + gradyzhuo + Genesis renderer/template，產出結構化 facts report
2. **write-spec step 5（產出 spec）**：8 段 contract-first 格式，所有 kit-specific 事實必須引用 facts report
3. **write-spec step 5b（audit-spec）**：跑完整審查（4b + 5b + 5c 外部審查）— 本 spec 預期 > 500 行不適用 --quick
4. **write-spec step 7（registry）**：寫 `docs/tasks/registry/phase-1e-aggregate-alignment.json`，`depends_on: ["dddkit-correction"]`，加 phase-1b partial-supersede banner

寫定後交 `/pickup`（多模型協作：Codex 實作 / Gemini Review / Claude 協調）。
