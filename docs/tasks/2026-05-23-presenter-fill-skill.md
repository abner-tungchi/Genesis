# /presenter-fill skill v1 — fill read-side AS execute() body (per-aggregate)

## 來源

討論：`docs/discussions/2026-05-23-presenter-fill-skill.md`

Ground truth refs：
- OC read-side AS（array）：`OpportunityContext/Sources/QuotationAggregate/Adapter/GetContractNotes/GetContractNotesApplicationService.swift`
- OC read-side AS（scalar + fallback）：`GetFontSize/GetFontSizeApplicationService.swift`
- OC Presenter（projector）：`GetContractNotes/GetContractNotesPresenter.swift`

依賴 Phase（全 done）：phase-1f（ContextShared infra）、phase-1g（per-aggregate ReadModel + Presenter projector codegen）、phase-1k（read-side AS scaffold + ApiHandler read method）。

**OC 架構核對（2026-05-23）**：body pattern 已對照 OC 多個 read-side AS 確認逐字相符 —— `{Name}Presenter(coordinator: .init(client: kdbClient, eventMapper: {Name}EventMapper()))`、`presenter.execute(input:)?.readModel`、`guard let readModel else { throw }`（GetPurpose）、`ProjectionReadInconsistency(cause:message:)`（GetQuotationIdByQuotingCaseGroupingId 等廣用）。唯一有意偏離見已知限制 #2。

## 目標

`/presenter-fill` 是 `/api` 的 read-side sibling。Phase 1.k 對 bundle.presenters[] codegen 出 read-side `{Name}ApplicationService.swift`，其 `execute()` body 留 `fatalError("TODO(/presenter-fill skill)")`。本 skill **只填這一處** body —— 透過 plugin-generated 的 `{R}Presenter`（projector）+ `kdbClient` 抓 readModel，依 output kind map 到 Output。**不**生成新檔、**不**動 type signature / imports / framework，**不**碰已 codegen 完成的 ApiHandler read method。

**v1 scope = per-aggregate only**（D1）：readModel 與 presenter 同一 aggregate（projector 與 read-side AS 同 module，無 import、無 circular dependency）。cross-aggregate（readModel.aggregateRef = `<context-level>`）presenter 因 `IAMContext → {A}Aggregate → IAMContext` 循環依賴無法填 → exit with hint，defer Phase 1.k.2。

---

## 介面合約

### Skill invocation

```
/presenter-fill <presenterName>
```

- `<presenterName>`：read-side AS / presenter 名（e.g. `GetUserAccessProfileRoles`）。對應 `{presenterName}ApplicationService.swift`。
- 工作目錄 = Genesis-bootstrapped project（Phase 1.g + 1.k scaffold 已產生）。
- 空 arg → exit 1（hint 用法）。

### Inputs the skill reads

| Path | Purpose | Required? |
|---|---|---|
| `Sources/<A>Aggregate/Adapter/<presenterName>/<presenterName>ApplicationService.swift` | read-side AS scaffold — 取 Input keyField、Output type（kind+optional）、TODO 註解（Presenter type + elementSource） | YES |
| `Sources/<A>Aggregate/**/<PresenterType>.swift`（projector） | 確認 projector 與 AS **同 module** 存在；不在同 module → cross-aggregate / prerequisite fail | YES |
| `Sources/<A>Aggregate/<A>Error.swift` | 確認 domain error enum 存在（throw chain 用） | YES |

> **self-describing scaffold**：read-side AS 的 TODO 註解格式為
> `// TODO(/presenter-fill skill): fetch via <PresenterType> (projector) and map readModel.<elementSource> to Output`。
> skill 從此行 parse `<PresenterType>` 與 `<elementSource>`，不需讀 bundle JSON。

### Outputs the skill modifies (in-place edit)

| Path | Operation |
|---|---|
| `Sources/<A>Aggregate/Adapter/<presenterName>/<presenterName>ApplicationService.swift` | 替換 `fatalError("TODO(/presenter-fill skill): ...")` 整段為實際 fetch + map body |

**唯一一個 fill category**（不像 /api 有 4 個）。ApiHandler read method 已被 Phase 1.k 完整 codegen，本 skill 不動。

### 衍生符號規則（從 scaffold parse）

設 AS 名 = `N`、TODO 解析出的 `<PresenterType>`（e.g. `GetUserAccessProfileRolesPresenter`）：

| symbol | 規則 | 實例 |
|---|---|---|
| Presenter type | TODO 註解 regex `fetch via (\w+Presenter)`；須 `hasSuffix("Presenter")` | `GetUserAccessProfileRolesPresenter` |
| eventMapper | `<PresenterType>` **去尾** `Presenter` suffix（`hasSuffix` 後 dropLast(9)）+ `EventMapper`（audit L8：suffix-strip，**非**全字串 replace） | `GetUserAccessProfileRolesEventMapper` |
| elementSource | TODO 註解 regex `map readModel\.([A-Za-z_][A-Za-z0-9_]*) to Output`；須 single Swift identifier，不符 → exit 3（audit M4） | `roles` |
| keyField | AS Input struct **唯一** field 名（**v1 限定 1 field**；>1 → exit 3，audit H2） | `userId` |
| `<A>` | AS 路徑 `Sources/<A>Aggregate/` | `UserAccessProfile` |
| readModel type | **不需顯式 naming** — 由 `presenter.execute(...)?.readModel` 型別推導 | — |

ReadModel local var 型別由 `presenter.execute(input:)?.readModel` 推導（Swift 型別推斷），skill 不需知道 `{stripGet}ReadModel` 名。

> **單一 input field 限制（audit H2）**：projector Input（`{Name}Input: CQRSProjectorInput`）只 wrap 單一 `id`，多出的 AS Input field（如 `filter`）是 fetch 後的 domain filter 邏輯（參 OC `GetContractNotes` 手寫 filter），無法自動填。v1 只支援 AS Input 恰 1 field（即 projector key）；>1 field → exit 3 defer v2。

### Output kind / optionality 偵測（從 AS `typealias Output`）

parser（audit L9）：取 `typealias Output = ` 後字串，**trim whitespace + 去 trailing comment**，得 `raw`：

| `raw` 判定（依序） | kind | nil 處理 |
|---|---|---|
| `raw.hasSuffix("?")` | optional single/scalar | `return readModel?.<elementSource>` 不 throw |
| `raw.hasPrefix("[") && raw.hasSuffix("]")` | array（non-optional） | throw on nil |
| 其他（plain identifier） | non-optional single/scalar | throw on nil |

> 其他格式（`[X]?`、`Array<X>`、`Optional<X>`、泛型）不在 v1 grammar → exit 4（scaffold integrity）。Phase 1.k 現行 renderer 只 emit 上述三式（見 `PresenterRenderer.outputType`），故 v1 足夠。

### Framework constraints（沿用，不可破壞）

- 型別來自 Phase 1.f `<Ctx>Shared`：`ApplicationService`、`ContextError<E>`、`ProjectionReadInconsistency`。
- `{R}Presenter` / `{R}EventMapper` / `{R}ProjectorProtocol`：plugin-generated（Phase 1.g projection-model.yaml + event-generator-config.yaml）。
- `KurrentDBClient` / `KurrentStorageCoordinator`：KurrentDB（read-side AS scaffold 已 `import KurrentDB`）。
- `presenter.execute(input:)?.readModel` 為 optional（CQRSProjector 行為）。

### Exit codes

- `0`: success — body 填好 / 已填過（idempotent skip）。
- `1`: prerequisite missing — AS scaffold 缺、`<A>Error.swift` 缺、projector 完全不存在、或 arg 空。
- `3`: **out-of-scope / defer**，含三種（皆 hint defer）：
  - **cross-aggregate**（audit M5）：`<PresenterType>` projector 不在 AS 同 module，而在 `Sources/<Context>/Projector/` 找到（exactly 1 match，不在 `<A>Aggregate`）→ hint「需 Phase 1.k.2 先修 AS placement」。
  - **multi-input-field**（audit H2）：AS Input 有 >1 field（key + filter 等）→ filter 屬 domain 邏輯無法自動填，hint「multi-field presenter 需 manual fill / defer v2」。
  - **elementSource 非 single Swift identifier**（audit M4）：不符 `^[A-Za-z_][A-Za-z0-9_]*$`（dotted path / key path）→ defer v2。
- `4`: **scaffold corrupted / ambiguous**（audit H3+M5+M6）：marker/block shape 不符；同名 presenter AS 命中 **≥2 aggregate**（列候選，提示 `/presenter-fill <Aggregate>.<Presenter>` v2 syntax）；cross-aggregate projector match **≥2**（ambiguous，列 paths）；half-filled（execute body structural invariant 未滿足）。

> exit 2（/api 用於 read-UC out-of-scope）在本 skill **不適用且不使用** —— AS 由 `<presenterName>` 定位到 `Adapter/<presenterName>/`，該路徑只對 presenters[] 存在，不會誤入 write-side UC。保留號碼語意空缺以對齊 /api。

---

## 實作步驟

### Step 1 — SKILL.md 主體（`~/.claude/skills/presenter-fill/SKILL.md` + Genesis bundled mirror）

frontmatter：`name: presenter-fill`、`disable-model-invocation: true`、`allowed-tools: Read, Edit, Glob, Grep`、`argument-hint: [presenterName]`。

5-Phase flow（**注意 idempotent 先於 parse**，audit H1）：

```
Phase 0: arg parse（空 → exit 1）
Phase 1: locate AS（Glob Sources/*Aggregate/Adapter/<presenterName>/<presenterName>ApplicationService.swift）
         → 0 match → exit 1
         → ≥2 match（同名跨 aggregate，audit H3）→ exit 4，列候選
         → 1 match → 取 <A> from 路徑
Phase 2: 抽 `package func execute(input: Input)` block，先做 idempotent structural invariant（audit H1+M6）：
         → 已完整填（block 內含 let presenter= / coordinator: .init(client: kdbClient / presenter.execute(input: / readModel / return，且無 fatalError 無 TODO）→ exit 0 skip
         → 半填（fatalError/TODO 消失但缺上述任一）→ exit 4
         → 未填（block 內含 `fatalError("TODO(/presenter-fill skill)`）→ 續 Phase 3
Phase 3: parse 未填 scaffold — AS Input fields（>1 → exit 3 multi-field，audit H2；取唯一 keyField）、
         Output type（kind+optional，見上方 parser）、TODO 註解的 <PresenterType>（須 hasSuffix Presenter）
         + <elementSource>（須 single identifier，否則 exit 3，audit M4）
Phase 4: locate projector — Glob Sources/<A>Aggregate/**/<PresenterType>.swift
         → 同 module 找到（≥1）→ 續；
         → 否則 Glob Sources/*/Projector/**/<PresenterType>.swift：exactly 1 match 不在 <A>Aggregate → exit 3（cross-aggregate）；≥2 → exit 4（ambiguous，列 paths，audit M5）；
         → 都沒有 → exit 1（prerequisite）
Phase 5: fill execute() body（依 output kind/optional，見下方 body 形狀）
```

### Step 2 — execute() body 形狀（Phase 5 emit）

`<PresenterType>` 簡寫 `P`；`eventMapper = P` 把 `Presenter` 換 `EventMapper`。

**non-optional output（`X` 或 `[X]`）**：
```swift
    package func execute(input: Input) async throws -> Output {
        let presenter = <P>(coordinator: .init(client: kdbClient, eventMapper: <eventMapper>()))
        guard let readModel = try await presenter.execute(input: .init(<keyField>: input.<keyField>))?.readModel else {
            throw ProjectionReadInconsistency(
                cause: "<presenterName>",
                message: "read model not found for \(input.<keyField>)"
            )
        }
        return readModel.<elementSource>
    }
```

**optional output（`X?`）**：
```swift
    package func execute(input: Input) async throws -> Output {
        let presenter = <P>(coordinator: .init(client: kdbClient, eventMapper: <eventMapper>()))
        let readModel = try await presenter.execute(input: .init(<keyField>: input.<keyField>))?.readModel
        return readModel?.<elementSource>
    }
```

> **D2**：non-optional nil → `ProjectionReadInconsistency`（Phase 1.f infra，保證 compile）→ `ApiHandler.mapToApiError` 回 nil → 503。404/422 精確語意需 designated domain notFound case → defer v2。
> **D3**：value mapping 一律直接 `readModel.<elementSource>`（假設 readModel field 型別 = Output element type）。per-element `.map { Dto(...) }` transform → defer v2。

### Step 3 — idempotent structural invariant（Phase 2，**先於 parse**，audit H1+M6）

**先抽 `package func execute(input: Input)` 的 body block**，所有判定只在此 block 內（避免 comment / 其他 method 字串誤判，audit M6）：

| 狀態 | 判定（皆限 execute block 內） | 動作 |
|---|---|---|
| 已完整填 | 含 `let presenter =` + `coordinator: .init(client: kdbClient` + `try await presenter.execute(input:` + `readModel` + `return`，且**無** `fatalError`、**無** `TODO(/presenter-fill skill)` | exit 0 skip |
| 未填 | 含 `fatalError("TODO(/presenter-fill skill)` | 續 Phase 3 fill |
| 半填 | 上述兩者皆非（fatalError/TODO 消失但缺 presenter.execute / return 等） | exit 4 |

> idempotent 必須先判（Phase 2），**不可**先 parse TODO 註解 —— 已填過的 body 其 TODO 註解已被移除，先 parse 會誤觸 exit 4 而非 exit 0（audit H1）。

### Step 4 — docs + registry + tests

- `docs/decisions.md`：加 /presenter-fill skill v1 ratification entry。
- `docs/architecture.md`：§10.12 /presenter-fill flow（read-side sibling of §10.11 /api）。
- `Tests/GenesisCoreTests/SkillInstallerTests.swift`：installed skill count 7 → 8，expected list 加 `presenter-fill`。
- 新 e2e fixture：per-aggregate readModel + per-aggregate presenter（readModel + presenter 同 aggregate），供 manual E2E。

---

## 失敗路徑

| 場景 | exit | stderr |
|---|---|---|
| arg 空 | 1 | `usage: /presenter-fill <presenterName>` |
| AS scaffold 缺（0 match） | 1 | `prerequisite missing: <presenterName>ApplicationService.swift not found; run genesis new` |
| 同名 AS 命中 ≥2 aggregate（audit H3） | 4 | `ambiguous presenter <presenterName> in aggregates [...]; use /presenter-fill <Aggregate>.<Presenter> (v2)` |
| `<A>Error.swift` 缺 | 1 | `prerequisite missing: <A>Error.swift` |
| AS Input >1 field（multi-field，audit H2） | 3 | `multi-field presenter input (filter logic) not auto-fillable in v1; manual fill or defer v2` |
| elementSource 非 single Swift identifier（audit M4） | 3 | `elementSource '<x>' is not a simple identifier; manual fill or defer v2` |
| projector 在 `Sources/<Context>/Projector/`（cross-aggregate，1 match） | 3 | `cross-aggregate presenter (<context-level> readModel) not fillable in v1 — needs Phase 1.k.2 to relocate read-side AS to context target` |
| context-level projector match ≥2（audit M5） | 4 | `ambiguous projector <PresenterType> in [...]; manual disambiguation needed` |
| projector 不存在於任何位置 | 1 | `prerequisite missing: <PresenterType> projector not generated; run /readmodel + genesis new first` |
| 半填（execute block structural invariant 未滿足） | 4 | `partial fill detected in <file>; manual repair needed` |
| TODO 註解 shape 不符（parse 不到 PresenterType/elementSource，且 block 未填） | 4 | `scaffold integrity check failed; cannot parse projector reference` |
| Output type 非 v1 grammar（`[X]?`/`Array<X>`/泛型） | 4 | `unsupported Output type grammar; manual fill` |
| idempotent re-run（已完整填） | 0 | `nothing to do — execute body already filled` |

---

## 不改動的部分

除上述 read-side AS execute() body 外，其他檔案均不改動。特別是：

- **不動 ApiHandler read method**（Phase 1.k 已完整 codegen）。
- 不動 read-side AS 的 type signature / Input/Output struct / imports / `init`。
- 不動 projector（Presenter / ReadModel）— 那是 Phase 1.g codegen + `/readmodel-mutation` v2 的事。
- 不寫 openapi.yaml / event.yaml / Package.swift / 任何 *.yaml。

### Non-goals（行為層）

- 本 task 不處理 cross-aggregate（context-level readModel）presenter（D1 defer Phase 1.k.2）。
- 本 task 不做 per-element DTO `.map` transform（D3 defer v2）。
- 本 task 不提供 404/422 精確 not-found 語意（D2，non-optional nil 統一 503）。
- 本 task 不填 projector 的 `when()` body（`/readmodel-mutation` v2）。
- 本 task 不修 Phase 1.k 的 read-side AS TODO 註解 hardcode per-aggregate path 的 bug（記錄於已知限制，Phase 1.k.2 修）。
- 本 task 不 bump Genesis 版本（skill 內容變動，非 renderer，與 /readmodel / /presenter / /api skill ship 一致）。

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
S=~/.claude/skills/presenter-fill/SKILL.md
B=Sources/GenesisCore/Resources/Templates/skills/presenter-fill/SKILL.md

# A1. SKILL.md 存在 + LoC ≤ 200
test -f "$S"
[ $(wc -l < "$S") -le 200 ]

# A2. 5+ Phase sections
[ $(grep -cE '^## (Phase [0-5]|Step [0-5]|步驟 [0-5])' "$S") -ge 5 ]

# A3. 單一 fill category 明示 + scaffold marker
grep -F 'TODO(/presenter-fill skill)' "$S"
grep -F 'execute' "$S"
grep -F 'fatalError' "$S"

# A4. 關鍵符號規則
grep -F 'EventMapper' "$S"
grep -F 'Presenter' "$S"
grep -F 'readModel' "$S"
grep -F 'ProjectionReadInconsistency' "$S"

# A5. D1 cross-aggregate defer 明示
grep -F 'cross-aggregate' "$S"
grep -F 'Phase 1.k.2' "$S"

# A5b. audit-driven guards 明示（multi-field / ambiguity / idempotent-first）
grep -F 'multi-field' "$S"
grep -Fe '同名' -e 'ambiguous' "$S"
grep -F 'idempotent' "$S"

# A6. output kind 三態
grep -F 'optional' "$S"
grep -F 'array' "$S"

# A7. 不動 ApiHandler 明文（D18-style 限制）
grep -F '不動 ApiHandler' "$S"
grep -F '不寫 openapi.yaml' "$S"

# A8. bundled mirror byte-identical
diff "$S" "$B"

# A9. docs updates
grep -F '/presenter-fill' docs/decisions.md
grep -F '/presenter-fill' docs/architecture.md

# A10. install-skills regression（install-skills 要求 project-dir 須先存在）
swift build
mkdir -p /tmp/presenter-fill-install-test
./.build/debug/genesis install-skills --scope project --project-dir /tmp/presenter-fill-install-test --force
test -f /tmp/presenter-fill-install-test/.claude/skills/presenter-fill/SKILL.md

# A11. SkillInstallerTests count bump（8 skills）
grep -F 'presenter-fill' Tests/GenesisCoreTests/SkillInstallerTests.swift
swift test --filter SkillInstallerTests
```

### Human 補做（需要人類介入）

對 per-aggregate e2e tree（新 fixture：readModel + presenter 同 aggregate）：

- [ ] 跑 `/presenter-fill <presenterName>` → 確認 execute() body 填好（fatalError 消失、有 `presenter.execute` + `return`），`swift build` Build complete（**驗證 `{R}EventMapper` plugin symbol 真實存在** — 此為最高風險點）。
- [ ] non-optional output：確認 nil 路徑 throw `ProjectionReadInconsistency`；optional output（另一 fixture/手改 isOptional）：確認 `return readModel?.field` 無 guard。
- [ ] 對 cross-aggregate presenter（`iam-presenter-bundle`）跑 → 確認 exit 3 + hint。
- [ ] idempotent：重跑同 presenter（**body 已填、TODO 註解已移除**）→ exit 0 skip，body 不重複填（audit H1 回歸）。
- [ ] 偽造半填（刪 fatalError 但不加 presenter.execute）→ exit 4。
- [ ] multi-input-field presenter（input.fields = [key, filter]）→ exit 3（audit H2）。
- [ ] 同名 presenter 在 2 個 aggregate 各有一個 AS → exit 4（audit H3）。

---

## 已知限制

1. **v1 per-aggregate only**（D1）：cross-aggregate（context-level readModel）presenter → exit 3，defer Phase 1.k.2（需把 read-side AS 從 `{A}Aggregate` 搬到 `{Context}` target 解循環依賴）。
2. **non-optional nil 統一 503**（D2）：`ProjectionReadInconsistency` → mapToApiError nil → `.serviceUnavailable`。404/422 精確語意需 designated domain notFound case，defer v2。read-side ApiHandler 本就無 404 path（Phase 1.k codegen 限制）。
   **與 OC 的有意偏離**：OC 在 domain error **有** notFound case 時（如 `QuotationError.quotationNotFound`，見 `GetPurposeApplicationService`）優先 `throw ContextError<{A}Error>(error: .quotationNotFound, ...)` → 422 精確語意；只在無 domain case 或真 inconsistency 時才用 `ProjectionReadInconsistency`（如 `GetQuotationIdByQuotingCaseGroupingId`）。Genesis bundle 產的 `{A}Error` 不保證有 notFound case（`UserAccessProfileError` 即無），故 v1 **統一**用 `ProjectionReadInconsistency`（OC-valid pattern，只是用得比 OC 廣）。v2 候選：bundle/adapter 標 designated notFound domain case → 對齊 OC 的 422 idiom。
3. **直接 field access**（D3）：假設 `readModel.<elementSource>` 型別 = Output element type。型別不符（需 per-element `.map` DTO transform）→ build fail，user manual fill；defer v2。
4. **`{R}EventMapper` plugin symbol 信任**：假設 Phase 1.g projection plugin emit `{R}EventMapper`（與 OC 一致）。pickup 的 real e2e build 為唯一可靠驗證。
5. **scaffold self-describing 依賴**：skill 從 TODO 註解 parse PresenterType + elementSource。Phase 1.k 改 scaffold 格式 → 需同步本 skill parse 規則。
6. **Phase 1.k scaffold bug 未修**：read-side AS TODO 註解 hardcode `Sources/{A}Aggregate/Usecase/Projector/...`（context-level 時錯）；ReadModel type 名 `{stripGet}ReadModel`。本 skill 不依賴該註解的 Reference path（只 parse PresenterType + elementSource），故不受影響；bug 本身留 Phase 1.k.2 修。
7. **不 bump 版本**：skill 內容變動，非 renderer。
8. **v1 單一 input field only（audit H2）**：projector Input 只 wrap 單一 key；多 field（key + filter）的 filter 屬 domain 邏輯（OC GetContractNotes 手寫），無法自動填 → exit 3 defer v2。
9. **同名 presenter 跨 aggregate / cross-agg projector 多 match（audit H3+M5）**：v1 不自動 disambiguate → exit 4 列候選；`/presenter-fill <Aggregate>.<Presenter>` syntax defer v2。
10. **idempotent 必須先於 parse（audit H1）**：已填 body 的 TODO 註解已移除，先 parse 會誤判半填；故 Phase 2 先做 execute-block structural invariant。
11. **elementSource / Output 限定 v1 grammar（audit M4+L9）**：elementSource 須 single Swift identifier、Output 須 `[X]`/`X?`/`X` 三式；key path / 泛型 / `Array<X>` → exit 3/4 defer。
12. **上游 Phase 1.k 限制（E2E 2026-05-23 發現，非本 skill）**：scalar output 配 collection elementType（如 `Set<String>`）時，Phase 1.k 的 openapi GET response + ApiHandler read method codegen 會把它當 array container（`OpenAPIArrayContainer`）→ 與 AS Output 型別錯配 → **project build fail**。/presenter-fill 的 fill 本身正確（AS body type-check 通過），但 ApiHandler（本 skill 不碰）編不過。→ 此類 presenter output 應避免 collection scalar，或待 Phase 1.k.x 修 openapi scalar 型別處理。本 skill exit 0 仍會填，build 失敗由上游 codegen 負責。
13. **依賴關係**：phase-1f / phase-1g / phase-1k（全 done）。

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals（1 fill category，per-aggregate read-side AS body）↔ Non-goals（不動 ApiHandler / 不寫 openapi / 不處理 cross-agg / 不做 .map transform）互斥
- [x] depends_on: phase-1f + phase-1g + phase-1k（全 DONE）
- [x] A1-A11 Agent runnable；Human E2E 段獨立列
- [x] 8 known limits 不與 acceptance 衝突
- [x] code sample 對照真實 OC（GetContractNotes/GetFontSize）+ 真實 Genesis scaffold（/tmp/rm-e2e 驗證符號）

---

## Audit findings resolution (Codex external 2026-05-23)

3H + 4M + 3L，全套修進 spec：

| ID | 嚴重 | 問題 | 修法 | 反映於 |
|---|---|---|---|---|
| H1 | 高 | parse TODO 先於 idempotent → 已填 body（TODO 已移除）重跑誤判 exit 4 | idempotent structural invariant 移到 Phase 2，先於 parse；未填才 parse TODO | Phase flow / Step 3 / known limit 10 |
| H2 | 高 | keyField 假設單欄，但 PresenterRenderer 允許多 input field（key+filter）→ 多欄 init compile fail | v1 限定單一 input field；>1 → exit 3 defer | 符號表 / exit 3 / known limit 8 |
| H3 | 高 | 同名 presenter 跨多 aggregate ambiguity 未定義 | ≥2 match → exit 4 列候選 | Phase 1 / exit 4 / known limit 9 |
| M4 | 中 | elementSource regex 過窄、無 identifier contract | 限定 `^[A-Za-z_][A-Za-z0-9_]*$`，不符 → exit 3 | 符號表 / exit 3 |
| M5 | 中 | cross-agg projector 多 match / path convention 未收斂 | exactly 1 match 不在 `<A>Aggregate` → exit 3；≥2 → exit 4 | Phase 4 / exit 4 |
| M6 | 中 | idempotent invariant 太鬆、未限定在 execute body | scope 到 `execute(input:)` block，強化已填條件 | Step 3 |
| M7 | 中 | exit 2 無可執行 predicate | 移除 exit 2（AS 由 presenterName 定位，不會誤入 write-side），保留號碼語意空缺 | exit codes |
| L8 | 低 | eventMapper 全字串 replace 風險 | `hasSuffix("Presenter")` + dropLast(9) + EventMapper | 符號表 |
| L9 | 低 | Output kind parser normalize 規則未寫 | trim + 去 comment + hasSuffix/hasPrefix；其他 grammar → exit 4 | Output kind 表 |
| L10 | 低 | known limits 沒接住 idempotent-ordering / multi-field / ambiguity / output-grammar | 補 known limit 8-11 | known limits |

---

## Sign-off

- [x] write-spec output reviewed
- [x] **audit-spec pass — Codex external 2026-05-23**：3H+4M+3L 全套修。內部 4b/5b 全 PASS（無 line 錨點、Agent/Human 分段、無 ≥N、depends_on phase-1f/1g/1k 皆 done）。body pattern 已對照 OC 逐字驗證。
- [x] decisions.md ratification（/presenter-fill skill v1 條目）+ architecture.md §10.12
- [x] registry status: ready → **done**（SKILL.md 125 行 authored + 全 acceptance gate PASS + real E2E swift build PASS 56.65s + 驗證 `{R}EventMapper` plugin symbol；E2E 順帶發現上游 Phase 1.k scalar-collection openapi 限制，記入 known limit 12）
