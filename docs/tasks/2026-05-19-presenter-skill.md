# /presenter skill v1 — bundle-writing skill for read-side AS design

## 來源

討論：`docs/discussions/2026-05-19-presenter-skill.md`
Sibling design pattern：`docs/tasks/2026-05-18-readmodel-skill.md`（structurally parallel）
Read-side AS facts: Phase 1.g Gemini agent `a835dbfeb3c99a33e` §4 + Phase 1.h facts §1

Ground truth refs：
- OC read-side AS：`OpportunityContext/Sources/AuditQuotingAggregate/Adapter/GetQuotingProofs/GetQuotingProofsApplicationService.swift`
- OC read-side ApiHandler method：`ApiHandler.swift:28-51` (`getQuotingProofs`)

## 目標

寫 `~/.claude/skills/presenter/SKILL.md` v1（≤250 LoC）+ Genesis bundled mirror `Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md`，讓 user 在 Genesis-bootstrapped project 內：

1. 跑 `/presenter <readModelName>` 啟動互動式 design flow
2. Skill 讀 bundle，列已有 `bundle.readModels[]`，user 選一個
3. User 選 output shape (`array` / `single` / `scalar`) + elementType + elementSource
4. Skill append 新 entry 到 `bundle.presenters[]`
5. 印 hint「待 Phase 1.k renderer ship 後可 codegen `Get<X>ApplicationService.swift`」

Skill **不**寫 Swift / yaml / 任何 codegen artifact — 純 bundle JSON writer。

**Codegen 後續工作**（不在此 spec scope）: Phase 1.k renderer 讀 bundle.presenters[] → emit:
- `Sources/<A>Aggregate/Adapter/Get<X>/Get<X>ApplicationService.swift` (read-side variant, kdbClient injection)
- ApiHandler.swift `getX` method scaffold
- openapi.yaml GET endpoint entry

---

## 介面合約

### Skill invocation

```
/presenter [<readModelName>]
```

- `<readModelName>`: optional — 若提供，skill 跳過 step 2 直接用它；否則 step 2 互動選
- 工作目錄 = Genesis-bootstrapped project root

### Inputs the skill reads

| Path | Purpose | Required? |
|---|---|---|
| `<bundle-path>` JSON | bundle.readModels[]、bundle.presenters[]、bundle.aggregates[] | YES |
| Optional `<bundle>.adapter.yaml` | streamPrefix override (per Phase 1.g convention) | OPTIONAL |

Skill 不讀其他 file。

### Outputs the skill writes

| Path | Action |
|---|---|
| `<bundle-path>` JSON | Single Write call — append `bundle.presenters[]` 新 entry |

### Exit codes

- `0`: success
- `1`: bundle missing / corrupted / no readmodels exist → hint user run `/readmodel` first
- `2`: user cancelled mid-flow (no partial writes)
- `3`: duplicate presenter name + user 選 abort
- `4`: readModelRef not found in bundle.readModels[] (defensive — user provided invalid arg)

### Generated bundle entry shape (D2 schema)

```json
{
  "presenterSpecId": "p-rm-GetQuotingProofs",
  "name": "GetQuotingProofs",
  "readModelRef": "GetQuotingProofs",
  "aggregateRef": "AuditQuoting",
  "input": {
    "fields": [
      { "name": "auditQuotingId", "type": "String", "fromPath": "auditQuotingId" }
    ]
  },
  "output": {
    "kind": "array",
    "elementType": "QuotingProofDto",
    "elementSource": "proofs",
    "isOptional": false
  },
  "endpoint": {
    "path": "/audit-quoting/{auditQuotingId}/quoting-proofs",
    "method": "GET"
  },
  "comment": null
}
```

### Field validation rules

| Field | Validation |
|---|---|
| `name` | `^Get[A-Z][A-Za-z0-9]+$`; unique within bundle.presenters[] |
| `readModelRef` | must exist in bundle.readModels[].name |
| `aggregateRef` | copied from chosen readmodel (denormalized); must be valid agg name OR `<context-level>` |
| `input.fields[].name` | valid Swift identifier; `^[a-z][A-Za-z0-9]*$` |
| `input.fields[].type` | one of `String` / `UUID` / `Int` / `Int64` (v1 limit; same as /readmodel key types) |
| `input.fields[].fromPath` | string; defaults to field name |
| `output.kind` | exactly one of `"array"` / `"single"` / `"scalar"` |
| `output.elementType` | non-empty Swift type string (DTO type assumed in bundle.dtos[] or Swift stdlib) |
| `output.elementSource` | non-empty; readModel field name (no validation against actual readModel — defer to renderer) |
| `output.isOptional` | bool |
| `endpoint.method` | "GET" v1 (defer POST/etc.) |

### Skill 5 steps (canonical flow)

```
Step 1 — Locate bundle (same as /readmodel)
  Parse JSON；fail-fast on syntax error
  Validate bundle.readModels[] non-empty → else exit 1 with hint

Step 2 — Choose readmodel (AskUserQuestion single-select)
  If $ARGUMENTS[0] provided → use directly (validate exists in bundle.readModels[])；else else exit 4
  Else: options = bundle.readModels[].name
  Selected → fetch its readModel object (for storedFields[] access in step 5)

Step 3 — Name the presenter
  Default = readmodel.name (e.g. "GetQuotingProofs")
  AskUserQuestion: [<default> (Recommended), Other]
  Validate: regex /^Get[A-Z][A-Za-z0-9]+$/, uniqueness in bundle.presenters[]
  Collision → [overwrite / pick new name / abort]

Step 4 — Choose output shape (AskUserQuestion single-select)
  Options:
    - "array (e.g. [<X>Dto])"
    - "single (e.g. <X>Dto)"
    - "scalar (e.g. String?)"
  Selected → branch step 5

Step 5 — Configure output details (subset of these depending on D4 selection)
  AskUserQuestion: "elementType (Swift type name)?"
    options = [<DTO names from bundle.dtos[]>, "Other (free-form)"]
    selected → output.elementType

  AskUserQuestion: "elementSource (readModel field name)?"
    options = readmodel.storedFields[].name + readmodel.key.field + "Other (free-form)"
    selected → output.elementSource

  If kind in [single, scalar]:
    AskUserQuestion: "isOptional?"
      options = ["true (nullable from readModel)", "false (required)"]

  endpoint defaults:
    path = "/" + kebab(aggregateRef) + "/{" + readmodel.key.field + "}/" + kebab(stripGetPrefix(name))
    method = "GET"

After all 5 steps:
  Build entry per D2 schema
  Re-serialise bundle (2-space indent)
  Single Write call to bundle path
  Print:
    "✅ presenter 'GetX' appended to <bundle-path>
    → readModelRef: GetX (links to bundle.readModels['GetX'])
    → output: <kind> of <elementType> from readModel.<elementSource>
    → endpoint: GET <path>
    → Next step (when Phase 1.k renderer ships): re-run `genesis new <bundle>` to scaffold
      Adapter/Get<X>/Get<X>ApplicationService.swift + ApiHandler read method + openapi GET entry."
```

### Framework constraints

| Constraint | Why |
|---|---|
| Skill 不寫 Swift / yaml | bundle = SSOT |
| 不修改其他 bundle entries | safety |
| AskUserQuestion 不可用 → exit 1 | UX consistency with /readmodel |
| `disable-model-invocation: true` | 必須 user 顯式 `/presenter` 呼叫 |
| readmodel.key.field 為 path 預設 ID | mirror OC pattern |

---

## 驗收標準

### A1 — Skill file exists
```
test -f Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
```

### A2 — Length budget
```
[ $(wc -l < Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md) -le 250 ]
```

### A3 — Frontmatter present
```
head -10 Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md | grep -F 'name: presenter'
head -10 Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md | grep -F 'disable-model-invocation: true'
head -10 Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md | grep -F 'AskUserQuestion'
```

### A4 — 5 steps headings
```
[ $(grep -cE '^## (Step [1-5]|步驟 [1-5])' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md) -eq 5 ]
```

### A5 — Key conventions in body
```
grep -F 'readModelRef' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F 'elementType' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F 'elementSource' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F 'array' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F 'single' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F 'scalar' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F 'bundle.readModels' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F 'AskUserQuestion' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
```

### A6 — Forbidden writes
```
grep -F '不寫 Sources/' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F '不寫 openapi.yaml' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
grep -F '不執行 genesis new' Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md
```

### A7 — Bundle schema extension parsed
```
swift test --filter BundleParserFullTests/testPresenterEntryParsed
swift test --filter BundleParserFullTests/testPresenterLegacyEmptyBundle
```

### A8 — PresenterBundleAppender unit test
```
swift test --filter PresenterBundleAppenderTests
```

涵蓋:
- testAppendHappyPathArrayOutput
- testAppendHappyPathSingleOutput
- testAppendHappyPathScalarOutput
- testDuplicateNameRejected
- testUnknownReadModelRefRejected
- testInvalidNameRejected (not Get-prefix)
- testInvalidOutputKindRejected
- testCrossAggregateInheritance (readModelRef → context-level)

### A9 — install-skills mirror
```
genesis install-skills --scope project --project-dir /tmp/presenter-install-test
test -f /tmp/presenter-install-test/.claude/skills/presenter/SKILL.md
diff Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md /tmp/presenter-install-test/.claude/skills/presenter/SKILL.md
```

### A10 — docs ratification
```
grep -F '/presenter skill v1' docs/decisions.md
grep -F 'presenters[]' docs/architecture.md
```

### A11 — Fixtures exist
```
test -f Tests/GenesisCoreTests/Fixtures/presenter-skill-input-bundle.json
test -f Tests/GenesisCoreTests/Fixtures/presenter-skill-answers.json
test -f Tests/GenesisCoreTests/Fixtures/presenter-skill-expected-output-bundle.json
```

### A12 — Manual E2E sign-off (NOT in CI)
- 真實 Claude Code session 內呼叫 `/presenter GetQuotingProofs` 或類似
- 跑滿 5 步 → 確認 bundle.presenters[] 新 entry
- 各 output kind 各跑一次（array / single / scalar）
- 確認 user cancel 不寫 bundle

---

## 失敗路徑

| 場景 | 行為 |
|---|---|
| Bundle 不存在 / 缺 readModels[] | exit 1 + hint `/readmodel` first |
| readModelRef 在 bundle.readModels[] 找不到 | exit 4 |
| 重複 name | AskUserQuestion: overwrite / rename / abort → abort = exit 3 |
| step 2-5 任一 cancel | exit 2 (rollback semantics — single Write at step 5 end) |
| AskUserQuestion 不可用 | exit 1 |
| Bundle write 失敗 | exit 1 |

---

## 已知限制 (per discussion D10)

1. **Filter/query params defer v2** — v1 只 path ID param
2. **Multi-readmodel join defer v2**
3. **Pagination defer v2**
4. **Output shape conditional (oneOf) defer v2**
5. **Phase 1.k renderer 待 ship** — bundle.presenters[] 寫好但 codegen 還不能跑；spec 寫 hint
6. **AI fill for execute() body defer** — 等 Phase 1.k 完，再決定要不要 AI fill skill
7. **`elementSource` 不驗證對應 readModel field 存在** — assume user 知道；defer 給 renderer / AI fill 階段
8. **endpoint.path 默認簡單，未考慮 RESTful semantics** — 可能要 `/audit-quotings/{id}/quoting-proofs` (plural) vs `/audit-quoting/{id}/quoting-proofs` (singular)；v1 用 simple kebab from agg name
9. **HTTP method GET only v1** — defer DELETE / specialized
10. **Cross-aggregate presenter 自 readmodel.aggregateRef 繼承** — explicit user override defer v2
11. **`disable-model-invocation: true`** — 同 /readmodel skill convention，必須 user 顯式呼叫

---

## 實作步驟（for /pickup）

1. SKILL.md content (≤ 250 lines) per 5-step flow
2. `Sources/GenesisCore/FullBundle.swift` — 新 PresenterSpec + 擴 FullBundle 加 `presenters: [PresenterSpec]`
3. `Sources/GenesisCore/BundleParser.swift` — decode RawPresenter + presenters[] (backwards-compat: missing → empty array)
4. `Sources/GenesisCore/PresenterBundleAppender.swift` (~200 lines) — pure transform `append(bundle, answers) → bundle` + validation
5. 3 fixtures (input bundle / answers / expected output)
6. `PresenterBundleAppenderTests.swift` (~8 tests per A8)
7. `BundleParserFullTests` 加 testPresenterEntryParsed + legacy empty compat
8. `docs/decisions.md` + `docs/architecture.md §10.9 /presenter skill flow`
9. Verify install-skills mirror (A9)
10. Manual E2E sign-off (A12)

---

## Sign-off requirements

- [ ] write-spec reviewed
- [ ] audit-spec (light Codex external — patterns mirror /readmodel)
- [ ] decisions.md ratification
- [ ] registry: draft → ready → done

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals (bundle-writing) ↔ Non-goals (codegen / openapi / Swift files) 互斥
- [x] depends_on: phase-1d (DONE — install-skills) + 2026-05-18-readmodel-skill (DONE — sibling pattern)
- [x] 11 known limits 不與 acceptance 衝突
- [x] A1-A11 全 Agent runnable；A12 = Human E2E sign-off
- [x] 5 steps / 3 output kinds 為設計常數，非 ≥N counts
