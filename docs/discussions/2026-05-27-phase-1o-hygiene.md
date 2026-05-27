---
topic: Phase 1.o — Hygiene phase (F2 / F3a-c / F5 — OC alignment + TODO marker unify + event.yaml map shape)
status: ready（決策已 lock，可進 write-spec）
date: 2026-05-27
origin: dogfood Layer 2 IAM bundle F2 + F3 + F5 + OC ground truth re-verification
predecessor: Phase 1.n (Custom type ownership routing — done) + Phase 1.l (Usecase Input OC alignment — done)
references:
  - Dogfood findings: `docs/discussions/2026-05-26-dogfood-iam-bundle-findings.md` §F2 §F3 §F5
  - OC ground truth Service: `~/JiaBao/Mendesky/OpportunityContext/Sources/QuotationAggregate/Usecase/Service/*Service.swift`
  - OC ground truth Usecase protocol: `~/JiaBao/Mendesky/OpportunityContext/Sources/QuotationAggregate/Usecase/Port/In/*/CreateQuotationUsecase.swift`
  - DDD-kit event.yaml samples: `.build/checkouts/swift-ddd-kit/samples/*/Sources/event.yaml`
  - Current Service template: `Sources/GenesisCore/Resources/Templates/v0.1/Service.swift.template`
  - Current Usecase template: `Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template`
  - Current event.yaml renderer: `Sources/GenesisCore/AggregateRenderer.swift` (`renderEventBlock`)
  - /usecase skill detection logic: `Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md`
  - User memory: `feedback-convention-over-configuration`
---

# Phase 1.o — Hygiene phase

## 議題定義

### 背景

dogfood Layer 2 用 user real IAM bundle 跑 Genesis 揭露 5 個 finding。Phase 1.n 已 ship F4 (type ownership routing) + F1 (validator wording reframe)。剩餘 3 個 finding（F2 / F3 / F5）合做為 hygiene phase。

寫 Phase 1.o discussion 過程中 deep-verify OC ground truth 揭露 **原 F3 認知錯誤** + **2 個額外 Genesis-vs-OC divergence**。F3 重新定義後與 F2 重疊（合併），總共 5 個 hygiene fix。

### Genesis vs OC ground truth 差異

| 項目 | Genesis 現況 | OC ground truth | 嚴重度 |
|---|---|---|---|
| **Service 宣告** | `package final class {UC}Service: {UC}Usecase` | `package struct {UC}Service: {UC}Usecase` | 中（值類型 vs 引用類型差異有語意） |
| **Usecase protocol syntax** | `protocol {UC}Usecase: Usecase<{UC}Input, {UC}Output>` | `protocol {UC}Usecase: Usecase where Input == {UC}Input, Output == {UC}Output` | 低（純語法差異，Swift 兩種皆合法） |
| **extension execute() body** | `// GENESIS-STUB: ...` + `fatalError("not implemented")` | 直接是真實業務邏輯（由 user / /usecase skill fill） | 低（marker 不一致，但 fill 機制正確） |
| **event.yaml properties** | array shape `properties: - name: X / type: "Y"` | DDD-kit upstream sample 全用 map shape `properties: X: "Y"` | 低（DDD-kit 0.3.0 backward-compat 兩格式皆接受） |

### 業務認知修正

**原 F3 finding**（dogfood 2026-05-26 紀錄）：「Service class 空殼 → 加 execute() stub」。

**重新查 OC ground truth（2026-05-27）**：OC Service 本來就**空殼**（只有 init + stored properties），execute() body 是放在 **protocol extension** 內。Genesis 既有 `extension {UC}Usecase { execute() body with fatalError stub }` pattern **是對的**，符合 OC。

**真正的 F3 問題**：Service 用 `class` 而非 `struct`、protocol 用 `Usecase<I, O>` 而非 `where Input == I, Output == O` — 兩個 OC alignment defect。

### 目標

把以下 5 個 hygiene fix 一次 ship：

1. **F2** TODO marker 統一：`fatalError("not implemented")` + `// GENESIS-STUB:` 雙重 marker → `fatalError("TODO(/usecase skill)")` 單 marker（對齊 `/api` / `/presenter-fill` / `/readmodel-mutation` 三 skill 既有 pattern）
2. **F3a** Service 宣告：`package final class` → `package struct`（OC 對齊）
3. **F3b** Usecase protocol syntax：`Usecase<I, O>` → `Usecase where Input == I, Output == O`（OC 對齊）
4. **F3c** extension execute() stub wording：`fatalError("not implemented")` + GENESIS-STUB 註解 → `fatalError("TODO(/usecase skill)")`（與 F2 重疊；單一 markerline）
5. **F5** event.yaml properties array shape → map shape with all values quoted（對齊 DDD-kit upstream sample）

完成後：
- `genesis new` 出來的 Service / Usecase / event.yaml byte-aligned to OC + DDD-kit sample convention
- `grep -r 'fatalError("TODO'` 一次找到所有 fill target（不需要記兩個 marker）
- /usecase skill 仍能正常運作（detection logic 同步更新）

### 範圍

#### 討論內

- `Service.swift.template`：class → struct
- `Usecase.swift.template`：protocol syntax + extension fatalError marker + remove GENESIS-STUB comment
- `AggregateRenderer.renderEventBlock`：array shape → map shape, all values quoted
- `/usecase` skill SKILL.md：detection markers update (`not implemented` → `TODO(/usecase skill)`)
- 既有 unit tests + integration tests 對應更新

#### 討論外

- 不重新設計 OC pattern 本身（OC putting biz logic in protocol extension 是 OC 選擇，本 phase 不 challenge）
- 不改 /api skill / /presenter-fill skill / /readmodel-mutation skill（這三個 skill 已使用統一的 `TODO(<skill>)` marker，不需動）
- 不改 Cosmogony emit（不在 Genesis repo scope）
- 不改 KurrentDB stream subscription / Server runtime 行為
- 不引入新 Service 變體（OC 有時 Service 多帶 `validator` dependency；本 phase 不支援，留 v2）

### 約束

- 對齊 OC：所有改動須與 `~/JiaBao/Mendesky/OpportunityContext` 既有 Service / Usecase / event.yaml 結構一致
- 對齊 DDD-kit upstream：event.yaml 對齊 `swift-ddd-kit/samples/*/Sources/event.yaml` map shape
- /usecase skill detection 必須繼續正確運作（不破壞 fill flow）
- 既有 fixture / integration test 期望值若因 codegen 結構改變而失準，顯式更新（不引入隱含 fallback）
- 沒有 backward compat 包袱：Phase 1.l/1.m 剛 ship，無「舊版生成的 Genesis project」回收問題

---

## 決策紀錄（2026-05-27 lock）

### D1. F2 TODO marker 統一

`extension {UC}Usecase { execute(...) }` 內 stub body：

```swift
// Before (current)
extension {UC}Usecase {
    package func execute(input: ...) async throws -> ... {
        // GENESIS-STUB: pattern is `repository.find → aggregate.{useCaseCamelCase}(...) → repository.save → return Output`.
        fatalError("not implemented")
    }
}

// After (Phase 1.o)
extension {UC}Usecase {
    package func execute(input: ...) async throws -> ... {
        fatalError("TODO(/usecase skill): pattern is repository.find → aggregate.{useCaseCamelCase}(...) → repository.save → return Output")
    }
}
```

**理由**：
- 對齊 `/api` / `/presenter-fill` / `/readmodel-mutation` 既有 `fatalError("TODO(<skill>)")` 單 marker pattern
- `grep -r 'fatalError("TODO'` 一次找到所有 fill targets
- pattern hint 從註解搬進 fatalError 訊息本身（執行時直接看到）
- 移除 `// GENESIS-STUB:` 註解，減少 codebase noise

### D2. F3a Service struct vs class

`Service.swift.template`：

```diff
- package final class {UC}Service: {UC}Usecase {
+ package struct {UC}Service: {UC}Usecase {
      package let repository: {Aggregate}Repository

      package init(repository: {Aggregate}Repository) {
          self.repository = repository
      }
  }
```

**理由**：OC 對齊（`CreateQuotationService` / `EditLetterContentService` / `HidePaymentItemSupplementaryNoteService` 全為 `package struct`）。

**Service struct 設計理由**（OC 風格）：
- Service 沒可變狀態（只有 immutable repository 引用）
- 不需要 identity（struct value semantics 自然 fit）
- protocol conformance 可直接 satisfied
- `final` keyword 多餘（struct 隱含 final-ish）

### D3. F3b Usecase protocol syntax align OC

`Usecase.swift.template`：

```diff
- package protocol {UC}Usecase: Usecase<{UC}Input, {UC}Output> {
+ package protocol {UC}Usecase: Usecase where Input == {UC}Input, Output == {UC}Output {
      var repository: {Aggregate}Repository { get }
  }
```

**理由**：對齊 OC。兩種語法 Swift 都接受，但 OC `where` 語法是 DDDKit 0.3.0 + OC convention，跟 user 自己 maintain 的 protocol 風格一致。

### D4. F3c extension execute() stub（與 D1 重疊）

`Usecase.swift.template` 的 extension 部分：

```diff
  extension {UC}Usecase {
      package func execute(input: {UC}Input) async throws -> {UC}Output {
-         // GENESIS-STUB: pattern is `repository.find → aggregate.{useCaseCamelCase}(...) → repository.save → return Output`.
-         fatalError("not implemented")
+         fatalError("TODO(/usecase skill): pattern is repository.find → aggregate.{useCaseCamelCase}(...) → repository.save → return Output")
      }
  }
```

**理由**：與 D1 為同一改動，於 Usecase.swift.template 一次落地。

### D5. F5 event.yaml properties map shape with all quoted

`AggregateRenderer.renderEventBlock`：

```swift
// Before
propLines.append("    - name: \(field.name)")
propLines.append("      type: \"\(resolved)\"")

// After
propLines.append("    \(field.name): \"\(resolved)\"")
```

**user fallback case**（原 propLines.isEmpty 分支）：

```swift
// Before
propLines.append("    - name: \(alias)")
propLines.append("      type: \"String\"")

// After
propLines.append("    \(alias): \"String\"")
```

**輸出範例**：

```yaml
# Before (current array shape)
PrivilegeGranted:
  kind: domainEvent
  aggregateRootId:
    alias: useraccessprofileId
  properties:
    - name: userId
      type: "String"
    - name: permissions
      type: "[String]"

# After (Phase 1.o map shape with all quoted)
PrivilegeGranted:
  kind: domainEvent
  aggregateRootId:
    alias: useraccessprofileId
  properties:
    userId: "String"
    permissions: "[String]"
```

**Quote 規則（user 拍板 = B 全部加 quote）**：所有 type value 統一加 double-quote，無條件 quote。Reason：
- 邏輯簡單 — 不需要動態檢測 YAML special char
- 一致性 — 不會有「為什麼這個有 quote 那個沒有」疑問
- 安全 — 永遠不會遇到 YAML parser flow-sequence 誤判（e.g. `[String]` 被解為 flow sequence 而非 string literal）
- DDD-kit upstream sample 是 bare（`customerId: String`）但 Genesis 走更保守的全 quote pattern；DDD-kit parser 接受兩者

### D6. /usecase skill detection logic 同步更新

`Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md`：

- 「未填」detection: `fatalError("not implemented")` + `// GENESIS-STUB:` → `fatalError("TODO(/usecase skill)")`
- 「已填」detection: 不含 `fatalError("TODO(/usecase skill)")`（含 `repository.find` 或 aggregate method call）
- description 第一段 / Step 規則 / 範例 fill body 全部對齊新 marker

**理由**：codegen 改 marker 後，skill 不更新會 forever 認為「未填」（找不到舊 marker）。同 PR 處理避免分裂兩 phase。

### D7. 命名：Phase 1.o

統一命名 Phase 1.o（前一個是 1.n）。不用 1.f.3 / 1.l.2 之類 sub-phase 命名。

---

## 預估工作量

| 項目 | 工 |
|---|---|
| Service.swift.template 改（D2） | 5 分鐘 |
| Usecase.swift.template 改（D3 + D4） | 10 分鐘 |
| AggregateRenderer.renderEventBlock 改（D5） | 15 分鐘 |
| /usecase SKILL.md 同步（D6） | 30 分鐘 |
| 既有 UseCaseRendererTests / AggregateRendererTests 期望值更新 | 30 分鐘 |
| Integration test fixture 重生 + assertion 更新（如 NewCommandTests 含 Service "class" 字串 assertion） | 30 分鐘 |
| /usecase skill BundleAppender 或 InstallerTests 若依賴 marker | 15 分鐘 |
| write-spec + audit-spec --quick + 修正 round | 30 分鐘 |
| pickup full chain implementation | 1-2 小時 |

**總計：~3-4 小時**

---

## 下一步

1. ✅ Discussion MD ready（status: ready）
2. → `/write-spec docs/discussions/2026-05-27-phase-1o-hygiene.md`
3. → write-spec 自動 chain 到 audit-spec
   - Spec 預估 ~200-250 行 → 可用 `--quick` 跳過外部 Codex（內部 4b/5b 仍跑）
4. → audit-spec PASS → status: ready
5. → `/pickup` 走完整 chain（Codex 主刀，預估 ~1.5 小時，比 Phase 1.n 短因為改動量小）
