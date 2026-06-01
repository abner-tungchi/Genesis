---
topic: "Genesis domain 層 codegen/fill gap vs OC AuditQuotingAggregate"
status: consensus
created: "2026-06-01"
updated: "2026-06-02"
participants:
  - Claude (Opus 4.8)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 2
mode: default
premises:
  fixed:        # evidence-backed facts（不可挑戰）
    - "PA-F1：genesis new 生成的 write-side domain 層（Entity ensureInvariant() / Commands command method body / Commands when(event:) reducer）全為 GENESIS-STUB 或 fatalError，且無任何 fill skill 覆蓋（/usecase 明文不動 Entity/Command）。read 側 projector when 反而有 /readmodel-mutation。"
    - "PA-F2：create UC 的 Entity init 簽名來自 event payload 全欄位（如 UserAccessProfile.init 含 permissions/roles/status），⊋ use-case Input business fields（僅 userId/department/jobTitle）→ /usecase Create pattern exit 3。"
    - "PA-F3：bundle §3 帶 invariants（name+errorCode+rules）但生成的 ensureInvariant() 是單一空 stub，未展開成 OC 式 named check*() + 順序 dispatch + errorCode throw。"
    - "PA-F4：生成的 <A>Error.swift 只有 bare enum，無 OC 式 extension ContextError where ErrorType==<A>Error 的 per-case static factory。"
    - "DDDKit plugin 從 event.yaml 生 events / <A>AggregateProtocol / EventMapper；DDDKit apply(event:) 在 when 前後各呼 ensureInvariant() 一次。"
    - "OC AuditQuotingAggregate 的 domain 層（ensureInvariant 17 check / command 驗證+apply / when 純 mutation / ContextError factory）全為手寫真實業務邏輯。"
  proposed:     # challengeable
    - "解法方向：domain 層大部分結構是 bundle 機械可導，Genesis 目前 UNDER-generate；應加強 codegen scaffold +（必要時）一個 domain-fill skill 填可導部分，rule body 留 marked TODO（沿用 test-gen scaffold-emitter 哲學）。"
    - "create init 簽名應改為對齊 use-case Input business fields；payload 衍生欄位（permissions/roles/status）在 init/command body 內計算（human/marked），而非進 init 簽名。"
---

# Genesis domain 層 codegen/fill gap vs OC AuditQuotingAggregate

## 議題定義

### 背景
全 pipeline parity audit（`2026-06-01-full-pipeline-parity-audit.md`）發現：Genesis 的 fill skill 覆蓋 orchestration（/usecase execute）、adapter（/api）、read（/readmodel-mutation, /presenter-fill）、test（/test-gen），但 **write-side domain 層（entity command body / when reducer / ensureInvariant / ContextError factory）無 codegen 完整 scaffold、也無 fill skill**。跑完所有現有 skill 後專案 compile-pass 但 runtime fatalError + 不檢查 invariant + replay 不還原 state。

### 目標
定出 Genesis 該怎麼補齊 domain 層以對齊 OC：哪些機械 codegen、哪些 fill skill、哪些 human 手寫；create-init 簽名怎麼修；ensureInvariant / when / ContextError factory 的生成策略。

### 範圍
- 討論內：write-side domain 層的 codegen/fill 策略（C1-C6）。
- 討論外：read 側（已有 /readmodel-mutation）；DDDKit plugin 行為；bundle schema 大改（除非 PA-F2 逼著小調 create payload）；test-gen（已 lock）。

### 子議題
- [ ] C1：domain 層該「新增 fill skill」還是「純 codegen scaffold 加強」還是「明確 human 手寫邊界」？三者比例？
- [ ] C2：create-init 簽名來源 = use-case Input fields vs event payload 全欄位（PA-F2 修法）。payload 衍生欄位（permissions/roles/status）何處來？
- [ ] C3：ensureInvariant() 該否從 bundle §3 機械展開成 named check*() + dispatch + errorCode throw（rule body 留 TODO）？
- [ ] C4：when(event:) reducer 的 `self.<field> = event.<field>` 是否機械可導（state field == payload field 同名）→ 該 codegen 直接填？
- [ ] C5：ContextError factory extension 是否該機械 codegen（純從 error enum cases 導）？
- [ ] C6：codegen/human 邊界 —— domain 層哪些是 bundle 機械可導（結構/簽名/assignment/factory）、哪些是不可導的業務 rule（如 `userPermissions ⊇ baseline(...)`）需 human？對齊 test-gen 的「scaffold 可導、mark 不可導」哲學？

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.8)

**總論點：Genesis 不是「缺一個 domain-fill skill」這麼簡單 —— 而是 domain 層 codegen 目前 UNDER-generate。PA-F1/F3/F4/F5 的大半其實是 bundle 機械可導的結構，應該在 `genesis new` 就生出來（或一個薄 domain skill 填），只有真正的業務 rule body 留 human marked TODO。這跟 test-gen 收斂的「scaffold 可導、mark 不可導」同一哲學。**

- **C5（ContextError factory）→ 純機械，codegen 直接生**。最簡單的一個。OC 的 `extension ContextError where ErrorType==AuditQuotingError { static func invalidBranchCount(function:message:) -> Self {...} }` 對每個 enum case 一個 factory —— 100% 從 error enum cases 導（case 名→factory 名）。Genesis 已生 enum + errorCode，補 factory extension 零業務知識。**先做，無爭議。**

- **C4（when reducer）→ 大半機械**。`when(event: <E>) throws { self.<f> = event.<f> }` 對「state field 與 payload field 同名同型」可直接生（IAM：`UserAccessProfileCreated` payload 有 userId/department/.../status，entity state 同名 → 全可導）。set/collection 的 append（OC `serviceItems.append`）是 add 類 event 的 pattern，較難但有 heuristic。**codegen 可填同名 assignment，非同名/集合操作 mark TODO。**

- **C3（ensureInvariant scaffold）→ 結構機械、condition body human**。bundle §3 有 invariant name + errorCode。可機械生：`ensureInvariant()` 順序呼叫 `checkUserId()`/`checkPermissions()`/`employeeMustActive()`（名來自 invariant name）+ 每個 check stub `func checkUserId() throws { /* TODO: rule */ throw ContextError<...>.userIdNotExist(...) }`。rule body（`⊇ baseline`）human。**對齊 OC 結構，省人寫 dispatch + throw 接線。**

- **C2（create-init）→ 簽名對齊 Input、payload 衍生欄位在 body 算**。現在 init 取 payload 全欄位是錯的抽象 —— init 應取 use-case Input business fields；Created event 需要的額外 payload（permissions/roles/status）在 init body 內計算/查詢（human/marked，因為那是外部員工資料或衍生）。修後 `/usecase` Create pattern 能 fill。**這是 codegen 簽名修 + 留 body TODO。**

- **C1（skill vs codegen vs human）→ 三者混合，但重心在「加強 codegen scaffold」**。我反對「新增一個大 domain-fill skill 填全部」—— 因為 domain rule body（invariant condition、command 驗證邏輯）是真正不可機械導的業務知識，硬填會像 test theater（假裝填了）。正解：(1) codegen 生 C3/C4/C5 的可導結構；(2) rule body 留 marked TODO 給 human（或薄 skill 引導，非自動填）；(3) PA-F2 codegen 簽名修。比例：~70% codegen scaffold 加強、~0% 自動填 rule、100% rule body human marked。

- **C6（邊界）→ 與 test-gen 同哲學**。機械可導：型別簽名、dispatch 接線、event 建構、同名 assignment、error factory。不可導：invariant condition、command 業務驗證、衍生欄位計算來源。後者 mark TODO，不假裝。

**Evidence**：parity audit 檔 PA-F1~F4 + 實證（promoteUser /usecase fill compile EXIT 0、createUserAccessProfile Create exit 3）；OC `AuditQuoting.swift` ensureInvariant + `Entity/Commands/AuditQuoting+EditBranchCount.swift`（command+when pair）+ `AuditQuotingError.swift`（ContextError factory）；生成 `UserAccessProfile.swift`/`UserAccessProfileError.swift`/`UserAccessProfile+PromoteUser.swift`（stub 證據）。

**待 Codex / Gemini R1**：(i) C1 的「加強 codegen 而非大 skill」對不對，還是該有 domain skill？(ii) C2 create-init 改簽名會不會破壞 event payload 完整性 / plugin 契約？(iii) C4 when 機械生同名 assignment 的安全性（會不會生錯誤語意）？(iv) 有沒有漏的 domain 層 misalignment？

#### Codex (GPT-5.4)

**立場**：部分同意 Claude —— 主軸補強 codegen scaffold、不開大 domain-fill skill。但不同意 C2 簡化成「init body 算」、不同意 C4「大半機械」。C3/C5 近純機械，C4 只有極窄 strict-safe subset，C2 需先解 payload provenance。

1. **renderer 可行性**：C3/C4/C5 可落在 codegen，但 `UseCaseRenderer.renderCommandExtension` 目前只拿 `useCase.input`，沒有 aggregate state / event payload mapping → reducer + event-builder 自動化資訊不足。
2. **C5 低成本非零成本**：`ContextError` 在 shared infra，但 `AggregateError.swift` 沒 shared import，且 `AggregateRenderer` 把 shared import 錯誤綁在 DTO/customType 是否存在 → primitive-only aggregate 補 factory 會編譯風險。
3. **C3 DDDKit 約束（載重）**：`DDDKit apply(event:)` 在 `when` 前後各跑 `ensureInvariant()` → 若 check stub 預設 `throw`，會讓**所有** event apply 立即失效。只能生 TODO/no-op skeleton，**不可預設 throw**。
4. **C4 只 strict-safe subset**：OC `EditBranchCount` 安全（`self.branchCount = event.branchCount`），但 `AddAccounting` 是 build ServiceItem + append；dogfood 自己也有反例：`UserPromoted.newJobTitle→state.jobTitle`、`PrivilegeGranted.permissions:[String]→state.permissions:Set<String>?`、`RolesAssigned` 同。同名同型非集合非 old/new pair 才可生。
5. **C2 不破 plugin 契約**（契約綁 event.yaml→generated event/mapper，非 entity init），但 Genesis 把 business init 與 replay init **綁同簽名**，改 input-only 必須**先 split business / rehydration init**。更乾淨解：bundle 標 created payload field provenance（input/derived/external）。
6. **漏掉的 misalignment**：(a) Genesis 連 create UC 也生 `Entity/Commands/<A>+Create….swift`，但 plugin aggregate protocol **不 dispatch Created 到 when(event:)** → 這份 create command/when 是 **dead scaffold**；OC 也沒 create command file。(b) C5 後 primitive-only aggregate 的 conditional shared import 編譯風險（同 §2）。

**C1-C6**：C1 加強 codegen 優先、skill 至多薄 TODO-expander；C2 split init + provenance；C3 dispatch+named check 骨架但**不預設 throw**、留 rules 註解；C4 strict-safe scalar only（同名同型非集合非 old/new），Created event 的 when 不該生（plugin 不走）；C5 直接機械生；C6 可導=error factory/init split/ensureInvariant dispatch/delete reducer/strict-safe scalar reducer，不可導=invariant predicate/command precondition/external lookup/provenance/append-merge-build/type 轉換/newX→state.x 語義。

#### Gemini（systems/maintainability lens）

**淨立場 + reframe：「Honest Emptiness is Safer than Dishonest Structure」**。同意不開 AI domain-fill skill、同意 C5 under-generation 該補；但**強烈反對** scaffold 出 business rule 的「結構」（個別 check*() 或 speculative when()）。10-month view 的最大威脅不是手寫成本，是 **「Domain Theater」** —— 結構上像在護欄、語義上空殼的 code。certainty 只在人腦時，生成單位必須是**剛性、逃不掉的 obligation**（編譯失敗或 runtime fatalError），不是柔軟的結構 stub。

1. **Domain Theater 威脅（C1）**：`func checkPermissions() throws { /* TODO */ }` 讓人六個月後以為 invariant 有保護；忘了填 → 編譯過、跑、靜默接受非法 state。OC `checkTotalAssets()` 多 clause 跨 status，`invariants.md` 只給 `⊇ baseline(...)`（baseline 不存在）→ codegen 無法安全 scaffold。Verdict：**honest blank 勝** —— ensureInvariant 帶 hard stop。
2. **C2 certainty laundering**：同意 Claude，init 拉入非 input 的 payload 欄位 = 逼 caller 捏造/查 data，破壞 aggregate 邊界。derived 欄位留 explicit TODO（cf. OC `status=.draft` default）。
3. **C3 1:1 mapping 謬誤**：bundle 3 invariants → OC 分解成 **17** check*()。emit 3 stubs 反而**約束**開發者的分解。Verdict：**不要 emit check*() stubs**；emit 單一 ensureInvariant 帶 rules inline comment，終止於 obligation，讓人自己分解。
4. **C4 replay silent corruption**：錯猜或靜默跳過複雜 transition 仍編譯 → replay 靜默還原錯 state。保證 1:1 scalar 可 emit；集合/enum/非同名**不可**給 partial 或 blank → emit `fatalError("GENESIS-TODO: implement state transition for <event>")`。test-time crash 勝 production state corruption。

**C1-C6**：C1 agree(no skill)/disagree(scaffold obligation 非 shell)；C2 agree；C3 **disagree**（不要 1:1 check stub）；C4 partial（只 1:1 scalar，其餘 fatalError）；C5 agree（純機械）；C6 hand-off 必須是 unapologetic 的 compile/runtime-breaking obligation，絕不 fake structure。

**facilitator note（Gemini 提）**：中間路 —— error factory 機械生（C5 agreed）但 check 分解留白（C3 Gemini 線），人得到 ergonomic throw site 卻無 false dispatch skeleton。

---

### Round 2 — Synthesis（Claude facilitator）

**收斂：domain 層補強 = 「機械生純可導的（error factory / init split / strict-safe scalar reducer / 移除 dead scaffold）+ 對 rule 層用『誠實 obligation 而非假結構』+ ensureInvariant 受 DDDKit 約束只能 no-op-runnable + commented obligation」。我撤回 R1 的 check*() stub 結構。**

決定性技術事實（仲裁 C3）：**DDDKit `apply(event:)` 在 `when` 前後各呼 `ensureInvariant()` 一次**（`DDDKit/Sources/DDDCore/Entity/AggregateRoot.swift`，我已親驗）。所以 ensureInvariant 預設**不能** throw/fatalError —— 否則 create init 的 apply、replay、每個 command 全炸。這同時 KO 我 R1 的「check stub 預設 throw errorCode」與 Gemini 的「ensureInvariant 帶 fatalError」。ensureInvariant 唯一可行預設 = **runnable no-op**。

**Rejection log（HARD）**：
- ❌ **我 R1「ensureInvariant 機械生 named check*() + 預設 throw errorCode」**：拒絕。(1) DDDKit pre/post-apply → 預設 throw 炸全部（Codex 論點3）；(2) bundle 3 invariant ≠ 開發者的 N check 分解（Gemini：OC 3→17），emit 固定 stub 約束分解 = Domain Theater。
- ❌ **我 R1「C4 when 大半機械（同名 assignment）」**：拒絕。Codex/Gemini 證 strict-safe subset 極窄（type 轉換 [String]→Set、old/new 語義、append/build 全不可）。改採 strict-safe scalar only + 其餘 fatalError。
- ❌ **Gemini「ensureInvariant 帶 fatalError obligation」**：拒絕（在 ensureInvariant 上）。DDDKit pre/post-apply 使其炸毀 runnable baseline（連 create happy-path 都跑不了）。obligation 在 ensureInvariant 只能是 commented TODO + 外部 report，不能是 fatalError。**但** Gemini 的 fatalError-obligation 對 **when() 非 trivial transition** 採納（when 只在該 event apply 時觸發，crash 是該 event 沒填的誠實訊號，勝過 no-op 靜默還原錯 state）。
- ❌ **「新增大 domain-fill skill 自動填 rule」**：三方一致拒絕（Domain Theater / certainty laundering）。

**部分採納（modify）**：
- 🟡 **Codex「bundle 標 payload provenance（input/derived/external）」**：採納為**未來增強**（讓 create-init 簽名 + derived 欄位來源可機械判定），但本輪不依賴它 —— 本輪 create-init 先 split + derived 欄位留 marked TODO in body。
- 🟡 **Codex「C3 dispatch + named check 骨架」**：部分採納降級 —— **不**生 named check stubs（Gemini 對：約束分解），但 ensureInvariant body 內嵌 bundle invariant rules + errorCodes 為 inline comment + GENESIS-TODO marker（ergonomic 引導，無 false structure，runnable）。

**收斂決定集（待三方 R2 確認 / 直接 lock）**：
1. **C5 — ContextError factory 機械生**：codegen emit `extension ContextError where ErrorType==<A>Error { static func <errorCode>(function:message:) }` per errorCode；同時修 `AggregateRenderer` 的 shared import（不該綁 DTO/customType 存在，否則 primitive-only aggregate 補 factory 編譯失敗）。【三方 agreed】
2. **C2 — create-init split + 對齊 input**：business init 簽名 = use-case Input business fields；rehydration init 分離；Created event 需的 derived payload 欄位（permissions/roles/status）在 business init body 留 `// GENESIS-TODO` + 暫以 fatalError 或 default 佔位。使 /usecase Create pattern 可 fill。【三方 agreed】
3. **C3 — ensureInvariant 保持 runnable no-op + commented obligation**：不生 named check stubs、不預設 throw；body 內嵌 bundle invariant rules + errorCode 為註解 + `// GENESIS-TODO: implement invariants`。【Claude 撤回 stub、Gemini honest-blank、Codex no-throw 三方收斂】
4. **C4 — when reducer strict-safe scalar only + 其餘 fatalError**：同名同型非集合非 old/new pair → emit `self.<f> = event.<f>`；其餘 → `fatalError("GENESIS-TODO: implement state transition for <event>")`。【Codex narrow + Gemini fatalError-honest】
5. **D-NEW1 — 移除 dead create command scaffold**：create UC 不生 `Entity/Commands/<A>+Create….swift`（plugin 不 dispatch Created 到 when，OC 無此檔）。【Codex+Gemini 新發現】
6. **C1/C6 — 無大 skill；codegen 補強 + honest obligation 邊界**：可導=error factory / init split / strict-safe scalar reducer / delete reducer / 移 dead scaffold；不可導=invariant predicate / command precondition / external lookup / 集合-build reducer / type 轉換 → 一律 honest TODO（不破 runnable baseline 處）或 fatalError（when 非 trivial）。【三方 agreed】

---

## 共識看板（R2 後）

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| C1 | 大 domain-fill skill vs codegen 補強 | codegen 補強 | codegen 補強（skill 至多薄 TODO-expander）| no skill | **agreed**（三方反對自動填 rule）|
| C2 | create-init 簽名 = input vs payload | 對齊 input + body TODO | 對齊 input + **split business/replay init** | 對齊 input（no certainty laundering）| **agreed**（evidence: 7-param init ⊋ 3 input；split init Codex 補）|
| C3 | ensureInvariant scaffold | R2 撤回 stub → no-op + commented obligation | dispatch+check 骨架但**不預設 throw** | 單一 ensureInvariant + obligation（不要 1:1 check stub）| **agreed**（DDDKit pre/post-apply 強制 no-op-runnable；不生 check stub）|
| C4 | when reducer 機械生 | R2 改 strict-safe scalar + 其餘 fatalError | strict-safe scalar only | 1:1 scalar，其餘 fatalError | **agreed**（同名同型非集合非 old/new → assign；其餘 fatalError）|
| C5 | ContextError factory 機械生 | 機械生 | 機械生（+ 修 shared import）| 機械生（純可導）| **agreed**（evidence: OC `AuditQuotingError.swift` factory；生成端缺）|
| C6 | codegen/human 邊界 | 可導 scaffold / rule human | 同 + provenance | honest obligation 非 fake structure | **agreed** |
| N1* | dead create command scaffold | （R1 未提）| 移除（plugin 不 dispatch Created→when）| 同（OC 無此檔）| **agreed**（Codex+Gemini 新發現）|
| N2* | AggregateRenderer shared import 綁 DTO 存在 | （R1 未提）| 修（primitive-only + factory 編譯風險）| （提及）| **majority**（Codex 證據；待 impl 驗）|

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | 不開大 domain-fill skill；domain 補強走 **codegen**（+ rule body human）| 2026-06-02 | R1 | 三方 agreed |
| D2 | **ContextError factory 機械生**：codegen emit per-errorCode static factory extension；修 AggregateRenderer shared import（不綁 DTO/customType 存在）| 2026-06-02 | R1+R2 | 最低風險、先做（C5 + N2）|
| D3 | **create-init split + 對齊 input**：business init 簽名 = use-case Input business fields；rehydration init 分離；derived payload 欄位（permissions/roles/status）body 內 `// GENESIS-TODO` 佔位 → 使 /usecase Create 可 fill | 2026-06-02 | R1+R2 | C2；解 PA-F2 |
| D4 | **ensureInvariant 保持 runnable no-op + commented obligation**：不生 named check stubs、**不預設 throw/fatalError**（DDDKit `apply` pre/post 跑它）；body 內嵌 bundle invariant rules + errorCode 為註解 + GENESIS-TODO | 2026-06-02 | R2 | C3；DDDKit 約束仲裁 |
| D5 | **when reducer strict-safe scalar only + 其餘 fatalError**：同名同型非集合非 old/new pair → `self.<f>=event.<f>`；其餘 → `fatalError("GENESIS-TODO: implement state transition for <event>")` | 2026-06-02 | R2 | C4；replay crash 勝 silent corruption |
| D6 | **移除 dead create command scaffold**：create UC 不生 `Entity/Commands/<A>+Create….swift` | 2026-06-02 | R1 | N1；plugin 不 dispatch Created→when，OC 無此檔 |

---

## 開放問題

1. **[未來增強] bundle payload provenance**：bundle 標 created payload field = input/derived/external，讓 create-init 簽名 + derived 欄位來源可機械判定（Codex）。本輪不依賴；create-init 先 split + derived 留 TODO。
2. **[待 impl 驗] N2 AggregateRenderer shared import**：修法（不綁 DTO/customType 存在）需在 impl 時驗 primitive-only aggregate + factory 仍編譯。
3. **[範圍外] read 側**：已有 /readmodel-mutation；本討論不碰。

---

## 下次討論指引

### 進度摘要
**收斂（R2 lock）。** 三方對 C1-C6 + N1 agreed、N2 majority。D1-D6 決定集成形 —— 全為 **codegen 補強**（無新大 skill）：ContextError factory 機械生(D2)、create-init split 對齊 input(D3)、ensureInvariant no-op+commented obligation(D4)、when strict-safe scalar+fatalError(D5)、移 dead create scaffold(D6)。仲裁關鍵 = DDDKit `apply` pre/post 跑 ensureInvariant（KO 預設 throw/fatalError）。下一步 **write-spec**。

### 待處理事項
write-spec：把 D1-D6 轉成 codegen spec（動 GenesisCore renderer/template）。spec 階段收開放 #1（provenance defer）/#2（N2 修法驗證）。

### 閱讀建議
- 本檔 R1/R2 + 決策 D1-D6
- `2026-06-01-full-pipeline-parity-audit.md`
- Genesis renderer：`AggregateRenderer.swift` / `UseCaseRenderer.swift` / `AggregateError.swift.template` / `Aggregate.swift.template` / `CommandExtension.swift.template`（Codex 指認）
- DDDKit `apply`：`DDDKit/Sources/DDDCore/Entity/AggregateRoot.swift`（D4 仲裁依據）

### 注意事項
對齊 test-gen 「scaffold 可導、mark 不可導」哲學。honest obligation（TODO/fatalError）> fake structure。ensureInvariant 例外：受 DDDKit 約束只能 no-op + 註解（不能 fatalError）。
