---
topic: Dogfood findings — IAM Context Bundle (Layer 2 sandbox, 2026-05-26)
status: triage（未轉 spec，等使用者選優先級）
date: 2026-05-26
origin: 第一次拿 user 自家 real bundle 跑 Layer 2 dogfood
references:
  - Bundle: `~/Downloads/IAM Context Bundle.json`
  - Sandbox: `/tmp/genesis-sandbox-iam/IAMContext/`
  - OC ground truth: `~/JiaBao/Mendesky/OpportunityContext/`
  - Brain log: `~/brain/raw/projects/genesis/2026-05-26.md` §[15:19]
---

# Dogfood findings — IAM Context Bundle

## 任務定位

第一次拿 user **真實** bundle（非 test fixture）跑 Genesis 完整 chain Layer 2（codegen + swift build，不含 fill / runtime）。Bundle 是 Cosmogony Event Storming Tool 匯出，user 自己定的業務語意，反映 Genesis 之前沒測過的真實使用模式。

### Bundle profile

```
Context:    IAMContext
Aggregates: UserAccessProfile (1)
UseCases:   7 (createUserAccessProfile / grantPrivilege / revokePrivilege /
                assignRoles / revokeRoles / promoteUser / transferDepartment)
Presenters: 0
ReadModels: 0
Pattern:    write-only context
```

### 結果

- ✅ 86 files generated
- ✅ `swift build` PASS（69.75s）
- ✅ `IAMContextServer` executable 真 link 出來
- ✅ Server entry 符合 Phase 1.m 預期
- ⚠️ 4 個結構性 finding（見下）

### 教訓

**Test fixture ≠ real bundle dogfood**。同樣是 IAMContext，`iam-cross-agg-presenter-bundle.json`（test fixture，Genesis 開發者手刻）與 user 自家 `IAM Context Bundle.json`（Cosmogony 匯出 + 業務語意）打到完全不同的角落。Fixture 暗合 Genesis 假設，real bundle 把假設打破 — dogfood 一次就抓到 4 個結構性缺口，每個都是 productizable，不是 one-off bug。

---

## Finding F1 — payload→state naming validator error message 誤導（reframed 2026-05-26）

### 現象

```
✗ bundle is invalid: createdEvent payload field(s) ["initialPermissions", "initialRoles"]
  have no matching state in aggregate 'UserAccessProfile'; adapter mapping required
  (not supported in Phase 1.e)
```

### Bundle 觸發語意

User real bundle `createUserAccessProfile.eventPayload` 用 `initialPermissions/initialRoles`（provenance prefix），但 aggregate state 是 `permissions/roles`。

### Reframe（user 決定 2026-05-26）

原本提案是「開 Phase 1.n 寫 adapter rename 機制」（1-2 天工）；user 認為 bundle 該 1:1 對齊 aggregate state naming，這個 mismatch 是**bundle 作者命名失誤**，不是 Genesis 該支援的功能：

- ✅ OC ground truth 所有 bundle 都 1:1 命名，沒任何 adapter rename
- ✅ Convention over configuration — bundle 跟 aggregate 認知一致比 codegen 複雜度低
- ✅ 跟 EventSourcing 派別中性決策一致（`initial*` provenance prefix 是合理慣例但**非必要**，team 選一條 stick 即可）
- ✅ 已存入 user memory: `feedback-convention-over-configuration`

### Genesis 真正該做的事

僅改 validator error message — 把錯誤訊息從「adapter mapping required (not supported in Phase 1.e)」改成清楚告訴使用者**該怎麼修 bundle**：

```diff
- have no matching state in aggregate 'UserAccessProfile';
- adapter mapping required (not supported in Phase 1.e)
+ have no matching state in aggregate 'UserAccessProfile'.
+
+ Fix: rename the event payload field(s) to match aggregate state names,
+ OR add the missing field(s) to aggregate state in bundle.
+
+ Genesis enforces 1:1 naming between event payload and aggregate state
+ (aligned with OC reference). Field rename via adapter is not supported.
```

同步移除 `AggregateRenderer.swift:146` 的誤導註解 `"deferred to Phase 1.f"`（Phase 1.f 從沒承擔此項，且我們現在決定**永遠不做**）。

### 規模 & 優先級

- 約 **30 分鐘**：改 error message + 移除誤導註解 + 對應 test 更新
- 🟢 **低**：純 hygiene，不阻塞功能
- 適合塞 hygiene phase（與 F2/F3/F5 合做）
- ~~建議命名：Phase 1.n / 1.f.2~~ → **取消單獨命名，併入 hygiene phase**

---

## Finding F2 — TODO marker 不一致

### 現象

```bash
$ grep -rn 'fatalError("TODO' Sources/ | wc -l
14    # 只看到 /api skill 的 14 個（7 AS + 7 ApiHandler route）

# 真正待 fill 的 Usecase 7 個 stub 被漏算
$ grep -rln 'GENESIS-STUB' Sources/
... 7 個 Usecase protocol extension default impl ...
```

### 兩種 marker 並存

| Renderer | 位置 | Marker |
|---|---|---|
| ApiHandlerRenderer | `<UC>ApplicationService.swift` + `ApiHandler.swift` | `fatalError("TODO(/api skill)")` |
| UseCaseRenderer | `<UC>Usecase.swift` 的 protocol extension default impl | `// GENESIS-STUB: ...` + `fatalError("not implemented")` |

### 影響

- Standard `grep TODO` 看不到 Usecase 待 fill
- `genesis status`（若未來做）統計待 fill 量會少算
- 使用者讀 codebase 認知負擔：兩種 pattern 都要記
- 新 fill skill 加進來時 convention 沒統一

### 修法方向

統一成 `fatalError("TODO(/usecase skill)")` 一致 marker。同步：
- 移除 `// GENESIS-STUB:` 註解（marker 自說明）
- 或保留註解作為 hint，但 `fatalError` 訊息對齊

### 規模 & 優先級

- 約 1 小時工：改 1 個 template + 對應 renderer test 期望值
- 🟡 **中**：UX/convention 問題，不影響功能
- 建議：跟 F3 合併做（同 area，同 commit）

---

## Finding F3 — Service class 空殼，無 execute() signature stub

### 現象

```swift
// Sources/UserAccessProfileAggregate/Usecase/Service/CreateUserAccessProfileService.swift
package final class CreateUserAccessProfileService: CreateUserAccessProfileUsecase {
    package let repository: UserAccessProfileRepository

    package init(repository: UserAccessProfileRepository) {
        self.repository = repository
    }
    // ← 沒 execute() 簽名！protocol extension 的 default impl 才是 fatalError 位置
}
```

### 為何今天能 swift build 過

- Protocol extension 提供 default impl（`fatalError("not implemented")`）
- Service 不 override 也滿足 protocol conformance
- runtime 跑到才會 crash

### 影響

- `/usecase` skill 必須完整推導 `execute(input:) async throws -> Output` 簽名（型別、async/throws、param label）
- 使用者讀 Service.swift 看不到「這裡要填什麼」的線索
- 與 AS pattern 不對稱（AS 是顯式 stub body）

### OC 對齊

OC 的 Service class 內**明確** override `execute(input:)`，Service.swift 自含完整實作而非空殼：

```swift
// OC reference (pseudo)
package final class EditPaidInCapitalService: EditPaidInCapitalUsecase {
    package let repository: QuotationRepository

    package init(...) { ... }

    package func execute(input: EditPaidInCapitalInput) async throws -> EditPaidInCapitalOutput {
        // 真實實作
    }
}
```

### 修法方向

UseCaseRenderer 的 Service.swift.template 加 `execute()` stub：

```swift
package func execute(input: {UC}Input) async throws -> {UC}Output {
    fatalError("TODO(/usecase skill)")
}
```

同步：移除 protocol extension 的 default fatalError impl（避免雙重 stub）。

### 規模 & 優先級

- 約 2-3 小時工：改 Service.swift.template + UseCaseRenderer 加 placeholder + 修對應 test 期望 + 確認 /usecase skill 行為（spec 應寫「找 Service 內既有 stub override」而非「protocol extension 內 default」）
- 🟡 **中**：functional 正確（runtime crash 而非 silent fail），但對齊 OC + 改善 onboarding
- 建議：跟 F2 合併

---

## Finding F4 — Custom type ownership routing（aggregate-private vs cross-aggregate）

### 現象

```
Sources/IAMContextShared/EmployeeStatus.swift   ← 錯位
```

但 `EmployeeStatus` 只被 `UserAccessProfile.state.status` 用，沒跨 aggregate。

### OC 對齊

| OC 路徑 | 屬性 |
|---|---|
| `Sources/CompanyRegistrationQuotingAggregate/QuotingStatus.swift` | 只 1 個 aggregate 用 → aggregate folder |
| `Sources/OCShared/OrganizationType.swift` | 多 aggregate 共用 → Shared |
| `Sources/OCShared/AccountingTypeDto.swift` | 多 aggregate 共用 → Shared |
| `Sources/OCShared/FileType.swift` | 多 aggregate 共用 → Shared |

決策規則：**type 被幾個 aggregate 引用** → 1 個放 aggregate folder，≥2 或無 owner（純 infra）放 Shared。

### Genesis 現況

`SharedTargetRenderer.swift:47`：

```swift
for dto in bundle.dtos where !emittedNames.contains(dto.name) && dto.isContextShared { ... }
```

- `isContextShared` 預設 true → 所有 DTO 一律 Shared
- 沒有 ownership 推算邏輯（沒掃 aggregate state / events / UC input / output 反查 type 引用方）
- `DtoSpec` 也沒「我屬於哪個 aggregate」欄位

### 修法方向

新增 type ownership resolver：

```
for each customType in (bundle.dtos + adapter.customTypes):
    refs := scan all aggregates' state / events / commands / UC input/output /
            presenters / readModels / 其他 DTO fields，
            找出引用此 type 的 aggregate 集合
    if refs.count == 1:
        route to Sources/<refs[0]>Aggregate/
    elif refs.count >= 2 or refs.count == 0:
        route to Sources/<Context>Shared/
    adapter.customTypes 顯式 owner override（若有）以 adapter 為準
```

涉及：
- 新增 `TypeOwnershipResolver.swift`（約 80-120 行）
- `SharedTargetRenderer` integrate resolver，按 owner 分發
- AggregateRenderer 需 import 自家產出的 type（今天可能透過 Shared 間接 import，要改成 same module）
- Tests: unit (resolver) + integration (real bundle 端到端驗證 EmployeeStatus 在 UserAccessProfileAggregate/)

### 規模 & 優先級

- 約 1-2 天工
- 🟡 **中-高**：codegen 結構正確性，影響 OC 對齊
- 建議命名：**Phase 1.o** 或 **Phase 1.f.3**

---

## Finding F5 — event.yaml 落後 DDD-kit upstream sample 慣例（array shape → map shape）

### 現象

Genesis 生的 `Sources/<X>Aggregate/event.yaml` `properties` 用 array of name/type 對：

```yaml
properties:
  - name: userId
    type: "String"
  - name: permissions
    type: "[String]"
```

DDD-kit 0.3.0 上游 samples（`samples/KurrentTransactionalProjectionDemo/Sources/event.yaml` 等三份）全部用 **map shape**：

```yaml
properties:
  customerId: String
  totalAmount: Double
```

### 兩種都能跑（今天）

Layer 2 build pass 證明 DDD-kit 0.3.0 backward-compat 兩邊都接受。但 upstream sample = 新慣例。

### 修法

`Sources/GenesisCore/AggregateRenderer.swift:293-306` 的 `renderEventBlock()`：

```swift
// 現況
propLines.append("    - name: \(field.name)")
propLines.append("      type: \"\(resolved)\"")

// 改後
propLines.append("    \(field.name): \(quoteIfNeeded(resolved))")
// quoteIfNeeded：對 [X]、{X: Y} 之類含 YAML-special char 的 type 加 quote
// 否則裸寫（對齊 sample：customerId: String）
```

### 影響 & 規模

- 只動 1 function（約 10 行）
- 對應 fixture / snapshot test 更新（2-3 處）
- `projection-model.yaml` 不受影響（events 本來就是 list，不該變 map）
- context-level event.yaml 內容 `{}`（empty）不受影響

約 **1 小時工**。

### 為什麼今天會用舊格式

歷史脈絡推斷：Phase 1.b/1.c Aggregate renderer 寫的時候 DDD-kit upstream 還沒切 map（或是看了某個更早 sample）。沒有 backward-compat 拔時沒人注意到。

---

## 優先級總表 & 建議下一步（reframed 2026-05-26）

| Finding | 嚴重 | 工作量 | 阻塞 dogfood？ | 建議 |
|---|---|---|---|---|
| F4 type ownership routing | 🟡 中-高 | 1-2 天 | 否（會錯位但 build 過） | **下一步先做** |
| F1 validator error message（reframed） | 🟢 低 | 30 分鐘 | 否（user 已改 bundle） | hygiene phase 合做 |
| F2 + F3 TODO marker + Service stub | 🟡 中 | 半天合做 | 否 | hygiene phase 合做 |
| F5 event.yaml map shape | 🟢 低 | 1 小時 | 否（backward-compat 跑得過） | hygiene phase 合做 |

### 新 Path X（F1 reframe 後）

```
原: F1 (Phase 1.n) → F4 (Phase 1.o) → F2+F3+F5 (Phase 1.p)
新: F4 (Phase 1.n) → F1+F2+F3+F5 (Phase 1.o, hygiene 合集)
```

### 兩條 path 選擇

#### Path X — 全部修完再繼續 dogfood

序：F1 → F4 → F2+F3 → 重跑 Layer 2 → Layer 3 fill
代價：~3-5 天，dogfood 暫停
好處：拿 clean codegen 進 Layer 3，避免錯位 finding 干擾真實 fill 階段問題

#### Path Y — 繼續 dogfood，平行收集 finding

序：先 Layer 3 fill（手動繞 F1 / 容忍 F4）→ 累積到 6-8 個 finding 後 batch 寫 spec
代價：fill 過程要繞 F1（手改 bundle）、F4（手動 mv 檔案，會被下次 codegen 蓋掉）
好處：盡量榨真實使用反饋，spec 一次寫完批次精準度高

### 我建議 Path X

理由：
1. F1 是 hard block，繞它要動 bundle，污染 dogfood 樣本
2. F4 codegen 錯位會讓 Layer 3 `/usecase`/`/api` skill 找不到 import 路徑（你今天 build pass 是因為 import 路徑湊巧對；fill skill 動到時可能爆）
3. 三個 finding 累積反而比一次做累

---

## 待 user 決定

- [ ] Path X 還是 Path Y？
- [ ] F1 命名（Phase 1.f.2 還是 Phase 1.n？）/ F4 命名（Phase 1.o 還是 Phase 1.f.3？）
- [ ] F2+F3 是合併成 1 個 task（短 spec）還是各自寫 spec？
- [ ] 哪個是下一個進 write-spec 流程的？
