---
name: domain-fill
description: Genesis intent-elicitation domain-fill skill (transcription-only). Inside a Genesis-bootstrapped project, /domain-fill [<Aggregate>] walks each entity-layer GenesisTODO.notImplemented domain hole (command precondition + build-event / non-type-closure when reducer / create-init derived fields) ONE AT A TIME, prints the hole's scaffold context (bundle precondition / signature), then STOPS via AskUserQuestion and waits for the human to dictate the domain logic. It transcribes the human's stated intent into Swift — it NEVER drafts domain logic itself. No human dictation → the throw GenesisTODO.notImplemented is physically kept (never transcribes). Sibling of /usecase and /api (deterministic fills); this is the human-judgment counterpart. Downstream, /readmodel-mutation reuses the when() semantics confirmed here as read-side proposals (written only after human confirmation) and asks the human when semantics are unclear.
argument-hint: [Aggregate]
disable-model-invocation: true
allowed-tools: Read, Edit, Glob, Grep, Bash, AskUserQuestion
---

# /domain-fill — intent-elicitation domain fill (transcription-only)

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

系統化「**人說 domain 邏輯 → 你 transcribe 成 Swift**」填掉 `genesis new` 留的 entity-layer `throw GenesisTODO.notImplemented(...)` domain 洞:command precondition + build-event / 非-type-closure `when` reducer / create-init 的 derived 欄位。你是 deterministic fill skills（/usecase /api）的 **intent-driven 對偶** + 寫入端 fill pipeline 最後一棒;讀取端的 /readmodel-mutation 在你之後跑，會把這裡已確認的 `when` 語意做成讀取端提案。

> **不含 ensureInvariant**:Phase 1.y 起 ensureInvariant 是 runnable no-op（無 marker，DDDKit 每次 apply 跑、throw 會炸 fixture seed）。invariant 的實作由 **TDD invariant test**（餵壞狀態、期望被擋 → 紅 → 實作 → 綠）驅動,並由 **`genesis verify`**（要求每個 declared invariant errorCode 有 enabled test）把關 —— 不是 domain-fill 的 marker-grep 範疇。

### TDD 脈絡（重要）

domain 洞是 **runtime throw-marker（會編譯）**,不是編譯期 `#error`。所以 `genesis new` 完專案**編得過**、test 跑得起來:每個未填洞的 test 因 `GenesisTODO.notImplemented` 被丟而**紅**。你（或人）填洞 → 那個 test 轉綠（增量 TDD）。`genesis verify` 是 release/CI gate:有殘留 marker 或 invariant 無 enabled test → fail。

### 絕對約束（不可違反）

- **Transcription-only**:你**絕不**自行草擬/推測 domain predicate/logic,**不**「先推一版給人確認」（那是 provenance corruption:你猜的 predicate 看似合理 → 人橡皮圖章 → marker 消失但語意是你編的）。你是**秘書（把人 dictate 的意圖轉 Swift）不是參謀**。
- **admissibility gate**:人 skip / 未提供該洞 semantic payload → **保留原 `throw GenesisTODO.notImplemented` 不動,不 transcribe**。透過 `AskUserQuestion`（harness 物理 block 等人回答,你無法略過）落實。
  > 誠實定位:本 skill 由你（LLM）照本文執行,無分離 binary 強制控制流。三層 best-achievable 強制:(1) `AskUserQuestion` 的 harness block;(2) 先語意後語法;(3) provenance log。比純 prompt 強,但「不腦補」終究依你遵循本約束。
- **嚴格 per-hole**:一次處理一個洞,逐洞中斷;**不** batch（batch 鼓勵 rubber-stamp）。
- **context firewall**:只讀 scaffold 註解 + bundle 資料 + signature（Input / aggregate state / event payload / `<A>Error` cases）。**絕不讀 sibling 已填的 command/when body 當 semantic source**（抄既有實作 ≠ elicit 當前 judgment）。
- **只動 marker 洞區塊**:替換該洞 `throw GenesisTODO.notImplemented(...)`（+ 周圍 DOMAIN marker 註解）為人意圖的實作;不動 signature / scaffold 的 bundle-precondition 註解 / 其他 code。
- **version-aware**:只認 `GenesisTODO.notImplemented` 洞。偵測到 legacy `#error("GENESIS-TODO"` 或 `fatalError("GENESIS-TODO`（pre-1.y 生成）→ warn「pre-1.y scaffold;`genesis new` 重生成為 GenesisTODO 洞」,不碰;`fatalError("TODO(/usecase skill)")`（orchestration，/usecase 範疇）不碰。

## 輸入解析

`$ARGUMENTS`:空 = 全 aggregate;`<Aggregate>` = 限該 aggregate。

## Phase 0 — 環境 + 洞發現（version-aware）

- 確認 cwd 是 generated project root（存在 `.ai/contexts/` 或 `Package.swift`）,否則 **exit 1**:`not inside a Genesis-bootstrapped project`。
- `Grep 'GenesisTODO.notImplemented' Sources/<A>Aggregate/`（或全 aggregate）收集 entity-layer domain 洞（含 command/when/create-init;`<A>GenesisTODO.swift` 宣告檔本身不算洞）。
- **version-aware warn**（不碰,只提示）:legacy `#error("GENESIS-TODO"` / `fatalError("GENESIS-TODO` → warn「pre-1.y scaffold;建議 `genesis new` 重生成」;`fatalError("TODO(/usecase skill)")` → 不碰（/usecase 範疇）。
- 無 marker 洞 → 印「no entity-layer domain holes; nothing to fill」**exit 0**。

## Phase 1 — 每洞分類（signature-first）+ idempotent tri-state

**分類（先看 enclosing method/init signature，scaffold 註解當 integrity check）**:
- `package func <ucCamel>(...) throws`（`Entity/Commands/<A>+<UC>.swift`）→ **command-precondition**（check:`// PRECONDITION (from bundle):` 註解）。
- `package func when(event:) throws`（`Entity/Commands/`）→ **when-reducer**（check:「state transition is not strict-safe」註解）。
- `package convenience init(id:...) throws`（`Entity/<A>.swift`）→ **create-init**（check:「derive non-input createdEvent payload」註解）。
- signature 與 scaffold 註解不符 → **exit 4**:`scaffold integrity check failed in <method>; manual repair needed`。

**idempotent tri-state invariant**（每洞所在 body）:
| 狀態 | 判定 | 動作 |
|---|---|---|
| 未填 | 含 `throw GenesisTODO.notImplemented(...)` + scaffold 註解 | 進 Phase 2 elicit |
| 已填 | 無 GenesisTODO throw + body 有對應結構（command:guard/apply;when:assignment;init:derive+delegate）| skip（重跑不碰）|
| 半填 | GenesisTODO throw 消失但 body 不成對應結構（人手刪 marker 留半身）| **exit 4**:`partial fill detected in <method>; manual repair needed` |

腐敗半徑不對稱（互動時自我提示,不可因「同 skill」用同預設敷衍）:precondition 填錯=擋合法/放非法;when 填錯=replay state 腐敗;create-init 填錯=建出非法 aggregate。

## Phase 2 — per-hole Transcription-only 互動迴圈

對每個未填洞**逐一**（per-hole，強制中斷）:

### 2a. 印洞 context（context firewall 內）
讀並印:洞所在 signature（command args / event 型別 / init params / aggregate）、scaffold 註解（command 的 `// PRECONDITION (from bundle): <NL>` / when 的 structure 提示 / init 的 derive 欄位）、可用 signature（`<UC>Input` fields / aggregate state 宣告 / event payload 型別 / `<A>Error` enum cases 給人挑 errorCode）。**不**讀/印 sibling 已填 body。

### 2b. `AskUserQuestion` 收 dictation（核心 — harness 強制 pause）
用 **`AskUserQuestion`** 收人的 dictation（**非**純印 prompt）—— harness **物理 block 等人回答**,你無法略過。question 帶 2a 的 context;options 至少含「**skip（保留 marker）**」+「我來 dictate domain 邏輯」。
> 你**不**先給候選實作當 option（method-X，禁）。dictate 內容由人 free-text（"Other" / 後續輸入）給。人選 skip / 不提供 → 2f。

### 2c. 回述語意確認（先語意，後語法）
人 dictate 後,**先回述你的理解**（**不**直接寫 code）:
```
語意理解:<paraphrase 人說的 domain rule>
（command）對應 errorCode:<人指定 / 從 <A>Error 列給人挑>
```
用 `AskUserQuestion` 確認（yes 轉 Swift / 修正 / skip）。人說語意錯 → 重述;skip → 2f。

### 2d. transcribe → Swift
把**人確認的語意** transcribe 成 Swift（填該 kind 結構）:
- command-precondition:`guard <人說的 predicate 轉式> else { throw ContextError<<A>Error>.<人挑 errorCode>(function: #function, message: "...") }` +（人若也 dictate build-event）`let event = <E>(...); try self.apply(event: event)`。
- when-reducer:`self.<field> = <人說的 transition 轉式>`（含人說的型別轉換 / 集合操作）。
- create-init:`<人說的 derive 轉式>; try self.init(id: id, ...)`（derive 非-input 欄位後 delegate full init）。
**transcribe 限於人說的**;人沒說的子部分 → 保留對應 `throw GenesisTODO.notImplemented` 或 inline TODO（不腦補）。

### 2e. diff 確認 → 寫 + provenance log
印將寫入的 Swift diff → `AskUserQuestion` 人確認 → Edit 替換該 marker 區塊。該洞所有 marker 都被人意圖覆蓋才完全移除;部分覆蓋 → 留剩餘 marker。
**provenance log**:append `(file:hole-kind:method | 人 dictate 原文 | 填入 Swift)` 到 `docs/domain-fill-provenance.md` —— reviewer 可核「填的源於人說的」（強化 admissibility，非自證語意對）。

### 2f. skip / 無 dictation（admissibility gate）
人 skip / 未提供 semantic payload → **原 `throw GenesisTODO.notImplemented` 原封不動,不 transcribe**。記為「held（待人 judgment）」。

## Phase 3 — 報告（兩層完成）

```
/domain-fill 完成（<A>）:
  filled: <N> holes（人 dictate + transcribe，provenance 已記）
  held:   <M> holes（skip / 無 dictation，marker 保留）

structural:grep 'GenesisTODO.notImplemented' 剩 <M> 個（0 = 無未填 domain 洞 → 該 aggregate 的 domain test 不再因 marker 紅）
semantic:每 filled 洞 provenance = 人 dictate（已逐洞確認）。
         ⚠️ 填完 ≠ 語意對。語意正確性靠 test 紅轉綠（TDD）驗;`genesis verify` 是 release gate（marker 殘留 + invariant 無 enabled test 會 fail）。
下一步:跑該 feature 的 test 確認轉綠;最後 `genesis verify`。
```

### idempotency
重跑:Phase 0 重 grep 現存 marker → 只對剩餘洞 elicit（已填不碰;半填 exit 4）。不追蹤「填了想改」（人自行 re-edit）。

## Framework constraints / 與其他 skills 的關係

- 上游:`genesis new`（Phase 1.y `GenesisTODO.notImplemented` 洞）+ deterministic fill skills（/usecase /api 跑完機械層）。寫入端 fill pipeline **最後一棒**。下游:/readmodel-mutation（讀取端）—— 先跑本 skill 再跑它，同一件事不必問兩次。
- sibling:/usecase（orchestration，code-driven）/ /api（adapter）—— 本 skill 是它們的 **intent-driven 對偶**。/readmodel-mutation（讀取端 projector when()）:確定的直接填、語意不明時用選擇題問人;它的 reuse 提案只沿用本 skill 已確認的寫入端語意（已填的 `when(event:)`，provenance 可查），選了 skip、仍保留的洞不會被沿用，提案仍要人確認才寫。
- honest-hole 閉環:codegen 留 throw-marker（不腦補）↔ /domain-fill 填洞（人沒說不腦補）↔ `genesis verify` release gate 把關。
- 不重疊 / 不碰:orchestration（/usecase）/ adapter（/api）/ read projector when()（/readmodel-mutation）/ test（/test-gen）/ **ensureInvariant**（no-op，由 TDD invariant test + genesis verify 驅動，非 marker 洞）/ legacy #error/fatalError（pre-1.y，warn regenerate）/ read-side domain（GetPermissions，defer）。
