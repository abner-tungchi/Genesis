---
topic: Phase 1.f — Genesis bootstrap ContextShared infra
status: consensus
date: 2026-05-18
origin: inline brief（無多 agent discussion round）
predecessor: Phase 1.e (Genesis bootstrap done) + /api skill v1 spec (blocked, draft)
references:
  - Gemini facts report 2026-05-18 (OC OCShared/ inventory)
  - Codex audit of /api skill v1 spec (revealed missing infra)
  - OC `/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/OCShared/`
---

# Phase 1.f — Genesis bootstrap ContextShared infra

## 議題定義

### 背景

`/api` skill v1 spec 跑完 Codex 外部審查揭露 fundamental scope gap：spec 假設 `ApplicationService` 協議、`Iso8601ParsingError`、`ContextError<E>` 等是 DDDKit 內建，**但實際它們住在 OC 自家 `OCShared/`（context-local infra）**。Genesis Phase 1.e 沒 bootstrap 這層，IAMContextShared 缺它，導致 `/api` 生成的 code 無法 compile。

User 決定（2026-05-18）：先停 /api skill spec，做 **Phase 1.f** 讓 Genesis 補 ContextShared infra → 解除 /api（及後續 `/usecase` / `/readmodel`）的 dependency。

Gemini facts report 跨讀 `OCShared/` 26 個檔，分類為：
- **CORE**（5 個）：ApplicationService、ContextError、Iso8601 helpers、ProjectionReadInconsistency、InvalidDecimalStringError — 任何 DDD/ES 專案都需要
- **CONVENTION**（4 個）：String+IsBlank（全形空格 aware）、String+PascalCase、String+StrippingPrefix、README charter
- **OC-SPECIFIC**（17 個）：AggregateRootNames、Quoting/Accounting/Pricing 等 OC 業務 DTO、ConfigKey/Value union — 不 bootstrap

### 目標

Genesis Phase 1.f 在 `Sources/{Ctx}Shared/` 自動 bootstrap 9 個 generic infra 檔（不含 user-specific DTO），讓後續 `/api` / `/readmodel` / `/usecase` skills 可依賴它們存在。完成後產出專案應該：

1. `swift build` 仍通過（與 Phase 1.e 標準同）
2. `Sources/{Ctx}Shared/` 含 9 個 bootstrap 檔 + 既有 DTO（從 bundle 來）
3. `/api` skill 解除 blocker，回頭修剩 H1/H2/H4 + M1/M2 + L1 後 ready

### 範圍

#### 討論內（in scope for Phase 1.f）

- bootstrap 9 個檔（見 Decision 1 完整 list）
- modify Phase 1.e templates / renderers 必要時（e.g. SharedTargetRenderer 新增 infra emission；PackageRenderer 已 cover `{Ctx}Shared` target — 不動）
- 加 Genesis-authored README.md 到 `{Ctx}Shared/`（mirror OC 慣例）
- 對 Phase 1.e 既有的「DTO + customType emit」邏輯不破壞
- 對 `/tmp/phase1e-manual` 跑 regression `swift build` 驗證
- 更新 docs/decisions.md + docs/architecture.md ratify Phase 1.f
- 解除 `/api` spec 的 H3 + H5 blocker

#### 討論外（Non-goals for Phase 1.f）

- 不 bootstrap `DtoConversionError`（cases reference OC DTOs；defer 給 `/api` 或 future `/dto-union` skill 在需要時生）
- 不 bootstrap `TimeZoneConstants.taipei` / `Calendar.taipei`（Taiwan-conventional；user 自行加）
- 不 bootstrap OC-SPECIFIC business DTOs（AggregateRootNames、QuotingBundleType、ConfigKey* 等 — 全 17 個 skip list）
- 不 bootstrap FileType / FileTypeDto（presupposes file uploads；future `/file` skill）
- 不寫 `Decimal.parse(_:)` 完整 throwing helper（只 ship `InvalidDecimalStringError` marker，匹配 OC 現況；user 自行加 helper）
- 不寫 ContextShared 的 unit tests（cheap to defer；spec 寫作期 spot-check 即可）
- 不修 `/api` skill spec 本身（Phase 1.f 完之後 /api spec 自己 revise）
- 不破壞 Phase 1.b/1.c 既有的 DTO-from-bundle emission（new infra **co-exist** 而非取代）

### 約束

1. **保持 Phase 1.e 既有 build 正常**：所有改動完後 `swift test` 仍 129/129 PASS（+ Phase 1.f 新增測試），`/tmp/phase1e-manual` swift build 通過
2. **OC 為 ground truth**：CORE 檔以 OC `OCShared/` verbatim 為基準，僅 doc-comment 中譯英、context-name placeholder 換掉
3. **`package` access modifier**：所有 bootstrap 檔皆 `package`（與 OC + Phase 1.e Aggregate template 慣例一致）
4. **不可破壞 idempotent re-run**：Genesis Phase 1.e 已加 manifest-version preflight；Phase 1.f bump templateVersion → 舊 dir 重跑會被 preflight reject（預期行為）

## 決策紀錄

### Decision 1: Phase 1.f shopping list（9 個檔）

**已 lock**（per Gemini facts report § 7 definitive list）

| 編號 | Path | Source | 改寫程度 |
|---|---|---|---|
| 1 | `Sources/{Ctx}Shared/ApplicationService.swift` | OC verbatim | doc-comment 中譯英 |
| 2 | `Sources/{Ctx}Shared/ContextError.swift` | OC verbatim | 不動 |
| 3 | `Sources/{Ctx}Shared/Iso8601.swift` | OC `Date+ISO8601.swift` 部分 | 拆出：保留 Iso8601ParsingError + Date(iso8601:) + iso8601String + parseIso8601；**移除** TimeZoneConstants.taipei + Calendar.taipei；timezone 預設改 `.gmt` |
| 4 | `Sources/{Ctx}Shared/ProjectionReadInconsistency.swift` | OC verbatim | 不動 |
| 5 | `Sources/{Ctx}Shared/InvalidDecimalStringError.swift` | OC `Decimal+Parsing.swift` 拆出 | 不動 |
| 6 | `Sources/{Ctx}Shared/String+IsBlank.swift` | OC verbatim | 不動（全形空格 awareness 保留，無害） |
| 7 | `Sources/{Ctx}Shared/String+PascalCase.swift` | OC verbatim | 不動 |
| 8 | `Sources/{Ctx}Shared/String+StrippingPrefix.swift` | OC verbatim | 不動 |
| 9 | `Sources/{Ctx}Shared/README.md` | Genesis-authored | mirror OC `OCShared/README.md` charter（neutral 化、移除 OC-specific 例子） |

### Decision 2: Timezone strategy

**已 lock**

- **移除** OC 的 `TimeZoneConstants.taipei` + `Calendar.taipei`（Taiwan-conventional）
- `parseIso8601(_:timeZone:)` 預設改 `.gmt`（forward-compat、安全）
- 文檔 README 提醒「若需 project-wide 時區，user 自行加 `TimeZoneConstants.swift` 並改 call sites」
- 不從 bundle.yaml 讀 `projectTimezone:`（YAGNI；user 用到時自加）

### Decision 3: Decimal helper 範圍

**已 lock**

- 只 ship `InvalidDecimalStringError` empty marker（匹配 OC 現況）
- **不**生成 `Decimal.parse(_:)` throwing helper（OC 也沒有，inline 用 `Decimal(string:)`；user 自行加 wrapper）
- 檔名：`InvalidDecimalStringError.swift`（OC 把它放 `Decimal+Parsing.swift` 是 misleading，重新命名更清楚）

### Decision 4: DtoConversionError — DEFER

**已 lock**

- 不 bootstrap（cases 引用 OC 業務 DTO，無 generic 等價物）
- 留給 `/api` skill 或 future `/dto-union` skill 在偵測到「cross-aggregate union DTOs」時 per-bundle 生成
- 預設 generic shape（若實作時需）：`enum DtoConversionError<Dto: Equatable>: Error { case foreign(Dto) }`

### Decision 5: ProjectionReadInconsistency — 早 ship

**已 lock**

- 雖然主要是 `/readmodel` skill 用，但只 19 LoC 零依賴，現在 ship 比 later patch 便宜
- 統一「ApiHandler catch 一組 known error types」的 contract，避免後續 skill 加它時打破 stable infra

### Decision 6: 全部 `package` access

**已 lock**

- 所有 bootstrap 檔 `package` modifier（與 OC + Phase 1.e Aggregate / Repository / event template 慣例一致）
- 例外：README.md 是 markdown，無 modifier
- 對應 Phase 1.e PackageRenderer 已把 `{Ctx}Shared` 設為同 package 內 target，跨 target 看到 `package` symbol 沒問題

### Decision 7: Genesis-authored README

**已 lock**

- 寫一份 neutral 英文 README，內容大致：
  - 模組職責：「pure data types + generic utils；no domain behavior, no transport binding」
  - 該 ship 進來的 3 個 yes/no 判準（mirror OC § 「加 type 決策樹」）
  - 列出 9 個 Genesis bootstrap 檔
  - 加 type 範例（user 該怎麼擴）
- 不複製 OC 中文 README（Genesis 是工具，user-facing 語言 neutral）

### Decision 8: Templates 機制

**已 lock**

- 所有 9 個檔放 Genesis 端 `Sources/GenesisCore/Resources/Templates/v0.1/Shared/`（既有 v0.1/ 結構下）
- SwiftFile 用 `.template` 後綴（即使無 placeholder 也統一處理）
- README.md 用 `.template` 後綴（含 `{ContextName}` placeholder for 標題）
- 新增 `SharedInfraRenderer.swift`（或擴 SharedTargetRenderer）負責 emit 9 個檔
- 既有 SharedTargetRenderer 的 DTO/customType emission 邏輯**不動**；infra emission 是新加的 step

### Decision 9: Bump templateVersion

**已 lock**

- `GenesisCoreVersion.current`: `0.1.0-phase1e` → `0.1.0-phase1f`
- 舊 dir（phase1e manifest）重跑 → manifest-version preflight 拒絕（per Phase 1.e Step 11，預期行為）
- 文檔（README + 失敗訊息）標明：phase1e → phase1f 不支援 in-place migration，user remove dir 重跑

## 開放問題

以下 spec 寫作期 step 3b 確認/補：

1. **`SharedTargetRenderer` 還是 `SharedInfraRenderer`？** OC 既有命名是 `SharedTargetRenderer`（負責 DTO + customType emission）。Phase 1.f 加 infra emission 該擴 existing 還是新建？建議：擴 existing（避免 2 個 renderer 共寫 `{Ctx}Shared/`，risk of duplicate-file conflict）
2. **needsShared 條件擴**：Phase 1.e `PackageRenderer.needsShared = !bundle.dtos.isEmpty || !adapter.customTypes.isEmpty`。Phase 1.f infra **總是** emit（不論 bundle 有無 DTO）→ `needsShared = true` always？或保留 conditional？建議：infra 是 universal，always emit，PackageRenderer needsShared 改為 `true` always（簡化邏輯，trade-off 是空 DTO bundle 也會建 Shared/ target，但本來就有 infra 檔填）
3. **OC ContextError.swift 的 `import Foundation`** — Date dependency。Genesis 端 template 直接 ship 同 imports。是否需驗證跨 platform（Linux Foundation）相容？建議：spot-check Linux build 留 Phase 1.f acceptance Human checklist；本身 Foundation 通用 type 應無問題
4. **README.md template 的 `{ContextName}` placeholder**：是否真要動態替換 context name 到標題？建議：是（與其他 .ai/contexts/{Ctx}/README.md 慣例一致）
5. **既有 `/tmp/phase1e-manual` regression test**：Phase 1.f 完成後重跑 `genesis new IAMContext`，**Sources/IAMContextShared/ 應該多 9 個檔**（含 EmployeeStatus.swift）。`swift build` 應仍通過（infra 是 pure-types, 不引新依賴）。建議：spec 加 acceptance bash 自動驗證
6. **是否要把 Phase 1.f bootstrap 的 infra 也加 plugin/codegen？** No — 全部 hand-written code 直接 ship，無 plugin/codegen 處理

## 後續

1. **write-spec**：以本 discussion MD 為輸入，產出 `docs/tasks/2026-05-18-phase-1f-context-shared-infra.md`（8 段 contract-first spec）
2. **audit-spec**：跑 4b + 5b + 5c（Codex 外部審；目標一輪 PASS — 本 task scope 較小，不應有 Phase 1.e 那種 protocol-level drift）
3. **/pickup**：實作 9 個 templates + renderer changes + version bump + docs；測試 + e2e build verify
4. **解除 /api skill blocker**：Phase 1.f 完成後，回頭 revise `docs/tasks/2026-05-18-api-skill.md` 的 H1/H2/H4 + M1/M2 + L1（H3/H5 自動解除），ready 後 /pickup
