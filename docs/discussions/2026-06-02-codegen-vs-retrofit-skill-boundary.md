---
topic: "deterministic fill 收回 codegen + fill skill 重定位為 code-driven retrofit（canvas drift 場景）"
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
  fixed:        # evidence / 前討論 locked
    - "mechanizability-by-type-closure 軸（domain-scaffold-emitter D1）：type/結構可導 → codegen 候選;需 human judgment → #error + /domain-fill。"
    - "D3 precedent：command scaffold 走 codegen-time 為主，理由 Codex『generator 已擁有該檔 + 已有 bundle 資料』。"
    - "/usecase /api /readmodel-mutation 是 deterministic：讀的是生成 code 的 signature（Input/Output/Command 簽名/create init），**不讀 bundle、不讀業務 md**;用寫死的 OC-distilled pattern（usecase 的 Create/Update/Delete;readmodel 的 type-closure pattern）。pattern 選擇 structural-first（簽名對得上才填，否則 exit 3）。"
    - "這批 fill skill 建於 scaffold-emitter / #error 洞 洞見之前（『codegen=結構,skill=所有 body』粗原則時代）—— 歷史包袱。"
    - "OC execute body ~94% 標準 shape（find→command→save→return + catch ladder），~6% 真分支 orchestration（RemoveServiceItems，需 judgment）。"
    - "Genesis 前提：canvas → bundle → code（canvas 為 SSOT）。Phase 4（verify-canvas / plan-canvas-sync canvas 反向同步 / drift 偵測）已設計、未實作。"
    - "A3（retrofit /command skill：後補全新 command/UC 進既有 aggregate，emit 新 scaffold）於 domain-scaffold-emitter defer。"
    - "codegen 輸出有 .scaffold-manifest.json sha256 追蹤;genesis new 拒絕 version-conflict 覆蓋。"
  proposed:     # user frame + challengeable
    - "user frame：初次生成（canvas 最新）→ codegen 直接生 deterministic body;後續在 code 加新 UC（**常常沒回更新 canvas/bundle**）→ 用 skill 填，因為 skill 讀 code signature 而非 bundle，bundle-less 也能做。"
    - "skill 不是刪掉，是重定位為 code-driven retrofit niche（增量 / bundle drift）。"
    - "完整 retrofit 需 A3（長新 UC 結構），否則 body-fill skill 只填得到 execute/adapter body、結構要手刻。"
    - "需對 canvas drift 表態（接受 vs Phase 4 回填）。"
---

# deterministic fill 收回 codegen + fill skill 重定位 retrofit

## 議題定義

### 背景
這 session 確立 mechanizability-by-type-closure 軸後，發現 `/usecase` `/api` `/readmodel-mutation`（deterministic fill skill）站錯邊：它們填的是 type/結構可導的 body（orchestration / adapter / type-closure reducer），讀 code signature 而非 bundle，本質是 codegen 該做的事 —— 卻因歷史（建於 scaffold-emitter 之前）留在 skill。

user 提出重定位 frame：**初次生成（canvas 最新）由 codegen 直接生這些 body;skill 重定位為「在 code 增量加新 UC、且常沒更新 canvas/bundle」時的 code-driven retrofit**。skill 「讀 code 不讀 bundle」的特性，正是 bundle-drift 場景的價值。

### 目標
定清楚一個架構決定的三面：(1) 初次 deterministic fill 收回 codegen?(2) skill 重定位為 retrofit 後，retrofit pipeline 完整需要什麼（A3）?(3) canvas drift 立場（接受 / 回填 / Phase 4）?+ migration/相容。

### 範圍
- 討論內：codegen vs retrofit-skill 邊界、A3 retrofit scaffold 設計綱要、canvas drift 立場、migration。
- 討論外：A3 完整 spec（本輪只定綱要）、Phase 4 完整設計、#error/domain-fill 機制（已 locked）。

### 子議題
- [ ] C1：初次生成的 deterministic fill（usecase orchestration / api wiring / readmodel type-closure）**收回 codegen**?還是維持 skill?6% 非標準 orchestration 怎麼辦（codegen #error?）。regen/manifest 覆蓋怎麼處理。
- [ ] C2：retrofit「加新 UC（bundle-less）」需要什麼 → A3 綱要：A3 emit 什麼（Input/Output/Command/event/Service + #error）?無 bundle 時結構從哪來（人 dictate? 輕量 descriptor? 從手寫 command stub 反推?）。
- [ ] C3：skill 重定位 —— 若初次 fill 收回 codegen，`/usecase` `/api` `/readmodel-mutation` 存活角色 = 純 retrofit?與 A3 的關係（A3 長結構 → fill skill 填 body → /domain-fill 填 #error）。
- [ ] C4：canvas drift 立場 —— 接受 drift（canvas 變起點不維護）vs 回填（retrofit 順手寫回 bundle/canvas）vs Phase 4 verify-canvas 收斂。要不要 retrofit 至少標記 drift。
- [ ] C5：migration / 相容 —— 既有生成專案 + 既裝 skill 怎麼辦;codegen 收回 body 後 manifest/regen 行為（codegen-emit 完整 body 反而 manifest 乾淨?）。

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.8)

**總立場：採 user frame —— 初次 deterministic fill 收回 codegen、skill 重定位 code-driven retrofit。這解掉 codegen-vs-skill 張力（skill 找到 bundle-less 不可取代 niche）。但 retrofit 要完整需補 A3，且 drift 要明確「回填優先、不默默爛」。**

- **C1（收回 codegen）→ YES**。理由：(a) type-closure 軸 + D3 precedent 一致 —— UseCaseRenderer 已擁有 `{UC}Usecase.swift` 且已有 command 簽名（自己生的），fill 時 Glob 讀簽名是重推導 codegen 已知的東西。(b) deterministic = 可重現、CI-testable、無 stochastic;renderer 已在做結構 codegen（AggregateRenderer/UseCaseRenderer），加 execute-body emit 不大。(c) **manifest 更乾淨**：codegen emit 完整 body → manifest sha256 記完整檔;現況「codegen emit stub + skill 填」→ 填完檔變了、與 manifest 不符、未來 regen 必衝突。codegen-emit 反而修掉這個。(d) 6% 非標準 orchestration → codegen 偵測不出標準 pattern 時 emit `#error`（scaffold-emitter 一致），人/`/domain-fill` 處理。
  - 收回範圍：usecase Create/Update/Delete orchestration、api AS+ApiHandler wiring、readmodel type-closure pattern（scalar/Dto-convert）。**不**收 type-closure 邊界外的（config-replace 等仍 #error）。

- **C2（A3 綱要）→ A3 是 retrofit 的「長結構」一棒，無 bundle 時靠輕量 descriptor / 人 dictate**。retrofit「加新 UC」缺的是結構（Input/Output/Command/event/Service），只有 codegen（從 bundle）會長。A3 補這棒：
  - input：無 bundle 時，A3 從**最小 UC descriptor**（UC 名 + command args + event payload + 是否 create/delete）長結構。descriptor 來源選項：(i) 人互動 dictate（domain-fill 式 AskUserQuestion）;(ii) 一個輕量 per-UC yaml/md;(iii) 人先手寫一個 command method stub，A3 反推。Claude lean (i)+(ii) 混合：A3 互動問最小結構 + 可存成輕量 descriptor 供重跑。
  - output：與 codegen 同形的 scaffold（Input/Output/Command/event/Service + #error 洞），讓下游 `/usecase`(若還在)/`/domain-fill` 接得上。
  - **A3 emit 的 deterministic body**：若 C1 把 fill 收回 codegen，A3 也應直接 emit deterministic body（不只 stub），與 codegen 一致。

- **C3（skill 重定位）→ `/usecase` `/api` `/readmodel-mutation` 萎縮為 retrofit-only**：初次由 codegen;它們存活因「讀 code 不讀 bundle」→ retrofit 場景（A3 長完結構後、或人手刻結構後）填 deterministic body。retrofit pipeline = **A3（結構）→ deterministic body（codegen-emit if A3 走 codegen path, 或 fill skill）→ /domain-fill（#error）**。可能 A3 直接內含 body emit，fill skill 進一步退化為「純既有專案的補填工具」。

- **C4（drift 立場）→ 回填優先，不默默爛**。user frame 偏「接受 drift」（務實），但 canvas 是 SSOT，放任爛會讓 bundle/regen 故事崩。Claude 主張：**retrofit（A3）順手把新 UC 的最小資訊回寫 bundle**（canvas 之後可從 bundle 對賬 / Phase 4 verify-canvas 收斂）。至少**標記 drift**（manifest 記「此 UC 為 retrofit-added, not in original bundle」）。逃生門(接受) + 誠實性(可回填) 兼得。

- **C5（migration/相容）→ 加 codegen body emit 是 additive，既有 skill 保留**。既有生成專案（codegen emit 過 stub）+ 既裝 skill 仍可用（skill 填 stub）。新 codegen 版本 emit 完整 body;version-conflict manifest 機制處理跨版本。fill skill 不立即刪（retrofit + 舊專案需要）。

**Evidence**：domain-scaffold-emitter D1（type-closure 軸）/ D3（codegen-primary precedent）;本 session /usecase SKILL.md 分析（讀 signature 非 bundle、寫死 pattern、structural-first）;gemini OC study（execute ~94% 標準）;Genesis manifest + Phase 4 roadmap;A3 defer 紀錄。

**待 Codex / Gemini R1**：(i) C1 值得?(ii) C2 descriptor 來源?(iii) C4 回填 bundle 可行?(iv) 更省的路?

#### Codex (GPT-5.4)

⚠️ **未取得**：Codex 派至 `codex:codex-rescue` 後 runtime 未 flush 最終訊息（companion 仍登記 running、本地 process 已退但 output 檔無最終分析）。讀了一堆檔（兩討論 + usecase/api SKILL.md + UseCaseRenderer + NewCommand + SourceWriter + ManifestRenderer + ReadModelBundleAppender…）但**未返回結構化 C1-C5**。per discuss tool-failure 透明度記此。下方 R2 的決定性論點（appender 已存在、A5 firewall 衝突）由 **Gemini 提出 + Claude 親自驗證 codebase**，非靠 Codex。

#### Gemini

**淨立場 + REFRAME：這不是「三面一決定」，是兩個正交軸被綁成一捆。** 拆開：
- **軸 A（C1）「deterministic body 由誰 emit」**：codegen（擁有檔+簽名）vs skill。純 systems 題，答案清楚 → **codegen**。
- **軸 B（C2/C3/C4 共同根）「Genesis 支不支援 bundle-less 增量」**：user frame 把「skill 讀 code 不讀 bundle」當 retrofit *價值*，**但那是 bug 不是 feature** —— 它正是讓 canvas SSOT 爛掉的機制。

**真正的決定是一個：bundle-less retrofit 要不要升格 first-class? → NO。** retrofit 應 **bundle-first**（先補 bundle 再生），bundle-less 只能是標記 drift 的 degraded 逃生門，絕不能變常態（否則 10 個月後 Genesis 從「canvas-driven codegen」退化成「一次性 scaffold + 手工增量墳場」）。

**決定性證據（推翻前提，Claude 已驗）**：`ReadModelBundleAppender.append(bundle:answers:) throws -> FullBundle` + `PresenterBundleAppender` **已存在** —— 接 FullBundle、驗證、回傳新增了原 Cosmogony export 沒有的 entry 的 bundle，no-partial-mutation。**Genesis 早就在寫回 bundle 結構。** Claude C4 問的「該不該寫 bundle」codebase 已答：該寫、已寫、有驗證。A3 回填 = UseCaseBundleAppender sibling，不是新能力。

- **G1**：bundle-less 是 drift 的「生產機制」非「應對場景」。若 skill 讓 bundle-less 比 bundle+regen 省力 → 100% 增量走 bundle-less → canvas 第一個月死 → verify-canvas 變考古。
- **G2**：A3 descriptor 必然長成第二個 bundle schema（Claude (i)+(ii) 是慢性毒）。「能長出 Input/Output/Command/event/Service 的輸入」定義上就是 UC 結構描述 = bundle 的 `UseCaseSpec`。正解：A3 互動 elicit → **寫真 `UseCaseSpec` 進 bundle（appender 模式）→ 正常 codegen**。一套真相。descriptor = VETO。
- **G3（沒人提的硬傷）**：bundle-less 與已 lock 的 **A5 context firewall（D5：A5 讀 scaffold + bundle preconditions/invariants/errorCode）衝突** —— bundle-less 時 A5 沒 bundle 可讀 → firewall 缺腳 → A5 退化「只看 scaffold + 人 dictate」、丟失 precondition NL/invariant rules。**bundle-less 不只爛 canvas，還降下游 domain-fill 的 honest-hole 品質。** 反證 G2：retrofit 必須先補 bundle，A5 才有 firewall。
- **G4**：C1 收回 codegen，renderer 完勝 SKILL.md —— 但理由是 **deterministic = pure function = 可單元測 = CI 鎖**（非 Claude 的「manifest 乾淨」，那個機制錯，見 C5）。「改要重編譯」是特性非成本（deterministic 邏輯本就該慢、該審、該鎖版）。

**C1-C5**：C1 → **YES codegen**（6% #error 與既有洞同籃）/ C2 → **VETO descriptor，A3 elicit→寫真 UseCaseSpec 進 bundle**/ C3 → skill 萎縮為 **migration-only**（A3 bundle-first + codegen emit body 後，fill skill 在 retrofit 幾無角色，趨近只服務 legacy 舊專案）/ C4 → **bundle-first canonical（drift=0）/ bundle-less = 顯式 `--no-bundle-sync` 逃生門 + 強制 manifest `role: retrofit-unsynced` 標記 / Phase 4 = 偵測網**，**無「靜默接受 drift」選項**/ C5 → additive AGREE，但**糾正 Claude manifest 論點**：codegen-emit 完整 body 後仍有 `#error` 洞要 A5 填 → 填完 sha 一樣對不上 manifest → 跟現況同問題;「codegen-emit 讓 manifest 乾淨」**不成立**。真正解 = manifest `role` 區分「machine-owned 完整檔」vs「machine-scaffold + human-fill 檔」（如 test-gen .generated/.authored），與 C1 無關。

漏的風險：R-a bundle-less ⊥ A5 firewall（最重要）/ R-b A3 descriptor=2nd schema（appender 可避）/ R-c Claude manifest 論機制錯 / R-d buildWhenBody/renderCommandExtension 缺 nested 語意輸入（D7 defer）→ C1 收更多 body 進 codegen 的成本被低估。

---

### Round 2 — Synthesis（Claude facilitator）

**全盤採納 Gemini 的兩軸 reframe + bundle-first。三個關鍵證據（appender 已存在、manifest 有 role、A5 firewall 讀 bundle）Claude 親自驗證屬實。我 R1 數處被推翻。**

**Rejection log（HARD）**：
- ❌ **我 R1 C2「A3 descriptor（互動 + 輕量 yaml）」**：VETO（Gemini G2）。descriptor 定義上是 UC 結構描述 = `UseCaseSpec` 子集 = 第二套真相 = drift 溫床。改 **A3 elicit → 寫真 `UseCaseSpec` 進 bundle（UseCaseBundleAppender，sibling of 已存在的 ReadModel/Presenter appender）→ 共用 codegen path**。
- ❌ **我 R1 C4「順手回寫 + 至少標記」（best-effort 軟）**：Gemini 對 —— 「順手回寫」會變「順手沒寫」。HARDEN：**bundle-first 為 canonical**（A3 寫 bundle 再 codegen，drift=0）;bundle-less 僅限**顯式逃生門 + 強制 manifest `role: retrofit-unsynced`**;無靜默 drift。
- ❌ **我 R1 C5「codegen-emit 讓 manifest 更乾淨」**：機制錯（Gemini）。codegen emit body 後仍有 `#error` 洞 → A5 填 → sha 仍對不上 → 同現況。regen-conflict 真正解 = manifest `role` 區分 machine-complete vs scaffold+human-fill（test-gen 兩檔分離思路），**與 C1 正交，C1 不解這題**。
- ❌ **我 R1 C3「skill 存活因 bundle-less」**：skill 存活真正理由是 **migration（legacy 舊專案）**，非鼓勵 bundle-less 新增。
- ✅ **採納 reframe**：兩正交軸（A=誰 emit body→codegen;B=bundle-less first-class?→NO）。root question 答 NO。

**收斂決定（待 lock）**：
1. **D1（軸 A / C1）**：deterministic fill（usecase orchestration / api wiring / readmodel type-closure）**收回 codegen**;6% 非標準 → `#error`。理由 = deterministic 可 pure-function 化、單元測、CI 鎖（非 manifest）。
2. **D2（reframe / 軸 B）**：**bundle-less retrofit 不升格 first-class**。retrofit canonical = bundle-first。
3. **D3（C2）**：A3 = **互動 elicit UC 結構 → 寫真 `UseCaseSpec` 進 bundle（UseCaseBundleAppender，比照已存在 appender）→ 共用 codegen**。**VETO 第二 descriptor schema**。一套真相。
4. **D4（C3）**：fill skill（/usecase /api /readmodel-mutation）→ **migration-only**（服務 codegen 版本過舊、只 emit 過 stub 的 legacy 專案）;新增走 D3 bundle-first，fill skill 無新 retrofit 角色。
5. **D5（C4 + G3）**：drift 立場 = bundle-first canonical（drift=0）/ bundle-less 顯式逃生門 + 強制 manifest `role: retrofit-unsynced` / Phase 4 verify-canvas 偵測網。**無靜默接受**。bundle-less ⊥ A5 context firewall（G3）強化「retrofit 必先補 bundle」。
6. **D6（C5 糾正）**：regen-conflict 不靠 C1 解;真正解 = manifest `role` 區分 machine-complete vs scaffold+human-fill（另案，呼應 test-gen 兩檔分離）。
7. **D7（R-d 成本）**：C1 收更多 body 進 codegen 時，`buildWhenBody`/`renderCommandExtension` 缺 nested 語意輸入（domain-scaffold D7 defer）會更早撞上 → 實作成本要計入。

---

## 共識看板（R2 後）

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| C1 | deterministic fill 收回 codegen | R2 改：YES | （未返回）| YES（理由=可測 CI 鎖）| **agreed**（codegen;6%→#error）|
| C2 | A3 結構來源 | R2 改：寫真 bundle | （未返回）| VETO descriptor，寫真 UseCaseSpec | **agreed**（appender 模式，一套真相）|
| C3 | skill 重定位 | R2 改：migration-only | （未返回）| migration-only | **agreed**（非鼓勵 bundle-less）|
| C4 | canvas drift 立場 | R2 改：bundle-first canonical | （未返回）| bundle-first + 強制標 drift，無靜默 | **agreed**（無靜默 drift）|
| C5 | migration/manifest | R2 改：manifest 論點撤回 | （未返回）| additive + manifest role 才解 regen | **agreed**（C1 不解 regen-conflict）|
| C6* | **reframe：兩正交軸 + bundle-less 不 first-class** | 採納 | （未返回）| 提出 | **agreed**（root=NO）|

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | deterministic fill（usecase orchestration/api wiring/readmodel type-closure）**收回 codegen**;6% 非標準 → `#error` | 2026-06-02 | R2 | 理由=可 pure-function 化、單元測、CI 鎖（Gemini G4）|
| D2 | **bundle-less retrofit 不升格 first-class**;retrofit canonical = bundle-first | 2026-06-02 | R2 | Gemini reframe;root question 答 NO |
| D3 | A3 = elicit UC 結構 → **寫真 `UseCaseSpec` 進 bundle（UseCaseBundleAppender，比照已存在 ReadModel/Presenter appender）→ 共用 codegen**;VETO 第二 descriptor schema | 2026-06-02 | R2 | appender 模式已驗存在 |
| D4 | fill skill（/usecase /api /readmodel-mutation）→ **migration-only**（legacy 舊專案）;新增走 bundle-first | 2026-06-02 | R2 | 撤 Claude R1「skill 存活因 bundle-less」|
| D5 | drift：bundle-first canonical（drift=0）/ bundle-less 顯式逃生門 + 強制 manifest `role: retrofit-unsynced` / Phase 4 偵測網;**無靜默 drift** | 2026-06-02 | R2 | bundle-less ⊥ A5 firewall（G3）強化 |
| D6 | regen-conflict 不靠 C1 解;真正解 = manifest `role` 區分 machine-complete vs scaffold+human-fill（另案，呼應 test-gen 兩檔分離）| 2026-06-02 | R2 | 糾正 Claude R1 manifest 論點 |
| D7 | C1 實作：`buildWhenBody`/`renderCommandExtension` 缺 nested 語意輸入（domain-scaffold D7 defer）→ 收更多 body 成本要計入 | 2026-06-02 | R2 | R-d |

---

## 開放問題

1. **[未驗-Codex]** Codex runtime 未 flush → C1-C6 標 agreed-pending-Codex。但決定性論點（appender 已存在 / A5 firewall 衝突 / manifest role）由 Claude 親驗 codebase，reframe 為證據強制。
2. **A3 完整 spec**：UseCaseBundleAppender 的 elicit UX（互動問什麼最小欄位）、validate 規則（比照 ReadModelBundleAppender）—— 另開 spec。
3. **D6 manifest role 兩態**（machine-complete vs scaffold+human-fill）—— 與 regen/Phase 3 `genesis diff/apply` 一起設計，另案。
4. **D1 收回範圍與順序**：usecase orchestration 先、api/readmodel 後?6% orchestration 的 #error 偵測（structural-not-recognized）落點。

---

## 下次討論指引

### 進度摘要
**R2 收斂（consensus，採 Gemini 兩軸 reframe）。** 核心翻轉:問題不是「三面一決定」而是兩正交軸 —— (A) deterministic body 收回 codegen（YES）;(B) bundle-less 升 first-class（NO）。retrofit = **bundle-first**（A3 elicit → 寫真 UseCaseSpec 進 bundle〔appender 已存在〕→ codegen），**VETO descriptor 第二 schema**;fill skill → migration-only;drift 無靜默（強制 manifest 標記）。我 R1 的 descriptor/順手回寫/manifest-乾淨 三處被推翻。下一步:依 D1（codegen 收回）+ D3（A3 bundle-first）write-spec。

### 待處理事項
write-spec：(a) D1 deterministic fill 收回 codegen（usecase orchestration 先）;(b) D3 A3 = UseCaseBundleAppender + elicit。D6 manifest role / Phase 4 另案。

### 閱讀建議
- 本檔 R1（Gemini）+ R2 + 決策 D1-D7
- `Sources/GenesisCore/ReadModelBundleAppender.swift`（A3 比照的 appender 模式）、`ManifestRenderer.swift`（role 欄位）
- `UseCaseRenderer.swift`（D1 收回落點）、`/usecase` SKILL.md（要收回的 pattern）
- domain-scaffold-emitter（type-closure 軸 / D7 nested 語意缺口）、intent-elicitation（A5 firewall 讀 bundle）

### 注意事項
bundle-first 是核心：一套真相（bundle）。bundle-less 僅標記 drift 的逃生門。descriptor = 第二 schema = veto。
