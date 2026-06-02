---
topic: "A5 intent-elicitation domain-fill skill：系統化「人說 domain 邏輯 → LLM 填 #error 洞」"
status: consensus
created: "2026-06-02"
updated: "2026-06-02"
participants:
  - Claude (Opus 4.8)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 2
mode: default
premises:
  fixed:        # evidence-backed / 前討論 locked，不可挑戰
    - "domain-scaffold-emitter D9：『人填』= 人說意圖 → LLM 寫（intent-driven），非人手打字。軸 = deterministic fill（skill 自動，judgment 從 bundle/code 可導）vs intent-driven fill（人供 judgment、LLM 寫）。"
    - "honest-hole 紅線（D9）：LLM 填 domain 時，人意圖沒涵蓋的洞不准 fabricate → 留 #error。intent-driven（人供 judgment）安全 vs 機械猜（無人供 judgment 硬填）危險。"
    - "Phase 1.u 已落地 #error 洞：command body（precondition scaffold + build-event frame + #error）、非-strict-safe when（#error）、ensureInvariant（有宣告 invariant → #error）。#error = 編譯期完成合約（grep #error → 填 → build 綠 = 填完）。"
    - "scaffold 是 LLM filler 的 prompt context：command 帶 bundle precondition 註解 + build-event frame;ensureInvariant 帶 bundle invariant 註解 + errorCode;when 帶 structure 註解。"
    - "deterministic fill skills 已存在且不碰 Entity domain：/usecase（execute orchestration，code-driven，明文不動 Entity/Command）、/api（adapter）、/readmodel-mutation（read projector when，含 Phase 1.v Dto-convert 等 type-closure pattern）、/test-gen（test scaffold）、/bundle-plan（plan-time method-X：LLM 推 + 人逐 UC 確認）。"
    - "Entity-layer domain（command body 業務驗證 / when reducer 非-type-closure / ensureInvariant predicate）目前無任何 fill skill —— A5 的目標領域。"
    - "bundle 帶半形式化 domain 資料：useCase.preconditions（NL，如 `status == Active`）、aggregate invariant.rules（如 `userPermissions ⊇ baseline(...)`）、errorCode。皆非可直接編譯 Swift。"
    - "test-gen 邊界：assertion 來自 spec、signature 來自 code，不讀 execute body 當 semantic source（避免被 impl 綁架）。"
  proposed:
    - "A5 是單一新 skill（hole-kind-aware），消費 #error 洞 + scaffold + bundle，互動式 elicit 人的 domain 意圖 → 填 → 沒涵蓋的留 #error。"
    - "A5 用 method-X 式互動（LLM 對每個洞先推一版 → 人確認/修正），對齊 /bundle-plan。"
    - "A5 sit 在 fill pipeline 末端（deterministic skills 之後），是 human-judgment 收尾。"
---

# A5 intent-elicitation domain-fill skill

## 議題定義

### 背景
Phase 1.t/1.u/1.v 把 domain 層做成 scaffold-emitter：機械可導的（execute / adapter / type-closure when / Dto-convert）由 deterministic skill 填;不可機械導的 domain 邏輯（command precondition predicate / 非-type-closure when reducer / ensureInvariant body / read-side domain 語意如 GetPermissions grant/revoke）留成 `#error` 洞。

user 的 reframe（D9）：這些洞由「**人說 domain 邏輯 → LLM 寫**」填，而非人手打字。A5 = 把這個「intent-driven fill」系統化成 skill（或機制）：消費 `#error` 洞 + scaffold context + bundle domain 資料，elicit 人的意圖，填進去，**人沒說的不准 fabricate（留 #error）**。

### 目標
定出 A5 的設計：(1) scope（填哪些洞）;(2) 互動模型（怎麼 elicit 意圖）;(3) skill 架構（單一 vs per-layer / 與既有 skill 關係）;(4) context 消費（讀什麼、讀到哪不算綁架）;(5) honest-hole 紅線執行（怎麼保證不 fabricate）;(6) 完成合約 + idempotency。

### 範圍
- 討論內：A5 skill 設計（C1-C6）+ 與既有 pipeline 整合。
- 討論外：bundle schema 改動;deterministic skills 行為（已 lock）;`#error` 機制本身（Phase 1.u locked）;A3/A4。

### 子議題
- [ ] C1：scope —— A5 填哪些 `#error` 洞？（command precondition / 非-type-closure when / ensureInvariant / read-side domain 語意）全部 domain 洞，還是特定層？
- [ ] C2：互動模型 —— 怎麼 elicit 人的 domain 意圖？method-X（LLM 對每洞推一版 → 人確認）vs 人 dictate-LLM-寫 vs 消費預先 stated intent（task spec / side file）？batch vs per-hole？
- [ ] C3：skill 架構 —— 單一 hole-kind-aware skill vs per-layer（command-fill / reducer-fill / invariant-fill）？與 /usecase（不碰 Entity）/ /bundle-plan（plan-time method-X）/ /readmodel-mutation 的關係？
- [ ] C4：context 消費 —— 讀什麼（#error grep / scaffold 註解 / bundle preconditions+invariants / state+event 型別）？讀到哪不算「被 impl 綁架」（test-gen 邊界類比）？
- [ ] C5：honest-hole 紅線執行 —— 怎麼保證人意圖沒涵蓋的洞不被 fabricate？fill 後怎麼驗「填對」（vs 填了但語意錯）？
- [ ] C6：完成合約 + idempotency —— build 綠 = 全填完？per-hole 追蹤？重跑（部分填）行為？

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.8)

**總立場：A5 = 單一 hole-kind-aware skill，sit 在 fill pipeline 末端，用 method-X 互動 elicit 意圖填 `#error` 洞，honest-hole 紅線靠「#error 是 grep-able 完成合約 + 沒涵蓋就留著」物理保證。它是 deterministic fill skills 的 intent-driven 對偶。**

- **C1（scope）→ 全部 domain `#error` 洞，單一 skill 統管**。A5 填 Phase 1.u/1.v 留的所有 intent-driven 洞：command precondition predicate + build-event body / 非-type-closure when reducer / ensureInvariant predicate / read-side domain 語意（GetPermissions grant-revoke memberwise）。理由：它們本質同一件事（人說 domain 邏輯 → LLM 寫進 `#error`），共用同一個 honest-hole 紅線 + 完成合約;分成 per-layer skill 會讓「填一個 aggregate 的 domain」要跑多個 skill，違反「一次把這個 aggregate 的 domain 講清楚」的人類心智。

- **C2（互動模型）→ method-X（per-hole LLM 推一版 → 人確認/修正/skip），對齊 /bundle-plan**。對每個 `#error` 洞，A5 讀 scaffold context（bundle precondition 註解 / invariant rules / event+state 型別）→ **推一版候選實作** → 印給人「這是我依 bundle `status == Active` 推的 guard：`guard status == .active else { throw ... }`，確認/修正/skip？」。人確認才寫;skip → 留 `#error`。這比「人從零 dictate」省力（scaffold + bundle 已給 LLM 半成品），比「LLM 自動填」安全（人 gate 每個 domain 判斷）。**batch**：一次處理一個 aggregate 的所有洞（人 batch 思考 domain，非零碎被打斷）。

- **C3（架構）→ 單一新 skill `/domain-fill`（或 `/fill-domain`），不擴既有**。不擴 /usecase（明文不動 Entity/Command，且 /usecase 是 code-driven 非 intent-driven）。不擴 /readmodel-mutation（它是 type-closure deterministic;A5 是 intent-driven，混入會模糊「機械 vs 人供 judgment」的軸）。新 skill 與 /bundle-plan 共用 method-X 互動慣例但不同階段（bundle-plan = plan-time spec gap;A5 = fill-time code hole）。A5 是 fill pipeline **最後一棒**（deterministic skills 跑完 → A5 收 domain 尾）。

- **C4（context 消費）→ 讀 scaffold + bundle + signature，不讀「別的已填 body 當答案」**。A5 讀：`#error` 洞本身 + 周圍 scaffold 註解（bundle precondition / invariant rules / build-event frame）+ aggregate state 宣告 + event payload 型別 + `<A>Error` enum cases（選 errorCode 用）。**邊界（類比 test-gen）**：不把「另一個已填的 command body」當這個洞的答案來源（那是抄、非 elicit 意圖）;domain 判斷的 source of truth 是「人此刻說的意圖 + bundle 宣告」，非既有 code。讀既有 code 只為拿 signature（怎麼 call / 型別）。

- **C5（honest-hole 紅線執行）→ `#error` 的物理性 + 三條保證**：(1) **物理**：沒填的洞 `#error` 還在 → build 不過 → 不可能 silent ship（Phase 1.u 已保證）。A5 只是把洞變少，沒填的留著。(2) **不 fabricate 規則**：A5 prompt 明令「人意圖沒涵蓋的部分，保留 `#error`，不要腦補 domain 邏輯」（人 skip 或沒提到的洞 → 留）。(3) **fill 後人 review**：A5 填完印 diff 給人最終確認（method-X 的確認已是一層）;但「填對 vs 語意錯」的終極驗證是 **/test-gen 產的 test + 人 author 的 Given**（test 是 domain 正確性的 check，呼應 test-gen 討論「certainty 在人」）。A5 不自稱保證語意對，只保證「人說了才填、沒說留洞」。

- **C6（完成合約 + idempotency）→ build 綠 = domain 洞全填;per-hole 靠 `#error` grep;重跑只碰還有 `#error` 的洞**。完成 = `grep -r '#error' Sources/` 空 → 全填。idempotent：A5 重跑時 grep 現存 `#error`，只對還沒填的洞 elicit（已填的不碰，類比既有 fill skill 的 idempotent invariant）。**不**追蹤「填了但人想改」（那是人重新 edit 的事，非 A5 scope）。

**Evidence**：D9 + honest-hole 紅線（domain-scaffold-emitter）;Phase 1.u `#error` 洞（command/when/ensureInvariant）;/bundle-plan method-X（plan-time LLM 推 + 人確認）;/readmodel-mutation type-closure（A5 的 deterministic 對偶）;test-gen「assertion 來自 spec / 不讀 execute body 當 source」邊界 + 「certainty 在人、test 是 domain check」。

**待 Codex / Gemini R1**：(i) skill vs doc...(ii) method-X rubber-stamp...(iii) honest-hole 結構保證...(iv) context 邊界。

#### Codex (GPT-5.4)

**立場：A5 有條件值得做成 skill —— 但增值不在「LLM 代寫」（那是 Cursor 日常），而在把既有 fill skill 的 operation contract（精準定位洞 / per-hole-kind context / idempotent 重跑 / 半填 fail-fast / 只有人明確供語意才移除 #error）正式化到 domain 洞。做不到這些就降級 doc。v1 scope 應先收斂 entity-layer。**

1. **C3 skill 正當性**：既有 fill skill 增值是 structural contract（/usecase 三分+半填 exit4;/readmodel-mutation per-method triage+partial abort）。A5 只有把「洞定位+context+partial 拒絕+重跑不碰已填」編碼進流程才配叫 skill;否則 prompt discipline，doc 即可。
2. **C5 prompt 不夠，要 admissibility gate**：Claude 的 #error 物理性+prompt「不 fabricate」+人 review，只保證「未填不 silent ship」，不保證「已填非 LLM 腦補」。仿 /readmodel-mutation Dto-convert 的 admissibility（三條件否則 exit3）：A5 規定「**只有人明確提供該洞 semantic payload（command:predicate+error choice;when:key/wrapper/transition;invariant:predicate）才可移除 #error**」，缺任一留洞，非靠 prompt 自律。
3. **C2 method-X 有 rubber-stamp 前例**：/bundle-plan 自承「批次+Enter 接受 → placeholder 殘留」（dogfood 教訓）。安全順序應「**先確認 domain 語句本身，再 render Swift，最後確認 code diff**」（先語意後語法），非直接「我寫好的 Swift，確認嗎？」。
4. **C1/C6**：fixed premise 已把 A5 鎖 entity-layer;read-side domain semantic 今天是 /readmodel-mutation exit3 leftover、非同種 codegen-embedded #error contract → **v1 先限 entity-layer，read-side 待同等 hole contract 再併**。完成合約拆兩層：**structural complete（#error 清空/build 綠）≠ semantic grounded（每個移除的洞有明確人意圖來源 + tests）**。
5. **C4 同意**：讀 scaffold/bundle/state+event type/error case;**不**讀 sibling command body 當 semantic source（那是複製既有實作非 elicit 當前 judgment）。
6. **可行性風險**：repo 混有 #error（新 template）與 legacy fatalError/TODO（既有生成例）→ A5 須 **version-aware**，否則 hole discovery/idempotency/completion 失真。

**C1-C6**：C1 v1 限 entity-layer / C2 method-X 但先語意後語法 / C3 skill 但正當性來自 encoded contract 否則 doc / C4 不讀 sibling body / C5 admissibility gate（無人意圖一律留洞）/ C6 兩層完成（structural vs semantic+provenance）+ idempotent + version-aware。

#### Gemini

**淨立場 + REFRAME：A5 極高風險。method-X（LLM 先推一版 → 人確認）會把 honest emptiness 轉成最陰險的 provenance corruption（LLM 猜 predicate 看似合理 → confirmation-fatigue 橡皮圖章 → #error 消失 → 「build 綠」變謊言，比 runtime fatalError 更糟）。REFRAME：A5 必須 Transcription-only（純轉譯）—— LLM 絕不准「推第一版」。互動 = 讀 scaffold/bundle → 印洞 context → 停下等人用自然語言 dictate 意圖 → LLM 把人的話 transcribe 成 Swift → 寫入。LLM 解決「語法苦力」，不解決「業務判斷苦力」。A5 價值不在省思考，在「確保人類意圖被結構化對應到正確洞、且隔離其他實作污染」。**

1. **method-X = provenance corruption 溫床（VETO C2/C5）**：plan 階段 placeholder 殘留肉眼可見（dishonest structure）;但 code 階段 LLM 猜的 `if status != .active { throw }` 看起來無懈可擊 → 人毫不猶豫確認 → #error 消失 = 系統標榜「人驗證過的 domain」實為 LLM 幻覺+橡皮圖章 = 最高危 silent corruption。prompt 紀律在 LLM completion 衝動前無防禦;唯一物理機制：**沒有人類 prompt（intent）就不准 trigger LLM completion**。
2. **batch 是 review 毒藥（VETO batch）**：整 aggregate domain 洞 batch = 鼓勵 rubber-stamp;ensureInvariant/when/precondition 需不同 context switch。**per-hole 強制中斷是 feature** —— #error 的意義在「逐一專注解決」。
3. **A5 必要性 = Context Firewall（C3/C4）**：不用 A5 讓人 Cursor 直接填 → 無差別把整個 workspace/別的寫錯 body/無關 utility 塞 context，破 C4 紅線。A5 作為 **Context Firewall**：嚴格限 LLM 只看 bundle signature + scaffold，物理阻斷抄別的 body → code 100% 源於「bundle 宣告 + 人當下 dictate」。
4. **hole-kind 腐敗不對稱（C1）**：precondition 填錯=擋合法/放非法;when 填錯=state 腐敗;ensureInvariant 填錯=廢 DDDKit 最後防線。單一 skill 統管對（紅線一致），但互動絕不能因「同 skill」用同預設敷衍 → 更強化 Transcription-only。

**C1-C6**：C1 單一 skill 統管（共享 context firewall + provenance）/ C2 **VETO method-X+batch，改 Transcription-only + 嚴格 per-hole**（LLM 是秘書非參謀）/ C3 A5 定位「強制隔離 context 的互動式聽寫工具」非「自動化最後一棒」/ C4 嚴守 test-gen 邊界、物理鎖死不讀別的 body / C5 廢「LLM 自主留 #error」prompt 幻想，CLI 控制流「無人 dictation = 物理保留原 #error 根本不 call LLM」/ C6 build 綠含金量全靠 C2 Transcription-only 驅逐 rubber-stamp。

---

### Round 2 — Synthesis（Claude facilitator）

**收斂：A5 = Transcription-only + 嚴格 per-hole + admissibility gate + v1 entity-layer + 兩層完成。我 R1 的 method-X（LLM 推一版）被兩方一致 VETO —— 那是 provenance corruption 溫床。採 Gemini 的 Transcription-only reframe + Codex 的 admissibility gate（同一結構保證，兩個角度）。**

兩方獨立指向同一結構保證（回答我 R1 問的「比 prompt 更強的保證」）：**沒有人類 dictation，A5 在 text 層保留原 #error、根本不 call LLM fill**。這是物理保證,非 prompt 自律。LLM 角色 = 秘書（把人說的話 transcribe 成 Swift），非參謀（草擬 domain 邏輯）。

**Rejection log（HARD）**：
- ❌ **我 R1 的 C2「method-X：LLM 對每洞推一版 → 人確認」**：拒絕（兩方 VETO）。LLM 先推 domain predicate → 看似合理 → 橡皮圖章 → provenance corruption（#error 消失但是 LLM 猜的）。改 **Transcription-only**：LLM 不推第一版，人先 dictate 意圖、LLM 只 transcribe。
- ❌ **我 R1「batch（一次整 aggregate）」**：拒絕（Gemini）。batch 鼓勵 rubber-stamp;不同 hole-kind 需不同 context switch。改 **嚴格 per-hole 強制中斷**（feature 非 bug）。
- ❌ **我 R1 C1「全部 domain 洞含 read-side 一次納入」**：部分拒絕（Codex）。read-side（GetPermissions）今天是 /readmodel-mutation exit3 no-op leftover、非 codegen-embedded #error → 不同 contract。**v1 限 entity-layer #error 洞（command/when/ensureInvariant）**;read-side domain 待同等 hole contract 再併。
- ❌ **我 R1 C5「靠 #error 物理性 + prompt 不 fabricate」**：升級。prompt 不夠 → **admissibility gate（結構）**：無人明確 dictation 該洞一律保留 #error，A5 不 call LLM。
- ❌ **我 R1 C6「build 綠 = 完成」**：部分拒絕（Codex）。build 綠 = **structural complete（#error 清空）≠ semantic grounded**。完成兩層：structural（#error 空）+ semantic（每洞有人意圖 provenance + /test-gen test 驗語意）。

**部分採納（modify）**：
- 🟡 **Codex「先語意後語法」**：採納為 Transcription-only 的子流程 —— 人 dictate 自然語言意圖 → A5 先回述「我理解的語意是 X」確認 → 再 transcribe Swift → 顯示 diff 確認。
- 🟡 **Codex「version-aware」**：採納 —— A5 偵測 #error（新）+ legacy fatalError/TODO（既有生成）兩種洞。

**收斂決定（待 lock）**：
1. **D1**：A5 = 單一 skill `/domain-fill`，v1 scope = **entity-layer #error 洞**（command precondition+build-event / 非-type-closure when / ensureInvariant）。read-side domain defer。
2. **D2（核心）**：**Transcription-only** —— LLM 絕不推第一版 domain 邏輯。流程：讀 scaffold/bundle/signature → 印洞 context → **停，等人 dictate 意圖** → A5 回述語意確認 → transcribe Swift → diff 確認 → 寫。
3. **D3（結構保證）**：**admissibility gate** —— 無人 dictation（skip / 沒提供 semantic payload）→ A5 物理保留原 #error，**不 call LLM**。honest-hole 靠 CLI 控制流，非 prompt。
4. **D4**：**嚴格 per-hole**（非 batch）—— 逐洞強制中斷;不同 hole-kind 不同 context。
5. **D5（context firewall）**：A5 只讀 scaffold + bundle（preconditions/invariants/errorCode）+ state/event signature + `<A>Error` cases;**不讀 sibling 已填 body 當 semantic source**（物理鎖死，防抄）。
6. **D6（兩層完成）**：structural（grep #error 空 / build 綠）+ semantic（每洞人意圖 provenance + /test-gen test 驗）。idempotent（重跑只碰剩餘洞）+ version-aware（#error + legacy fatalError）。
7. **D7（正當性）**：A5 作為 **Context Firewall + encoded contract**（idempotent / partial fail-fast / provenance gate）才證成 skill;否則降 doc。

---

## 共識看板（R2 後）

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| C1 | scope | R2 改：v1 entity-layer | v1 entity-layer | 單一 skill 統管 | **agreed**（單一 skill，v1 限 entity-layer #error;read-side defer）|
| C2 | 互動模型 | R2 改：Transcription-only + per-hole | 先語意後語法 | **VETO method-X → Transcription-only + per-hole** | **agreed**（LLM 秘書不參謀;人先 dictate、LLM transcribe）|
| C3 | 架構（skill?）| 單一 skill | skill 但需 encoded contract 否則 doc | A5 = Context Firewall | **agreed**（skill 正當性 = context firewall + encoded contract）|
| C4 | context 消費 | scaffold+bundle+signature 不讀 body | 同（不讀 sibling body） | 同（物理鎖死） | **agreed**（test-gen 邊界;不讀別的 body 當 semantic source）|
| C5 | honest-hole 保證 | R2 升級：admissibility gate | admissibility gate | Transcription-only CLI 控制流 | **agreed**（無人 dictation → 物理保留 #error 不 call LLM，非 prompt）|
| C6 | 完成合約 | R2 改：兩層 | structural vs semantic+provenance | build 綠靠 C2 含金 | **agreed**（structural #error 空 + semantic provenance+test;idempotent;version-aware）|

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | A5 = 單一 skill `/domain-fill`，**v1 scope = entity-layer #error 洞**（command precondition+build-event / 非-type-closure when / ensureInvariant）；read-side domain defer | 2026-06-02 | R2 | Codex scope 收斂;read-side 非同種 #error contract |
| D2 | **Transcription-only**：LLM 絕不推第一版 domain 邏輯。流程 讀 scaffold/bundle/signature → 印洞 context → 停等人 dictate → A5 回述語意確認 → transcribe Swift → diff 確認 → 寫 | 2026-06-02 | R2 | Gemini reframe（VETO method-X）;LLM 秘書非參謀 |
| D3 | **admissibility gate（結構保證）**：無人 dictation（skip / 未供 semantic payload）→ A5 物理保留原 #error、**不 call LLM**。honest-hole 靠 CLI 控制流非 prompt | 2026-06-02 | R2 | 兩方獨立指向同保證 |
| D4 | **嚴格 per-hole**（非 batch）：逐洞強制中斷;不同 hole-kind 不同 context | 2026-06-02 | R2 | Gemini（batch 鼓勵 rubber-stamp）|
| D5 | **context firewall**：只讀 scaffold + bundle（preconditions/invariants/errorCode）+ state/event signature + `<A>Error` cases;**不讀 sibling 已填 body 當 semantic source** | 2026-06-02 | R2 | test-gen 邊界;物理鎖死防抄 |
| D6 | **兩層完成**：structural（grep #error 空 / build 綠）+ semantic（每洞人意圖 provenance + /test-gen test 驗語意）。idempotent（重跑只碰剩餘洞）+ version-aware（#error + legacy fatalError）| 2026-06-02 | R2 | Codex;build 綠 = structural ≠ semantic |
| D7 | A5 正當性 = **Context Firewall + encoded contract**（idempotent / partial fail-fast / provenance gate）才證成 skill;否則降 doc | 2026-06-02 | R2 | 兩方 conditional-yes |

---

## 開放問題

1. **read-side domain（GetPermissions grant/revoke memberwise）**：今天是 /readmodel-mutation exit3 no-op leftover、非 #error。要納 A5 需先讓 /readmodel-mutation exit3 也 emit #error（統一 hole contract），或另路徑。defer（D1 v1 不含）。
2. **Transcription-only 的「回述語意確認」具體 UX**：人 dictate 自然語言 → A5 怎麼回述讓人確認「LLM 沒誤解」？需 spec 階段定（self-report 格式）。
3. **version-aware**：repo 混 #error（新 template）+ legacy fatalError/TODO（既有生成例）。A5 v1 是否只認 #error（要求先 regen），還是兩種都認？spec 階段定。

---

## 下次討論指引

### 進度摘要
**R2 收斂（consensus）。** 三方對 C1-C6 agreed。核心翻轉:我 R1 的 method-X（LLM 推一版 → 人確認）被兩方 VETO（provenance corruption）→ 改 **Transcription-only**（LLM 秘書不參謀，人先 dictate）+ admissibility gate（無 dictation 物理留 #error）+ 嚴格 per-hole + v1 entity-layer + 兩層完成。D1-D7 spec-ready。下一步 write-spec。

### 待處理事項
write-spec A5 `/domain-fill`：Transcription-only 流程 + admissibility gate + per-hole + context firewall + 兩層完成 + version-aware。spec 收開放 #1（read-side defer）/#2（回述 UX）/#3（version-aware 範圍）。

### 閱讀建議
- 本檔 R1/R2 + 決策 D1-D7
- Phase 1.u（#error 洞形狀）、`/bundle-plan`（method-X 反面教材 + 互動慣例）、`/readmodel-mutation`（admissibility gate 範本）、test-gen（context 邊界 + certainty 在人）

### 注意事項
**Transcription-only 是核心安全約束**：LLM 不發明 domain 邏輯，只 transcribe 人說的。無人 dictation → 物理保留 #error（CLI 控制流，非 prompt 自律）。這是 honest-hole 從 Phase 1.u（codegen 留洞）延伸到 A5（fill 洞不腦補）的閉環。
