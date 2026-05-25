# Phase 1.j — Variant B `init(from payload:)` extension emission (OC-aligned, Date scope)

## 來源

討論：`docs/discussions/2026-05-25-phase-1j-variant-b-extension.md`

OC ground truth：`Sources/AuditQuotingAggregate/Adapter/AddAccounting/AddAccountingApplicationService.swift`（extension 在同 AS file，含 Date `try Date.parseIso8601(...)` + enum DTO `.init(from:)` + array DTO `try .map { try ... }`）+ 對應 handler 短形 `try <UC>Input(from: payload, ...)` + `catch is Iso8601ParsingError → .invalidDateFormat`。

依賴 Phase（全 done）：phase-1f / phase-1h / phase-1i / 2026-05-18-api-skill。

## 目標

對含 Date AS Input field 的 UC，Phase 1.h ApplicationService.swift codegen 額外 emit `extension {UC}ApplicationServiceInput { init(from payload:, ...) throws { ... } }` 到同 AS file 尾部；handler method body 改用短形 `try <UC>ApplicationServiceInput(from: payload, <aggIdName>:, operatorId:)` 取代 inline guard+throw。**純品質改善**：行為不變，與 OC pattern 1:1。

**v1 scope = Variant B-Date only**（plain pass-through + Date / Date? 解析）。Decimal / nested DTO / array DTO 留 v2。

---

## 介面合約

### Bundle schema

無變更。UC.input field type（已 `Date` / `Date?`）為 truth source。

### ApplicationService.swift.template 改動

加新 placeholder `{PAYLOAD_INIT_EXTENSION}`，位置在 `}` (struct end) 與 `package struct {UC}ApplicationServiceOutput` 之間。**Variant A** 時為空字串（無 extension）；**Variant B-Date** 時為：

```swift

extension {UC}ApplicationServiceInput {
    package init(
        from payload: Components.Schemas.{UC}Request,
        {AGG_ID_NAME}: String,
        operatorId: String
    ) throws {
        self.init(
            {AGG_ID_NAME}: {AGG_ID_NAME},
{PAYLOAD_INIT_BODY_LINES}
            operatorId: operatorId
        )
    }
}

```

`{PAYLOAD_INIT_BODY_LINES}` per non-aggId non-operatorId AS Input field：

| field type | emit |
|---|---|
| plain（String/Int/Bool/Optional plain）| `            <f>: payload.<f>,` |
| `Date` / `Date?` | `            <f>: try Date.parseIso8601(payload.<f>),`（Phase 1.f `parseIso8601` 兩 overload 由 Swift 自動 resolve；String→Date / String?→Date?） |

### ApiRenderer 改動

新增 `hasVariantBDate(uc: UseCaseSpec) -> Bool`：對每個 input field（排除 aggIdName + operatorId）的 `SwiftTypeResolver.resolve(rawType)` 結果是 `Date` 或 `Date?` → return true。

新增 `renderPayloadInitExtension(uc:, aggIdName:) -> String`：

- 若 `hasVariantBDate(uc)` 為 false → 回空字串。
- 否則 emit extension block（per F1 OC pattern），逐 field 依型別 substitute。

ApplicationService template render 加 `{PAYLOAD_INIT_EXTENSION}` 變數。

### /api skill v5 升級

SKILL.md v5：

- Phase 3 parse inputs 加：grep AS file 含 `extension {UC}ApplicationServiceInput { init(from payload:` 字樣 → 設 `hasInitFromPayload = true`。
- Phase 4 Variant 偵測沿用 v4（依 AS Input field 型別判 Date/Decimal）。新增分支：若 `hasInitFromPayload && Variant B-Date 純 Date 無 Decimal` → 走「short-form」路徑。
- Phase 5 category 2 emit：
  - **short-form（hasInitFromPayload + Date only）**：
    ```swift
            let asInput: {UC}ApplicationServiceInput
            do {
                asInput = try {UC}ApplicationServiceInput(
                    from: payload,
                    {aggIdName}: {aggIdName},
                    operatorId: operatorId
                )
            } catch is Iso8601ParsingError {
                return .unprocessableContent(.init(body: .json(.init(error: .invalidDateFormat))))
            }
    ```
  - **inline（v4 fallback，無 extension 或含 Decimal）**：維持 v4 邏輯。
- A12 acceptance 加 short-form pattern 偵測（grep `try .*ApplicationServiceInput\($` 之類）。
- known limits 加：Variant B-Decimal 仍走 inline（不走 short-form），直到 v2 擴展 init 支援 Decimal。

### 既有測試 / fixtures 影響

- iam-bundle.json：UC 全 plain String，無 Date → ApiRenderer 對所有 UC `hasVariantBDate=false` → 空 extension → behavior 不變（Variant A path）。既有 Phase 1.h ApiRendererTests 全 PASS。
- /api v4 e2e（無 Date）：handler 仍 inline form（無 extension 偵測）→ v4 behavior 不變。
- 新增 fixture `iam-date-uc-bundle.json` 或派生：1 個 UC 含 Date field，e2e 驗 extension emit + handler 短形 + build pass。

### Exit codes / 失敗路徑

ApiRenderer：無新 exit；型別解析失敗仍走 Phase 1.h 既有 `SwiftTypeResolver` 例外鏈。
/api skill v5：v4 既有 exit codes 全保留；新增 idempotent 判定「已填 short-form」= body 含 `try <UC>ApplicationServiceInput(\n    from: payload,` + `catch is Iso8601ParsingError`。

---

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template` | 加 `{PAYLOAD_INIT_EXTENSION}` placeholder |
| `Sources/GenesisCore/ApiRenderer.swift` | 加 `hasVariantBDate(uc:)` + `renderPayloadInitExtension(uc:, aggIdName:)` + template 變數注入 |
| `Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md` | v5：category 2 短形路徑 + extension 偵測；known limit Decimal 仍 inline |
| `Tests/GenesisCoreTests/ApiRendererTests.swift` | 加 Variant B-Date emission test（Date field UC → extension 含 `try Date.parseIso8601`；no Date → 無 extension） |
| `Tests/GenesisIntegrationTests/Fixtures/iam-date-uc-bundle.json`（or 派生） | **新檔** — 含 Date field UC，real e2e fixture |
| `Sources/GenesisCore/Version.swift` | 不變（與 /api / /presenter-fill / /readmodel-mutation 一致，skill+codegen 改動不 bump） |
| `docs/decisions.md` | Phase 1.j ratification |
| `docs/architecture.md` | §10.15 Variant B short-form flow |
| `docs/tasks/registry/phase-1j-variant-b-extension.json` | **新檔** |

---

## 實作步驟

### Step 1 — Template 加 placeholder

在 `ApplicationService.swift.template` 的 `package struct {UC}ApplicationServiceInput { ... }` 結束的 `}` 與 `package struct {UC}ApplicationServiceOutput` 之間插入 `{PAYLOAD_INIT_EXTENSION}` 行。

### Step 2 — ApiRenderer extension emission

1. 在 `ApiRenderer` 加：
   ```swift
   private static func hasVariantBDate(uc: UseCaseSpec) -> Bool {
       uc.input.contains { f in
           let t = SwiftTypeResolver.resolve(rawType: f.rawType)
           return (t == "Date" || t == "Date?") && f.name != "operatorId" && /* exclude aggIdName via caller */
       }
   }
   ```
   exclude `aggIdName` via passing it in or filtering before.

2. `renderPayloadInitExtension(uc:, aggIdName:) -> String`：若無 Date → ""。否則 emit extension block，逐 non-aggId-non-operator field 依型別 substitute。

3. ApplicationService render call 加：
   ```swift
   "PAYLOAD_INIT_EXTENSION": renderPayloadInitExtension(uc:uc, aggIdName:aggIdName)
   ```

### Step 3 — /api skill v5 SKILL.md 升級

修改 Phase 3 / Phase 4 / Phase 5 / acceptance：

- Phase 3 加 extension 偵測（grep AS file）。
- Phase 4 加 short-form 條件（extension + Date-only Variant B）。
- Phase 5 category 2 emit 短形範例。
- known limit 補：Decimal 仍 inline（v2 候選擴展）。

### Step 4 — Tests + fixture

新 Apple Date UC fixture（最簡：1 aggregate + 1 UC 含 Date field）。ApiRendererTest 驗 extension emit。

### Step 5 — Real E2E

`genesis new` from fixture → ApplicationService.swift 含 extension 區塊 → /api 跑該 UC 填 categories 1/2 → handler 短形 emit → `swift build` PASS。

### Step 6 — Docs

decisions.md Phase 1.j ratification + architecture.md §10.15。

---

## 失敗路徑

| 場景 | 處理 |
|---|---|
| AS Input 無 Date field（Variant A 或 純 Decimal） | extension 空字串，handler 仍 inline（v4 path） |
| AS Input 有 Date field | extension emit；/api v5 走短形 |
| 既有 v4 handler 已 inline 填過 | structural invariant 仍視為「已填」exit 0 skip（不自動升級為短形） |
| Phase 1.h template render 失敗（placeholder undefined） | TemplateRenderer 例外鏈 |

---

## 不改動的部分

- ApiHandlerRenderer 不動（v4 handler method body shape 仍是 codegen scaffold，由 /api skill fill）。
- BundleParser / 既有 schema / Phase 1.i openapi.yaml 不動。
- /readmodel / /presenter / /presenter-fill / /readmodel-mutation 不動。
- write/read codegen chain framework 不動。

### Non-goals（行為層）

- 本 task **不包含** Variant B-Decimal extension（v2 候選）。
- 本 task **不包含** nested DTO / array DTO 自動 emit（v2 候選）。
- 本 task **不包含** Variant A 改用 init(from payload:)（沒理由，無 throws 需求）。
- 本 task **不包含** 自動把 v4 已填的 inline handler 升級為短形（v1 不 retro-upgrade）。
- 本 task **不 bump 版本**。

---

## 驗收標準

### Agent 必做

```bash
# A1. ApplicationService template 含 {PAYLOAD_INIT_EXTENSION} placeholder
grep -F '{PAYLOAD_INIT_EXTENSION}' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApplicationService.swift.template

# A2. ApiRenderer 含 hasVariantBDate / renderPayloadInitExtension
grep -F 'hasVariantBDate' Sources/GenesisCore/ApiRenderer.swift
grep -F 'renderPayloadInitExtension' Sources/GenesisCore/ApiRenderer.swift

# A3. iam-bundle Variant A 不破壞 (regenerate to a tmp dir; AS file should NOT contain extension block)
mkdir -p /tmp/phase1j-va-test
./.build/debug/genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json --output /tmp/phase1j-va-test --no-git --skip-build >/dev/null
! grep -F 'init(from payload:' /tmp/phase1j-va-test/Sources/UserAccessProfileAggregate/Adapter/CreateUserAccessProfile/CreateUserAccessProfileApplicationService.swift

# A4. iam-date-uc-bundle Variant B 含 extension
mkdir -p /tmp/phase1j-vb-test
./.build/debug/genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-date-uc-bundle.json --output /tmp/phase1j-vb-test --no-git --skip-build >/dev/null
grep -F 'init(from payload:' /tmp/phase1j-vb-test/Sources/*/Adapter/*/*ApplicationService.swift
grep -F 'try Date.parseIso8601' /tmp/phase1j-vb-test/Sources/*/Adapter/*/*ApplicationService.swift

# A5. SKILL.md v5 short-form 描述
grep -F 'init(from payload:' Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md
grep -F 'Iso8601ParsingError' Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md
grep -F 'short-form' Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md

# A6. mirror byte-identical
diff Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md ~/.claude/skills/api/SKILL.md

# A7. swift build / tests
swift build
swift test --filter ApiRendererTests
```

### Human 補做

- [ ] real e2e：用 iam-date-uc-bundle 跑 `genesis new` + `/api <ucWithDate>` → 確認 handler emit short-form + extension 已存在 → `swift build` Build complete。
- [ ] iam-bundle 既有 e2e re-run：確認 Variant A 不變、handler 仍 inline、build pass。
- [ ] /api skill v5 對既有 v4 已填 handler 跑 → idempotent exit 0（不自動升級短形）。

---

## 已知限制

1. **Variant B-Decimal 不擴 extension**：仍走 v4 inline handler；defer v2。
2. **nested DTO / array DTO 不擴 extension**：依賴 DTO scaffold + non-throws/throws init pattern；defer v2。
3. **v1 不 retro-upgrade 既有 v4 fills**：handler 已填 inline 的不會自動改 short-form；user 想升級須 manual unfill + 重跑。
4. **與 OC pattern 對齊**：extension 同 AS file（不獨立 +Init.swift）；error case 統一 `.invalidDateFormat`（infra case）。
5. **不 bump 版本**。
6. **依賴關係**：phase-1f / phase-1h / phase-1i / 2026-05-18-api-skill（全 done）。

---

## Sign-off

- [x] write-spec output reviewed
- [⚠️] audit-spec partial — Codex external 2026-05-25 API 529 server overloaded（4 次重試皆失敗）。Self-audit 確認：1) Genesis `Date.parseIso8601` 雙 overload（String→Date / String?→Date?）→ Date 與 Date? 用同樣 `try` form，spec body emission rule 已簡化；2) /api v5 extension 偵測用 multi-grep `extension {UC}...Input { init(from payload:` 多行 tolerant；3) idempotent v4 inline 不 retro-upgrade（v1 不 auto-fix）。Codex 後續可補審。
- [x] decisions.md ratification（Phase 1.j 條目）+ architecture.md §10.15
- [x] registry status: ready → **done**（template placeholder + ApiRenderer hasVariantBDate/renderPayloadInitExtension + /api v5 短形偵測 SKILL.md 199 行 ≤200 + 新 fixture iam-date-uc-bundle.json + real E2E swift build PASS: ScheduleAccessReviewApplicationService.swift.o compiled with extension `try Date.parseIso8601(payload.reviewDate)`）
