# /readmodel-mutation skill v1 — fill projector when() body (per-Presenter)

## 來源

討論：`docs/discussions/2026-05-25-readmodel-mutation-skill.md`

OC ground truth refs：
- set scalar：`Sources/QuotationAggregate/Usecase/Projector/GetFontSize/GetFontSizePresenter.swift`（`readModel.fontSize = event.fontSize`）
- append struct + removeAll predicate + updateAt by id：`Sources/QuotationAggregate/Usecase/Projector/GetContractNotes/GetContractNotesPresenter.swift` + `GetPaymentItems/GetPaymentItemsPresenter.swift`
- anchor set 多 field：各 read 的 `QuotationCreated` handler

依賴 Phase（全 done）：phase-1f / phase-1g / phase-1g.2 / phase-1k / phase-1k.2 / 2026-05-23-presenter-fill-skill。

## 目標

`/readmodel-mutation <presenterName>` 是 `/api`、`/presenter-fill` 的第三個 in-place fill skill。對指定 readModel projector（`{Name}Presenter.swift`），逐個 `when(readModel: inout R, event: E)` 方法填 mutation body 取代 Phase 1.g 留下的 `_ = readModel; _ = event;` stub。AI 依 5 patterns 對應 event payload 與 readModel storedFields 型別，emit 對應 mutation 語句。**不**動 type signature / imports / framework / scaffold-once 範圍外的檔案。

**v1 scope = per-Presenter**（D2）：一次填一個 presenter 的所有 when() body。

---

## 介面合約

### Skill invocation

```
/readmodel-mutation <presenterName>
```

- `<presenterName>`：projector / presenter 名（e.g. `GetUserAccessProfileRoles`、`GetContractNotes`）。對應 `{presenterName}Presenter.swift` 內所有 `when()` 方法。
- 工作目錄 = Genesis-bootstrapped project（Phase 1.g/1.k.2 projector scaffold 已產生）。
- 空 arg → exit 1。

### Inputs the skill reads

| Path | Purpose | Required? |
|---|---|---|
| `Sources/<A>Aggregate/Usecase/Projector/<presenterName>/<presenterName>Presenter.swift`（per-agg） 或 `Sources/<contextName>/Projector/<presenterName>/<presenterName>Presenter.swift`（context-level） | projector scaffold — 取所有 `when(readModel: inout ReadModelType, event: <E>)` 方法 + ReadModelType reference | YES |
| `Sources/<A>Aggregate/Usecase/Projector/<presenterName>/<stripGet(presenterName)>ReadModel.swift` 或 context 變體 | ReadModel 的 storedFields 型別（決定 collection / scalar / Set） | YES |
| `Sources/<A>Aggregate/event.yaml` / `Sources/<contextName>/event.yaml`（plugin input） | event payload 結構（每個 event 的 payload fields） | YES |

> **self-describing scaffold**：projector 已有 stub `when(readModel: inout ReadModelType, event: <EventTypeName>) throws { _ = readModel; _ = event; }`。skill 從這些 method signature parse 每個 event 的 typeName。

### Outputs the skill modifies (in-place edit)

| Path | Operation |
|---|---|
| `<presenterName>Presenter.swift`（per-agg 或 context-level） | 每個未填的 `when()` method：替換 `_ = readModel; _ = event;` placeholder 為實際 mutation body |

### 5 patterns + heuristic（v1 必含）

設 `event` 為 plugin-generated event payload struct（fields from event.yaml）；`readModel` 為 ReadModelType（fields from `{stripGet}ReadModel.swift` storedFields）。

| pattern | 偵測 heuristic | emit body |
|---|---|---|
| **set scalar** | event name 含 `Created` / `Edited` / `Updated` / `Set`，event payload 有同名 scalar field 對應 readModel storedField | `readModel.<f> = event.<f>` (per matched field) |
| **set anchor 多 field** | event name 含 `Created`，event payload 多個 fields 對應 readModel 多個 storedFields | `readModel.<f1> = event.<f1>`\n`readModel.<f2> = event.<f2>` ... |
| **append struct entry** | event name 含 `Added` / `Created`（when readModel storedField 為 Array/Set），event payload fields ⊇ collection element type fields | `readModel.<collection>.append(.init(<field>: event.<field>, ...))` |
| **removeAll by predicate** | event name 含 `Removed` / `Deleted`，event 有 `*Id` field 對應 collection element id | `readModel.<collection>.removeAll { $0.<id> == event.<id> }` |
| **updateAt by id** | event name 含 `Edited` / `Updated` / `Renamed`，event 有 `*Id` field（locator）+ 其他 fields（要更新的 value） | `guard let i = readModel.<collection>.firstIndex(where: { $0.<id> == event.<id> }) else { return }`\n`readModel.<collection>[i].<f> = event.<f>` |

**Set / assignList**（額外配套）：event payload 有單一 `[X]` field 對應 readModel `Set<X>` storedField → `readModel.<setField> = Set(event.<arrayField>)`（v1 簡單支援；複雜 union/diff 留 manual）。

**Pattern priority（self-audit clarification）**：當 event 名同時觸發多個 pattern：

1. 名稱含 `Removed` / `Deleted` 且 event 有 `*Id` 對應 collection elem id → **removeAll** 優先
2. 名稱含 `Edited` / `Updated` / `Renamed` 且 event 有 `*Id` locator + 其他 fields → **updateAt** 優先
3. 名稱含 `Added` 且 payload fields ⊇ collection elem fields → **append** 優先
4. 名稱含 `Created`（anchor event）→ **set anchor 多 field**（即使有 collection storedField，初始為空，不在 anchor event append）；明確 `Created` payload **不對應** 任何 collection 元素 fields。
5. 名稱含 `Set` / `Edited` 但 payload 全 scalar field 直對 readModel scalar storedField → **set scalar**

**out-of-scope（exit 3）**：

- reorder via Dictionary + compactMap、insert-at-position with fallback、cross-event 條件 update
- custom type wrapping（如 OC `PaymentItemServiceItemType(eventPayloadRawValue:)`）
- **append struct 有 collection elem field 不在 payload 中**（self-audit）：如 OC `ContractNoteAddedByUser` event 只有 `noteId, note`，但 readModel `Entry` 還有 `uniqueCode, traits, quotingCaseIds` —— v1 不自動 emit `uniqueCode: nil, traits: [], quotingCaseIds: []` defaults，因為「該不該填 nil/empty」是 domain 決策。exit 3 hint 「append struct: payload 缺 field <X> for collection elem，請 manual 填 default value (nil/[])」。

### Idempotent structural invariant（per-method，granular）

每 `when()` method 在 `package func when(readModel: inout ReadModelType, event: <E>) throws {` 與 `}` 之間 body block：

| 狀態 | 判定 | 動作 |
|---|---|---|
| 已填 | block 含 `readModel.` 開頭的 assignment / method call（`.append(` / `.removeAll(` / `[i].`），且**無** `_ = readModel` `_ = event` placeholder | skip 該 method |
| 未填 | block 含 `_ = readModel` + `_ = event`（Phase 1.g stub，**tolerant matching**：忽略 whitespace、comment 行、placeholder 順序，只要兩個 `_ =` discard pattern 都在即視為未填） | 套 5 patterns 偵測填 |
| 半填 | 兩者皆非（placeholder 消失但無 mutation） | 標記該 method 為 corrupted，整次 exit 4 |

「已填」+「未填」可混雜在同一 file（granular per-method）；全 file 至少有 1 個未填且無半填 → 繼續 fill 未填 + skip 已填，最後印 report。

> **placeholder 偵測 tolerance（self-audit）**：grep 行為要對 whitespace / comment 容差，例如 `_ = readModel  // unused` 也視為「未填 placeholder」。實作 hint：用 line-based grep `^\s*_ = readModel` + `^\s*_ = event`，全 method block 內找到兩個皆視為未填。

### Framework constraints

- `ReadModelType` 由 projector typealias 推導；不需顯式 naming（同 /presenter-fill 推導 pattern）。
- event payload struct（如 `RolesAssigned`、`UserAccessProfileCreated`）由 plugin 從 event.yaml 生成；skill 假設 plugin 已 emit 對應 type。
- 不動 buildReadModel / coordinator / categoryRule 等 framework 部分。

### Exit codes

- `0`: success — 全 method 已填或 skipped-as-already-complete。
- `1`: prerequisite missing — `<presenterName>Presenter.swift` 缺、`<stripGet>ReadModel.swift` 缺、或 arg 空。
- `2`: 保留語意空缺（對齊 /presenter-fill）。
- `3`: out-of-scope — 至少一個 event 無法套 5 patterns 推測（reorder/insert/custom-wrap 等），exit 3 + hint「該 event 留 manual hand-fill」。
- `4`: corrupted / half-filled — 某 method block shape 不符（無 placeholder 又無 mutation） / 多個 `<presenterName>Presenter.swift` ambiguous match。

---

## 實作步驟

### Step 1 — SKILL.md（`~/.claude/skills/readmodel-mutation/SKILL.md` + Genesis bundled mirror）

frontmatter：`name: readmodel-mutation`、`disable-model-invocation: true`、`allowed-tools: Read, Edit, Glob, Grep`、`argument-hint: [presenterName]`。

5-Phase flow（與 /presenter-fill 對稱）：

```
Phase 0: arg parse（空 → exit 1）
Phase 1: locate Presenter（Glob per-agg + context；0→exit 1；≥2→exit 4）
         + locate ReadModel.swift 同 module
Phase 2: parse projector — 取所有 when(readModel: inout ReadModelType, event: <E>) 方法簽名
Phase 3: parse ReadModel storedFields + event payload structs（從 event.yaml）
Phase 4: per method idempotent 檢查 + pattern detection + emit body
         （已填 skip；未填套 pattern；半填 → exit 4 整次 abort；無 pattern → exit 3）
Phase 5: report (filled / skipped-already / skipped-no-pattern)
```

### Step 2 — body emission per pattern（Phase 4 templates）

對每個未填的 `when()` method 內 body block，依 heuristic 選 pattern 後 emit：

**set scalar** —— 對每個 event payload field f 找到 readModel.f 同名同型，emit：
```swift
        readModel.<f1> = event.<f1>
        readModel.<f2> = event.<f2>
```

**append struct** —— readModel.<col>: [X]，event payload fields ⊇ X 的 fields，emit：
```swift
        readModel.<col>.append(.init(
            <field1>: event.<field1>,
            <field2>: event.<field2>
        ))
```

**removeAll** —— event 有 `<X>Id`，readModel.<col> 是 collection of struct with `<X>Id`：
```swift
        readModel.<col>.removeAll { $0.<X>Id == event.<X>Id }
```

**updateAt by id** —— event 有 id locator + 其他 fields：
```swift
        guard let i = readModel.<col>.firstIndex(where: { $0.<X>Id == event.<X>Id }) else { return }
        readModel.<col>[i].<f> = event.<f>
```

**assignList Set<X>** —— event 有 `<arr>: [X]`，readModel.<setField>: Set<X>：
```swift
        readModel.<setField> = Set(event.<arr>)
```

### Step 3 — 修 NewCommand / SkillInstallerTests / docs

- SkillInstaller 動態掃目錄，新 skill 自動 register。SkillInstallerTests count 8 → 9。
- docs/decisions.md：加 /readmodel-mutation v1 ratification entry。
- docs/architecture.md：§10.14 mutation fill flow（與 §10.11 /api、§10.12 /presenter-fill flow 對稱）。

---

## 失敗路徑

| 場景 | exit | stderr |
|---|---|---|
| arg 空 | 1 | `usage: /readmodel-mutation <presenterName>` |
| Presenter.swift 缺 | 1 | `prerequisite missing: <presenterName>Presenter.swift not found; run /readmodel + genesis new` |
| 同名 Presenter ≥2 modules | 4 | `ambiguous presenter <presenterName> in [...]; use /readmodel-mutation <Module>.<Presenter> (v2)` |
| `<stripGet>ReadModel.swift` 缺 | 1 | `prerequisite missing: <stripGet>ReadModel.swift` |
| Pattern 不對應（reorder / insert-at-pos / custom wrap） | 3 | `event <E>: no matching mutation pattern (reorder/insert/custom-wrap not in v1); manual hand-fill required` |
| 半填（placeholder 消失但 readModel mutation 也沒） | 4 | `partial fill detected in when(...event: <E>); manual repair needed` |
| idempotent re-run（全 method 都填） | 0 | `nothing to do — all when() bodies already filled` |

---

## 不改動的部分

除 `<presenterName>Presenter.swift` 的 `when()` body 外，其他檔案均不改動。特別是：

- 不動 ReadModel.swift（那是 /readmodel + Phase 1.g 的範疇）。
- 不動 projector 的 buildReadModel / coordinator / categoryRule 等 framework 部分。
- 不寫 openapi.yaml / event.yaml / Package.swift / bundle JSON / 任何 *.yaml。
- 不動 read-side AS body（那是 /presenter-fill 的範疇）。

### Non-goals（行為層）

- 本 task **不包含** bundle schema 擴展（v1 = in-place fill，per D1）。
- 本 task **不包含** reorder via Dictionary + compactMap pattern。
- 本 task **不包含** insert-at-position with fallback append pattern。
- 本 task **不包含** custom value type wrapping（如 OC `PaymentItemServiceItemType(eventPayloadRawValue:)`）。
- 本 task **不包含** cross-event 條件 update（讀 readModel 其他狀態才決定怎麼變）。
- 本 task **不 bump 版本**：skill 內容變動，非 renderer（與 /readmodel、/presenter、/api、/presenter-fill 一致）。

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
S=~/.claude/skills/readmodel-mutation/SKILL.md
B=Sources/GenesisCore/Resources/Templates/skills/readmodel-mutation/SKILL.md

# A1. SKILL.md 存在 + LoC ≤ 200
test -f "$S"
[ $(wc -l < "$S") -le 200 ]

# A2. 5+ Phase sections
[ $(grep -cE '^## (Phase [0-5]|Step [0-5]|步驟 [0-5])' "$S") -ge 5 ]

# A3. 5 patterns + heuristic 明示
grep -F 'set scalar' "$S"
grep -F 'append' "$S"
grep -F 'removeAll' "$S"
grep -F 'updateAt' "$S"
grep -F 'assignList' "$S"

# A4. 必要關鍵 token
grep -F 'when(readModel:' "$S"
grep -F 'TODO(Phase 1.g)' "$S"  # 識別 Phase 1.g stub marker
grep -F 'readModel.' "$S"
grep -F 'event.' "$S"

# A5. 不動 / D18-style 限制 明示
grep -F '不動 ReadModel' "$S"
grep -F '不寫 openapi.yaml' "$S"
grep -F 'buildReadModel' "$S"

# A6. exit code 1/3/4 明示
grep -F 'exit 1' "$S"
grep -F 'exit 3' "$S"
grep -F 'exit 4' "$S"

# A7. idempotent per-method
grep -F 'idempotent' "$S"
grep -F 'per-method' "$S"

# A8. bundled mirror byte-identical
diff "$S" "$B"

# A9. docs updates
grep -F '/readmodel-mutation' docs/decisions.md
grep -F '/readmodel-mutation' docs/architecture.md

# A10. install-skills regression
swift build
mkdir -p /tmp/rmm-install-test
./.build/debug/genesis install-skills --scope project --project-dir /tmp/rmm-install-test --force
test -f /tmp/rmm-install-test/.claude/skills/readmodel-mutation/SKILL.md

# A11. SkillInstallerTests count bump
grep -F 'readmodel-mutation' Tests/GenesisCoreTests/SkillInstallerTests.swift
swift test --filter SkillInstallerTests
```

### Human 補做（需要人類介入）

對 per-agg readModel projector e2e tree（用 `iam-readmodel-bundle.json` 或派生 fixture）：

- [ ] 跑 `/readmodel-mutation GetUserAccessProfileRoles` → 確認每個 when() body 填了 reasonable mutation（依 event name + payload fields 對應 5 patterns 之一）；`swift build` Build complete。
- [ ] context-level projector 也可填（用 `iam-cross-agg-presenter-bundle.json` 的 GetUserAccessSummary readModel）→ 確認 Phase 1.k.2 context-module projector locate path 正確。
- [ ] idempotent：重跑 → exit 0 skip（filled methods 不重複填）。
- [ ] 偽造半填（刪 stub `_ = readModel; _ = event;` 但不加 mutation） → exit 4。
- [ ] out-of-scope event（reorder-style 命名 + Dictionary compactMap 需求）→ exit 3 + hint。

---

## 已知限制

1. **v1 5 patterns only**：reorder / insert-at-pos / custom-wrap / cross-event 條件 update → exit 3 manual hand-fill。
2. **set scalar 依賴 event payload field name 與 readModel storedField 同名**：rename / divergence 需 manual。
3. **append struct fields 假設 event payload fields ⊇ collection element fields 且同名同型**：不同型（DTO 轉換）→ manual。
4. **AI heuristic 依賴 event name 命名慣例**（Created/Added/Removed/Edited/Updated/Reordered）：非標準命名 → defer 5 pattern 不適用 → exit 3。
5. **per-Presenter scope**：一次填一個 presenter；跨 presenter 共 event 不集中處理。
6. **不擴 bundle schema / renderer**（D1 = A）：bundle 不存 mutation 規則；重 `genesis new` 不會同步 fills（scaffold-once protect existing）。
7. **不 bump Genesis 版本**：與 /readmodel、/presenter、/api、/presenter-fill 一致。
8. **append struct payload-missing-field（self-audit）**：collection elem 有 field 不在 event payload（OC pattern：`uniqueCode: nil, traits: [], quotingCaseIds: []` defaults）→ exit 3 manual hand-fill，因為 default value 屬 domain 決策不可自動推。
9. **pattern priority 規則明示**：見「Pattern priority」段落；event name 同時觸發多 pattern 時依規則決勝負。
10. **placeholder 偵測 tolerance**：tolerant matching 對 whitespace / comment，但仍假設 `_ = readModel` / `_ = event` 兩 line 都存在；user 若手動只刪一個 → 半填 exit 4。
11. **依賴關係**：phase-1f / phase-1g / phase-1g.2 / phase-1k / phase-1k.2 / 2026-05-23-presenter-fill-skill（全 done）。

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals（fill projector when() body）↔ Non-goals（不動 ReadModel / framework / 不擴 bundle / 不做 reorder/insert/custom）互斥
- [x] depends_on: phase-1f/1g/1g.2/1k/1k.2/presenter-fill v1（全 DONE）
- [x] A1-A11 Agent runnable；Human E2E 段獨立列（5 項）
- [x] 8 known limits 不與 acceptance 衝突
- [x] body sample 對照 OC（GetContractNotes/GetPaymentItems/GetFontSize/QuotationCreated 等 5 patterns 都有真實對應）

---

## Sign-off

- [x] write-spec output reviewed
- [⚠️] **audit-spec partial — Codex external 2026-05-25 server overloaded (API 529 三次)，self-audit 抓到 3 個 clarification（pattern priority / append payload-missing-field / placeholder tolerance）已修進 spec**。內部 4b/5b 全 PASS（無 line 錨點、Agent/Human 分段、無 ≥N、6 依賴 phase 皆 done）。Codex 後續可補審；若補審揭露新風險，spec 加 v2 entry。
- [x] decisions.md ratification（/readmodel-mutation v1 條目）+ architecture.md §10.14
- [x] registry status: ready → **done**（SKILL.md 133 行 authored + 20/20 mechanical gate PASS + SkillInstaller 9 skills + real E2E swift build PASS：assignList pattern `readModel.roles = Set(event.roles)` 對 plugin-generated `RolesAssigned.roles` field 真實 compile, GetUserAccessProfileRolesPresenter.swift.o 編出）
