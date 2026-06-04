---
topic: "test-gen 重設計：從空殼 scaffold 升級為『真 test』—— §5/§6 transcription + Given honest-hole + --fill-given 彈性"
status: consensus
created: "2026-06-03"
updated: "2026-06-04"
participants:
  - Claude (Opus 4.8)
  - Codex (GPT-5.4)
  - Gemini
  - Round 3 re-validation (adversarial workflow, 3 lens + empirical swiftc 6.2.3)
facilitator: Claude
rounds_completed: 3
mode: default
premises:
  fixed:        # evidence（workflow understand survey，OC gold standard + 現況 + bundle 能力）
    - "OC test 黃金標準（1448 test 檔，480 Swift Testing，0 XCTest）：每 usecase test = struct @Suite(.serialized, .tags(.<agg>)) 持 kdbClient=KurrentDBClient(.localhost()) + repository + init() wire;每 test body 包 withTestBundle(client:){ bundle in }。**真 KurrentDB 非 in-memory**。"
    - "OC Given：bundle.generateAggregateRootId(for:)/generateId(for:) 生 id;state 靠呼叫真前置 usecase via shared SharedUtility/UsecaseCall/<A>.swift helper（createAuditQuoting(...)）;多步 chain;143 個 local setupX helper。"
    - "OC When：<UC>Input(...) → <UC>Service(repository:) → try await execute(input:)（.execute(input: 1504 次）。OC Then 4 種：output assert / re-hydrate repository.find 讀回 aggregate 斷言 state（518 次，主力）/ #expect(throws: ContextError<<A>Error>.self)+error?.error==.case（574 次）/ DDDError aggregateNotFound（161 次）。不直接斷言 event。"
    - "現況 test-gen：兩檔分離（.generated machine-owned / .authored human-owned）。只有 create-happy-path（~3%）是 runnable;其餘 97% = @Test(.disabled)+Issue.record+註解掉的 structure template（Phase 1.s honest-scaffold / skipped-not-green / 防 test-theater）。user 認為『空殼、沒用』。"
    - "bundle 能力：Gherkin §6 在 task-spec markdown（bundle-plan LLM 推 + 人確認）;FullBundle **不**帶 scenario，只帶 input/eventPayload/preconditions。§5 error 表（condition|errorCode|HTTP）機械 from invariants。**§6 happy Examples 是 placeholder（v-userId），error Given 是未譯中文 invariant 標題**。"
    - "mechanizability（type-closure 軸）：機械可導 = harness + When-call shell + output.id assert + re-hydrate 行 + #expect(throws:) envelope + **error code（§5 轉錄）**;judgment 只兩塊 = Given-state（哪些 fixture/順序）+ Given-data-values（哪個 input 值觸發哪個 invariant）。每 error scenario ~80% 行可機械生、~20% 要人。"
    - "honest-hole 家族：codegen 留 #error → /domain-fill 填;test-Given 洞是其 test-layer 對應物。--fill-given = /domain-fill 的 test 版（秘書非參謀、AskUserQuestion-block、不猜哪個值觸發 invariant = provenance corruption）。"
    - "aggregate-not-found error test 全機械可生（無需 domain Given，只要不存在的 id）→ 與 create-happy-path 同為 fully-auto。"
  proposed:
    - "redesign = 三層 hybrid（type-closure 分層）：(1) 機械生 harness/When/output-id/re-hydrate（不變+延伸）;(2) **§5/§6 transcription：把註解 stub 升級成 LIVE error-envelope**（#expect(throws: ContextError<X>){...}; #expect(error?.error==.code) 兩行真 code、error code 從 §5 轉錄），只留 arrange(Given-state)+input-mutation(Given-data-values) 為單一具名 TODO 洞;(3) **--fill-given 互動 elicitation**（mirror /domain-fill）。"
    - "保留兩檔分離 + skipped-not-green + .disabled+Issue.record。"
    - "可能加 /fixture-gen sibling skill（機械包 create/add UC 的 execute → fixture helper，unblock 多數 error Given-state）。"
---

# test-gen 重設計 — 真 test

## 議題定義

### 背景
現況 test-gen（Phase 1.s）只把 create-happy-path（~3%）生成 runnable test，其餘 97% 是 `.disabled` + 註解掉的 template —— user 認為「空殼、沒用」。workflow understand survey 證明:**deterministic/judgment 的界線比現況畫的細得多**。OC gold standard 顯示一個 error test 的 ~80% 行(harness / When / re-hydrate / `#expect(throws:)` envelope / **§5 error code**)是機械可導的;只有 ~20%(Given-state + Given-data-values)是 domain judgment。現況把整個 body 註解掉 = 過度悲觀。

### 目標
定出 test-gen 重設計:(1) §5/§6 transcription 的範圍與安全(把註解升級成 live code);(2) judgment 洞怎麼處理（honest TODO / --fill-given elicitation / 上游 enrich §6）;(3) /fixture-gen sibling 是否可行（fixture library 是 error Given 的硬上游）;(4) fake-green / test-theater 防護;(5) 兩檔分離 + scenario-id + provenance;(6) scope（usecase-layer;read-model lane defer）。

### 範圍
- 討論內:test-gen skill 重設計（transcription + honest-hole + 互動 + fixture 上游）+ 與既有 honest-hole 家族整合。
- 討論外:bundle schema 大改、Phase 4、KurrentDB infra 本身（採 OC 真 KDB 模型）、read-model test lane（defer）。

### 子議題
- [ ] C1：§5/§6 **transcription 範圍與安全** —— 把 error-envelope + error code 升級成 LIVE code（非註解）;§6 placeholder/中文標題 Given 怎麼辦（偵測 → 路由 honest TODO，不照抄）?哪些保持 disabled。
- [ ] C2：judgment 洞（Given-state + Given-data-values）—— honest TODO 洞 vs **--fill-given elicitation（mirror /domain-fill）** vs 上游 enrich §6（bundle-plan 讓 error Given 帶真值）?三者組合。
- [ ] C3：**/fixture-gen sibling** —— fixture library（SharedUtility/UsecaseCall createX helper）是所有 error/update Given 的硬上游。它可機械生（包 create/add UC 的 execute，signature-derived）嗎?還是純人寫?
- [ ] C4：fake-green / test-theater 防護 —— richer template 更接近「silent pass for wrong reason」（如未 arrange 卻 throws aggregateNotFound 而非目標 invariant）;怎麼守（.disabled+Issue.record + assert 具體 error code + context firewall 不讀 execute body）。
- [ ] C5：兩檔分離 + scenario stable id（D7）+ test-provenance.md（mirror domain-fill-provenance）。
- [ ] C6：scope —— usecase/application layer（不碰 aggregate-unit invariant test，arrange/act/assert 交織）;read-model lane defer。

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.8)

**總立場（依 understand survey）：test-gen 重設計 = type-closure 分層的三層 hybrid。核心是「把現況註解掉的 error-test body 升級成 LIVE 可編譯 code，error code 從 §5 轉錄，只留 Given-state + Given-data-values 兩個具名洞」—— 讓 test skeleton 跟 entity `#error` 一樣 honest-hole。判斷洞由 --fill-given（/domain-fill 的 test 版）elicit，絕不猜。**

- **C1（transcription）→ 升級註解為 LIVE code，但 placeholder/中文 Given 偵測路由 TODO 不照抄**。每個 §6 scenario（含 error）emit **真可編譯 body**：harness + When-triple + 對 error 用 `let error = await #expect(throws: ContextError<<A>Error>.self) { _ = try await usecase.execute(input: input) }; #expect(error?.error == .<§5 code>)`（**兩行真 code，error code 從 §5 表轉錄**，§5 是全 spec 最可機械轉錄的 test 事實）。**aggregate-not-found** test 全機械生（DDDError predicate + 不存在 id，無需 domain Given）→ 與 create-happy-path 同 fully-auto。**source-data honesty**：§6 happy Examples 是 placeholder（v-userId）、error Given 是未譯中文標題 → **偵測到 placeholder/title-verbatim → 路由 honest TODO 洞，不照抄**（lint，比照 bundle-plan placeholder marking）。

- **C2（judgment 洞）→ honest TODO + --fill-given elicitation;§6 上游 enrich 為輔**。兩個 judgment 洞（Given-state 叫哪些 fixture、Given-data-values 哪個值觸發 invariant）= test-layer 的 domain hole。預設留 **單一具名 TODO 在 LIVE body 內**（`// TODO(test-given): arrange + input value that trips .<code>`）+ test 保持 `.disabled`。**--fill-given**（mirror /domain-fill）：per-scenario AskUserQuestion 攤開 §6 Given（中文 invariant 標題）+ 可用 fixture helper signature + `<UC>Input` signature + `<A>Error` cases → 停等人 dictate「createProfile 然後 set status .resigned, input newJobTitle=manager」→ transcribe 成 arrange + input 值 → 移到 .authored.swift。**絕不猜哪個值觸發 invariant**（= provenance corruption）。無 dictation → 留 disabled。

- **C3（/fixture-gen）→ 可行且高價值，建議獨立 sibling skill**。fixture library（OC SharedUtility/UsecaseCall 的 `createAuditQuoting(...)` 薄包 `CreateAuditQuotingService(repository:).execute(...)`）是所有 error/update Given 的硬上游。**單步 fixture（包一個 create/add UC 的 execute）是 signature-derived 機械可生**（與 When-call 同型）→ `/fixture-gen` 可機械產 per-UC 的 `create<A>(...) / <verb>(...)` helper。**多步 chain（Codex 的 WithFilingMethodAdjustment）不機械生**（順序是 judgment）→ 留 --fill-given / 人。這 unblock 多數 error Given-state 的「呼叫前置 UC」那半（剩「哪些/順序/值」judgment）。

- **C4（fake-green 防護）→ 三層守**：(1) **disabled-until-filled**：任何含未填 Given-data-value TODO 的 test 保持 `@Test(.disabled)` + `Issue.record`（skipped-not-green，D6 不變且更 load-bearing）。(2) **assert 具體 error code**：§5 轉錄的 `error?.error == .<code>` 讓「wrong-reason throw」（如未 arrange 卻 aggregateNotFound）**斷言失敗而非 silent pass**。(3) **context firewall**（mirror domain-fill D5）：test-gen / --fill-given **只讀 signature + §5/§6 + fixture helper signature，絕不讀 execute() body 當 semantic source**（否則 test 變成 re-confirm impl 非 spec）。

- **C5（兩檔 + id + provenance）→ 全沿用 + 加 provenance**：兩檔分離不變（arrange/act/assert 交織，in-file marker 圍不住，Codex/Gemini 前證）;machine 永不覆寫 .authored.swift;--fill-given 填的 test 移到 .authored（不留 .generated，否則 regen 覆蓋）。scenario **stable id**（D7 open）對 --fill-given 的 move 更急 → 建議 bundle-plan 補 stable scenario id。--fill-given 寫 **test-provenance.md**（mirror domain-fill-provenance：scenario | 人 dictate arrange | 轉錄 Swift）供 reviewer 核 Given 源於人非捏造。

- **C6（scope）→ usecase/application layer;read-model lane defer**。Finding C：usecase-layer error test 比 aggregate-unit invariant test 可 scaffold（後者 arrange/act/assert 交織，過度承諾會重蹈 drift）。read-model/projector test lane（InMemoryReadModelStore）defer。

**Evidence**：workflow understand survey（本檔 fixed premises;OC AddTaxComplianceAuditUsecaseTests gold standard、§5/§6 能力、mechanizability map）;/domain-fill（transcription/firewall/provenance 模型）;domain-scaffold-emitter（#error honest-hole）;bundle-plan（§6 + placeholder marking）。

**待 Codex / Gemini R1（adversarial）**：transcription 安全?/fixture-gen 可靠?--fill-given 相對 plan-time 真有救?防護夠不夠?

#### R1 Adversarial 三方 critique（workflow `test-gen-redesign-debate`，3 lens 並行打破 + synthesize）

**Gemini（fake-green / maintainability lens）—— HIGH break：judgment-locus 被 R1 under-modeled。**
- OC 證據:error「觸發點」常**不在 arrange**:(A) input-value（單次 call 的壞欄位）/ (B) **act-sequence**（duplicate = execute 兩次,`AddTaxComplianceAuditUsecaseTests:63-86`,~14/45）/ (C) **prior-state**（先跑別的 UC,`RecordPredecessorAuditorInfo:92-123`）。R1 的「統一單次-execute live body + 一個 Given TODO」對 (B)(C) 是**謊言**,且比註解 stub 更逼真的 fake-green（body 讀起來完整,人只看到 Given TODO 看不到缺的 act-step）。
- **reframe：從「填 Given」改「classify judgment-locus → 每類選 body-shape」**。(A) live-ish thunk body;(B)(C) honest disabled stub,**shape 命名缺的 sequence/chain**。unknown → 預設 disabled stub（不 live）。
- C4(b) **blind to code-collision**:§5 是全 invariant 集,錯 arrange 可 throw 一個 code 撞上的真 ContextError → green 卻證明不了目標 invariant。fix:non-create UC 加 **positive-arrange precondition（#require aggregate 存在）** + --fill-given 記 **causal why**。
- C3 /fixture-gen「薄包」**假**:`createAuditQuoting` 寫死 `customerStatus:.established`/`organizationType:.limitedCompany`（judgment baseline,決定哪些 invariant 可達）;`addAccountingForX` 嵌 curated Set。fix:bare wrapper、**每參數必填、無 default judgment**、provenance header、signature 變則 fail-loud。
- firewall **拆兩職**:「不讀 execute body 當 spec」（留）vs「不跑 test」（**丟**）—— 一次真 localhost-KDB run 是抓「忠實轉錄但錯」dictation 的唯一 oracle,且不讀 source 不破 provenance。

**claudeImpl（feasibility lens）—— 3 個 HIGH：**
- **LIVE-compilable 假**:`AggregateRenderer:185` 對有 invariant 的 aggregate emit 編譯期 `#error` → SUT 在 /domain-fill 前不編譯 → transcribed body 不可能 live。reframe:**pre-staged,fill-state ladder**。
- **create-happy-path runtime fatalError**:`AggregateRenderer:226` derived-payload aggregate 的 convenience init fatalError（/domain-fill 不填）→ 有 derived field 時 happy-path 也得 disabled。
- **no-bundle 無 §5/§6 源**:`write-ddd-spec` 是 9 行 placeholder,只有 bundle-plan 產 §5/§6 → 無 §5 → fail-loud disabled。
- + §5 row vs enum case cardinality（seenCodes dedup）、precondition 無對應 enum case、cross-aggregate fixture 需第二 repository。
- **確認**:§5 errorCode→enum case **機械 by construction**（`AggregateRenderer:259` + bundle-plan §5 同欄位）。

**Codex（code-level lens，Swift 6.2.3 實測）—— 1 FATAL：**
- **`.disabled` body 仍 type-check（實證）**:R1 的「live body + 裸 TODO hole」**編不過**（`cannot find input in scope`）→ 破壞整個 target 含 green happy-path。fix（load-bearing）:洞 = **typed fatalError thunk** `let input: <UC>Input = { fatalError("GENESIS-TODO") }()`,body type-complete 但 disabled 不跑。
- error-test 形狀 `await #expect(throws: ContextError<<A>Error>.self){...}; #expect(error?.error == .case)` **編譯+執行通過,wrong-type/wrong-case 都 fail**（guard b 實證最強）。
- **aggregate-not-found 用不同 shape**:DDDError **非 Equatable**、throw raw DDDError 非 ContextError → 必須 predicate-closure `error.code == .aggregateNotFound`,**envelope 拆兩支**。
- output.id 是 `String?`、且有兩個 Output family（UseCaseOutput vs ApplicationServiceOutput）→ 只在 bound Output conform UseCaseOutput 時 assert,優先 re-hydrate。
- **Tag 要註冊**:`.tags(.auditQuoting)` 的 `auditQuoting` 是 `TestTag.swift` 的 static var,新 aggregate 未宣告 = 編譯錯 → emit Tag static var 或 fallback .serialized-only。

---

### Round 2 — Synthesis（Claude facilitator）

**R1 spine 存活（3-layer mechanizability split / regen-safe harness / disabled-not-green / 兩檔 / context firewall / --fill-given secretary / fixture-gen sibling），但 headline「LIVE code」被三個獨立驗證的 code 事實 REFRAME 成「pre-staged type-complete bodies on a fill-state ladder」。**

**Rejection log（HARD，皆 code-verified）**：
- ❌ **「§6 error stub 全變 LIVE compilable code」**:`AggregateRenderer:185 #error` → SUT pre-domain-fill 不編譯。改 **fill-state ladder（auto-green / green-after-domain-fill / green-after-fill-given）**。
- ❌ **「live body + 裸 Given TODO」**:`.disabled` body 仍 type-check（Codex 實測）→ 裸洞編不過、破壞整 target。改 **typed fatalError thunk**（C1-thunk，load-bearing）。
- ❌ **「judgment 洞 = 單一 arrange TODO」**:trip 常在 act-sequence（14/45）/ prior-state → 統一 single-execute body = 更逼真 fake-green。改 **judgment-locus classifier → 每類 body-shape**。
- ❌ **「guard(b) assert §5 code 足夠」**:§5 全 invariant 集,code-collision → green 證明不了。加 **positive-arrange precondition + causal-why provenance**。
- ❌ **「/fixture-gen 薄包」**:fixture helper 藏 baseline judgment。改 **bare wrapper、每參必填、fail-loud drift-guard**。
- ❌ **「aggregate-not-found 用 ContextError envelope」**:DDDError 非 Equatable 非 ContextError → envelope **拆兩支**。
- ❌ **「firewall = 不讀 + 不跑」**:拆兩職,**confirming KDB run 允許**（off-by-default flag）作 wrong-but-faithful dictation 的唯一 oracle。
- ❌ **「output.id == aggId 普遍」**:`String?` + 兩 Output family → 僅 UseCaseOutput-conform 時 assert,優先 re-hydrate。

**收斂決定（spec-ready，待 user 拍板 4 個 scope-edge）**：
1. **C1 fill-state ladder**：Tier-A auto-green = create-happy-path（**僅無 derived-payload field**）+ aggregate-not-found（DDDError predicate）;Tier-B pre-staged = input-value-locus §5 error（typed-thunk body,/domain-fill 清 #error + 人填 arrange 後 green）;Tier-C honest disabled stub = act-sequence + prior-state locus（shape 命名缺的 sequence/chain）。Phase-1 grep aggregate 的 #error/fatalError,有則全 body `.disabled`（首次 red build 不會 unattributable）。
2. **C1-thunk（load-bearing）**：未填洞 = **compilable typed fatalError thunk** `let input: <UC>Input = { fatalError("GENESIS-TODO: ...") }()`。INVARIANT（spec 斷言 + grep 驗）:.generated + .authored 必須**在每個 fill-state（0/部分/100%）都編譯**。
3. **C2 三路 routing**（judgment-locus classifier,驅動自 invariant.title/rule 提到 prior-state/repetition vs input-shape;**unknown → Tier-C disabled,絕不 live**）：input-value → Tier-B thunk + --fill-given 填 input mutation;act-sequence → Tier-C stub（N 次 execute 模板）;prior-state → Tier-C stub（ordered chain 模板）。**--fill-given 合約改為「dictate 整個 test（sequence+values+causal why）」**,secretary 非 advisor,AskUserQuestion-block,寫 .authored,無 dictation → disabled。enrich-§6 **out**（留 bundle-plan）。
4. **C2-param**：`@Test(arguments:)` parameterization **v1 defer** —— emit 單一代表 case + `// GENESIS-TODO: parameterize` marker,不靜默 under-cover。
5. **C3 /fixture-gen（sibling，narrowed）**：bare single-UC wrapper、**每參必填無 default**、provenance header、cross-aggregate emit shared-util static `create<A>(repository:)`、signature 變 fail-loud。curated preset + multi-step 留人/--fill-given。
6. **C4 guard stack（四層）**：(a) disabled-until-filled + C1-thunk（skipped-not-green AND 編譯）;(b) assert specific §5 code **envelope 拆兩支**（ContextError invariant vs DDDError predicate）+ **positive-arrange precondition**（non-create #require aggregate 存在）;(c) firewall 拆兩職（不讀 execute body 留 / 不跑 改 off-by-default flag）;(d) **Tag 註冊**（emit static var 或 fallback .serialized-only）。Non-goal 明寫:guard(a) 是 convention 非 binary-enforced（人手刪 .disabled 留空 body 會 silent pass）。
7. **C5 兩檔 + stable id + provenance**：machine 永不寫 .authored;reconcile **HARD 依賴 stable scenario id**（emit `// test-gen-scenario-id:`;bundle-plan 未出 id 前 --fill-given 禁改 func 名 + 帶 id placeholder）;id-keyed mutual-exclusion 防 redeclaration;**test-provenance.md 記 causal-why**（不只轉錄）。
8. **C6 scope**：usecase/application layer;read-model lane defer（**明寫 leaky boundary**:re-hydrate green 但 read-side projection 壞 = false confidence）;**localhost-KDB hard prerequisite**（明寫 DB-down vs arrange-wrong 歧義,不加 in-memory store, D9）。

---

## 共識看板（R2 後）

| # | 子議題 | Claude R1 | Codex | Gemini | claudeImpl | 狀態 |
|---|--------|-----------|-------|--------|-----------|------|
| C1 | transcription | LIVE code | FATAL: disabled 仍 type-check | reframe locus | #error SUT 不編譯 | **agreed**: fill-state ladder + thunk |
| C2 | judgment 洞 | 單一 Given TODO | — | 3 locus / 3 shape | — | **agreed**: locus classifier 三路 |
| C3 | /fixture-gen | 薄包可生 | 每參暴露 | 薄包假,藏 baseline | cross-agg 需第二 repo | **agreed**: bare 必填 + fail-loud |
| C4 | guard | 三層 | envelope 拆兩支 + Tag | guard(b) blind + firewall 拆 | — | **agreed**: 四層 + positive-arrange |
| C5 | 兩檔/id | 沿用+provenance | redeclaration | rename orphan | title collision | **agreed**: stable-id HARD + causal-why |
| C6 | scope | usecase + defer read | KDB serialized | read-model leaky | KDB 歧義 | **agreed**: defer + 明寫 boundary |
| C7* | firewall 拆兩職（不讀 vs 不跑）| 隱含不跑 | — | KDB run = 唯一 oracle | — | **agreed-pending-user**: off-by-default flag |

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | fill-state ladder（Tier-A auto-green / Tier-B pre-staged input-value / Tier-C honest disabled stub）取代 R1 flat-live;Phase-1 grep #error/fatalError 有則全 disabled | 2026-06-03 | R2 | AggregateRenderer:185/226 verified |
| D2 | 未填洞 = **typed fatalError thunk**;INVARIANT: .generated+.authored 每 fill-state 皆編譯 | 2026-06-03 | R2 | Codex Swift 6.2.3 實測 load-bearing |
| D3 | judgment-locus classifier 三路（input-value→Tier-B / act-sequence→Tier-C N-call / prior-state→Tier-C chain;unknown→Tier-C）| 2026-06-03 | R2 | Gemini reframe（14/45 act-seq）|
| D4 | error envelope **拆兩支**（ContextError invariant: error?.error==.case / DDDError infra: predicate error.code）| 2026-06-03 | R2 | DDDError 非 Equatable verified |
| D5 | guard stack 四層（disabled+thunk / specific-code 拆兩支 + positive-arrange #require / firewall 拆兩職 / Tag 註冊）| 2026-06-03 | R2 | code-collision + Tag compile break |
| D6 | --fill-given：transcription-only secretary,合約=「dictate 整 test（sequence+values+causal why）」,AskUserQuestion,寫 .authored,記 causal-why provenance | 2026-06-03 | R2 | mirror /domain-fill |
| D7 | /fixture-gen sibling: bare 必填無 default + provenance header + fail-loud drift-guard;preset/multi-step 留人 | 2026-06-03 | R2 | baseline judgment verified |
| D8 | 兩檔 + stable-id HARD reconcile（emit id-comment,pre-id 禁 rename）;scope usecase-layer + read-model defer（明寫 leaky）;localhost-KDB hard prereq（明寫歧義）| 2026-06-03 | R2 | |

---

## 開放問題（需 user 拍板 4 個 scope-edge，皆不阻架構）

1. **KDB-run verification oracle**：v1 是否 ship「confirming localhost-KDB run（throw 對上 §5 code 才 tag verified）」off-by-default flag,還是全 defer?（Gemini:抓 faithful-but-wrong dictation 的唯一 oracle;代價 = fill-time DB 依賴 + red-because-DB-down 歧義）。建議:ship flag, off-by-default。
2. **judgment-locus classifier 保守度**：unknown → Tier-C disabled stub（under-emit live = 安全）vs 冒險 emit live。建議:保守（under-emit）。
3. **/fixture-gen 打包**：獨立 `/fixture-gen` skill vs `/test-gen --fixtures` 子模式?（影響 skill registry + phase 編號）。
4. **bundle-plan stable scenario-id sequencing**：test-gen 先 ship（no-rename + id-placeholder workaround）+ 另案改 bundle-plan emit id,還是 block test-gen 等 bundle-plan id 先?

---

## 下次討論指引

### 進度摘要
**R2 consensus（adversarial workflow 3 lens + synth）。** R1 spine 存活但 headline「LIVE code」REFRAME 成「fill-state ladder + typed-thunk pre-staged bodies」（三個 code-verified 事實:#error SUT 不編譯 / .disabled 仍 type-check / DDDError 非 Equatable）。Gemini judgment-locus reframe（3 類 body-shape）防 act-sequence/prior-state 的 fake-green。spec-ready,待 user 拍 4 個 scope-edge。

### 待處理事項
user 答 4 開放問題 → write-spec（v1 scope 8 項 + Non-goals 明寫 boundary）→ audit-spec → impl。

### 閱讀建議
- 本檔 R2 + 決策 D1-D8 + 開放問題
- OC gold standard `AddTaxComplianceAuditUsecaseTests.swift`（:63-86 duplicate act-sequence;:226-247 aggregate-not-found DDDError predicate）
- `AggregateRenderer.swift:185/226/259`（#error / create fatalError / errorCode→case）;`TestTag.swift`（Tag 註冊）;`SharedUtility/UsecaseCall/AuditQuoting.swift`（fixture baseline judgment）
- /domain-fill SKILL.md（--fill-given mirror）

### 注意事項
**核心安全（強化版）**：(1) typed-thunk 讓 disabled body 編譯（每 fill-state 皆編譯是 INVARIANT）;(2) judgment-locus 決定 body-shape（act-sequence/prior-state 絕不 emit single-execute live body = fake-green）;(3) envelope 拆兩支（ContextError vs DDDError）;(4) 絕不猜哪個值觸發哪個 invariant。

---

## Round 3 — Post-Phase-1.y 再驗證（2026-06-04，adversarial workflow 3 lens + 實測 swiftc 6.2.3）

### 為何重開
R2 共識（上面）是 **Phase 1.y 實作之前** 拍板的。1.y 翻了 R2 的兩根地基：
1. **`#error` 編不過 → `GenesisTODO.notImplemented` 編得過**（runtime throw-marker）。R2 整個「fill-state ladder（編譯分層）」的理由消失。
2. **honesty 從 `@Test(.disabled)`+`Issue.record` → `genesis verify`**（1.y shipped），而 `VerifyChecker.enabledTestRegions` **明確排除 `.disabled`** → R2 要 emit 的 disabled stub 會讓 `genesis verify` **整批判定 uncovered → fail**。currently-shipped `test-gen/SKILL.md` 因此**已經對 1.y 壞掉**，flip 是 forced 非 optional。

### 提出的 reframe：「編譯分層 tier」→「runtime-red ladder」
所有 test 一律 **enabled 且編得過**；紅的方式兩種：
- **R-SUT 紅**：test 全填好、domain 未填 → `execute` 丟 GenesisTODO → `#expect(throws: ContextError<X>)` 失敗（乾淨紅）。
- **R-ARRANGE 紅**：test 有 judgment 洞 → typed throwing GenesisTODO thunk（D2 fatalError-thunk 的 enabled 版，改 throw 不 crash）→ 跑起來乾淨紅。`--fill-given` 轉錄人口述 → R-ARRANGE → R-SUT → 綠。

### 裁決：**reframe HOLDS，但有 3 個強制 honesty fix**（adversarial 抓出，皆實測）

| Fix | all-enabled flip 開的洞 | 修法 |
|---|---|---|
| **FIX-1** | `VerifyChecker.referencesCode` 非 string-literal-aware（VerifyChecker.swift:104 自承）→ thunk TODO 字串裡的 `.code` token **無 live assertion 也算 covered**。pure-thunk test 假性滿足 verify。實測 `vc_probe.swift` CASE2/3/4 covered=true。 | thunk 訊息**禁含字面 `.code`**（用非點形式 "trips duplicateFoo"）；**emit 真的 enabled `#expect(error?.error == .code)`**；`referencesCode` 比對前**剝除字串字面**（比照既有 comment-strip）。 |
| **FIX-2** | `genesis verify` marker 只掃 **Sources/**（VerifyChecker.swift:34）。enabled-red 把洞搬進 **Tests/** → 一個 100% 未填 Given 的 suite **能通過 verify**。 | 擴 VerifyChecker 掃 Tests/ enabled `@Test` 段內非註解的 `genesisTODO(` / `GenesisTODO.notImplemented` thunk → 新增 `remainingTestHoles` 類別，fail gate。 |
| **FIX-3** | act-sequence 錯誤（duplicate = execute **兩次**）若 emit 成 single-execute body，在 enabled-red 下是**更逼真的謊**（編得過、跑得動、甚至會紅）。 | judgment thunk 對 act-sequence/prior-state 必須 **sequence-shaped**（兩個 execute、第二個包 `#expect(throws:)`，內值留 thunk），半填可結構性看見。 |

### 實測確認（swiftc 6.2.3 + 真 SwiftPM Testing target，3 lens 一致）
- **載重 switch**：`let input: X = try genesisTODO("…")`（throwing thunk）**編得過且乾淨紅**（不 crash）；`fatalError` thunk 在 enabled test **SIGABRT exit 133 殺整 runner** → `fatalError → throwing-GenesisTODO` 強制。
- bare `throw` + 後面引用未宣告符號 → `cannot find input in scope`（Codex 舊發現存活）→ 洞**必須是 typed value**。
- `#expect(throws: ContextError<X>.self)` 收 GenesisTODO → 乾淨紅（真 Testing target 驗）。
- `package GenesisTODO` 對同 package test target 可見 ✓。derived-payload create-happy 現在 enabled-red（catch-ladder 把 GenesisTODO 原樣傳出）✓。
- DDDError value-capture（form a `#expect(throws: DDDError.self)` + `error?.code ==`）**無需 Equatable** ✓ → D4 簡化。
- 未宣告 `@Tag` → 整 target 編不過 → tag-decl emission 強制（D5d 更嚴，無 .disabled 吸收）。

### D-decision 處置（R2 → Round 3）
| D | 處置 | 為何 |
|---|---|---|
| D1 fill-state ladder | **DROPPED** | 編譯分層前提消失（GenesisTODO 全編得過）；改 2-lane runtime-red |
| D2 typed thunk | **REFRAMED** | typed-value invariant 存活；fatalError → throwing-GenesisTODO（強制，否則 crash 整 suite）|
| D3 locus classifier | **REFRAMED** | 3-template picker → 2-way emit（mechanical full body / judgment envelope+thunk）；locus 只剩 thunk-shape（FIX-3）+ hint string |
| D4 envelope split | **REFRAMED** | 語意兩分支存活；丟「DDDError 強制 predicate-closure」；統一 value-capture 模板 (type, member-path, case) |
| D5 guard stack | **REFRAMED** | (a) disabled→丟，改 throwing-thunk + verify Tests-hole gate(FIX-2)；(b)(c)(d) 存活；+ FIX-1 補回「弱化 test 被抓」的警報（取代失去的 Issue.record trap）|
| D6 --fill-given | **REFRAMED** | 秘書合約存活；+「轉錄後 test 預期 R-SUT 紅非綠」；+ act-sequence 連 sequence 一起 dictate（FIX-3）|
| D7 /fixture-gen | **SURVIVES** | bare-wrapper/每參必填 code-confirmed（OC fixture 預設值藏 judgment）；v1 defer，獨立 sibling |
| D8 兩檔/scope/KDB | **SURVIVES** | 兩檔分離(A/A/A 交織，in-file marker 不夠)；usecase-layer；KDB hard prereq；scenario-id 稍更 load-bearing |

### 2-lane 模型（spec-ready）
- **Lane A MECHANICAL**：create-happy（含 derived-payload）+ aggregate-not-found → full enabled body → 1-stage 紅（R-SUT）→ 綠。例外：no-derived create-happy 立即綠（mechanical init + no-op ensureInvariant）→ create-time invariant 由它自己的 Lane-B error test 擔，不由 happy path 抵。
- **Lane B JUDGMENT**：input-value / act-sequence / prior-state → assertion envelope + typed-throwing-thunk 洞 → 2-stage 紅（R-ARRANGE → fill-given → R-SUT）→ 綠。
- **兩個正交 gate**：`genesis verify` =「每 invariant 有 enabled test 以 **live assertion** 引用其 code」（FIX-1/2 後）；`swift test` =「domain+Given 填了」（只有 localhost KDB up 才有診斷力）。green-verify + red-test 是 test-gen 後、domain-fill 前的**正常**狀態。

### user 拍板（2026-06-04）
- **Q4（ship 策略）→ 現在就 ship v1**（title-based reconcile + `// test-gen-scenario-id:` placeholder；不 block 在 bundle-plan emit stable id）。
- **Q1（KDB oracle）→ v1 defer**（靠 --fill-given causal-why provenance + 人審；oracle 在 test 能轉綠前無訊號；revisit 為 post-domain-fill gate）。
- **Q3（/fixture-gen 打包）→ 延後決定**（v1 不做 fixture-gen；等真要做時再決定 standalone vs --fixtures submode）。
- **Q2（locus 保守度）→ moot**：無 .disabled tier，保守 = 「unknown/judgment → thunk 洞，絕不 fabricated body」，已是 forced spec invariant，非 user posture。

### 下一步
write-spec（Phase 1.z，`docs/tasks/2026-06-04-phase-1z-test-gen-enabled-red.md`）→ audit-spec（adversarial workflow）→ impl。spec_ready = true。
