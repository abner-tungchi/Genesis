---
topic: "TDD-first honest-hole：domain 洞 #error → 會編譯的 test-red marker;Phase 1.u/1.u.1/test-gen 的 TDD-coherent 重整"
status: consensus
created: "2026-06-03"
participants: [Claude (Opus 4.8), Codex (GPT-5.4), Gemini]
facilitator: Claude
rounds_completed: 2
mode: default
premises:
  fixed:
    - "user 確認開發模式 = 純 TDD（test-first，一個 feature 一個 feature 測）：寫 test → 跑出 meaningful red（assertion 失敗）→ 實作 → green。"
    - "#error 機制（verified）：編譯期 directive，aggregate module 編不過 → test target 編不過 → swift test 的 build 階段就掛，0 個 test 跑得起來。且 unconditional：任一洞沒填 → 整 module 編不過 → 要全部 domain 填完才有任何 test 能跑。直接消滅增量 TDD red-green。"
    - "DDDKit apply(event:) 順序：ensureInvariant()[pre] → when(happened:) → ensureInvariant()[post] → add(domainEvent:)。ensureInvariant 每次 apply 前後各跑一次。"
    - "OC fixture 模型：Given 靠呼叫真前置 usecase（createX → execute → apply 事件）seed state；create 走 rehydration init（不經 when）；後續事件經 when。"
    - "被反轉/影響的既有決定：domain-scaffold-emitter D2（#error over fatalError）、Phase 1.u（domain 洞 = #error）、Phase 1.u.1（genesis new tolerate-#error rollback + BuildFailureClassifier）、test-gen R2（fill-state ladder / disabled-until-filled，建在 #error + impl-first 上）。"
    - "honest-hole『信號位置』隨開發模式移動：no-test 世界 gate = swift build green → #error（編譯期擋）;TDD 世界 gate = swift test green → 會編譯的 test-red stub（test 紅就是 honest 信號）。"
  proposed:
    - "domain 洞改『會編譯、跑了丟獨特標記 error』的 throw-marker（GenesisTODO.notImplemented），讓 fresh gen 編得過、test 跑得起來、紅在對的 test。"
    - "ensureInvariant 例外：因每次 apply 跑、throw 會讓 fixture seed 不起來 → 必須 no-op（pass），revert 回 Phase 1.t D4;invariant 的紅由測 invariant 的 test 給。"
    - "Phase 1.u.1 的 BuildFailureClassifier 變 dead code（fresh gen 不再有 #error）→ 移除/簡化;test-gen R2 從 disabled-until-filled 改 enabled-and-red。"
---

# TDD-first honest-hole

## 議題定義

### 背景
user 確認開發模式是純 TDD（test-first，逐 feature）。但 Phase 1.u 把 domain 洞做成 `#error`（編譯期擋）—— 這讓「整專案編不過、要全部 domain 填完才有任何 test 能跑」,直接消滅 TDD 的增量 red-green。所以 `#error` 在 TDD 下行不通,domain 洞要改成「**會編譯、但跑了讓對應 test 紅**」的表示。這反轉 domain-scaffold-emitter D2 / Phase 1.u,並連動 1.u.1 與 test-gen R2 —— 三塊耦合,要一起變成 TDD-coherent。

### 目標
(1) 每種 domain 洞（command body / 非-strict-safe when / ensureInvariant / create-init）在 apply() 路徑上的 throw-safety,各該用 throw-marker 還是 no-op;(2) GenesisTODO marker 型別設計（不與 error-test 的 ContextError 期望衝突）;(3) Phase 1.u.1 BuildFailureClassifier 怎麼處理;(4) test-gen R2 的 TDD 重整（disabled→enabled-red,fill-state ladder 還適用嗎,--fill-given/fixture-gen 在 TDD 下的角色）;(5) throw-marker 有沒有把 #error 本來擋的 dishonesty/fake-green 放回來;(6) Genesis 是 TDD-only 還是要支援 build-gate + test-gate 雙模式。

### 子議題
- [ ] C1：per-hole throw-safety —— command / when / ensureInvariant / create-init,各 throw-marker vs no-op?（apply pre/post ensureInvariant + replay/seed cascade）
- [ ] C2：GenesisTODO marker 型別（位置 / 不與 `#expect(throws: ContextError<X>)` 衝突 / greppable）
- [ ] C3：Phase 1.u.1 BuildFailureClassifier + NewCommand rollback —— 移除 / 簡化 / 重定位?
- [ ] C4：test-gen R2 TDD 重整 —— enabled-and-red vs disabled-until-filled;fill-state ladder / --fill-given / fixture-gen 在 TDD 下還對嗎?
- [ ] C5：fake-green 回歸風險 —— no-op ensureInvariant 在「無對應 test」時 silent-pass?throw-marker 像實作但不是?
- [ ] C6：TDD-only vs 雙模式（build-gate #error + test-gate marker）—— Genesis 立場 + 維護成本。

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.8)

**總立場：domain 洞改 throw-marker（會編譯 + test-red），但 ensureInvariant 例外必須 no-op（apply 每次跑、throw 會炸 fixture seed）。honest-hole 信號從 build-gate（#error）移到 test-gate（test 紅）。三塊（1.u 洞 / 1.u.1 rollback / test-gen R2）一起變 TDD-coherent。關鍵約束：test-gate 只有在『每個洞都有對應的紅 test』時才 honest → test-gen 必須對每個 invariant/UC 產紅 test,否則 no-op 洞會 silent-pass。**

- **C1（per-hole throw-safety）→ 依在 apply() 路徑上的位置決定**：
  - **ensureInvariant（有 declared invariant）→ no-op（NOT throw）**。它每次 apply 前後跑;throw → 連 createX fixture 的 apply 都失敗 → 該 aggregate 全 test 紅在 seed 而非 assertion。**revert 回 Phase 1.t D4 的 no-op + 註解**。invariant 的紅由「測該 invariant 的 test」給（state 壞了卻沒被擋 → test 紅）。
  - **command body → throw-marker OK**。command 在 usecase-call（When）跑,不在 replay 路徑。throw → 只影響呼叫它的 test（+ 用該 command 當 fixture 的 test）。
  - **非-strict-safe when → throw-marker OK（但有 cascade）**。when(E) 在 apply(E) 跑。throw → 任何 apply E 的地方紅（測該 UC 的 test = 對的紅;用 E 當 Given 的別 test = 連帶紅,但 TDD bottom-up 可接受;create 事件走 init 不經 when → create fixture 不受影響）。
  - **create convenience init（derived field）→ throw-marker（取代 Phase 1.t.1 的 fatalError）**。init 已是 `throws`;fatalError 會 crash 整個 test process（比 #error 更不適合 TDD）。
  - 原則:**在 replay/seed 路徑上、且會擋住 fixture 的 → no-op（只有 ensureInvariant）;只影響「測它自己的 test」的 → throw-marker**。

- **C2（marker 型別）→ `{Context}Shared` emit `package enum GenesisTODO: Error { case notImplemented(String) }`**。distinctive（非 domain error）、greppable。**不與 error-test 衝突**:error-test 用 `#expect(throws: ContextError<<A>Error>.self)`,收到 `GenesisTODO`（不同型別）→ throws-match 失敗 → test 紅（正確:該 error 邏輯還沒實作）。happy test 收到意外 throw → 紅。

- **C3（1.u.1）→ BuildFailureClassifier 變 dead code,移除;NewCommand build 回到「失敗即 rollback」單純版**。fresh gen 改 throw-marker 後**編得過** → `genesis new` build green、不 rollback（genesis new 不跑 test）。tolerate-#error 的整套（BuildFailureClassifier + domainHolesRemain 分支）無 #error 可容忍 → 移除,回到 Phase 1.e 的「resolve+build 失敗即 rollback」。

- **C4（test-gen R2 TDD 重整）→ disabled-until-filled 改 enabled-and-red;ladder 重新詮釋**：
  - TDD 下 test 一開始就 **enabled 且紅**（domain throw marker → 紅）,不是 disabled。
  - **error test 的 arrange（Given）= 人寫 test 時就要寫的東西**（TDD test-first）—— 不是 test-gen 事後 elicit,而是「test-gen 產機械骨架 + 人 TDD 寫 test 時填 arrange」。--fill-given 從「事後填洞」變「協助你 TDD 寫 test 的互動」（同 transcription 模型,只是時機在 impl 之前）。
  - fill-state ladder 仍有意義但語意變:Tier-A（create-happy / not-found）= enabled,實作後綠;Tier-B/C = enabled-red,人補 arrange + 你實作後綠。
  - **judgment-locus 分類、envelope 拆兩支、typed-thunk → 重新評估**:typed-thunk（為了 disabled body 編譯）在 TDD-enabled 下還需要嗎?（enabled red test 的 input 要嘛人寫、要嘛...）—— 這塊要 R2 細想。
  - **關鍵新約束**:test-gate honest 的前提是「每個 declared invariant / error case 都有一個紅 test」。no-op ensureInvariant 若無對應 test = silent-pass。所以 **test-gen 必須對每個 §3 invariant / §5 error 產一個 test**（紅到 ensureInvariant 實作）—— 這是 no-op ensureInvariant 的 honesty 配套。

- **C5（fake-green 回歸）→ 信號移到 test-gate,所以 honesty = 「洞有對應紅 test」**：
  - no-op ensureInvariant **無對應 test 時確實 silent-pass** → 配套 = test-gen 強制產 invariant test（C4）。
  - throw-marker「像實作但不是」→ 但它**丟獨特 error、greppable、且任何斷真實行為的 test 都紅** → 不會 fake-green。比 no-op body 誠實（no-op 可能矇混過只測 output.id 的 test）。
  - 殘留風險:人手實作了一半（compiles + 過了部分 test）—— 這是 TDD 本來就靠「test 覆蓋夠不夠」守的,非洞表示能解。

- **C6（TDD-only vs 雙模式）→ 傾向 TDD-only（throw-marker），不維護雙模式**。雙模式（#error build-gate + marker test-gate 二選一）增維護成本 + 兩套 codegen 分支。user 確認 TDD → 單一 throw-marker 模式。但保留討論:有人不寫 test 時,throw-marker 專案 build green 但 runtime 炸 —— 這是否可接受（vs #error 擋）?（傾向:可接受,因為「不寫 test 又要保證」本來就無解;throw-marker + greppable 已是合理底線。）

**Evidence**：apply() pre/post ensureInvariant（DDDKit verified）;#error 編譯期阻斷（verified）;OC fixture seed via createX → apply;Phase 1.t D4（ensureInvariant no-op 原版）/ 1.t.1（create init fatalError）/ 1.u（#error）/ 1.u.1（BuildFailureClassifier）/ test-gen R2。

**待 Codex / Gemini R1（adversarial）**：catch 吞 marker?cascade?backstop 夠?雙模式?

#### R1 Adversarial 三方 critique（workflow `tdd-honest-hole-debate`，3 lens + synth;兩載重事實 Claude 親驗）

**Codex（code-level）—— 確認預測的 break + 一個無法驗的**：
- **FATAL→required-fix（confirmed）**:command/when 丟的 GenesisTODO 會被 usecase catch-ladder 最後的 `catch { throw DDDError.executeUsecaseFailed }` **包成 DDDError**（OC `AddTaxComplianceAuditUsecase:48-49` + Genesis 生成的 `UseCaseRenderer:160` 同形;原 error 埋在 userInfos）→ test 收到的是 DDDError 不是 GenesisTODO → 紅但是 incidental wrong-type,跟真失敗無法區分。**但 catch-ladder 是 Genesis 生成的 code → 在 catch-all 前插 `catch let e as GenesisTODO { throw e }` 即修** → 降為 required same-PR change,非 design-killer。
- **create-init = seed-path blocker**:fixture 經 createX seed → 該 init 的 marker 讓**每個 downstream test 紅在 seed 而非 assertion**（= R1 要消滅的 all-or-nothing collateral）。keep marker（勝 fatalError crash）但 rationale 改「seed-path 洞,紅 create-fixture-dependent test = 誠實的 derivation-unimplemented 信號」。
- **stress-a 無法驗**（sandbox 擋 swift)。→ **Claude 親驗:HOLDS**(見下)。

**Gemini（honesty / 10-month）—— 兩個 HIGH**：
- **C5 backstop 是循環論證**:R1 說 no-op ensureInvariant 由「test-gen 產紅 invariant test」backstop。但 test-gen 自己 R2 說「哪個 state 觸發 invariant」是 test-gen **無法合成**的 human judgment → 自動產的 invariant test 是 **disabled stub(永不變紅)** → no-op silent-pass → **比 #error 更糟**(#error 至少拒編譯)。fix:別靠 test-gen 合成,加**結構性 `genesis verify` lint**(grep marker + 斷言每個 declared invariant errorCode 有 ≥1 個 enabled test 引用它)—— 非循環,只查「enabled test 存在」這個結構事實。
- **build-gate 做了兩件事**:#error 同時 (1) 擋增量 TDD(壞,移除)+ (2) 保證未填 domain 不進可 ship artifact(好,**保留,移出 compiler**)。R1 兩個都丟了。fix:marker 編得過(TDD 活)+ `genesis verify` release-gate 擋 ship(非 TDD 的 presence-net 救回)。CLAUDE.md.template:3「will NOT compile until filled」變謊言,要改。

**claudeImpl（ripple/feasibility）—— make-or-break seam**：
- **GenesisTODO 放哪是 make-or-break**:`{SharedImport}` 是**條件式**(只在有 DTO/customType 時 emit)→ no-DTO bundle 的 aggregate 沒 import → {Ctx}Shared 的 GenesisTODO **找不到 → 編不過 → 0 test**(正是要殺的失敗)。→ 改 **per-aggregate 檔**(放 aggregate target,免 cross-import)。
- domain-fill SKILL.md **整個 grep-coupled 到 `#error`** → 要全改 grep GenesisTODO + 反轉 version-aware(#error→legacy-warn / GenesisTODO→current)。test-gen SKILL.md ship `.disabled` stub → 要 flip enabled-red。CLAUDE.md.template:3 要改。BuildFailureClassifier 移除 churn(2 檔 + NewCommand 3 區 + env-gated test 反轉)。

---

### Round 2 — Synthesis（Claude facilitator;兩載重事實親驗）

**R1 方向對、scheme sound、無 design-killer。但它不是「換個 marker」—— 是一個橫跨 renderer + skills + 新 `genesis verify` 的 ATOMIC migration,且 test-gen rewrite + genesis verify 是 HARD same-change 前置(否則 no-op ensureInvariant 比 #error 更糟,silent fake-green)。**

**兩載重事實(Claude 親自實測,非靠 agent 聲稱)**：
- ✅ **Swift Testing wrong-type → 乾淨紅**:`#expect(throws: RealError.self)` 收到 GenesisTODO → `expected error of type RealError, but notImplemented(...) of type GenesisTODO was thrown instead`;value-capture `e?.error` 為 nil 也紅;correct-type 綠。**前提是 marker 型別活著到 test**（→ C2 catch-ladder fix）。
- ✅ **catch-ladder 包 marker**:Phase 1.x 的 catchLadder 末支 `catch { throw DDDError.executeUsecaseFailed }` 會吞 GenesisTODO → 必須加 `catch let e as GenesisTODO { throw e }`。

**Rejection log（HARD）**：
- ❌ **「catch-ladder 吞 marker 是 FATAL」**:非 fatal —— ladder 是 Genesis 生成,插一支 rethrow 即修(required same-PR)。
- ❌ **「create-init marker 只影響自己的 test」**:是 seed-path 洞,reclassify(keep marker,改 rationale)。
- ❌ **「test-gen 產的 invariant test 就是 backstop」**:循環(test-gen 合成不出 invariant-tripping state → disabled stub 永不紅)。改 **genesis verify 結構 lint**(查 enabled test 存在,非靠 test 內容)。
- ❌ **「honest-hole 只是 relocated build→test-gate」**:是 **relocated-and-WEAKENED + release-gated**（test 要 存在+正確+有跑;#error 三者都不需要）。spec 要誠實寫成「刻意換取 TDD 的 conditional trade」。
- ❌ **「build-green-runtime-throw 可接受(C6)」**:#error 的 **presence-guarantee**(免費保證未填不 ship)被丟掉。改 genesis verify release-gate 救回。
- ❌ **「GenesisTODO 放 {Context}Shared」**:條件式 import 對 no-DTO bundle 會編不過 → 改 per-aggregate 檔。
- ❌ **「BuildFailureClassifier 獨立移除」**:必須是 migration 最後一步(全 #error site 遷完 + 綠 build regression test 後)。

**收斂決定（spec-ready）**：
1. **C1 per-position（re-axis 在 catch-ladder 邊界）**:ensureInvariant → **no-op**(forced,DDDKit pre/post-every-apply,throw 炸 create-init seed);command / 非-strict when / create-init → **throw-marker**(皆在 catch-ladder 下游 → 需 C2 fix)。create-init reclassified seed-path（keep marker 勝 fatalError crash）。
2. **C2 marker + transparent channel**:GenesisTODO **per-aggregate 檔**(aggregate target,免 cross-import;`package enum GenesisTODO: Error, Sendable { case notImplemented(String) }`)+ **catch-ladder 插 `catch let e as GenesisTODO { throw e }`**(載重 fix,marker 型別才活到 test)。
3. **C3 移除 BuildFailureClassifier = migration 最後一步**(全 churn:2 檔 + NewCommand 3 區 → unconditional swiftBuildFailed + 反轉 env-gated test 斷言成 green build)。
4. **C4 test-gen rewrite = HARD same-change 前置**:invariant/error backstop lane emit **enabled 紅 test**(`#expect(throws: ContextError<<A>Error>.self)` vs GenesisTODO → 紅);每 §3 invariant / §5 error 一個 enabled 紅 test;窄 disabled lane 只留「無法合成的 multi-step Given」(honest「blocked: prerequisite unfilled」);**typed-thunk 存活但 arrange-placeholder 改丟 GenesisTODO 非 fatalError**(enabled test 跑到 fatalError 會 crash 整 suite)。
5. **C5 backstop = 兩部分契約**:(1) test-gen 產 enabled 紅 test;(2) **新 `genesis verify`**(grep 任何 GenesisTODO marker + 每 declared invariant errorCode 有 ≥1 enabled test 引用)。非循環(查結構,非合成)。明寫:no-op ensureInvariant 只在 genesis verify gate 時 honest。
6. **C6 single codegen mode + genesis verify release-gate**:不維護雙 codegen 分支;presence-net 由 genesis verify(release/CI gate,非 build gate)救回。CLAUDE.md.template:3 改成 verify/release framing。

---

## 共識看板（R2 後）

| # | 子議題 | Claude R1 | Codex | Gemini | claudeImpl | 狀態 |
|---|--------|-----------|-------|--------|-----------|------|
| C1 | per-hole throw-safety | apply-position | catch-ladder 邊界才是軸 | ensureInvariant no-op forced | 4 site 可定位 | **agreed**: ensureInvariant no-op / 其餘 marker |
| C2 | marker + 傳遞 | {Ctx}Shared | catch 吞 marker → rethrow | — | 條件 import 破 → per-agg 檔 | **agreed**: per-agg 檔 + catch rethrow |
| C3 | 移 BuildFailureClassifier | dead code | 最後一步 | sequencing | full churn | **agreed**: 最後步 + 反轉 e2e |
| C4 | test-gen TDD | enabled-red | 同 PR 硬前置 | — | deployed SKILL 是 disabled | **agreed**: enabled-red,thunk 改 throw |
| C5 | backstop | test-gen 產 test | disabled 永不紅 | **循環** → genesis verify | — | **agreed**: 兩部分(test + verify lint) |
| C6 | 模式 | TDD-only | — | build-gate 兩職要拆 | CLAUDE.md 謊言 | **agreed**: single codegen + verify release-gate |

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 | 備註 |
|---|------|---------|------|------|
| D1 | ensureInvariant → no-op（forced）;command / 非-strict when / create-init → throw-marker（皆在 catch-ladder 下游）| 2026-06-03 | R2 | create-init reclassified seed-path |
| D2 | GenesisTODO = per-aggregate 檔（aggregate target,免 cross-import）`package enum ...: Error, Sendable`;catch-ladder 插 `catch let e as GenesisTODO { throw e }`（載重）| 2026-06-03 | R2 | 條件 import 對 no-DTO bundle 會破 |
| D3 | Swift Testing wrong-type → 乾淨紅（Claude 親驗 Swift 6.x）;前提 marker 型別活到 test | 2026-06-03 | R2 | empirical |
| D4 | test-gen rewrite = HARD same-change:enabled 紅 test/invariant/error backstop lane;窄 disabled lane(無法合成 Given);thunk 改丟 GenesisTODO | 2026-06-03 | R2 | disabled 永不紅 → 不能當 backstop |
| D5 | backstop 兩部分:test-gen enabled 紅 test + 新 `genesis verify`(grep marker + 每 invariant 有 ≥1 enabled test)| 2026-06-03 | R2 | 破循環(查結構非合成)|
| D6 | single codegen mode;genesis verify = release/CI gate(非 build gate)救回 presence-net;CLAUDE.md.template:3 改 | 2026-06-03 | R2 | honest-hole 信號 relocated-and-WEAKENED,刻意 trade |

---

## 開放問題（5 個 scope-edge,Claude 提預設,待 user 確認）

1. **genesis verify 形式/接線**:CLI subcommand vs SwiftPM build-plugin vs CI script。**唯一真需 user 決的**(決定 presence-net 是 load-bearing 還是 advisory)。預設:CLI `genesis verify` + 你接 CI required-check。
2. **adapter/presenter fatalError（5 site,domain 層外,仍 crash test process）**:v1 一起改 marker vs defer。預設:**defer + 文件標**(不在 domain test 紅路徑,擴 blast radius)。
3. **in-flight 專案 migration**:既有 #error 專案。預設:**regenerate-from-scratch**(IAMContext 是 dogfood,可重生;不做 #error→marker 一次性 rewrite)。
4. **precondition/enum-cardinality gap**:precondition 丟的 ContextError case 不在生成的 `<A>Error`(只從 invariant 生)→ 無 enum case 可正向斷言。預設:**v1 接受 precondition 洞只有 marker-red 無 positive-assertion backstop**(文件標)。
5. **KurrentDB 紅的歧義**(hole-unfilled vs DB-down vs arrange-wrong):預設 **v1 接受 noise + 文件標**(你已說 test 本來就要 local KDB)。

---

## ordered change-list（spec 用）

STEP 0 ✅ 載重事實親驗（wrong-type 紅 + catch-ladder 吞）。STEP 1 declare GenesisTODO per-aggregate 檔（role + manifest + scaffold-once）。STEP 2 catch-ladder rethrow（載重）。STEP 3 遷 3 domain #error site（command/when → marker;ensureInvariant → no-op）。STEP 4 create-init fatalError → marker。STEP 5 新 `genesis verify`（marker grep + invariant-enabled-test 斷言）。STEP 6 test-gen SKILL.md rewrite（enabled 紅）。STEP 7 regression test（有 invariant 的 bundle 生出來 swift build EXIT 0）。STEP 8（最後）移 BuildFailureClassifier + 反轉 e2e。STEP 9 docs sync（CLAUDE.md.template + domain-fill SKILL.md grep 反轉）。

## 下次討論指引

### 進度摘要
**R2 consensus（adversarial workflow 3 lens + Claude 親驗 2 載重事實）。** R1 throw-marker 方向對、無 design-killer,但是橫跨 renderer+skills+新 genesis verify 的 ATOMIC migration;test-gen rewrite + genesis verify 是 HARD same-change 前置。核心矯正:(1) catch-ladder 吞 marker → 插 rethrow;(2) backstop 循環 → genesis verify 結構 lint;(3) build-gate 兩職拆(marker 編譯 + verify release-gate)。待 user 確認 5 scope-edge → write-spec。

### 待處理事項
user 確認 5 開放問題(多數有預設)→ write-spec(ordered change-list 9 步)→ audit-spec → impl。**反轉 Phase 1.u（#error）+ 1.u.1（BuildFailureClassifier）**。

### 閱讀建議
- 本檔 R2 + 決策 + ordered change-list
- Phase 1.u（#error site:CommandExtension.template / UseCaseRenderer buildWhenBody / AggregateRenderer ensureInvariant）/ 1.t.1（create init）/ 1.u.1（BuildFailureClassifier + NewCommand）
- test-gen R2 討論（要 TDD 重整）;domain-fill SKILL.md（grep-coupled #error）;CLAUDE.md.template:3

### 注意事項
honest-hole 信號 build-gate → release-gate(genesis verify)+ test-gate,是**刻意的 conditional trade**(換 TDD)。no-op ensureInvariant 只在 genesis verify 把關時 honest。這是 atomic migration,test-gen + genesis verify 不可後補。
