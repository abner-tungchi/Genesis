---
topic: Phase 1.n — Custom type ownership routing (aggregate-private vs context-shared)
status: ready（決策已 lock，可進 write-spec）
date: 2026-05-26
origin: dogfood Layer 2 IAM bundle F4 finding（無多 agent discussion round）
predecessor: Phase 1.e (custom types via Shared) + Phase 1.h (isContextShared field)
references:
  - Dogfood findings: `docs/discussions/2026-05-26-dogfood-iam-bundle-findings.md` §F4
  - Routing source: `Sources/GenesisCore/SharedTargetRenderer.swift:18-58`
  - `isContextShared` parsing: `Sources/GenesisCore/BundleParser.swift:442-446`
  - Per-agg DTO mapper emit: `Sources/GenesisCore/ApiRenderer.swift:52-75`
  - Validator gate（F1 連帶修正）: `Sources/GenesisCore/AggregateRenderer.swift:148-156`
  - User bundle: `~/Downloads/IAM Context Bundle.json`
  - OC reference: `~/JiaBao/Mendesky/OpportunityContext/`（**僅參考，不視為 ownership ground truth**）
  - User memory: `feedback-convention-over-configuration`
---

# Phase 1.n — Custom type ownership routing

## 議題定義

### 背景

Layer 2 dogfood 跑 user real IAM bundle 時，`EmployeeStatus` enum 被 Genesis 放到 `Sources/IAMContextShared/EmployeeStatus.swift`。但 `EmployeeStatus` 只被 `UserAccessProfile.state.status` 引用，沒跨 aggregate。

OC 對 ownership 的處理有兩個值得注意的事實：

- ✅ `OCShared/` 內的 cross-boundary value type（如 `OrganizationType` / `FileType` / `AccountingTypeDto`）— 是跨多個 aggregate 共用、stable across context 的 type，**合理**放 Shared
- ⚠️ `CompanyRegistrationQuotingAggregate/QuotingStatus.swift` 與 `AuditQuotingAggregate/QuotingStatus.swift` **identical**（`diff` exit 0），usage=2 卻沒 lift 到 Shared，各 aggregate 各 dup 一份

**User 決策（2026-05-26）**：OC dup pattern **視為 technical debt，不當 Genesis ground truth**。理由：很可能是 OC 還沒同步 aggregate 共用的 type，不是刻意 design。Genesis 對 ownership 採乾淨的「使用次數」rule：

```
usage == 0 (純 infra) → Shared
usage == 1            → 該 aggregate folder
usage ≥ 2             → Shared (always lift, no dup)
```

「同名 DTO 不同欄位」的情境被視為 bundle validity error（duplicate name 不准），不在 routing scope。

### Genesis 現況

Genesis 已支援 per-aggregate vs Shared 標記 — `DtoSpec.isContextShared` field（Phase 1.h 引入）：

```swift
// BundleParser.swift:442-446
let hasPhase1hSchema = raw.dtoKind != nil || raw.isContextShared != nil
let resolvedIsContextShared = raw.isContextShared ?? (hasPhase1hSchema ? false : true)
```

- `isContextShared: true` → `SharedTargetRenderer` 放 `<Context>Shared/`
- `isContextShared: false` + `aggregateRef` → `ApiRenderer` 走 per-agg DTO mapper emit

**問題在 Cosmogony 沒填這個欄位**：

```jsonc
// user real bundle 的 EmployeeStatus DtoSpec
{
  "kind": "DtoSpec",
  "name": "EmployeeStatus",
  "description": "This is a Enum",
  "fields": [...]
  // ← 沒 isContextShared、沒 aggregateRef
}
```

Legacy fallback `resolvedIsContextShared = true` → 一律塞 Shared/。

### 兩條路徑同時走

**Cosmogony 端**（user 可推動）：將 emit 修正為填 `isContextShared` + `aggregateRef`，long-term 解決源頭。
**Genesis 端**（本 Phase 1.n 處理）：

1. 短期 unblock — 加 auto-detect fallback（bundle 沒填時 Genesis 推算）
2. 長期穩定 — Cosmogony 補完欄位後，Genesis 尊重 explicit 標記，auto-detect 自動退場

### 目標

- 解決 F4：IAM bundle `EmployeeStatus` 重生後正確放在 `Sources/UserAccessProfileAggregate/EmployeeStatus.swift`
- 順手做 F1 reframe（validator error message hygiene）
- Bundle 作者意圖被尊重；Cosmogony emit fix 後 Genesis 邏輯仍正確
- 留 warning 機制鼓勵 explicit marking 取代 auto-detect

### 範圍

#### 討論內

- BundleParser `isContextShared` default 行為與 auto-detect fallback
- `TypeOwnershipResolver`（新元件）— 純 function of bundle，推算 ownership
- SharedTargetRenderer routing 邏輯（per-agg vs Shared 分發）
- AggregateRenderer 對自家 enum 的 emit（既有 `ApiRenderer` per-agg 路徑已支援，可能要擴）
- Warning system（auto-detect 啟用時提示 user / Cosmogony 補欄位）
- F1 validator error message reframe（順手做）

#### 討論外

- Cosmogony Event Storming Tool 的 UI/JSON emit 改動（不在 Genesis repo scope；user 端另行推動）
- Adapter typeOwnership override（**不採納**，bundle 才是 SSOT，per [[feedback-convention-over-configuration]]）
- 「同名 DTO 不同欄位」的衝突解析（視為 bundle validity error，本 phase 不解）
- 純跨 aggregate dup 模式的特例（OC QuotingStatus type 的處理）— 不對齊 OC debt

### 約束

- 對齊 [[feedback-convention-over-configuration]]：bundle 為 SSOT，Genesis 不 silent 接管，warning 引導使用者修源頭
- Backward compat：既有 fixture / IAM Cross Agg Presenter / 既有 IAM 測試 bundle 重生結果，若 ownership 推算結果改變要顯式更新 test 期望值
- 不破壞 ContextError / ApplicationService 等既有 Shared infra emit（這些走 `renderInfraFiles`，與 routing 邏輯分開）

---

## 設計提案

### 整體架構 — 2-tier ownership decision

```
┌─────────────────────────────────────────────────────────────┐
│ Tier 1: Bundle explicit marking                             │
│   DtoSpec.isContextShared + (if false) aggregateRef         │
│   → 來自 Cosmogony emit 或 user 手填                          │
│   → 最高優先級，尊重作者意圖                                  │
└─────────────────────────────────────────────────────────────┘
                            ↓ (若 bundle 未標記)
┌─────────────────────────────────────────────────────────────┐
│ Tier 2: Genesis auto-detect by usage scan                   │
│   TypeOwnershipResolver scan bundle:                        │
│     - aggregates[].state[].type                             │
│     - useCases[].input[].type                               │
│     - useCases[].eventPayload[].type                        │
│     - presenters[].input/output                             │
│     - readModels[].fields[].type                            │
│     - bundle.dtos[].fields[].type （直接引用 only，不遞迴）  │
│   Decide:                                                   │
│     refs == 1 → that aggregate folder                       │
│     refs ≥ 2 → Shared                                       │
│     refs == 0 → Shared (orphan / pure infra)                │
│   Emit warning 教使用者改 bundle 標記                         │
└─────────────────────────────────────────────────────────────┘
```

### 元件變更

#### 1. 新增 `TypeOwnershipResolver.swift`

純 function of `FullBundle`，輸出 type → ownership 對照表：

```swift
public enum TypeOwnership {
    case contextShared
    case ownedBy(aggregateName: String)
}

public enum TypeOwnershipResolver {
    /// 對 bundle 內每個 customType（bundle.dtos + adapter.customTypes）推算 ownership.
    /// Tier 1 (explicit) 優先，Tier 2 (usage scan) fallback.
    public static func resolve(
        bundle: FullBundle,
        adapter: Adapter
    ) -> (ownership: [String: TypeOwnership], warnings: [String])
}
```

實作大綱：

1. 對每個 customType `T`：
2. **Tier 1**: 找 `bundle.dtos[]` 內名稱為 `T` 的 DtoSpec 是否有 explicit `isContextShared`：
   - 有 `isContextShared=true` → `.contextShared`
   - 有 `isContextShared=false` + `aggregateRef="X"` → `.ownedBy(X)`
   - 有 `isContextShared=false` 但缺 `aggregateRef` → error message + skip
3. **Tier 2 (Tier 1 not set)**: scan usage：
   - 收集 refs (Set<aggregateName>)
   - `refs.count == 0` → `.contextShared` (warning: "T 沒被引用，視為 infra")
   - `refs.count == 1` → `.ownedBy(refs.first!)` (warning: "T auto-routed to <agg>; consider marking explicit")
   - `refs.count >= 2` → `.contextShared` (warning: "T auto-shared from N usages; consider marking explicit")
4. 回傳 ownership map + warnings

#### 2. `SharedTargetRenderer` 重構

`renderBundleDtosAndCustomTypes` 改為呼叫 resolver：

```swift
let (ownership, warnings) = TypeOwnershipResolver.resolve(bundle: bundle, adapter: adapter)
// emit warnings via logger / stdout

for (name, spec) in byName {
    switch ownership[name] {
    case .contextShared:
        // 既有 Shared emit 路徑
    case .ownedBy(let aggName):
        // delegate to per-agg emit (新路徑或借用 ApiRenderer 既有 mapper path)
    }
}
```

#### 3. `ApiRenderer` per-agg DTO mapper emit 已存在（line 52-75）

但目前 hard-code 「assume first aggregate」（v1 assumption）— Phase 1.n 改為用 resolver 結果指定確切 aggregate：

```diff
- guard let firstAggregate = bundle.aggregates.first else { return outputs }
- for dto in bundle.dtos where !dto.isContextShared {
+ for dto in bundle.dtos {
+   guard case .ownedBy(let aggName) = ownership[dto.name] else { continue }
+   let mapperPath = "Sources/\(aggName)Aggregate/Adapter/Dto/\(dto.name)+Domain.swift"
+   ...
+ }
```

#### 4. AggregateRenderer custom type enum emit（per-agg）

若 ownership = `.ownedBy(X)`，emit `Sources/<X>Aggregate/<TypeName>.swift`（與 OC QuotingStatus 同 dir 結構）。

實作面：擴 `SharedTargetRenderer.renderCustomType` 接受 dynamic `dir`，path 從 ownership 決定。

#### 5. F1 validator error message reframe（順手做）

`AggregateRenderer.swift:146-156`：

```diff
-                // Fail-fast: every payload field must have a matching state field. Phase 1.e does not provide
-                // a payload-to-state adapter mapping (deferred to Phase 1.f). Orphan payload fields would
-                // generate `self.<nonExistentField> = ...` lines that fail to compile with a confusing error.
+                // Genesis enforces 1:1 naming between createdEvent payload and aggregate state
+                // (aligned with OC reference convention). Field rename via adapter is intentionally not supported —
+                // bundle authors should align naming, not introduce bridging configuration.
                 let stateFieldNames = Set(spec.state.map { $0.name })
                 let orphanFields = payloadFields.filter { !stateFieldNames.contains($0.name) }
                 if !orphanFields.isEmpty {
                     throw GenesisError.bundleInvalid(
                         reason: "createdEvent payload field(s) \(orphanFields.map { $0.name }) "
-                            + "have no matching state in aggregate '\(spec.name)'; "
-                            + "adapter mapping required (not supported in Phase 1.e)"
+                            + "have no matching state in aggregate '\(spec.name)'.\n"
+                            + "Fix: rename the event payload field(s) to match aggregate state names, "
+                            + "OR add the missing field(s) to aggregate state in bundle. "
+                            + "Genesis enforces 1:1 naming (aligned with OC); field rename via adapter is not supported."
                     )
                 }
```

### 對既有 fixture 的影響

掃 `Tests/GenesisIntegrationTests/Fixtures/` 內 bundle：

- `iam-bundle.json` / `iam-readmodel-bundle.json` / 其他 — 若 DtoSpec 沒設 `isContextShared`，Tier 2 啟用，結果視 usage scan 而定
- 預期改變：純 aggregate-private 的 customType（如 `EmployeeStatus`）會從 `<Context>Shared/` 移到 `<Aggregate>Aggregate/`
- Integration test 期望值需更新（會在 spec 寫具體清單）

---

## 決策紀錄（2026-05-26 lock）

### D1. Routing 哲學

採 **2-tier hybrid**：bundle explicit marking 為主（Tier 1），usage-based auto-detect 為 fallback（Tier 2）。

**理由**：對齊 [[feedback-convention-over-configuration]] — bundle 為 SSOT；Cosmogony 補欄位後 Tier 2 自動退役。

### D2. Adapter typeOwnership override → **不採納**

Adapter 不擔 ownership 角色；保持 `customTypes` 為 type definition override 用途。

**理由**：bundle 才是 SSOT；OC dup pattern 視為 OC debt 不採納，移除 adapter override 的存在理由。

### D3. Usage scan scope = 直接引用 only

掃 `aggregate.state[]`, `useCase.input[]`, `useCase.eventPayload[]`, `presenter.input/output`, `readModel.fields[]`, `dto.fields[]`，**不遞迴**。

**理由**：YAGNI；間接引用情境少，遇到時 warning 引導使用者改 bundle 即可。

### D4. Tier 2 啟用時 emit **warning**

不 silent、不 error。Warning 顯示 type name + auto-detected ownership + 建議的 bundle 標記。

**理由**：dogfood 不 break、convention 長期推進兼顧；對齊 [[feedback-convention-over-configuration]] 教使用者改源頭。

### D5. F1 error message reframe **併入 Phase 1.n**

`AggregateRenderer.swift:146-156` 一起改，避免拆 PR 重新 audit。F2/F3/F5 留 Phase 1.o hygiene phase。

**理由**：F1 改動位置與 F4 邏輯都在 AggregateRenderer / Shared routing 相關 area，併合 reviewer context 集中、test fixture 更新一次到位。

### D6. Ownership 衝突處理

「同名 DtoSpec 不同欄位」視為 bundle validity error（duplicate name 不准），在 BundleParser 階段 fail-fast。

`.ownedBy(X)` 但 `aggregateRef="X"` 在 `bundle.aggregates[]` 找不到 → BundleParser fail-fast。

---

## 預估工作量

| 項目 | 工 |
|---|---|
| `TypeOwnershipResolver` + unit tests | 0.5 天 |
| `SharedTargetRenderer` / `ApiRenderer` / `AggregateRenderer` 整合 | 0.5 天 |
| Warning emit + logger / stdout 接 | 0.2 天 |
| F1 error message + 移除 misleading comment | 0.2 天 |
| Fixture / integration test 期望值更新 | 0.3 天 |
| 含 write-spec + audit-spec + 修正 round | 0.3 天 |

**總計：~2 天**

---

## 下一步

1. ✅ Discussion MD ready（status: ready）
2. → 跑 `/write-spec docs/discussions/2026-05-26-phase-1n-type-ownership-routing.md`
3. → write-spec 自動 chain 到 audit-spec
4. → audit-spec PASS → status: ready → 排程實作（pickup / 手動）
