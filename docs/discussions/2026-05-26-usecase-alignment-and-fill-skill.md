# /usecase skill + Phase 1.l Usecase Input OC alignment（facts + 決策）

## 任務定位（兩個耦合 tasks）

1. **Phase 1.l — Usecase Input OC 對齊** (gating prerequisite)
2. **/usecase skill v1** — 第四個 in-place fill skill

兩者耦合：/usecase 需要 Usecase Input 含 aggId + operatorId 才能照 OC pattern 寫 body。Phase 1.l 先做。

## Facts gathered（OC 探勘）

### F1. OC Usecase Input shape（4 個 UC 一致）

| UC | Usecase Input fields |
|---|---|
| `EditPaidInCapital` | `{quotingId, paidInCapital, operatorId}` |
| `EditFontSize` | `{quotationId, fontSize, operatorId}` |
| `CreateQuotation` | `{quotationId, quotingCaseGroupingId, operatorId}` |
| `EditLetterTitle` | `{quotationId, quotingCaseId, title, operatorId}` |

→ **OC Usecase Input 一律包含 aggId + 業務欄位 + operatorId**。AS Input == Usecase Input（字段集合相同，1:1 pass-through）。

### F2. OC 4 種 Usecase extension body patterns

| pattern | OC 範例 | 形狀 |
|---|---|---|
| **Update**（最常見）| `EditPaidInCapital` / `EditFontSize` / `RenamePaymentItem` / `EditContractNote` | `find by aggId → guard not-nil throw aggregateNotFound → aggregate.<method>(...) → repository.save(..., userId: input.operatorId) → return .init(id: aggId, message: nil)` |
| **Update + Validator** | `EditLetterTitle` / `ShowPaymentItemSupplementaryNote` | 同 Update，find 後加 `try await validator.validateRecipientCase(...)`；catch ladder 多 `ContextError<{OtherAgg}Error>` branch |
| **Create** | `CreateQuotation` | 無 find；`try <Aggregate>(id: input.aggId, ...) → save → return .init(id: aggId, message: nil)` |
| **Delete** | `DeleteQuotation` | `find → repository.delete(byId: agg.id, userId: input.operatorId) → return .init(id: aggId)`（無 message） |

### F3. OC 通用 catch ladder

所有 4 種 pattern 共用：

```swift
} catch let error as ContextError<{A}Error> {  // optional, only when aggregate.<method> can throw domain error
    throw error
} catch let error as ContextError<{OtherAgg}Error> {  // optional, only with validator
    throw error
} catch let error as DDDError {
    throw error
} catch {
    throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
}
```

### F4. OC 結構（per UC）

OC 每個 write UC 有：
- `Adapter/<UC>/<UC>ApplicationService.swift` （AS）
- `Usecase/Port/In/<UC>/<UC>Usecase.swift`（protocol + extension default execute body）
- `Usecase/Port/In/<UC>/<UC>Input.swift`（含 aggId + 業務 + operatorId）
- `Usecase/Port/In/<UC>/<UC>Output.swift`（含 `id` field）
- `Usecase/Service/<UC>Service.swift`（空殼 struct conform Usecase，僅 init repository）
- `Entity/Commands/<Agg>+<UC>.swift`（aggregate 的 domain method）

Genesis 端結構（已 ship）：完全對齊。

### F5. Genesis 端目前差異

| 項目 | OC | Genesis 現狀 |
|---|---|---|
| `{UC}Input` aggId field | ✓ | ❌ |
| `{UC}Input` operatorId field | ✓ | ❌ |
| `{UC}Service` struct | ✓ 空殼（init repo） | ✓ 空殼（class final，init repo） |
| `{UC}Usecase` protocol | `Usecase<Input, Output>` + `var repository` | 一致 |
| `{UC}Usecase` extension default body | ✓ OC patterns A/B/C/D | ❌ `fatalError("not implemented")` stub（GENESIS-STUB） |

### F6. /api skill v4 行為（要 revert）

v4 category 1 fill body 因 Usecase Input 無 aggId/operatorId，emit：

```swift
let service = <UC>Service(repository: repository)
_ = try await service.execute(input: .init(
    userId: input.userId,  // 只業務欄位
    department: input.department,
    jobTitle: input.jobTitle
))
```

對齊 OC 後（Phase 1.l + /api v6）：Usecase Input 將與 AS Input 同形狀 → fill 邏輯回到 v3 草稿的「pass-through 全部 fields」：

```swift
let service = <UC>Service(repository: repository)
_ = try await service.execute(input: .init(
    useraccessprofileId: input.useraccessprofileId,   // aggId
    userId: input.userId,
    department: input.department,
    jobTitle: input.jobTitle,
    operatorId: input.operatorId                       // operatorId
))
```

→ 等於 OC `EditPaidInCapital` AS execute() pattern：1:1 pass-through。

### F7. OC `Aggregate` 真實 factory pattern

```swift
let quotation = try Quotation(id: input.quotationId, quotingCaseGroupingId: input.quotingCaseGroupingId)
```

直接呼叫 `<Aggregate>(id:, <fields>:)` throws init。Genesis 端 `AggregateRenderer` 已 emit `init(id:, <fields>:) throws { ... }` 結構（Phase 1.e ratification）— 可用。

## 決策

### D1：Usecase Input 對齊 OC（含 aggId + operatorId）

UseCaseRenderer.renderInput 自動 inject：
- `aggId` from `bundle.aggregates[].identityName`（lookup by `useCase.aggregateSpecId`），如 `useraccessprofileId: String`
- `operatorId: String`

兩個 fields 插在最前 + 最後（aggId 第一，operatorId 最後，與 OC 一致）。中間是原 `useCase.input[]` 業務欄位。

### D2：/api skill v6 升級

revert v4 category 1 fill 邏輯為「pass-through 全部 fields」（包含 aggId + operatorId）。

伺機點：handler asInput → service.execute 的 mapping 變成全 1:1，極簡：

```swift
_ = try await service.execute(input: .init(
    <aggId>: input.<aggId>,
    <field1>: input.<field1>,
    ...
    operatorId: input.operatorId
))
```

v4 既有 fills 不 retro-upgrade（structural invariant 視已填 exit 0）—— 但會 compile fail！因為 Usecase Input 從沒 aggId+operatorId 變有，舊 fill 缺欄位。**這是 Phase 1.l 的 breaking change**，要明示 known limit + e2e 重生 fixtures。

### D3：/usecase skill v1（4 patterns + heuristic）

| pattern | trigger | body 形狀 |
|---|---|---|
| **Create** | UC name 以 `Create` / `Establish` 開頭，且 `aggregate.<method>` 是 `init`-style factory | `try <Aggregate>(id: input.aggId, <fields>) → save → return .init(id: aggId, message: nil)` |
| **Update** | UC name 以 `Edit` / `Set` / `Rename` / `Add` / `Remove` 開頭 + aggregate 有對應 `<methodName>(...)` Command extension | `find → guard → aggregate.<method>(...) → save → return .init(id: aggId, message: nil)` |
| **Delete** | UC name 以 `Delete` 開頭 | `find → guard → repository.delete(byId:, userId:) → return .init(id: aggId)` |
| **Update + Validator** | （複雜，defer v2）validator class 偵測+注入 | manual fill / exit 3 |

method name detection：scaffold 已有 `Entity/Commands/<Agg>+<UC>.swift` 含 `func <ucCamel>(<args>) throws`，grep 之。

aggregate method args matching：domain method 的 params 對應 UC Input 業務欄位（非 aggId/operatorId）。

### D4：Service struct 不動

Genesis 已 emit `Service` 空殼，與 OC 完全一致。/usecase 只填 Usecase extension body。

### D5：Catch ladder 一律 emit

不偵測 `aggregate.<method>` 是否會 throw domain error —— 一律 emit `catch let error as ContextError<{A}Error>` branch（多 catch 一個無害 case 也 compile pass）。

### D6：existing fixture regeneration

`iam-bundle.json` regenerate 後 Usecase Input shape 改變，**/api skill v4 既有 fills 會 compile fail**。Phase 1.l + /api v6 spec 明示這是 breaking change，e2e 流程必須重生 + 重填。

---

## 兩個 spec 範圍

### Phase 1.l spec 範圍

- `UseCaseRenderer.renderInput` 加 inject aggId + operatorId
- `UsecaseInput.swift.template`：placeholder 順序保持，但 renderer 注入 fields 含 aggId（first）+ operatorId（last）
- `/api skill v4 → v6`：category 1 fill 改全 pass-through；known limit 加「Phase 1.l breaking change：既有 v4 fills 需 manual unfill 重填」
- 既有 ApiRendererTests / NewCommandTests / fixtures 影響評估 + 修
- Real e2e：iam-bundle regen + /api 重填 createUserAccessProfile + swift build PASS

### /usecase skill v1 spec 範圍

- SKILL.md ≤200 LoC，5-Phase flow（與 /api / /presenter-fill / /readmodel-mutation 對稱）
- 4 patterns（Update + Update+Validator + Create + Delete）+ heuristic（UC name prefix + aggregate method grep + factory init grep）
- exit codes：0 / 1 / 3 (Update+Validator defer / unsupported) / 4 (corrupted)
- idempotent（block 含 `repository.find` / `aggregate.X` / `repository.save` 等 → 已填）
- Real e2e：iam-bundle regen → /api 填 → /usecase 填 createUserAccessProfile → swift build PASS（Usecase body 真實 work，不再 fatalError trap）

## 下一步

write-spec Phase 1.l → write-spec /usecase → audit-spec 兩份（Codex 可用就上，否則 self-audit）→ pickup Phase 1.l → regen fixture → pickup /usecase → real e2e → commit。
