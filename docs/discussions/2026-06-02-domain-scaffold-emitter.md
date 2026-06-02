---
topic: "domain layer scaffold-emitter：skill 規範 code-shape + 狀況模板 + bundle pre/post-condition，人填業務邏輯"
status: consensus
created: "2026-06-02"
updated: "2026-06-02"
participants:
  - Claude (Opus 4.8)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 2
status_note: "R2 consensus；三方（Claude+Codex+Gemini）皆返回實際分析。"
mode: default
supersedes_framing: "2026-06-02-when-reducer-fill-skill.md（窄結論「只 Dto-convert」被本輪 reframe 取代為更廣的 scaffold-emitter）"
premises:
  fixed:        # evidence-backed（OC code-shape 萃取 + bundle 能力 spot-verify）
    - "user reframe：skill 規範『程式碼寫法 + 遇到什麼狀況怎麼寫（structure/situational template）』+ command 的 pre/post-condition（可從 bundle 來），業務邏輯內容交人填。"
    - "OC execute body：thin pass-through，~94% 標準 shape（find→guard-aggregateNotFound→aggregate.<cmd>(...)→save(userId:)→return + 3-arm catch ladder），3 變體（standard/create/delete）+ 1 罕見 orchestration。frame 機械、DOMAIN hole = 哪個 command + arg mapping + Output shape。"
    - "OC command method shape：[precondition guards 0..N] → build event → try self.apply(event:)。51 個 method：8 純機械（無 guard）、43 有 guard；guards ~73 generic（可重用：serviceItem-exists / non-empty / dup-id / ≥0 / non-blank / config-present…）+ ~64 bespoke domain（date-order / filing-method / revenue-threshold…）。frame 機械、predicate 多 domain。"
    - "post-condition：command 內無顯式 post-condition；由 ensureInvariant()（DDDKit apply 前後各跑）擔任。command guards 與 ensureInvariant checks 大致 disjoint（command=per-request shape、ensureInvariant=cross-field/cross-item state），稅務域有刻意部分重疊。"
    - "bundle 帶資料（spot-verify）：每 UC 有 `preconditions: [String]`（半形式化 NL，如 promoteUser `status == Active`、grantPrivilege `permissions not already in user.permissions`）；每 invariant 有 `rules: [{when, rule}]`（如 `userPermissions ⊇ baseline(department, jobTitle)`）。皆非可直接編譯的 Swift。"
    - "前討論結論（2026-06-02-when-reducer-fill）：config-replace 全填不可機械（key/wrapper/predicate 無命名信號 → silent corruption）；read-side Dto-convert 型別可閉合可填。Phase 1.t D4=ensureInvariant 註解 obligation、D5=codegen scalar when / 否則 fatalError。"
  proposed:
    - "scaffold-emitter 取代『fill-or-fatalError 二元』：對 command/when，skill emit 規範化 structure + bundle-derived pre/post scaffold + DOMAIN markers（人填 predicate），既非 silent full-fill 也非 bare fatalError —— 是 guided scaffold（沿用 test-gen 哲學）。"
    - "command method 該有專屬 scaffold skill（emit frame + bundle precondition guard scaffold + generic-guard 選單 + DOMAIN marker）。"
---

# domain layer scaffold-emitter

## 議題定義

### 背景
前面數輪確立:domain 層（command method body / when reducer / ensureInvariant）的**業務邏輯內容**不可機械化（config-replace 全填 = silent corruption）。但 user 提出更好的 reframe:**skill 不該填內容,該規範「寫法 structure + 狀況模板 + bundle 來的 pre/post-condition」,把內容（domain predicate/logic）的洞留給人填。** OC code-shape 萃取證實三種 body 都高度規律（frame 機械、hole 是 domain）;bundle 也帶 precondition + invariant-rule 資料。

### 目標
規劃完整流程:(1) scaffold-emitter 模型（emit structure + situational + bundle pre/post + markers）;(2) command method 的 scaffold skill（新 vs 擴 vs codegen）;(3) bundle precondition→command guard scaffold + invariant rule→ensureInvariant 的對應;(4) when reducer 改 scaffold（取代前輪 fill-or-fatalError）;(5) 與既有 pipeline 整合 + **要補的 / 要改的清單**。

### 範圍
- 討論內:execute/command/when 三 body 的 scaffold-emitter 設計 + bundle pre/post 接線 + skill 架構 + ADD/CHANGE 清單。
- 討論外:bundle schema 大改（用既有 preconditions/rules 欄位）;真·orchestration 罕見 case（手寫例外）;DDDKit。

### 子議題
- [ ] C1：scaffold-emitter 模型 —— emit「structure + situational template + bundle pre/post + DOMAIN markers」，人填 predicate/logic。對 domain 層對不對?如何兼顧 compile（scaffold 要能編譯 or 明確不編譯，不 silent）?
- [ ] C2：command method scaffold —— 新 skill / 擴 / codegen?emit 什麼（frame + bundle precondition guards + generic-guard 選單 + DOMAIN marker）?
- [ ] C3：bundle pre/post 接線 —— preconditions(NL) → command guard scaffold（errorCode 怎麼接、predicate 怎麼 mark）;invariant rules → ensureInvariant（D4 已做）;precondition vs invariant 的分工（OC 是 disjoint）。
- [ ] C4：when reducer —— 改 scaffold（pattern frame + DOMAIN markers，含 config-replace 的 structure）vs 前輪「scalar 填/其餘 fatalError」。guided scaffold 比 bare fatalError 好且不 silent?
- [ ] C5：整合 + ADD/CHANGE —— 與 /usecase（execute 已做）、D4（ensureInvariant）、D5（codegen scalar when）、read-side Dto-convert 整合;要補什麼、改什麼、supersede 什麼。

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.8)

**總立場:採 user 的 scaffold-emitter reframe —— 它把前輪「config-replace 不可填」的死結解開了。關鍵洞見:不可機械化的是 predicate CONTENT，不是 STRUCTURE。skill emit structure + bundle pre/post + DOMAIN markers（人填 content），既不 silent-corrupt（洞是顯式 TODO）也不只 bare fatalError（有 frame + bundle 來的 guard 清單 + generic guards 引導）。這就是 test-gen 的 scaffold-emitter 哲學套到 domain 層。**

- **C1（模型）→ 採 scaffold-emitter，compile 策略 = 「frame 編譯 + 洞用 fatalError/TODO 佔位」**。command scaffold:build-event 的 arg-mapping + `try self.apply(event:)` 是機械 frame（編譯）;precondition guards 從 bundle 來,emit 成「`// PRECONDITION(bundle): status == Active` + guard scaffold + `// DOMAIN: fill predicate` + 對應 errorCode throw」;body 結尾用 `fatalError("GENESIS-TODO: ...")` 直到人填完所有 guard。**洞是顯式 marker（不會 silent 填錯），但 frame + bundle precondition 清單 + generic-guard 提供強引導**（勝過 bare fatalError）。

- **C2（command scaffold skill）→ 新 skill `/command`（or `/domain-command`）**。前輪我主張開新 skill 被「config-replace 不可填」推翻;但 reframe 後 scaffold 有實質內容(frame + bundle precondition guards + generic-guard 選單 + event-build mapping + markers),不再是空 payload。職責:emit command method scaffold。不擴 /usecase（職責 orchestration、明文不動 Command）。不純 codegen:bundle precondition→guard 的 errorCode 接線 + generic-guard 選單需 per-UC 判斷,skill（in-place、idempotent、可重跑）比 codegen 一次性好。

- **C3（bundle pre/post 接線）**:
  - **precondition → command guard scaffold**:每個 bundle precondition emit 一個 guard scaffold,precondition NL 當 comment,errorCode 若能對到某 invariant errorCode（如 promoteUser `status==Active` ↔ employeeNotActive）則接、否則 emit `// DOMAIN: pick/declare errorCode` marker。predicate body = `// DOMAIN: <precondition NL>` + 人填。
  - **invariant rules → ensureInvariant**:D4 已做（rules 當註解 obligation）。維持。
  - **分工**:command guards（per-request precondition，from bundle preconditions）vs ensureInvariant（cross-field state，from bundle invariants）—— OC 是 disjoint,Genesis 照搬:precondition 進 command scaffold、invariant 進 ensureInvariant。post-condition = ensureInvariant（無獨立 post）。

- **C4（when scaffold）→ 改 guided scaffold（取代前輪 fill-or-fatalError）**:每個 when 依偵測到的 pattern emit structure:
  - scalar（型別可閉合）→ 直接填 `self.x = event.x`（同前 D5）。
  - append-factory / config-replace → emit **structure scaffold**:`// PATTERN: config-replace` + 註解版骨架（guard serviceItem → removeAll(key) → append）+ `// DOMAIN: config-key / value-wrapper` markers + `fatalError` 佔位。**比 bare fatalError 好（給出 structure + 已知 event fields）、不 silent（key/wrapper 是顯式洞）。**
  - 這正面回應 Gemini 前輪 veto:不 FILL config-replace（避 silent corruption）,但 emit 它的 STRUCTURE 引導人填。

- **C5（整合 + ADD/CHANGE）**:
  - **ADD**:`/command` scaffold skill（command method）;when scaffold（擴 D5 codegen 或併入 /command）;read-side Dto-convert（擴 /readmodel-mutation，前輪 D2）。
  - **CHANGE**:D5 codegen when（scalar 填/否則 bare fatalError）→ 升級成 guided scaffold（structure + markers）;CommandExtension template 的 command body（現 `fatalError("not implemented")`）→ scaffold;與 D4 ensureInvariant 一致（都是 obligation scaffold）。
  - **SUPERSEDE**:前輪「when-reducer-fill」窄結論（只 Dto-convert / 其餘 bare fatalError）被本輪 scaffold-emitter 取代（其餘也給 structure scaffold）。

**Evidence**:OC code-shape 萃取（gemini，本檔 fixed premises）;bundle preconditions + invariant rules spot-verify（promoteUser `status==Active` 等）;test-gen scaffold-emitter 哲學（Phase 1.s）;前討論 config-replace veto（不 full-fill）。

**待 Codex / Gemini R1**:(i) compile 安全...(ii) 新 skill vs codegen...(iii) errorCode 接線...(iv) 偽引導風險。

#### Gemini

**淨立場:接受 reframe（structure 機械 / content 人填），但加硬約束 —— 有洞的 scaffold 必須是 compile-time error，不是 runtime `fatalError`。** `fatalError` 太弱（編譯過、上線、runtime 才炸 = latent bug）;洞要做成 undefined symbol / `#error` 之類**讓 build 直接斷**,等同 test-gen `.disabled`（skipped≠green）的 domain-code 版。

1. **scaffold「誠實」的充要條件 = 空洞是編譯期失敗**。`fatalError("TODO")` 編譯過 → defer 到 runtime/replay = latent。洞要 break build（最早 feedback）。
2. **bundle precondition 不可靠地自動接 errorCode**。NL precondition（`status==Active`）與 invariant errorCode 是**語意非結構**對應（grantPrivilege precondition 無對應 invariant）。自動接 = 猜 = throw 錯 error = silent corruption。scaffold 只該把 precondition NL 放 comment + `// DOMAIN: pick errorCode` marker。
3. **config-replace 是 guided scaffold 的好對象（非 deterministic fill）**:`guard→removeAll→append` 結構一致,但 key/wrapper/extra-predicate 非型別可導 → emit structure + compile-time 洞。
- **failure-surface map**:compile-time error（理想）> runtime fatalError（latent）> replay error（最陰險,silent state corruption）。
- **C1-C5**:execute=codegen-deterministic / command-guards（bundle+bespoke）=emit-structure-scaffold（NL comment + compile-hole，不自動接 errorCode）/ when-scalar=codegen-deterministic / when-append-factory=（標 deterministic — 但與前輪 D5 defer 衝突，見 R2 reconcile）/ when-config-replace=emit-structure-scaffold（compile-hole）。

#### Codex (GPT-5.4)

**立場:同意 scaffold-emitter,但 (a) command scaffold 該 codegen-time 為主非新 skill;(b) 未填洞要 compile-fail（`#error`）非 fatalError;(c) NL precondition + OC guard catalog 不可機械接線。**

1. **generator 已擁有 command 檔 + 已有 bundle 資料** → codegen-time scaffold 低風險本地化。`UseCaseRenderer.renderCommandExtension` 已收 `useCase.input`/`eventPayload`,`UseCaseSpec.preconditions` 已在 parser。
2. **compile-pass + fatalError 不夠**:現 template `fatalError("not implemented")`,人填一半移掉 trap → 編譯過、看似 done。既有 skill 都防半填（/usecase exit4 / readmodel-mutation exit4 / test-gen .disabled+Issue.record）。code 版 = **`#error("GENESIS-TODO: ...")`** 或 generated/authored split;trailing fatalError 只 runtime-loud 非 authoring-safe。
3. **bundle precondition 太弱無法自動選 ContextError**:NL free text vs invariant errorCode 只 heuristic;且**生成的 error enum 只從 invariants 來**（`AggregateRenderer.renderError` from `spec.invariants`）→ generic-guard error（duplicateServiceItemId/missingStartDate）**根本沒有生成的 case 可 target**。
4. **OC 的 generic guard 池只部分通用**:non-empty/dup-id 是 reusable primitive,但多數綁 serviceItems/configs/config-key/tax-enum = 非 context-agnostic。Genesis 至多 ship 極小 primitive 選單,其餘 emit marker。大型 OC-derived 選單 = domain theater。
5. **非 scalar when scaffold 需擴 renderer 語意輸入**:`buildWhenBody` 現只見 eventType+stateFields+payloadFields,無 nested `ServiceItem.configs` model → config-replace scaffold 要先擴輸入 or 移 retrofit skill。
- **C1-C5**:C1 `#error` 非 fatalError;C2 **codegen-time 為主,`/command` skill 只當 retrofit/regen 後補**;C3 precondition→comment+marker、errorCode 手動/建議;C4 when 分層升級（scalar 留、非 scalar 僅 provable 才 guided scaffold 否則 compile-marker）;C5 command-frame+precondition-comment 低中成本、errorCode auto-wire 高風險、大 guard 選單高風險、rich non-scalar when 需更多語意輸入。

---

### Round 2 — Synthesis（Claude facilitator）

**三方收斂 + 兩個我 R1 沒到位的升級。產出 ADD/CHANGE 清單（user 要的）。**

**Rejection log（HARD）**:
- ❌ **我 R1「洞用 `fatalError("GENESIS-TODO")` 佔位」**:拒絕。Codex+Gemini 獨立同主張 —— fatalError 編譯過 = 人填一半移 trap 就 silent「看似 done」。改 **`#error("GENESIS-TODO: ...")`（Swift 編譯期 directive，洞未填則 build 斷）** = test-gen `.disabled` 的 domain-code 版。
- ❌ **我 R1「新 `/command` skill 為主路徑」**:拒絕。Codex 證據 —— generator 已擁有 command 檔 + 已有 bundle 資料（renderCommandExtension 收 input/eventPayload、UseCaseSpec.preconditions 已在）→ **command scaffold 該 codegen-time 為主**。`/command` skill 降為 **retrofit（後補 command 進既有 aggregate）,defer**。
- ❌ **我 R1「bundle precondition → guard 自動接 errorCode」**:拒絕。三方一致 —— NL→errorCode 是語意非結構對應 + 生成 error enum 只含 invariant errorCodes（generic-guard error 無 case）→ 自動接 = 猜錯 error。errorCode **手動/marker**。

**部分採納（modify）**:
- 🟡 **when-append-factory（Gemini 標 deterministic vs 前輪 D5 defer）reconcile**:append-factory 的 event→factory-param 對應只在**已知 factory（OC ServiceItem.standard）**內型別可閉合;generic Genesis **不知道 domain factory 形狀** → 維持 **guided scaffold（非 auto-fill）**,與前輪 D5「append-factory 暫不 auto」一致。
- 🟡 **非 scalar when guided scaffold**:Codex 對 —— `buildWhenBody` 現無 nested config model;config-replace scaffold 需先擴 renderer 語意輸入。**本輪只到「emit commented structure + `#error` hole」**,不做 nested 推斷。

**收斂決定**:
1. **D1**:採 scaffold-emitter（structure 機械 + bundle pre/post + DOMAIN markers;content 人填）。
2. **D2（升級）**:未填 DOMAIN 洞 = **`#error("GENESIS-TODO: ...")`**（編譯期斷，非 runtime fatalError）。CHANGE 現有 CommandExtension `fatalError("not implemented")` + D5 非-strict-safe when `fatalError` → `#error`。
3. **D3（修正 C2）**:command scaffold = **codegen-time 為主**（擴 renderCommandExtension + CommandExtension.template）;`/command` retrofit skill **defer**。
4. **D4**:command scaffold emit = build-event frame（機械,from eventPayload）+ bundle precondition 當 **comment + `// DOMAIN` marker + `#error` hole**（無自動 errorCode）+ `try self.apply(event:)`。invariant → ensureInvariant（1.t D4 既有,keep）。
5. **D5**:errorCode **不自動接**（手動/建議-only;生成 error enum 只有 invariant errorCodes,需擴才有 generic-guard case → 另議）。
6. **D6**:generic-guard 選單 = 至多極小 primitive（non-empty/≥0/non-blank）;OC ~73 多 OC-specific → marker 為主,不 ship 大選單（domain theater）。
7. **D7**:when —— scalar 留 codegen-fill（1.t D5）;非 scalar（config-replace/append-factory）→ guided scaffold（commented structure + `#error` hole），不 auto-fill 不 bare fatalError。**rich nested 推斷 defer**（需擴 buildWhenBody 語意輸入）。
8. **D8**:execute 不動（/usecase 已處理）。read-side Dto-convert（前輪 D2）仍有效（擴 /readmodel-mutation）。

---

## 要補的（ADD）/ 要改的（CHANGE）清單

### ADD（要補）
| # | 項目 | 位置 | 內容 |
|---|---|---|---|
| A1 | **command precondition scaffold** | `UseCaseRenderer.renderCommandExtension` + `CommandExtension.swift.template` | 每個 `useCase.preconditions` → emit `// PRECONDITION(bundle): <NL>` + `// DOMAIN: implement guard + pick ContextError` + 結構 guard skeleton;errorCode 不自動接 |
| A2 | **read-side Dto-convert pattern** | `/readmodel-mutation` SKILL.md（第 6 pattern）| `readModel.x = <X>Dto(from: event.y)`（型別可閉合;解 GetPermissions exit-3）|
| A3 *(defer)* | **`/command` retrofit skill** | 新 skill | 後補 command 進既有 aggregate（codegen-time 為主後的補充,非首要）|
| A4 *(另議)* | **generated error enum 補 generic-guard cases** | `AggregateRenderer.renderError` | 現只從 invariants 生;generic guard（dup-id/missing-field）需 case 才能 throw —— 需 bundle 來源或 convention,另議 |

### CHANGE（要改）
| # | 項目 | 從 → 到 |
|---|---|---|
| C1 | **command body 佔位** | `CommandExtension.swift.template`:`fatalError("not implemented")` → **build-event frame + `#error("GENESIS-TODO: command logic")`**（編譯期洞）|
| C2 | **when 非-strict-safe 佔位** | `UseCaseRenderer.buildWhenBody`:`fatalError("GENESIS-TODO...")` → **commented structure scaffold + `#error`**（config-replace 給 guard→removeAll→append 註解骨架 + `// DOMAIN: key/wrapper` + `#error`）|
| C3 | **scalar when** | 不變（1.t D5 codegen-fill 保留）|
| C4 | **ensureInvariant** | 不變（1.t D4 obligation comment 保留;與 scaffold 哲學一致）|

### SUPERSEDE
- `2026-06-02-when-reducer-fill-skill.md` 的窄結論（「只 Dto-convert、其餘 bare fatalError」）→ 本輪 scaffold-emitter 取代（其餘給 guided scaffold + `#error`;Dto-convert 仍做 = A2）。

### 待釐清 / 風險
- **`#error` 讓生成專案在 domain 全填完前無法 build**（honest 但 aggressive;trade-off:domain 邏輯未填的 aggregate 本就不該 ship;人 incrementally 填）。R2 採此（三方一致 compile-time signal）。
- 非 scalar when 的 rich nested scaffold 需擴 `buildWhenBody` 語意輸入（defer）。
- generated error enum 只含 invariant errorCodes（A4 另議）。

---

## 共識看板（R2 後）

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| C1 | scaffold-emitter 模型 + compile 策略 | R2 改：`#error` 編譯期洞 | `#error` 非 fatalError | compile-time error 非 fatalError | **agreed**（三方一致 compile-time signal）|
| C2 | command scaffold：新 skill vs codegen | R2 改：codegen 為主 | codegen 為主、skill retrofit | codegen scaffold（skill retrofit scope）| **agreed**（codegen-time 為主，/command defer retrofit）|
| C3 | bundle precondition → guard errorCode | R2 改：不自動接 | 不自動接（enum 只有 invariant case）| 不自動接（語意非結構 trap）| **agreed**（comment + DOMAIN marker，errorCode 手動）|
| C4 | when 非 scalar scaffold | guided scaffold + `#error` | 僅 provable / 否則 marker、需擴語意 | emit-structure-scaffold + compile-hole | **agreed**（commented structure + `#error`;rich nested defer）|
| C5 | 整合 + ADD/CHANGE | （見清單）| 分層成本評估 | scaffold/fatalError 邊界表 | **agreed**（ADD/CHANGE 清單成形）|
| C6* | append-factory deterministic? | scaffold（reconcile）| —（OC-specific）| 標 deterministic | **majority→reconciled**（generic Genesis 不知 factory → scaffold，與前輪 D5 一致）|

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | 採 **scaffold-emitter**（structure 機械 + bundle pre/post + DOMAIN markers;content 人填）| 2026-06-02 | R2 | user reframe;三方接受 |
| D2 | 未填 DOMAIN 洞 = **`#error("GENESIS-TODO")`**（編譯期斷，非 runtime fatalError）| 2026-06-02 | R2 | Codex+Gemini 升級;= test-gen `.disabled` domain 版 |
| D3 | command scaffold = **codegen-time 為主**（擴 renderCommandExtension + template）;`/command` skill defer retrofit | 2026-06-02 | R2 | Codex 證據:generator 已擁有檔+資料 |
| D4 | command scaffold = build-event frame + bundle precondition（comment + DOMAIN marker + `#error`）+ apply;invariant → ensureInvariant（1.t D4 keep）| 2026-06-02 | R2 | |
| D5 | errorCode **不自動接**（手動/建議;生成 enum 只有 invariant case）| 2026-06-02 | R2 | 三方一致 |
| D6 | generic-guard 選單至多極小 primitive;OC ~73 多 OC-specific → marker | 2026-06-02 | R2 | 避 domain theater |
| D7 | when：scalar 留 codegen-fill（1.t D5）;非 scalar → guided scaffold（commented structure + `#error`）,不 auto-fill;rich nested defer | 2026-06-02 | R2 | append-factory generic 不 auto |
| D8 | execute 不動（/usecase）;read-side Dto-convert（前輪 D2）擴 /readmodel-mutation | 2026-06-02 | R2 | |

---

## 開放問題

1. **`#error` aggressive**:生成專案在 domain 全填完前無法 build（trade-off 採之,三方一致;domain 未填本不該 ship）。
2. **non-scalar when rich scaffold** 需擴 `buildWhenBody` 語意輸入（nested config model）→ defer。
3. **generated error enum 只含 invariant errorCodes**（A4）—— generic-guard error（dup-id/missing-field）無 case;補法（bundle 來源 vs convention）另議。

---

## 下次討論指引

### 進度摘要
**R2 收斂（consensus）。** scaffold-emitter reframe 三方接受 + 兩升級（`#error` 非 fatalError、codegen-time 非新 skill）。ADD/CHANGE 清單成形（見上）。下一步:依清單 write-spec（A1 command precondition scaffold + C1/C2 `#error` 為先;A2 Dto-convert;A4/rich-nested 另議）。

### 待處理事項
write-spec:Phase（命名待定，如 1.u）—— codegen command scaffold（A1）+ `#error` 洞（C1/C2）+ Dto-convert（A2）。

### 閱讀建議
- 本檔 R1/R2 + ADD/CHANGE 清單 + 決策 D1-D8
- `UseCaseRenderer.renderCommandExtension`/`buildWhenBody`、`CommandExtension.swift.template`、`/readmodel-mutation` SKILL.md、`AggregateRenderer.renderError`（A4）

### 注意事項
`#error` 編譯期洞是核心安全約束（半填不 silent compile-pass）。errorCode 不自動接。generic-guard 不 ship 大選單。
