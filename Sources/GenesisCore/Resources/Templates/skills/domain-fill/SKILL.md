---
name: domain-fill
description: Genesis intent-elicitation domain-fill skill (transcription-only). Inside a Genesis-bootstrapped project, /domain-fill [<Aggregate>] walks each entity-layer #error("GENESIS-TODO") domain hole (command precondition + build-event / non-type-closure when reducer / ensureInvariant) ONE AT A TIME, prints the hole's scaffold context (bundle precondition / invariant rules / signature), then STOPS via AskUserQuestion and waits for the human to dictate the domain logic. It transcribes the human's stated intent into Swift — it NEVER drafts domain logic itself. No human dictation → the #error is physically kept (never transcribes). Sibling of /usecase /api /readmodel-mutation (deterministic fills); this is the human-judgment counterpart.
argument-hint: [Aggregate]
disable-model-invocation: true
allowed-tools: Read, Edit, Glob, Grep, Bash, AskUserQuestion
---

# /domain-fill — intent-elicitation domain fill (transcription-only)

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

系統化「**人說 domain 邏輯 → 你 transcribe 成 Swift**」填掉 `genesis new` 留的 entity-layer `#error("GENESIS-TODO")` domain 洞：command precondition + build-event / 非-type-closure `when` reducer / `ensureInvariant`。你是 deterministic fill skills（/usecase /api /readmodel-mutation）的 **intent-driven 對偶** + fill pipeline 最後一棒（收 entity-layer `#error` domain 尾）。

### 絕對約束（不可違反）

- **Transcription-only**：你**絕不**自行草擬/推測 domain predicate/logic，**不**「先推一版給人確認」（那是 provenance corruption：你猜的 predicate 看似合理 → 人橡皮圖章 → `#error` 消失但語意是你編的）。你是**秘書（把人 dictate 的意圖轉 Swift）不是參謀**。
- **admissibility gate**：人 skip / 未提供該洞 semantic payload → **保留原 `#error` 不動，不 transcribe**。透過 `AskUserQuestion`（harness 物理 block 等人回答，你無法略過）落實。
  > 誠實定位：本 skill 由你（LLM）照本文執行，無分離 binary 強制控制流。三層 best-achievable 強制：(1) `AskUserQuestion` 的 harness block;(2) 先語意後語法;(3) provenance log。比純 prompt 強，但「不腦補」終究依你遵循本約束。
- **嚴格 per-hole**：一次處理一個洞，逐洞中斷;**不** batch（不「一次推整 aggregate 讓人一起確認」—— batch 鼓勵 rubber-stamp）。
- **context firewall**：只讀 scaffold 註解 + bundle 資料 + signature（Input / aggregate state / event payload / `<A>Error` cases）。**絕不讀 sibling 已填的 command/when body 當 semantic source**（抄既有實作 ≠ elicit 當前 judgment）。
- **只動 `#error` 洞區塊**：替換該洞 `#error(...)`（+ 周圍 DOMAIN marker 註解）為人意圖的實作;不動 signature / scaffold 的 bundle-precondition 註解 / 其他 code。
- **只認 `#error("GENESIS-TODO: ...")` 洞（version-aware）**：legacy `fatalError(...)` domain 洞（pre-1.u）、create convenience-init 的 `fatalError("GENESIS-TODO: derive non-input payload...")`（Phase 1.t.1）、`fatalError("TODO(/usecase skill)")`（orchestration，/usecase 範疇）**都不碰** → 偵測到印 warn。

## 輸入解析

`$ARGUMENTS`：空 = 全 aggregate;`<Aggregate>` = 限該 aggregate。

## Phase 0 — 環境 + 洞發現（version-aware）

- 確認 cwd 是 generated project root（存在 `.ai/contexts/` 或 `Package.swift`），否則 **exit 1**：`not inside a Genesis-bootstrapped project`。
- `Grep '#error("GENESIS-TODO' Sources/<A>Aggregate/`（或全 aggregate）收集 entity-layer domain 洞。
- **version-aware warn**（不碰，只提示）：
  - legacy `fatalError("not implemented")` / `fatalError("GENESIS-TODO: implement state transition` → warn「pre-1.u scaffold;建議 `genesis new` 重生成為 #error 洞」。
  - create convenience-init `fatalError("GENESIS-TODO: derive non-input payload` → warn「此 domain 洞仍 fatalError（Phase 1.t.1）;v1 不填，待遷 #error」。
  - **不** grep/碰 `fatalError("TODO(/usecase skill)")`（orchestration，/usecase 範疇）。
- 無 `#error` 洞 → 印「no entity-layer domain holes; nothing to fill」**exit 0**。

## Phase 1 — 每洞分類（signature-first）+ idempotent tri-state

**分類（先看 enclosing method signature，scaffold 註解當 integrity check）**：
- `package func <ucCamel>(...) throws`（`Entity/Commands/<A>+<UC>.swift`）→ **command-precondition**（check：`// PRECONDITION (from bundle):` 註解）。
- `package func when(event:) throws`（`Entity/Commands/`）→ **when-reducer**（check：「state transition is not strict-safe」註解）。
- `package func ensureInvariant() throws`（`Entity/<A>.swift`）→ **ensureInvariant**（check：「Bundle-declared invariants」註解）。
- signature 與 scaffold 註解不符 → **exit 4**：`scaffold integrity check failed in <method>; manual repair needed`。

**idempotent tri-state invariant**（每洞所在 method body）：
| 狀態 | 判定 | 動作 |
|---|---|---|
| 未填 | 含預期 `#error("GENESIS-TODO: ...")` + scaffold 註解 | 進 Phase 2 elicit |
| 已填 | 無 `#error` + body 有對應結構（command:guard/apply;when:assignment;invariant:check）| skip（重跑不碰）|
| 半填 | `#error` 消失但 body 不成對應結構（人手刪 #error 留半身）| **exit 4**：`partial fill detected in <method>; manual repair needed` |

腐敗半徑不對稱（互動時自我提示，不可因「同 skill」用同預設敷衍）：precondition 填錯=擋合法/放非法;when 填錯=replay state 腐敗;ensureInvariant 填錯=廢 DDDKit 守門。

## Phase 2 — per-hole Transcription-only 互動迴圈

對每個未填洞**逐一**（per-hole，強制中斷）：

### 2a. 印洞 context（context firewall 內）
讀並印：洞所在 method signature（command args / event 型別 / aggregate）、scaffold 註解（command 的 `// PRECONDITION (from bundle): <NL>` / ensureInvariant 的 invariant rules + errorCode / when 的 structure 提示）、可用 signature（`<UC>Input` fields / aggregate state 宣告 / event payload 型別 / `<A>Error` enum cases 給人挑 errorCode）。**不**讀/印 sibling 已填 body。

### 2b. `AskUserQuestion` 收 dictation（核心 — harness 強制 pause）
用 **`AskUserQuestion`** 收人的 dictation（**非**純印 prompt） —— harness **物理 block 等人回答**，你無法略過。question 帶 2a 的 context;options 至少含「**skip（保留 #error）**」+「我來 dictate domain 邏輯」。
> 你**不**先給候選實作當 option（method-X，禁）。dictate 內容由人 free-text（"Other" / 後續輸入）給。人選 skip / 不提供 → 2f。

### 2c. 回述語意確認（先語意，後語法）
人 dictate 後，**先回述你的理解**（**不**直接寫 code）：
```
語意理解：<paraphrase 人說的 domain rule>
（command）對應 errorCode：<人指定 / 從 <A>Error 列給人挑>
```
用 `AskUserQuestion` 確認（yes 轉 Swift / 修正 / skip）。人說語意錯 → 重述;skip → 2f。

### 2d. transcribe → Swift
把**人確認的語意** transcribe 成 Swift（填該 kind 結構）：
- command-precondition：`guard <人說的 predicate 轉式> else { throw ContextError<<A>Error>.<人挑 errorCode>(function: #function, message: "...") }` +（人若也 dictate build-event）`let event = <E>(...); try self.apply(event: event)`。
- when-reducer：`self.<field> = <人說的 transition 轉式>`（含人說的型別轉換 / 集合操作）。
- ensureInvariant：`<人說的 invariant check 轉式，throw ContextError<...>.<code>>`。
**transcribe 限於人說的**;人沒說的子部分（某 build-event 欄位 / 某 invariant check）→ 保留對應 `#error` 或 inline TODO（不腦補）。

### 2e. diff 確認 → 寫 + provenance log
印將寫入的 Swift diff → `AskUserQuestion` 人確認 → Edit 替換該 `#error` 區塊。該洞所有 `#error` 都被人意圖覆蓋才完全移除;部分覆蓋 → 留剩餘 `#error`。
**provenance log**：append `(file:hole-kind:method | 人 dictate 原文 | 填入 Swift)` 到 `docs/domain-fill-provenance.md` —— reviewer 可核「填的源於人說的」（強化 admissibility，非自證語意對）。

### 2f. skip / 無 dictation（admissibility gate）
人 skip / 未提供 semantic payload → **原 `#error` 原封不動，不 transcribe**。記為「held（待人 judgment）」。

## Phase 3 — 報告（兩層完成）

```
/domain-fill 完成（<A>）：
  filled: <N> holes（人 dictate + transcribe，provenance 已記）
  held:   <M> holes（skip / 無 dictation，#error 保留）

structural：grep '#error' 剩 <M> 個（0 = 結構完整可 build）
semantic：每 filled 洞 provenance = 人 dictate（已逐洞確認）。
          ⚠️ build 綠 = structural 完整，**非** semantic 保證。語意正確性靠 /test-gen 產的 test + 人 author 的 Given 驗（certainty 在人）。
下一步：填完所有洞 swift build;跑 /test-gen 驗 domain 語意。
```

### idempotency
重跑：Phase 0 重 grep 現存 `#error` → 只對剩餘洞 elicit（已填不碰;半填 exit 4）。不追蹤「填了想改」（人自行 re-edit）。

## Framework constraints / 與其他 skills 的關係

- 上游：`genesis new`（Phase 1.u `#error` 洞）+ deterministic fill skills（/usecase /api /readmodel-mutation 跑完機械層）。A5 = fill pipeline **最後一棒**（收 entity-layer `#error` domain 尾）。
- sibling：/usecase（orchestration，code-driven）/ /api（adapter）/ /readmodel-mutation（read，type-closure deterministic）—— 本 skill 是它們的 **intent-driven 對偶**。
- honest-hole 閉環：Phase 1.u codegen 留洞（不腦補）↔ /domain-fill 填洞（人沒說不腦補）。
- 不重疊 / 不碰：orchestration（/usecase）/ adapter（/api）/ read type-closure（/readmodel-mutation）/ test（/test-gen）/ legacy fatalError + create convenience-init fatalError（v1 非 #error，待遷）/ read-side domain（GetPermissions，需 /readmodel-mutation exit3 先 emit #error）。
