# Phase 1.l — Usecase Input OC alignment (auto-inject aggId + operatorId) + /api skill v6

## 來源

討論：`docs/discussions/2026-05-26-usecase-alignment-and-fill-skill.md`

OC ground truth：所有 OC Usecase Input（`EditPaidInCapitalInput` / `EditFontSizeInput` / `CreateQuotationInput` / `EditLetterTitleInput`）一律含 `{aggId, 業務欄位, operatorId}`，OC Usecase extension body 必用 `input.<aggId>` 與 `input.operatorId`。

依賴 Phase（全 done）：phase-1e（aggregate.identityName）、phase-1h（ApiRenderer scaffold）、phase-1i（ApiHandler）、2026-05-18-api-skill（v4）、phase-1j（Variant B extension）。

## 目標

修補 Genesis bundle/renderer 一處架構 divergence：`{UC}Input` 自動 inject aggId + operatorId fields，與 OC pattern 1:1 對齊。**伺機解決** /api skill v4 H2 finding 的根因（Service Input 缺 aggId/operatorId 導致 fill 邏輯需要 SSOT 砍 fields），讓 AS Input ≡ Usecase Input。

完成後 unblock `/usecase` skill 寫 OC pattern A/B/C/D body（need `input.aggId` + `input.operatorId`）。

**Breaking change**：既有 `/api` v4 fills 缺新 aggId + operatorId 欄位 → compile fail。e2e 流程需 regen fixtures + 重填 /api v6。

---

## 介面合約

### Bundle schema

無變更。`useCase.input[]` 仍為業務欄位，aggId + operatorId 由 renderer 自動 inject。

### UseCaseRenderer.renderInput 改動

讀 `useCase.aggregateSpecId` → lookup `bundle.aggregates[].identityName`，取 aggId field 名（如 `useraccessprofileId`）。

emit `{UC}Input` 字段順序：

```
1. <aggId>: String
2. ... 原 useCase.input[] 各 field ...
3. operatorId: String
```

init params + assignments 同步加。

### UsecaseInput.swift.template

template 不改（已用 `{InputFieldDecls}` / `{InitParams}` / `{InitAssignments}` placeholder）。renderer 統一在 fields 前後注入 aggId + operatorId。

### /api skill v6 升級（category 1 fill 反轉）

v4 fill body 用「Service Input is SSOT，砍 aggId/operatorId」邏輯。v6 改為「pass-through 全部 fields」對齊 OC：

```swift
let service = <UC>Service(repository: repository)
_ = try await service.execute(input: .init(
    <aggId>: input.<aggId>,
    <field1>: input.<field1>,
    ...
    operatorId: input.operatorId
))
return .init(<aggId>: input.<aggId>)
```

SKILL.md 改：

- category 1 sample 反轉為「pass-through 全部 fields」。
- 移除「Service Input SSOT，只填 `{UC}Input` 宣告的 fields」段落（D1 規則改為「AS Input ≡ Usecase Input」）。
- server-generated ID variant 保留（Service Input 含 ID 但 AS 不含的 case 仍存在）。
- known limit：「Phase 1.l breaking change — 既有 v4 fills 缺新 aggId+operatorId fields，須 manual unfill + 重跑 /api v6」。
- Variant B-Date short-form（Phase 1.j）保留。

### 既有測試 / fixture 影響

- `ApiRendererTests`：v1 字段順序檢驗 test 須改（如有依字段順序的斷言）。
- `BundleParserTests`：無影響（bundle schema 無變更）。
- `UseCaseRendererTests`（如有）：UsecaseInput 新增 2 fields 的 emission test 改 expected。
- 既有 fixture `iam-bundle.json` 等 regenerate 後 Usecase Input 含 aggId + operatorId。
- `/tmp/api-e2e` 等手動 e2e tree 失效，須重生 + 重跑 /api。

---

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/UseCaseRenderer.swift` | `renderInput` 加 aggId + operatorId 注入；簽名需 access `bundle.aggregates` lookup identityName（或在 `render(useCase:bundle:adapter:)` 入口已有 bundle）|
| `Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md` | v6：category 1 改 pass-through；known limit 加 breaking change；mirror 同步 |
| `Tests/GenesisCoreTests/UseCaseRendererTests.swift` | 加 aggId + operatorId 注入 test（per write UC） |
| `Tests/GenesisCoreTests/ApiRendererTests.swift` | 既有測試若依 Usecase Input 字段順序則修 |
| `Sources/GenesisCore/Version.swift` | 不變（quality alignment，與其他 phase 一致不 bump） |
| `docs/decisions.md` | Phase 1.l ratification |
| `docs/architecture.md` | §10.16 Usecase Input OC alignment note |
| `docs/tasks/registry/phase-1l-usecase-input-oc-alignment.json` | **新檔** |

---

## 實作步驟

### Step 1 — UseCaseRenderer.renderInput inject

1. caller `render(useCase:bundle:adapter:)` 加 lookup：
   ```swift
   guard let agg = bundle.aggregates.first(where: { $0.aggregateSpecId == useCase.aggregateSpecId }) else { throw bundleInvalid }
   let aggIdName = agg.identityName
   ```
2. `renderInput` 簽名加 `aggIdName: String` 參數。
3. **canonical ordering（audit M4 — dedupe 兩者）**：
   ```swift
   let businessFields = fields.filter { $0.name != aggIdName && $0.name != "operatorId" }
   let aggIdField = FieldSpec(name: aggIdName, rawType: "String")
   let operatorIdField = FieldSpec(name: "operatorId", rawType: "String")
   let canonicalFields = [aggIdField] + businessFields + [operatorIdField]
   ```
   結果順序：aggId 第一、業務欄位中間、operatorId 末位。dedupe 涵蓋 user 誤把 aggId 或 operatorId 寫進 `useCase.input[]` 的 case。
4. `decls` / `initParams` / `assignments` 三組 list 從 `canonicalFields` 統一產生。

### Step 2 — /api skill v6 SKILL.md

修 category 1 「Service Input 是 SSOT」段落為「Usecase Input ≡ AS Input 全 pass-through」。改 body sample。known limit 補 breaking change。mirror 到 `~/.claude/skills/api/SKILL.md`。LoC 維持 ≤200。

**audit M5 — stale v4 fill 偵測**：category 1 idempotent invariant 不可只看「service.execute + return + no fatalError」（v4-filled 滿足此但缺新欄位 → compile fail 卻 skip）。改為：parse 已填 body 內 `service.execute(input: .init(...))` 的 argument labels，與**當前** Usecase Input 業務欄位 + aggId + operatorId 做集合比對 —— `aggId` 或 `operatorId` label 缺 → **exit 4 stale v4 fill detected**（hint：「Phase 1.l 後 v4 既有 fill 缺 `<aggId>` / `operatorId`；manual unfill 該 body + 重跑 /api v6」）。

### Step 3 — Tests

UseCaseRendererTests 加 emission test：bundle `useCase.input = [field1, field2]` + aggregate identityName `myAggId` → emitted `UsecaseInput` should contain `myAggId: String` 首位 + `operatorId: String` 末位。

### Step 4 — Real E2E

1. `genesis new IAMContext --from-bundle iam-bundle.json --output /tmp/p1l-e2e --no-git --skip-build`
2. `cat /tmp/p1l-e2e/Sources/UserAccessProfileAggregate/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileInput.swift` → 確認 fields = `{useraccessprofileId, userId, department, jobTitle, operatorId}`
3. 對 createUserAccessProfile AS 填 v6 短形（含 aggId + operatorId pass-through）
4. `swift build` → Build complete

### Step 5 — Docs

decisions.md Phase 1.l ratification + architecture.md §10.16。

---

## 失敗路徑

| 場景 | 處理 |
|---|---|
| useCase.aggregateSpecId 不在 bundle.aggregates → identityName lookup 失敗 | throw `bundleInvalid` |
| bundle 已含 `operatorId` 為業務欄位（user 誤寫）| dedupe，保留一份在 operatorId 末位 |
| 既有 v4 fills 缺 aggId+operatorId → 重 build fail | breaking change，known limit 明示，user 需 manual unfill + 重跑 /api v6 |

---

## 不改動的部分

- 其他 renderer（PresenterRenderer、ReadModelRenderer 等）不動。
- `useCase.input[]` bundle schema 不改 — 業務語意維持「業務欄位 only」，aggId+operatorId 是 transport-layer auto-injected。
- AggregateRenderer 不動。

### Non-goals（行為層）

- 本 task **不** retro-upgrade 既有 v4 fills（structural invariant 視已填 skip；user 須 manual unfill 重跑 v6）。
- 本 task **不** 改 bundle schema（aggId/operatorId 不入 `useCase.input[]`，仍由 renderer 注入）。
- 本 task **不** 升級 /presenter / /presenter-fill / /readmodel-mutation（read-side 不受影響）。
- 本 task **不 bump 版本**。

---

## 驗收標準

### Agent 必做

```bash
# A1. UseCaseRenderer 注入 aggId + operatorId
grep -F 'identityName' Sources/GenesisCore/UseCaseRenderer.swift
grep -F 'operatorId' Sources/GenesisCore/UseCaseRenderer.swift

# A2. SKILL.md v6 category 1 pass-through + breaking change note
grep -F 'pass-through' Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md
grep -F 'Phase 1.l' Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md
[ $(wc -l < Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md) -le 200 ]

# A3. mirror byte-identical
diff Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md ~/.claude/skills/api/SKILL.md

# A4. iam-bundle regen → Usecase Input 含 aggId + operatorId
rm -rf /tmp/p1l-test && mkdir -p /tmp/p1l-test
./.build/debug/genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json --output /tmp/p1l-test --no-git --skip-build >/dev/null
grep -F 'useraccessprofileId: String' /tmp/p1l-test/Sources/UserAccessProfileAggregate/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileInput.swift
grep -F 'operatorId: String' /tmp/p1l-test/Sources/UserAccessProfileAggregate/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileInput.swift

# A5. 全 unit + integration tests PASS
swift build
swift test

# A6. docs
grep -F 'Phase 1.l' docs/decisions.md
grep -F 'Phase 1.l' docs/architecture.md
```

### Human 補做

- [ ] 對 /tmp/p1l-test 跑 /api v6 填 createUserAccessProfile：handler 短形 + service.execute 含 aggId+operatorId → swift build PASS。
- [ ] 確認既有 v4 fills（如有保留的 e2e tree）build fail，重 unfill+重填後 pass。

---

## 已知限制

1. **Breaking change for v4 fills**：既有 v4 fills 缺新 aggId+operatorId fields → re-regen / re-fill 必要。
2. **bundle schema 不改**：useCase.input[] 仍只業務欄位；aggId/operatorId 是 codegen-time auto-inject 慣例。
3. **不 bump 版本**。
4. **依賴關係**：phase-1e / phase-1h / phase-1i / 2026-05-18-api-skill / phase-1j（全 done）。

## Audit findings resolution (Codex external 2026-05-26)

| ID | 嚴重 | 問題 | 修法 |
|---|---|---|---|
| M4 | 中 | dedupe 只 cover operatorId 不含 aggId double-emit | canonical ordering + filter aggIdName & operatorId 兩者再 prepend/append |
| M5 | 中 | /api v6 stale v4 fill detection 用「service.execute+return+no fatalError」會誤判 skip 但 build fail | invariant 改 parse `.init(...)` argument labels 對比 current Input 集合；缺 aggId/operatorId → exit 4 stale |

（H1+H2+M3+M6+L7 在 /usecase spec 修）

## Sign-off

- [x] write-spec output reviewed
- [x] **audit-spec pass — Codex external 2026-05-26**：2H+4M+1L 跨兩 spec 全套修（本 spec 對應 M4+M5）。
- [x] decisions.md ratification + architecture.md §10.16
- [x] registry status: ready → **done**（UseCaseRenderer inject + canonical ordering aggId/operatorId dedupe；/api SKILL.md v6 pass-through + stale v4 detection 192 行 ≤200；real e2e: /tmp/p1l-e2e CreateUserAccessProfileApplicationService.swift.o compiled with full pass-through pattern；全 test suite PASS 0 regression）
