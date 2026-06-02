# Phase 1.w — /domain-fill skill（intent-elicitation domain fill，A5）

## 來源

討論：`docs/discussions/2026-06-02-intent-elicitation-domain-fill-skill.md`（R2 consensus，D1-D7）。

## 目標

新增 `/domain-fill` skill（住 `Sources/GenesisCore/Resources/Templates/skills/domain-fill/SKILL.md`），系統化「**人說 domain 邏輯 → LLM transcribe 成 Swift**」填掉 Phase 1.u 留的 entity-layer `#error` 洞（command precondition+build-event / 非-type-closure when / ensureInvariant）。它是 deterministic fill skills（/usecase /api /readmodel-mutation）的 **intent-driven 對偶** + fill pipeline 最後一棒。

核心安全（討論 lock）：**Transcription-only** —— LLM **絕不推第一版 domain 邏輯**（method-X「LLM 推→人確認」會造成 provenance corruption：LLM 猜的 predicate 看似合理 → 橡皮圖章 → `#error` 消失但語意是 LLM 編的）。LLM 是**秘書（把人 dictate 的意圖轉 Swift）不是參謀（草擬）**。

**admissibility gate 的執行模型（Codex audit HIGH — 誠實定位）**：`/domain-fill` 是 LLM 照 SKILL.md 執行，**無獨立 CLI binary 強制控制流**，所以「無人意圖不填」不能是純 prose 自律（同一個該等待的 LLM 也能自己腦補）。本 skill 用**三層 best-achievable 強制**逼近結構保證：
1. **`AskUserQuestion` harness 強制 pause（最接近結構）**：每個洞用 `AskUserQuestion` 收人的 dictation —— harness **物理 block 等人回答**，skill 無法略過。人選「skip」→ 該洞 `#error` 不動。
2. **先語意後語法**：人 dictate → 先 `AskUserQuestion` 回述語意確認 → 才 transcribe → diff 確認。
3. **provenance log**：每個 filled 洞記 `(hole, 人 dictate 原文, 填入內容)` 到 side log，reviewer 可核對「填的源於人說的」。
誠實聲明（見已知限制）：這是 **workflow-level policy + AskUserQuestion harness pause**，非「分離 enforcer 的物理保證」;「不腦補」終究依執行 LLM 遵循 SKILL.md，但 `AskUserQuestion` 的 block + provenance log 使其遠強於純 prompt。

## 介面合約（Interface Contract）

### Skill frontmatter

```markdown
---
name: domain-fill
description: Genesis intent-elicitation domain-fill skill (transcription-only). Inside a Genesis-bootstrapped project, /domain-fill [<Aggregate>] walks each entity-layer #error("GENESIS-TODO") domain hole (command precondition + build-event / non-type-closure when reducer / ensureInvariant) ONE AT A TIME, prints the hole's scaffold context (bundle precondition / invariant rules / signature), then STOPS and waits for the human to dictate the domain logic in natural language. It transcribes the human's stated intent into Swift — it NEVER drafts domain logic itself. No human dictation → the #error is physically kept (never calls the LLM to fabricate). Sibling of /usecase /api /readmodel-mutation (deterministic fills); this is the human-judgment counterpart.
argument-hint: [Aggregate]
disable-model-invocation: true
allowed-tools: Read, Edit, Glob, Grep, Bash, AskUserQuestion
---
```

### 絕對約束（不可違反）

- **Transcription-only（D2）**：LLM **不**自行草擬/推測 domain predicate/logic。只把人 dictate 的意圖 transcribe 成 Swift。禁止「我先推一版給你確認」。
- **admissibility gate（D3）**：人 skip / 未提供該洞的 semantic payload → **保留原 `#error` 不動，不 transcribe**。透過 `AskUserQuestion`（harness block 等人）+ provenance log 強制（非純 prose;見上「執行模型」誠實定位）。
- **嚴格 per-hole（D4）**：一次處理一個洞，逐洞強制中斷;**不** batch（不「一次推整 aggregate 讓人一起確認」）。
- **context firewall（D5）**：只讀 scaffold 註解 + bundle 資料 + signature（Input/state/event/`<A>Error` cases）。**絕不讀 sibling 已填的 command/when body 當 semantic source**（那是抄既有實作，非 elicit 當前 judgment）。
- **只動 `#error` 洞區塊**：替換該洞的 `#error(...)`（+ 周圍 DOMAIN marker 註解）為人意圖的實作;不動 signature / scaffold 的 bundle-precondition 註解 / 其他 code。
- **只認 `#error("GENESIS-TODO: ...")` 洞（v1，version-aware）**：legacy `fatalError(...)` domain 洞（pre-1.u 生成）+ `fatalError("TODO(/usecase skill)")`（orchestration，非 domain，/usecase 範疇）**不碰** → 偵測到 legacy domain fatalError 印 warn「run genesis new 重生成 #error 洞，或本 skill 不追蹤」。

## 輸入解析

`$ARGUMENTS`：
| 形式 | 處理 |
|------|------|
| 空 | 對 generated project 全部 aggregate 的 entity-layer `#error` 洞 |
| `<Aggregate>` | 只該 aggregate 的洞 |

## Phase 0 — 環境 + 洞發現（version-aware）

- 確認 cwd 是 generated project root（`.ai/contexts/` 或 `Package.swift`），否則 exit 1。
- `Grep '#error("GENESIS-TODO' Sources/<A>Aggregate/`（或全 aggregate）收集 entity-layer domain 洞清單。
- **version-aware**：另 grep legacy domain `fatalError("not implemented")` / `fatalError("GENESIS-TODO: implement state transition` → 若有，印 warn（pre-1.u scaffold;建議 `genesis new` 重生成為 `#error` 洞;本 skill v1 只填 `#error`）。**不** grep/碰 `fatalError("TODO(/usecase skill)")`（orchestration 洞，/usecase 範疇）。
- 無 `#error` 洞 → 印「no entity-layer domain holes; nothing to fill」exit 0。

## Phase 1 — 每洞分類（signature-first）+ idempotent tri-state invariant

**分類（Codex LOW #3：先看 enclosing method signature，scaffold 註解當 integrity check）**：
- 在 `package func <ucCamel>(...) throws`（`Entity/Commands/<A>+<UC>.swift`）內 → **command-precondition**（integrity check：有 `// PRECONDITION (from bundle):` 註解）。
- 在 `package func when(event:) throws`（`Entity/Commands/`）內 → **when-reducer**（check：「state transition is not strict-safe」註解）。
- 在 `package func ensureInvariant() throws`（`Entity/<A>.swift`）內 → **ensureInvariant**（check：「Bundle-declared invariants」註解）。
- signature 與 scaffold 註解不符 → exit 4（scaffold 被改壞 / 非預期洞）。

**idempotent tri-state invariant（Codex MED #4，per hole-kind，對齊既有 fill skill）**：每個洞所在 method body 三態判定：
| 狀態 | 判定 | 動作 |
|---|---|---|
| 未填 | 含預期 `#error("GENESIS-TODO: ...")` + scaffold 註解 | 進 Phase 2 elicit |
| 已填 | 無 `#error` + body 有對應結構（command:guard/apply;when:assignment;invariant:check） | skip（重跑不碰）|
| 半填 | `#error` 消失但 body 不成對應結構（人手刪 #error 留半身）| **exit 4**：`partial fill detected in <method>; manual repair needed` |

腐敗半徑不對稱（Gemini 論點 4，互動時心理提示，不可因「同 skill」用同預設敷衍）：precondition 填錯=擋合法/放非法;when 填錯=replay state 腐敗;ensureInvariant 填錯=廢 DDDKit 守門。

## Phase 2 — per-hole Transcription-only 互動迴圈

對每個洞**逐一**（per-hole，強制中斷）：

### 2a. 印洞 context（context firewall 內）
讀並印給人：
- 洞所在的 method signature（command args / event 型別 / aggregate）。
- scaffold 註解：command 的 `// PRECONDITION (from bundle): <NL>`、ensureInvariant 的 invariant rules + errorCode、when 的 structure 提示。
- 可用 signature：`<UC>Input` fields / aggregate state 宣告 / event payload 型別 / `<A>Error` enum cases（給人挑 errorCode）。
- **不**讀/印 sibling 已填 body。

### 2b. 用 `AskUserQuestion` 收 dictation（D2/D3 核心 — harness 強制 pause）
用 **`AskUserQuestion`**（非純印 prompt）收人的 dictation —— harness **物理 block 等人回答**，skill 無法略過。question 印 2a 的 context，options 至少含「**skip（保留 #error）**」。人選 skip 或不提供 domain 邏輯 → 2f。
> LLM **不**先給候選實作當 option（那是 method-X，禁）。option 是「我要 dictate / skip」性質;dictate 內容由人在 free-text（AskUserQuestion 的 "Other" / 後續輸入）給。

### 2c. 回述語意確認（先語意，後語法 — 開放#2 收斂）
人 dictate 後，A5 **先回述理解**（用 `AskUserQuestion` 或印出 + 等確認，**不直接寫 code**）：
```
語意理解：<paraphrase 人說的 domain rule>
（command）對應 errorCode：<人指定 / 從 <A>Error 列給人挑>
```
`AskUserQuestion` 確認語意（yes 轉 Swift / 修正 / skip）。人說語意錯 → 重述;skip → 2f。

### 2d. transcribe → Swift
把**人確認的語意** transcribe 成 Swift（填進該 kind 的結構）：
- command-precondition：`guard <人說的 predicate 轉式> else { throw ContextError<<A>Error>.<人挑 errorCode>(function: #function, message: "...") }` + （人若也 dictate build-event 對應）`let event = <E>(...); try self.apply(event: event)`。
- when-reducer：`self.<field> = <人說的 transition 轉式>`（含人說的型別轉換 / 集合操作）。
- ensureInvariant：`<人說的 invariant check 轉式，throw ContextError<...>.<code>>`。
**transcribe 限於人說的**;人沒說的子部分（如某 build-event 欄位、某 invariant check）→ 保留對應 `#error` 或 inline TODO（不腦補）。

### 2e. diff 確認 → 寫 + provenance log
印將寫入的 Swift diff → `AskUserQuestion` 人確認 → Edit 替換該 `#error` 區塊。確認該洞所有 `#error` 都被人意圖覆蓋才完全移除;部分覆蓋 → 留剩餘 `#error`。
**provenance log**：append `(file:hole-kind:method, 人 dictate 原文, 填入 Swift)` 到 `docs/domain-fill-provenance.md`（或 `.ai/` 下）—— reviewer 可核「填的源於人說的」（強化 admissibility，非自證語意對）。

### 2f. skip / 無 dictation（admissibility gate）
人 skip 或未提供 semantic payload → **原 `#error` 原封不動**，A5 不 call LLM 填。記為「held（待人 judgment）」。

## Phase 3 — 報告（兩層完成，D6）

```
/domain-fill 完成（<A>）：
  filled: <N> holes（人 dictate + transcribe）
  held:   <M> holes（skip / 無 dictation，#error 保留）

structural：grep '#error' 剩 <M> 個（0 = 結構完整可 build）
semantic：每個 filled 洞的 provenance = 人 dictate 意圖（已逐洞確認）。
          ⚠️ build 綠 = structural 完整，**非** semantic 保證。語意正確性靠 /test-gen 產的 test + 人 author 的 Given 驗（certainty 在人）。
下一步：填完所有洞後 swift build;跑 /test-gen 驗 domain 語意。
```

### idempotency
重跑 `/domain-fill`：Phase 0 重 grep 現存 `#error` → 只對剩餘洞 elicit（已填的不碰）。不追蹤「填了想改」（人自行 re-edit）。

## Framework constraints / 與其他 skills 的關係

- 上游：`genesis new`（Phase 1.u `#error` 洞）+ deterministic fill skills（/usecase /api /readmodel-mutation 跑完機械層）。A5 = **fill pipeline 最後一棒**（收 entity-layer domain 尾）。
- sibling：/usecase（orchestration，code-driven）/ /api（adapter）/ /readmodel-mutation（read projector，type-closure deterministic）—— A5 是它們的 **intent-driven 對偶**（人供 judgment）。
- 共用 honest-hole 哲學：Phase 1.u codegen 留洞（不腦補）↔ A5 fill 洞（人沒說不腦補）= 閉環。
- 不重疊：A5 **不**碰 orchestration（/usecase）/ adapter（/api）/ read type-closure（/readmodel-mutation）/ test（/test-gen）。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/skills/domain-fill/SKILL.md` | **新檔** — /domain-fill skill 全文（Phase 0-3，Transcription-only + admissibility gate + per-hole + context firewall + 兩層完成 + version-aware）|
| `Tests/GenesisCoreTests/SkillInstallerTests.swift` | skill 數 11 → 12：`bundledSkillNames` set 加 `"domain-fill"`；`installIntoEmptyDir` 11 → 12；`installSkipsExisting` 10 → 11 |

### 不需改
- `SkillInstaller.bundledSkillNames()` auto-scan `Templates/skills/` → 加 dir 自動納入，無需改 installer。
- codegen / 既有 skill / DDDKit / bundle schema。

## 實作步驟

### Step 1：寫 `domain-fill/SKILL.md`
1. 建目錄 + 寫 SKILL.md（frontmatter + 絕對約束 + Phase 0-3）。
2. 關鍵務必寫進：Transcription-only（不推第一版）/ admissibility gate（無 dictation 不 call LLM 留 #error）/ 嚴格 per-hole / context firewall（不讀 sibling body）/ 先語意後語法（2c 回述）/ 只認 #error + version-aware warn legacy / 兩層完成。
3. 對齊既有 fill-skill 寫法慣例（exit code、語意錨點、`> Genesis version: {GenesisVersion}` header）。

### Step 2：skill count tests
1. `SkillInstallerTests`：3 處（name set +domain-fill / installIntoEmptyDir 11→12 / installSkipsExisting 10→11）。

### Step 3：verify（見驗收）

## 失敗路徑

| 條件 | 行為 |
|---|---|
| cwd 非 generated project | exit 1 + hint |
| 無 `#error` 洞 | 印「nothing to fill」exit 0 |
| 偵測 legacy domain fatalError（pre-1.u）| warn（建議 regen 為 #error;v1 不填 legacy）|
| 偵測 create convenience-init `fatalError("GENESIS-TODO: derive non-input payload...")`（Phase 1.t.1，仍 fatalError 非 #error）| **v1 不碰** + warn（此 entity-layer domain 洞仍是 fatalError;見已知限制，建議 follow-up 遷 #error 才納 A5）|
| 半填（#error 消失但 body 不成結構）| **exit 4**：`partial fill detected; manual repair needed`（Phase 1 tri-state）|
| 人 skip / 無 dictation | 保留原 `#error`，不 transcribe（admissibility gate via AskUserQuestion skip）|
| 人 dictate 後語意回述被否 | 重述，不寫 code 直到語意確認 |
| 人意圖只覆蓋洞的一部分 | 填覆蓋的、剩餘留 `#error`（不腦補補完）|

> **scope 誠實邊界（Codex MED #5）**：A5 是 entity-layer **`#error`** 洞的「最後一棒」，**非所有 entity-layer domain 洞**。兩個 entity-layer domain 洞**仍是 `fatalError` 不在 v1**：(a) create convenience-init 的 `fatalError("GENESIS-TODO: derive non-input payload...")`（Phase 1.t.1）;(b) pre-1.u legacy fatalError。兩者需先遷 `#error` 才納 A5（follow-up）。

## 不改動的部分
- codegen（Phase 1.u 已產 `#error` 洞）/ `#error` 機制。
- /usecase /api /readmodel-mutation /test-gen /bundle-plan SKILL.md。
- read-side domain 洞（GetPermissions，今天是 /readmodel-mutation exit3 no-op、非 #error）—— **v1 不含**（開放#1 defer;需先讓 /readmodel-mutation exit3 也 emit #error 統一 contract）。
- create convenience-init `fatalError` 洞（Phase 1.t.1）—— **v1 不含**（仍 fatalError;follow-up 遷 #error）。

### Non-goals（行為層）
- **不** LLM 自行草擬 domain 邏輯（Transcription-only;違反 = provenance corruption）。
- **不** batch（嚴格 per-hole）。
- **不**讀 sibling 已填 body 當答案（context firewall）。
- **不**碰 orchestration / adapter / read type-closure / test 洞（各有 deterministic skill）。
- **不**填 legacy fatalError 洞（v1 只 #error;version-aware warn）。
- **不**含 read-side domain（GetPermissions，defer）。
- **不**保證 semantic 正確（只保證 provenance = 人 dictate;語意靠 test-gen 驗）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test 2>&1 | tail -5   # 全 pass（含 skill count 11→12）

SK=Sources/GenesisCore/Resources/Templates/skills/domain-fill/SKILL.md
test -f "$SK"
grep -q 'name: domain-fill' "$SK"
grep -q 'disable-model-invocation: true' "$SK"
# 核心約束在
grep -qiE 'transcription-only|不.*推第一版|never.*draft' "$SK"
grep -qiE 'admissibility|無.*dictation|保留.*#error|never call' "$SK"
grep -qiE 'per-hole|逐洞|一次.*一個洞' "$SK"
grep -qiE 'context firewall|不讀.*sibling|不讀.*body' "$SK"
grep -qiE '先語意|回述|語意.*確認' "$SK"
grep -qiE 'version-aware|legacy.*fatalError' "$SK"
grep -q '#error' "$SK"
# AskUserQuestion harness pause（HIGH/MED2：非純 prose）
grep -q 'AskUserQuestion' "$SK"
grep -q 'AskUserQuestion' <(sed -n '/allowed-tools/p' "$SK")   # 在 allowed-tools
# provenance log（HIGH）
grep -qiE 'provenance' "$SK"
# tri-state / exit 4（MED4 idempotent 對齊既有 fill skill）
grep -qiE '半填|partial fill|exit 4' "$SK"
# signature-first 分類（LOW3）
grep -qiE 'signature-first|enclosing.*signature|package func when\(event' "$SK"
# scope 誠實邊界（MED5：create convenience-init fatalError 不在 v1）
grep -qiE 'convenience-init.*fatalError|derive non-input' "$SK"
# install-skills 納入 domain-fill
TMPHOME=$(mktemp -d); HOME="$TMPHOME" swift run genesis install-skills 2>&1 | grep -q 'domain-fill'
test -f "$TMPHOME/.claude/skills/domain-fill/SKILL.md"
rm -rf "$TMPHOME"
```

### Human 補做
- [ ] regen IAM（Phase 1.u #error 洞）→ 跑 `/domain-fill UserAccessProfile`，對 promoteUser command precondition 洞：dictate「員工要在職」→ 確認 A5 回述語意 + 挑 employeeNotActive errorCode → transcribe → 寫。確認 LLM **沒**先推一版、確認 skip 的洞 `#error` 保留。
- [ ] 對某洞 skip → 確認 `#error` 原封不動（admissibility gate）。
- [ ] 填完所有洞 → `swift build` 綠;跑 `/test-gen` 驗 domain 語意（兩層完成）。
- [ ] 體感：Transcription-only 是否真的「人主導、LLM 聽寫」（非 LLM 主導人橡皮圖章）。

## 已知限制
- **semantic 正確性不保證**：A5 只保證 provenance（人 dictate）+ structural（#error 清）。語意對錯靠 /test-gen test 驗（certainty 在人，D6）。
- **read-side domain 未含**（v1）：GetPermissions 等需 /readmodel-mutation exit3 先 emit #error 統一 contract（開放#1，defer）。
- **version-aware v1 只填 #error**：legacy fatalError 洞（pre-1.u 生成）需 regen;不向後填。
- **admissibility「結構保證」是 best-achievable 非分離 enforcer（Codex HIGH，誠實）**：`/domain-fill` 是 LLM 照 SKILL.md 執行，無獨立 binary 強制控制流;同一個該等待的 LLM 理論上仍能腦補移除 #error。緩解三層：(1) `AskUserQuestion` harness **物理 block 等人回答**（最接近結構，skill 無法略過）;(2) 先語意後語法 + 人 diff 確認;(3) provenance log 供 reviewer 核「填的源於人說的」。比純 prompt 強，但非「分離 enforcer 物理保證」。
- **semantic 正確性不保證**：A5 只保證 provenance（人 dictate）+ structural（#error 清）。語意對錯靠 /test-gen test 驗（certainty 在人，D6）。
- **scope ≠ 所有 entity-layer domain 洞**：v1 只 `#error` 洞;create convenience-init fatalError（Phase 1.t.1）+ legacy fatalError 仍需先遷 #error（follow-up）。
- **read-side domain 未含**（v1）：GetPermissions 需 /readmodel-mutation exit3 先 emit #error 統一 contract（開放#1）。

### 依賴關係
- 軟相依（done）：Phase 1.u（#error 洞）、1.v（Dto-convert，deterministic 對偶邊界）。
- 後續：read-side domain 納入（開放#1）、create convenience-init + legacy fatalError 遷 #error（MED5 follow-up）、A4。
