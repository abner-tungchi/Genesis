# /readmodel skill v1 — bundle-writing skill for ReadModel design

## 來源

討論：`docs/discussions/2026-05-18-readmodel-skill.md`

Ground truth refs：
- OC canonical projection-model.yaml：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/AuditQuotingAggregate/projection-model.yaml`
- OC canonical ReadModel + Presenter：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/AuditQuotingAggregate/Usecase/Projector/GetAccountingType/` 整目錄
- OC canonical JS projection：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/projections/OC_GetAccountingTypeProjection.js`
- Cross-aggregate canonical：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/OpportunityContext/Projector/GetSelectedServiceItems/`
- Gemini facts report 2026-05-18（discussion §1）
- 既有 placeholder：`Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md`（短 placeholder，內容 TBR）
- 既有 personal skill（**不同 lifecycle，不衝突**）：`~/.claude/skills/readmodel/SKILL.md`（config.md-centric per-feature 直生 Swift；長度 ~180 行）

## 目標

寫出 Genesis-bundled `Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md` v1 的真實內容（取代現存 placeholder），讓 `/readmodel` 在 Genesis-bootstrapped project 內：

1. 讀 bundle JSON 顯示既有 aggregates / events
2. 用 `AskUserQuestion multiSelect:true` 收集 user 的 readmodel 設計選擇
3. append 新 entry 到 `bundle.readModels[]`
4. 印「下一步：re-run `genesis new <bundle>` (Phase 1.g 完工後 actionable)」

**Scope narrow**：Skill 只存**結構**（ReadModel 形狀 + 哪些 events 影響它 + key 怎麼抽）。**不**存 per-event mutation 邏輯 — renderer 將生 Presenter 的空 `when()` body with `// TODO: mutate readModel` 註解，**user 後續手工填**（或未來開 `/readmodel-mutation` skill 自動化，out of scope v1）。

Skill **不直接生 Swift / YAML / JS code** — 那是 Genesis renderer 的 job（Phase 1.g 待開）。

---

## 介面合約（Interface Contract）

### Skill invocation

```
/readmodel [bundle-path]
```

- `[bundle-path]`: optional；missing 時 skill 找 cwd 下 `bundle.json` / `*-bundle.json` / 互動詢問
- 工作目錄 = Genesis-bootstrapped project root 或 bundle JSON 所在目錄；skill 不假設 Swift sources 存在

### Inputs the skill reads

| Path | Purpose | Required? |
|---|---|---|
| `<bundle-path>` JSON | 取得 context / aggregates / events / useCases / 既有 readModels；append target | YES (fail-fast if missing) |
| Optional `<bundle>.adapter.yaml` (sibling) | streamPrefix override；若 missing → 走 §streamPrefix-resolution | OPTIONAL |

Skill 不讀其他 file（不讀 `.ai/contexts/`、不讀 `Sources/`、不讀 `openapi.yaml`）。

### Outputs the skill writes

| Path | Action | Condition |
|---|---|---|
| `<bundle-path>` JSON | **Single Write tool call** (full bundle re-serialised with new entry appended) | 成功完成互動且 user 在 step 6 final confirm |

無其他 file write。

### Atomicity guarantee (revised)

- Skill 不做 streaming write / partial commit；全部 user input 收集完才一次 `Write` overwrite
- 在 single `Write` call 之前 bundle 完全未動
- POSIX rename / atomic-replace 不在 v1 scope；若 process 被殺在 `Write` 中間 → bundle 可能損毀（known risk, low probability, 與 Genesis 其他 single-Write 工具同 risk profile）
- 不在保證範圍：磁碟損毀、SIGKILL during Write tool call、filesystem 不支援 atomic-rename

### Exit codes

- `0`: success（bundle appended）
- `1`: bundle file not found / not parseable JSON / missing required top-level fields (aggregates) / chosen aggregate has zero events
- `2`: user cancelled mid-flow（無 partial writes — bundle 完全未動）
- `3`: duplicate readmodel name + user 選 abort

### Generated bundle entry shape (D2 schema — revised)

當 `/readmodel` 成功，bundle.readModels[] 多一個 entry：

```json
{
  "name": "GetAccountingType",
  "aggregateRef": "AuditQuoting",
  "key": {
    "field": "auditQuotingId",
    "type": "String",
    "fromEventPayload": "quotingId"
  },
  "storedFields": [
    { "name": "accountingType", "type": "AccountingTypeDto?", "default": "nil" }
  ],
  "events": [
    { "name": "AuditQuotingCreated", "sourceAggregate": "AuditQuoting" },
    { "name": "AccountingTypeEdited", "sourceAggregate": "AuditQuoting" }
  ],
  "comment": null
}
```

**Schema 變更說明 (vs discussion D2)**：
- `key` 升為 object，含 `field` / `type` / `fromEventPayload`（the JS `event.body[...]` 取 key 的欄位名）— **取代** discussion 的 `events[].payloadKeyField`
- **限制**：v1 要求所有 selected events 共用同一 `key.fromEventPayload`（match OC canonical pattern, JS 用 single shared `handleEvent`）
- `storedFields[]` 不含 key 欄位（key 由 constructor 注入，非 stored field with default）
- `events[].sourceAggregate` 強制 present（解 cross-aggregate event-name collision footgun）
- `sourceAggregates[]` 從 D2 移除 — 用 `events[].sourceAggregate` 集合推導

### Field validation rules

| Field | Validation |
|---|---|
| `name` | non-empty；matches `^Get[A-Z][A-Za-z0-9]+$`；unique within bundle.readModels[] |
| `aggregateRef` | either a name in bundle.aggregates[].aggregate，or the literal `"<context-level>"` |
| `key.field` | non-empty；valid Swift identifier；matches `^[a-z][A-Za-z0-9]*$` |
| `key.type` | one of: `String`, `UUID`, `Int`, `Int64` (v1 limit；其他 Hashable types defer) |
| `key.fromEventPayload` | non-empty string；**must appear in every selected event's resolved payload**（strict v1） |
| `storedFields[].name` | unique within entry；valid Swift identifier；**不可** 等於 `key.field` |
| `storedFields[].type` | non-empty string；no Swift-type validation (skill 不解析 Sources/) |
| `events[].name` | must exist in some bundle aggregate's `events[].name` |
| `events[].sourceAggregate` | must be a name in bundle.aggregates[].aggregate |

### Event payload resolution algorithm (NEW)

Step 3 / Step 5 / Step 6 都需要知道 event 的 payload field names。Resolution 演算法：

```
resolvePayload(eventName, bundle):
  // Pass 1: direct payload on aggregate.events[]
  for each aggregate in bundle.aggregates:
    for each event in aggregate.events:
      if event.name == eventName and event.payload exists:
        return event.payload.fields  // [{name, type}]

  // Pass 2: indirect via useCases[]
  for each uc in bundle.useCases:
    if uc.emittedEvent == eventName:
      return uc.eventPayload  // [{name, type}]

  // Pass 3: nothing found
  return []  // empty → step 5/6 falls back to manual entry
```

→ Step 3 event preview 用 Pass-1+Pass-2 結果 label；Step 5/6 candidate fields 同。

### Skill 6 steps (canonical flow)

```
Step 1 — Locate bundle
  讀 $ARGUMENTS[0] | 找 cwd `*-bundle.json` | 詢問 path
  Parse JSON；fail-fast on syntax error
  Validate top-level: manifestVersion / context / aggregates (non-empty)

Step 2 — Choose aggregate (AskUserQuestion single-select)
  Options = bundle.aggregates[].aggregate + "<context-level>"
  If only 1 aggregate → skip + announce
  If "<context-level>" chosen → flag for step 3

Step 3 — Choose events (AskUserQuestion multiSelect:true)
  Source events list:
    if aggregateRef == "<context-level>" → flatten all aggregates' events[] labelled "[<aggregateName>] <eventName>"
    else → chosen aggregate's events[]
  If source list empty (aggregate has 0 events) → exit 1 with hint
  Show each event's resolved payload field names (per algorithm above) in option description
  User selects ≥1 event；require non-empty

Step 4 — Name the readmodel
  Default candidate = "Get" + extractCommonNoun(selectedEvents) heuristic
  Ask via AskUserQuestion with default as recommended option
  Validate: regex /^Get[A-Z][A-Za-z0-9]+$/, uniqueness
  On collision → AskUserQuestion: overwrite / pick new name / abort

Step 5 — Key field selection (AskUserQuestion single-select)
  Compute candidate keys:
    candidates = ∩(resolvePayload(e, bundle).map(f => f.name) for e in selectedEvents)
  If empty intersection → AskUserQuestion: 'enter key field manually' (free-form) — **warn**: violates strict v1 single-key constraint, blocks codegen
  If single candidate → show as recommended，still ask confirm
  If multiple → present all as options
  Once chosen, set key.fromEventPayload = chosen field name
  Ask key.type (default "String"; one-select among allowed types)
  Ask key.field (default = key.fromEventPayload; user can rename to e.g. "auditQuotingId" while payload key remains "quotingId")

Step 6 — Stored fields (AskUserQuestion multiSelect:true)
  Candidate fields = union of (resolvePayload(e, bundle).map(f => f.name) for e in selectedEvents) minus key.field
  Always offer "Other" for free-form additions
  User picks which to store；for each, AskUserQuestion default type = inferred from payload schema (else "String?")
  Result → storedFields[]

After all 6 steps:
  Build entry per revised D2 schema
  Re-serialise bundle with new entry appended, 2-space indent
  Single Write call to bundle path
  Print success summary + next-step hint (revised per M3 below)
```

### Success message (revised per audit M3)

```
✅ readmodel '{name}' appended to {bundle-path}
   → Bundle entry now contains structural definition.
   → Next step (when Phase 1.g renderer ships): re-run `genesis new <bundle>` to
     scaffold ReadModel.swift / Presenter.swift / projection-model.yaml entry /
     OC_*Projection.js with empty `when()` bodies you'll fill in by hand.
   → Phase 1.g status: see docs/tasks/registry/phase-1g-readmodel-renderer.json
```

### Framework constraints

| Constraint | Why |
|---|---|
| Skill 不執行 `genesis new` | 避免 implicit regeneration；user 自決何時 regen |
| 不寫 `Sources/`、`projections/`、`.ai/` 任何 file | bundle = SSOT，避免 drift |
| 不修改 bundle 其他 entries | append-only safety；diff-friendly |
| `AskUserQuestion` 不可用時 → fail-fast with hint，**不**自動降級到 numbered list | v1 一致性優先；degrade path 是 known limitation 留 v2 |
| Skill `disable-model-invocation: true` | 必須由 user 顯式 `/readmodel` 呼叫；不被其他 skill 自動 trigger |
| 所有 selected events 必須有共用 `payloadKeyField` (strict) | match OC canonical JS pattern (single shared linkTo key)；不一致 → step 5 warn + 用 manual entry path，但 step 6 結束才允許寫入 |

### streamPrefix resolution (per audit M4)

精確 precedence：

1. **Explicit override**: `<bundle>.adapter.yaml` 含 `streamPrefix: "OC_"` → use it
2. **bundle.context.streamPrefix**: 若 bundle.context 是 object 且含 `streamPrefix` → use it
3. **Deterministic fallback** (last resort):
   - strip suffix `"Context"` from contextName: `OpportunityContext` → `Opportunity`, `IAMContext` → `IAM`
   - **若結果為已知 alias** (whitelist: `Opportunity → OC`): map
   - else: upper-snake-case + underscore: `IAM_`, `Billing → BILLING_`

範例：
| contextName | adapter override | fallback | 最終 |
|---|---|---|---|
| `OpportunityContext` | (none) | `OC_` (via alias) | `OC_` |
| `IAMContext` | (none) | `IAM_` | `IAM_` |
| `BillingContext` | (none) | `BILLING_` | `BILLING_` |
| `OrderContext` | `"OD_"` | (override wins) | `OD_` |
| `OrderContext` | (none) | `ORDER_` | `ORDER_` |

Skill **不問 user** 確認 prefix；deterministic resolution + override file = single SSOT。**Alias map** 由 Genesis 維護（v1 hardcode `Opportunity → OC`；後續加 user-supplied）。

### Placeholder substitution rules (for SKILL.md template)

SKILL.md 是 Markdown agent prompt；用 placeholder：

| Placeholder | 來源 |
|---|---|
| `{GenesisVersion}` | `Sources/GenesisCore/Version.swift` `GenesisCoreVersion.current` 由 install-skills 注入 |
| `{Date}` | install-skills 注入 ISO-8601 date |

SKILL.md **本體不含** 業務 placeholder（aggregate names / event names）— 那些是 skill 執行時動態讀 bundle。

---

## 驗收標準（Acceptance Criteria）

### A1 — Skill file exists at canonical location
```
test -f Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
```

### A2 — Length budget (advisory)
```
[ $(wc -l < Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md) -le 300 ]
```
> 提高至 300（per audit L1）；correctness gates 優先於 size。

### A3 — Frontmatter present
```
head -10 Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md | grep -F 'name: readmodel'
head -10 Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md | grep -F 'disable-model-invocation: true'
head -10 Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md | grep -F 'allowed-tools:'
```

### A4 — Frontmatter `allowed-tools` 列表正確
```
head -10 Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md | grep -F 'Read'
head -10 Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md | grep -F 'Write'
head -10 Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md | grep -F 'AskUserQuestion'
```
> No `Bash`, no `Edit`（v1 純 single Write JSON）

### A5 — 6 steps headings present
```
[ $(grep -cE '^## (Step [1-6]|步驟 [1-6])' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md) -eq 6 ]
```

### A6 — Key conventions in SKILL.md body
```
grep -F 'bundle' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F 'readModels' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F 'AskUserQuestion' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F 'multiSelect' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F 'fromEventPayload' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F 'aggregateRef' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F '<context-level>' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F 'sourceAggregate' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F 'resolvePayload' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
```

### A7 — Forbidden-writes section explicit
```
grep -F '不寫 Sources/' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F '不寫 projections/' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
grep -F '不執行 genesis new' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
```

### A8 — `genesis install-skills` 安裝後 mirror 一致
```
genesis install-skills --target /tmp/readmodel-install-test
diff Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md /tmp/readmodel-install-test/.claude/skills/readmodel/SKILL.md
```

### A9 — Bundle schema fixtures exist for unit-test
```
test -f Tests/GenesisCoreTests/Fixtures/readmodel-skill-input-bundle.json
test -f Tests/GenesisCoreTests/Fixtures/readmodel-skill-answers.json
test -f Tests/GenesisCoreTests/Fixtures/readmodel-skill-expected-output-bundle.json
```

### A10 — Bundle-transform unit test passes (revised per audit H4)
```
swift test --filter ReadModelBundleAppenderTests
```

**Test design**: 不測 skill prompt 本體，測**底層 bundle-transform 函數**（Skill 在 SKILL.md 描述邏輯；test 驗證 Swift implementation of that logic）：

- `ReadModelBundleAppender.append(bundle: FullBundle, answers: Answers) throws -> FullBundle`
- `Answers` = decoded from `readmodel-skill-answers.json`（user's scripted choices for steps 2-6）
- Test feeds input bundle + answers → asserts output JSON byte-equal expected bundle
- Edge tests: duplicate name → throws；empty events → throws；inconsistent payloadKeyField → throws；context-level → cross-aggregate entry shape correct

**Note**: A10 不測 SKILL.md prompt-side AskUserQuestion behaviour — 那走 sign-off manual E2E（見後）。

### A11 — Manual E2E sign-off (NOT in CI)
- 真實 Claude Code session 內呼叫 `/readmodel ./Tests/GenesisCoreTests/Fixtures/readmodel-skill-input-bundle.json`
- 跑滿 6 步、答 yes / overwrite / valid name / valid key
- 確認 bundle written 正確；確認 AskUserQuestion 被正確呼叫（包含 multiSelect:true）
- 確認 user cancel 在任一步都不寫 bundle
- 記錄 transcript 為 sign-off artifact

### A12 — decisions.md ratification entry
```
grep -F '/readmodel skill v1' docs/decisions.md
```

### A13 — architecture.md updated
```
grep -F 'readModels[]' docs/architecture.md
grep -F 'streamPrefix' docs/architecture.md
grep -F 'resolvePayload' docs/architecture.md
```

### A14 — Whitelist-aware static lint (revised per audit H5)

SKILL.md 不可在「imperative generate phrases」context 提及 Swift file generation：

```
# Allowed: 在「禁止寫」/「不會生」/「TODO」/「Phase 1.g」context 提及 .swift / Sources/ / projections/
# Forbidden: imperative生成短語 (whole-line context check)
!  awk 'NR>0 && /(generate|emit|produce|write|create)[^,]*\.(swift|js|yaml)/' Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md | grep .
```

> 取代 audit-flagged 過度嚴格的純 grep ban；改 whitelist-aware 才不誤殺合法的 non-goal 描述。

---

## 失敗路徑（Failure Modes）

| 場景 | Skill 行為 |
|---|---|
| Bundle file 不存在 | exit 1，print path + 提示「先 `genesis new` 產 bundle？」 |
| Bundle JSON syntax error | exit 1，print 第一個 error line + column |
| Bundle 缺 `aggregates` 或為空 | exit 1，提示「先 bootstrap aggregate」 |
| Chosen aggregate 有 0 events | exit 1，提示「該 aggregate 還沒 event；用 /aggregate 或 /usecase 補」 |
| User 在 step 2-6 任一 cancel | exit 2，**不**寫 bundle（rollback semantics: 整個 flow 是 dry-run until step 6 final Write） |
| 重複 readmodel name | AskUserQuestion: [overwrite / pick new name / abort]；abort = exit 3 |
| 選的 events 在 bundle 內找不到 | step 3 不該發生（options 來自 bundle），但 defensive check + exit 1 |
| `events` 間 `payloadKeyField` 找不到共用 key（strict v1） | step 5 進 manual-entry path；user 可填，但若 final entry 違反「共用 key」契約 → warn 後仍寫入（與 v1 strict claim 在 spec 載明）|
| `AskUserQuestion` tool 不可用（純 file mode） | exit 1，print「請在 Claude Code session 內呼叫」 |
| Bundle write 失敗（perm / disk full） | exit 1，bundle 未動 + IO error |
| Process SIGKILL during Write tool call | bundle 可能損毀（known unmitigated v1 risk；非 expected failure mode）|

### Idempotent re-run

- 第二次 `/readmodel` 想 update 已存在 entry → 走 step 4 collision → 選 "overwrite" → 重跑 step 3-6 重採集（**不** in-place mutate）
- 同 invocation 內不支援多 readmodel；user 想加多個 → 跑多次 `/readmodel`

---

## 已知限制（Known Limitations）

1. **Bundle 內 events 可能無 payload schema**（fixtures 如 `readmodels-bundle.json` 是 minimal）
   - resolvePayload Pass-3 退回空 list
   - Step 3 event preview 退化 to name-only
   - Step 5 candidate key intersection 為空 → 手動指定 path
   - Step 6 candidate stored fields 為空 → 全由 user 手動加
   - 不 block skill 完成，只是 UX 較差

2. **AskUserQuestion 不可用 → exit 1，不 graceful degrade**
   - v1 一致性優先；v2 可加 numbered-list fallback

3. **`/presenter` skill 仍未設計**
   - bundle.presenters[] schema 不在此 spec scope
   - 若 `/presenter` 後續需 read bundle.readModels[].storedFields[] → 此 schema 已 ready
   - 若 `/presenter` 決定要新 field → bundle schema 需擴 + 此 spec 可能要 follow-up

4. **`+Query.swift` extension methods 不在 bundle**
   - 開發者手寫；Genesis renderer 不會碰

5. **`ReadModelPersistence` (swift-ddd-kit) 不支援**
   - bundle 假設 Kurrent replay-on-read（OC pattern）
   - 未來若要支援 stateful read-model store → schema 需 `storage:` 欄位

6. **既有 `~/.claude/skills/readmodel/SKILL.md` (personal skill) 命名衝突**
   - Personal skill: config.md-centric, generates Swift directly
   - Genesis-bundled skill: bundle-centric, no code-gen
   - Claude Code precedence rules (project-local overrides global) 假設成立 — 但**尚未驗證**（audit M6）
   - **加 acceptance check A15**: install-skills 跑完 manual E2E `/readmodel --help` 確認 resolved skill description 是 Genesis bundle-writing 那條
   - SKILL.md description 必須明確標示「Genesis bundle-writing skill (designed for Genesis-bootstrapped projects)」

7. **Mutation 邏輯不在 bundle**（per audit H1 scope narrow）
   - bundle 只存 ReadModel structural shape + event subscription
   - Phase 1.g renderer 將生 Presenter 的空 `when()` body with TODO 註解
   - User 手工填 mutation；或 v2 加 `/readmodel-mutation` skill 收集 per-event mutation 規則

8. **streamPrefix derivation 有 alias map dependency**
   - Genesis v1 hardcode `Opportunity → OC`；其他 context 走 upper-snake fallback
   - 若 alias map 不符 user 期望 → 改 adapter override

9. **bundle.context streamPrefix 欄位可能是 string 不是 object**（per audit M4）
   - 當前 fixtures `context: "IAMContext"` (string)
   - resolution 走 fallback path
   - 若 bundle 升 context 為 object → schema migration 走 manifestVersion bump

10. **Cross-aggregate readmodel 需 Phase 1.g renderer 支援 context-level Projector 目錄**
    - 對齊 OC `Sources/OpportunityContext/Projector/` pattern
    - 此 skill 不 block on Phase 1.g；skill 可寫 cross-aggregate entry，等 Phase 1.g 完才 actionable

11. **strict single-key constraint** 在 manual-entry path 不 enforce
    - step 5 manual entry user 可輸入任何欄位名；step 6 結束 final entry build 時 warn 但仍寫
    - rationale: skill 不該 paternalistic block；audit warning 在 console + entry comment 中

12. **`storedFields[].type` 不驗證**
    - skill 純存 string；correctness 由 Genesis renderer + swift build 兜底
    - 包含 user 拼錯 (`Stirng?`) 只能等 build error
    - v2 可加 type lint

13. **Bundle write atomicity** 是 single-Write best-effort（非 atomic-rename）
    - SIGKILL during Write → bundle corruption risk（小概率）
    - v2 可走 temp + rename via Bash tool（會犧牲 `allowed-tools` 簡潔性）

14. **Phase 1.g 待開**（per audit M3）
    - skill v1 寫 entry 後 hint user re-run `genesis new`，但 renderer 尚未實作
    - success message 明確聲明 Phase 1.g 狀態 + registry pointer
    - skill v1 itself 不 block on Phase 1.g — entry 寫進 bundle 是 forward-compatible

---

## 實作步驟（for /pickup）

1. **Schema migration**（first）：
   - 在 `Sources/GenesisCore/BundleParser.swift` (or wherever readModels[] 被 decode) 加新欄位：
     - `aggregateRef`, `key{field,type,fromEventPayload}`, `storedFields[]{name,type,default}`, `events[]{name,sourceAggregate}`, `comment`
   - 維持 backwards-compat：舊 `{name: "Foo"}` 還能 decode（其餘 nullable）
   - 更新 `Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json` + `readmodels-bundle.json` 加 1-2 個對齊新 schema 的 entry 驗證
2. **Author** `Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md`（≤300 lines）依 6-step structure
3. Add fixtures (`Tests/GenesisCoreTests/Fixtures/`):
   - `readmodel-skill-input-bundle.json`（含 2 aggregates，每 aggregate 3-5 events with payload）
   - `readmodel-skill-answers.json`（scripted answers 對應 step 2-6）
   - `readmodel-skill-expected-output-bundle.json`（input + 1 new readmodel entry）
4. Add `Sources/GenesisCore/ReadModelBundleAppender.swift`：
   - `static func append(bundle: FullBundle, answers: Answers) throws -> FullBundle`
   - Test 走這個 entry point；SKILL.md prompt 描述 step flow 但 underlying transform logic 一致
5. Add `Tests/GenesisCoreTests/ReadModelBundleAppenderTests.swift`：
   - happy path
   - duplicate name → throws
   - empty events → throws
   - cross-aggregate flatten correctness
   - resolvePayload algorithm 跑各 3 個 case
6. Update `docs/decisions.md` 加 `/readmodel skill v1 ratification` entry（含 audit H/M/L all-resolved 摘要）
7. Update `docs/architecture.md`：
   - §3 path layout：document `Sources/<Context>/Projector/` for cross-aggregate (Phase 1.g 之後 actionable)
   - 新 §10.4 ReadModel skill flow（6-step bundle write，含 resolvePayload, streamPrefix resolution）
8. Verify `genesis install-skills` mirrors 新 SKILL.md（A8）
9. 跑 spec A1-A14 全 acceptance 檢核
10. **Sign-off manual E2E** (A11)：實際 Claude Code session 跑 /readmodel + 記 transcript artifact

---

## 後續任務 (post-/readmodel-skill landing)

- **Phase 1.g** — Genesis renderer 支援 bundle.readModels[] → 產 4 個 human-written files (ReadModel.swift / Presenter.swift / projection-model.yaml entry / OC_<X>Projection.js)；Presenter `when()` 空 body + TODO
- **`/presenter` skill** — design phase；reference 此 spec 為兄弟 skill 風格
- **`/readmodel-mutation` skill (v2 candidate)** — 收集 per-event mutation 邏輯，自動填 Presenter `when()` body
- **bundle.context 升為 object**（含 streamPrefix override）via manifestVersion bump
- **payload schema standardisation** in bundle.aggregates[].events[]（消除 resolvePayload Pass-2 indirect lookup）

---

## Sign-off requirements

- [ ] write-spec output reviewed
- [ ] audit-spec pass 1 (internal consistency) — 14 known limits 不與 acceptance 衝突；revised D2 schema 與 step flow 對齊
- [ ] audit-spec pass 2 (Codex external) — 已跑，回 6H + 4M + 2L，**全部 fix 已 apply 到此 v2 spec**
- [ ] decisions.md ratification entry added
- [ ] registry entry status: draft → ready

---

## Audit findings resolution (v2 spec, post-Codex audit)

| ID | Severity | Issue | Fix applied in this v2 |
|---|---|---|---|
| H1 | high | D2 schema 沒 event→readmodel mutation mapping | **Scope narrow**：bundle 只存 structural shape；mutation 由 user 手填或 v2 `/readmodel-mutation` skill；§目標 + 已知限制 #7 explicit |
| H2 | high | key field 在 fields[] with default null 矛盾 OC non-optional | `storedFields[]` 不含 key；key 是頂層 object with `field/type/fromEventPayload`；validation rule explicit |
| H3 | high | Payload discovery 未指明走 useCases[].eventPayload | 新增 `resolvePayload` 演算法 §（Pass-1 direct → Pass-2 via useCases join → Pass-3 empty）|
| H4 | high | A10 swift test 跑不了 skill+AskUserQuestion | A10 改測 `ReadModelBundleAppender.append`（Swift fn）；prompt-side 走 A11 manual E2E sign-off |
| H5 | high | A13 ban Sources/ 矛盾 A7 字串要求 | A14 改 whitelist-aware imperative-phrase awk lint；A7 + A14 並存 |
| H6 | high | "no partial writes" vs OVERWRITE 沒 atomic | 弱化承諾：single Write call best-effort；SIGKILL during Write 是 known unmitigated risk #13 |
| M1 | medium | payloadKeyField 不一致 v1 warn-only 沒指明 JS shape | strict v1：要求所有 events 共用同一 key.fromEventPayload；manual entry path 違反時 warn 但寫入（限制 #11）|
| M2 | medium | cross-aggregate readmodel 沒記 event sourceAggregate | `events[].sourceAggregate` 強制 present；schema 變更 §載明 |
| M3 | medium | success 訊息叫 user re-run `genesis new` 但 Phase 1.g 未 ship | success message 加 Phase 1.g 狀態聲明 + registry pointer |
| M4 | medium | streamPrefix 公式 internally inconsistent | 新 §streamPrefix-resolution：precedence 表 + alias map + 例子 |
| L1 | low | 250-line cap 偏緊 + 引用 personal skill 行數錯誤 | A2 提升 300（advisory）；§來源 ref 改「~180 行」避免精確錯誤 |
| L2 | low | zero events aggregate → step 3 require ≥1 衝突 | failure modes 加「Chosen aggregate 有 0 events → exit 1」 |
| M6 (new) | medium | global vs project-local skill precedence 未驗證 | 限制 #6 加 acceptance check A15（manual E2E `/readmodel --help`）|

---

## Spec self-check (4b 通用規則)

- [x] 無 line 錨點（不依賴具體 line numbers）
- [x] Goals / Non-goals 互斥（Goals 寫 bundle structural shape；Non-goals: 不生 Swift, 不執行 genesis new, 不存 mutation 邏輯）
- [x] Agent / Human 分段（A1-A10/A12-A14 = Agent runnable；A11 = Human E2E sign-off；implementation steps mixed）
- [x] 無 ≥N counts（除「6 steps」是設計常數，「14 known limits」反映實況）
- [x] depends_on 透明: phase-1d-install-skills (DONE) 為 hard dep；Phase 1.g 為 soft dep

## Spec self-check (5b 內部一致性)

- [x] D1 skill 不生 code ↔ A14 whitelist-aware lint ↔ §framework constraints — 一致
- [x] D2 revised schema ↔ Step 5 設 key object ↔ Step 6 設 storedFields[] ↔ A6 grep keys — 一致
- [x] resolvePayload algorithm ↔ Step 3/5/6 引用 ↔ A6 grep `resolvePayload` ↔ 限制 #1 reflects Pass-3 fallback — 一致
- [x] events[].sourceAggregate 強制 ↔ field validation 表 ↔ M2 fix — 一致
- [x] strict single-key constraint ↔ Step 5 manual path ↔ 限制 #11 reflects warn-not-block ↔ M1 fix — 一致
- [x] streamPrefix resolution precedence ↔ 限制 #8 (alias map) + #9 (string-vs-object) ↔ M4 fix — 一致
- [x] A10 Swift fn + A11 manual E2E + A14 awk lint ↔ failure modes process-SIGKILL 為 known risk #13 — 一致
- [x] success message Phase 1.g pointer ↔ 後續任務 Phase 1.g 列 ↔ depends_on soft — 一致

