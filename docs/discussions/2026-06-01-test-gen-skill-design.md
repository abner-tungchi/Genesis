---
topic: "Genesis test-gen skill 設計：§6 Gherkin → Swift 測試，不被 impl 綁架"
status: consensus
created: "2026-06-01"
updated: "2026-06-01"
participants:
  - Claude (Opus 4.8)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 3
mode: explore
premises:
  fixed: []
  proposed: []
meta_note: |
  --explore mode：user 對 framing 也不確定，讓三方各自 propose framing，不預設前提。
  user 唯一給的方向訊號：「test 不該被 impl 綁架」是核心直覺、「test 正確性 certainty 在 human、bundle 只 glimpse」是觀察。但這些在 explore mode 下視為「值得 stress-test 的 framing」，非 fixed premise。
---

# Genesis test-gen skill 設計：§6 Gherkin → Swift 測試，不被 impl 綁架

## 議題定義

### 背景

Genesis 從 Cosmogony Event Storming bundle codegen 出 DDD/ES Swift 專案，後續 per-feature 開發靠 fill skill 補 execute body：
- `/usecase`：填 domain Usecase `execute()` body（**code-driven**，從 generated code 結構推，套 Create/Update/Delete pattern；不讀 task spec）
- `/api`：填 adapter ApplicationService / ApiHandler body（code-driven + openapi.yaml）

`/bundle-plan`（Phase 1.r）把 bundle 拆成 per-UC task spec MD：
- §1/§2/§3/§7 機械填
- §5 error cases 機械（aggregate-wide invariants，per OC `ensureInvariant()` model）
- §6 Gherkin Scenarios 由 LLM 推 + **human 在 plan 階段經 method-X 逐 UC 確認**

**缺口**：目前**沒有任何 skill 把 §6 Gherkin 變成可跑的 Swift test code**。task spec 的 runbook 寫 `run swift test`，但沒人「寫」那些 test。§6 是 human-confirmed 的 intended behavior，卻沒被機械消費。

### 目標

定出 **test-gen skill** 的設計決策：要不要獨立、source of truth、certainty gate、TDD ordering、測試層級、Gherkin→Swift 機制。

### 範圍

- **討論內**：test-gen skill 該怎麼設計（上述 6 個子議題 C1-C6）。
- **討論外**：bundle-plan / fill skill 既有行為不重設計（除非 test-gen 強迫修改其中一個）；Cosmogony bundle schema 不動；runner / orchestrator（誰派 task spec 工）是另一議題。

### 約束（explore mode — 以下視為 proposed，非 fixed）

- user 直覺：test 不該被 impl 綁架（同一寫 impl 的東西寫 test → test 傾向確認 impl 而非驗證 intended）。
- user 觀察：test 正確性 certainty 在 human，bundle 只 glimpse；§6 已 human-confirmed。
- 環境：Swift cross-platform（macOS + Linux），XCTest；OC（OpportunityContext）有既有 test 寫法可當 ground truth。

### 子議題

> C1-C6 中性編號，不放 ranking。

- [ ] C1：test-gen 獨立 skill vs 併進 /usecase /api
- [ ] C2：source of truth — 只讀 spec / 讀 impl 拿 type signature / 兩者；讀 impl 到什麼程度不算被綁架
- [ ] C3：certainty gate — §6 plan-階段 human 確認夠不夠當 test source of truth；要不要再一輪 human gate
- [ ] C4：TDD ordering — test 先於 impl（red-green driving fill skill）vs impl 後補；哪個讓「不被綁架」成立
- [ ] C5：測試層級 — §6 對應 domain unit（aggregate invariant）/ usecase（execute orchestration）/ api integration / 多層
- [ ] C6：Gherkin → Swift 機制 — Given/When/Then → setup/exercise/assert；§6 具體度不足（F3 placeholder Examples / F4 抽象 Given）時 fail-loud vs best-effort

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.7)

**Framing 挑戰（explore mode）**：user 的「test 不被 impl 綁架」直覺**方向對、但需 nuance**。純獨立（test-gen 永不讀 impl）做不到 — 不讀 code 就不知道 method 名 / type signature → test 編不過。所以「不被綁架」的正確定義是：**assertions / behavior 來自 spec（§6/§5），呼叫機制（type signature / method name）來自 code** — 而非「完全不碰 code」。這條線是整個設計的關鍵。

**對 C1-C6 的立場**：

- **C1（獨立 vs 併入）→ 獨立 skill**。理由：(1) test-gen 的 input 是 spec（§6 human-confirmed intent），跟 /usecase 的 code-driven input 本質不同；(2) 獨立才能讓「assertions 來自 spec」結構成立 — 併進 /usecase 會讓同一個 context 同時看 impl 邏輯 + 寫 assertion，confirmation bias 難避免；(3) 不同 cadence — spec 改時 test 該重生，跟 impl 解耦。

- **C2（source of truth）→ 雙來源但分工**：assertion/behavior 純從 §6/§5 推；type signature / 怎麼呼叫從 code（generated skeleton）讀。**界線**：可讀 `<UC>Input.swift` / Entity / Service signature 知道「怎麼 call」，但**不讀 execute body**（那是 impl 邏輯，讀了就被綁架）。execute body 在 test-first 時還是 `fatalError` stub，本來也沒東西可抄。

- **C3（certainty gate）→ §6 plan-階段確認即足夠，不再 gate，但要求 §6 concrete**。§6 已 human-confirmed = certainty 注入點。test-gen 不該再開一輪確認（double-confirmation fatigue）。**但** F3/F4 dogfood 顯示 §6 可能停在 placeholder Examples / 抽象 Given — 此時 test-gen 該 **fail-loud**（拒絕產 vague test），不是再 gate。所以 C3 真正問題不是「要不要再 gate」，是「§6 夠不夠 concrete」。

- **C4（TDD ordering）→ test 先於 impl（red-green）**。這是讓「不被綁架」**結構成立**的唯一 ordering — test 在 impl 存在前寫，物理上無法從 impl 推。流程：`genesis new`（skeleton + fatalError body）→ **test-gen（red，對著 fatalError）** → `/usecase` `/api` fill（→ green）。skeleton 提供 signature（C2 的「讀 code 拿機制」），fatalError body 讓 test 自然 red。

- **C5（測試層級）→ 主要 usecase/integration level，§3 invariant 可選 domain unit**。理由：§6 Gherkin 是 behavior-level（operator 做 X → event persisted / error thrown），自然對應 usecase execute 層。**OC ground truth 佐證**：OC test（如 `WhenTaxComplianceAuditAddedTests`）是 integration-level — 用真 `KurrentDBClient` / `EventBus` / `withTestBundle` / real repository，behavior-narrative 命名，不是 pure unit。所以 §6 → usecase/integration test 最對齊既有慣例。§5/§3 的 aggregate invariant 可另產 domain unit test（更 deterministic，但次要）。

- **C6（Gherkin → Swift + concreteness）→ fail-loud**。Given→arrange（建 aggregate 到指定 state）/ When→act（call usecase execute）/ Then→assert（event persisted / error thrown）。**concreteness 要求高**：§6 若有 placeholder Examples（`<userId>` / `v-userId`）或抽象 Given（中文 invariant title 直塞）→ test-gen **fail-loud**：「§6 incomplete, 跑 /bundle-plan §6 確認補真值」。理由：placeholder data 的 test 比沒 test 更糟（false green / 編不過）。

**衍生 meta-point（re-elevate F3/F4）**：我之前把 F3/F4（§6 placeholder Examples / 抽象 Given）判為「dogfood 抄捷徑、非 finding」。但**一旦 test-gen 要消費 §6，F3/F4 就從「非 finding」升級成「test-gen 的硬前提」** — §6 不 concrete，test-gen 就無法運作。這反過來證明 bundle-plan 的 §6 method-X 確認（補真實 Examples + 具體 Given）是 test-gen 的必要上游，值得嚴格做。

**Evidence**：OC `Tests/OpportunityContextTests/Listener/AuditQuoting/WhenTaxComplianceAuditAddedTests.swift`（integration test pattern：withTestBundle + real repo + EventBus + behavior-narrative 命名）；`docs/discussions/2026-06-01-bundle-plan-dogfood-findings.md`（F1 invariant model / F3-F4 §6 具體度）；`skills/bundle-plan/SKILL.md`（§6 產出格式）。

#### Codex (GPT-5.4)

**立場**：C1 獨立 skill / C2 雙來源分工（§6/§5 定 behavior，code 提供型別+介面+infra wiring）/ C3 §6 plan-time 確認原則足夠，但 TODO/placeholder/抽象 Given 必須 fail-loud / C4 預設 test-first，backfill 可支援但標低信任 / C5 預設 usecase/application-service integration，domain unit + API + listener 按需 / C6 Gherkin 先 lint 再轉，Examples→參數化，Given→setup catalog，不夠具體拒產。

**關鍵論點**：
1. 不該塞進 fill skill — `/usecase`(SKILL.md:17)、`/api`(SKILL.md:23) 都明定只 in-place 替換 body 不生新檔；產 `Tests/...` 新檔是不同責任 → 新 sibling skill。
2. 「不被綁架」= assertion 不從 impl 來，非完全不讀 code。OC usecase test 直接 build Input + Service.execute（`CreateAuditQuotingUsecaseTests.swift:43`）。界線：可讀 signature/imports/TODO 狀態，不可從 execute branches/catch ladder 反推 expected behavior。
3. **infra 現實（重要）**：generated usecase 綁 concrete `{Aggregate}Repository`(Usecase.swift.template:4)，repository 是 `EventSourcingRepository` over `KurrentStorageCoordinator`(Repository.swift.template:3)。**除非改 codegen abstraction，test-gen 預設只能生 KurrentDB-backed integration test**（in-memory test 不自然）。
4. OC ground truth 支持「usecase/application/API integration 為主」：Create usecase test 用 `.localhost()` KDB + real repo + withTestBundle + reload 斷言（CreateAuditQuotingUsecaseTests.swift:12/36/49）。
5. §5 aggregate-wide invariant ≠ 每個 UC 機械產可執行 error test — error setup 常需一串合法前置 usecase（AddTaxComplianceAuditWithFilingMethodAdjustmentTests.swift:34/46）；§6 Given 必須具體到可 setup。
6. Gherkin→Swift 需 setup helper/catalog（OC 有 `SharedUtility/UsecaseCall/AuditQuoting.swift:20/214` 的 `createAuditQuoting`/`addAccounting`），沒 equivalent arranger 就只能 inline 長 setup 或 fail-loud。
7. **框架 mismatch（load-bearing）**：Genesis scaffold 是 `import XCTest`/XCTestCase(TestPlaceholder.swift.template:1)，但 OC 實際是 Swift Testing（`import Testing`/@Suite/@Test/#expect，CreateAuditQuotingUsecaseTests.swift:3）。test-gen 應 detect existing style — fresh Genesis emit XCTest、OC-like mature emit Swift Testing。

**對 Claude 回應**：同意核心 framing + C1 獨立 + C3 不二次 gate + C6 fail-loud。分歧：(a) 讀 execute body 不該神化禁止 — 禁的是當 semantic source，讀它判 TODO/idempotent 狀態合理（/usecase 已這樣）；(b) **不同意 C4「唯一 ordering」強說法** — backfill 仍可 spec-based，只是信任低，要 `--backfill` flag + warning；(c) **不同意拿 OC listener test 當 §6 主要 ground truth** — listener 是 EventBus/cross-aggregate pattern，普通 write UC 該參考 Usecase/ApplicationService/API test。

#### Gemini

**Framing 挑戰（systems/maintainability lens，10-month view）**：打掉一個 Claude + user 共享的隱含前提 —「test-gen 是對的抽象，只是要選對 source/ordering/layer」。從「spec 演化後 test 變怎樣」看，**test-gen-as-one-shot-codegen 在大半情況是錯的抽象**，對的是 **scaffold-stub-emitter + human-authored fixture library**。

**關鍵論點**：
1. **test theater 已存在 scaffold**：`TestPlaceholder.swift.template:4` 就是 `XCTAssertTrue(true, ...)` — 字面 tautological green test。專案出生第一天就帶永遠綠、零驗證的 test。證明「機制責任=讓 swift test 變綠」時，最省力均衡點就是 trivial assertion。
2. **OC error test 證明 §6 抽象 Given 機械轉不出真 test**（核心反駁 C6）：`TaxComplianceInvariantTests.swift:176-180` 觸發某 invariant 違反，Given 是一串具體領域編排（createAuditQuoting + 特定 workItemTypes + configs 設定卻不 add serviceItem 才 throw）。這領域知識**不在 §6/§5/bundle/generated code 任何一處 — 在寫 invariant 的人腦裡**。F4 不是 dogfood 偶發品質問題，是**結構性鴻溝**：§6 plan-time 人能寫的 Given ≠ 跑得起來的 test 需要的 Given。多數 error case 跨不過 → C6 不是 fail-loud vs best-effort，是「機械路徑對 error case 根本不存在」。
3. **drift 真空**：bundle-plan 對 spec 有 `--replan` superseded/amendment（SKILL.md:163-176），**test 沒對應機制**。human 為讓 error test 跑動手補領域編排 → bundle 改 → 重生 test → 人補的被整檔覆蓋。最糟 anti-pattern：**生成物既不能手改（會被洗）又不能不手改（不改是 theater）**。Claude C1 的「重生很自由」恰製造此 trap。
4. **certainty laundering**：§6 confirm 的是 scenario intent，非 test body 的 Given fidelity。auto-gen 拿人確認的 high-level intent + 機器拼湊的 plausible Given/assert → 產出「看似承載 human certainty、實則只承載 machine plausibility」的 artifact。比沒 test 危險，因為**冒用**了 human certainty 的信用。
5. **OC 真投資在 fixture library 不在 per-test body**：`SharedUtility/UsecaseCall/AuditQuoting.swift` 一整批手寫 helper。對的切點：機器生 (a) Swift Testing @Suite 骨架+import+repo init boilerplate（純機械、重生安全）+ (b) 從 §5/§6 推的 `@Test func` 命名空殼 + `// TODO(test): author Given for <invariant>` marker — 把領域編排洞明確留給 human，marker 區隔不被重生覆蓋。
6. **happy-path create 是唯一 auto-gen 真成立的格**：create test Given = 無前置狀態，body 高度機械（CreateQuotationUsecaseTests.swift:20-35）。越往 update/delete/error，Given 領域 fidelity 需求越高，auto-gen ROI 趨零。scope = 「generate create-happy-path test + scaffold everything else as authored TODOs」。

**立場（per C1-C6）**：C1 獨立（理由是 lifecycle/drift，非 confirmation bias）/ C2 同意分線 + 補「要讀既有 fixture helper 簽名，否則繞過 fixture library 跟 OC 慣例分裂；讀 test fixture 不算綁架」/ C3 反對「§6 confirmed 即足夠」— 把機器無法 confirm 的 Given 標 human TODO，不假裝 §6 足夠也不 fail-loud 整批拒 / C4 test-first 同意但指洞：error test 要 `#expect(throws:)`，fatalError stub 會 crash process 不是 clean red，CI 難區分「真 red」vs「沒填」/ C5 同意 usecase 為主 + 兩更正（框架是 Swift Testing；OC test 需真 KurrentDB → red-green 閉環硬依賴跑著的 DB）/ C6 **反對 fail-loud 為主策略** — 會讓 error case 永遠拒生（結構常態）；主張分流：create-happy-path 機械生可跑 test、其餘生 named 空殼 + TODO marker（解 drift），fail-loud 只在連 scenario 名都推不出時。

**對 Claude 回應**：Agree C2 分線 / C4 test-first 大方向 / C1 結論 / C5 §6 對 usecase 層。Disagree：(a) Claude 把 F3/F4 升級成「嚴格做 §6 method-X 就能餵 test-gen」對 happy-path Examples 對、對 error Given 無效（人 plan-time 也寫不出 config 踩線編排）；(b) fail-loud 殺掉所有 error-path 產出；(c) Claude 全程假設 regeneration free，沒碰 hand-edit drift；(d) 漏了 XCTest/Swift Testing mismatch + KurrentDB 依賴；(e) 最根本：Claude 預設 test-gen 是對的抽象，Gemini 主張對的抽象是 scaffold emitter + fixture-TODO marker，硬對全 UC 生完整 test → test theater + drift trap → net-negative，不如不做。

---

### Round 2 — Synthesis（Claude facilitator）

**收斂提案：test-gen = scaffold emitter（採 Gemini C7 reframe），用 Codex 的 fixture-catalog 補 Given gap。**

R1 後我改變立場 — Gemini 的 C7 reframe 對。但 Codex 的「setup catalog」其實是補上 Gemini 缺口的橋：**領域編排的 Given 不該由 test-gen 生、而是由 human-authored fixture library 封裝，test-gen 去 call 它**。合起來是一個乾淨的設計：

**test-gen 產出三類（非全產完整 test）**：
1. **Suite scaffold + boilerplate**（純機械、regen-safe）：Swift Testing `@Suite` + import + repository init。
2. **create-happy-path 完整可跑 test**（唯一機械成立的格，Gemini 論點 6 + Codex 論點 4 OC 佐證）：build Input → Service.execute → assert event persisted。
3. **其餘（update/delete/error）= named `@Test` 空殼 + marker**：`// TODO(test): arrange via fixture for <scenario>`。Given 的領域編排留給 human，**但若既有 fixture helper（OC `SharedUtility/UsecaseCall/` pattern）存在就 reference 它**（Codex 論點 6 + 7）。

**配套決議**：
- **C6/C7**：採 scaffold-TODO（乙），**不 fail-loud 為主**。fail-loud 只在「連 scenario 名都推不出」。
- **drift**：marker-isolated regen — 重生只動 scaffold + create-happy-path，TODO marker 段 + human 補的 fixture call 用 marker 區隔不覆蓋（解 Gemini 論點 3）。
- **框架**：對齊 **Swift Testing**（OC ground truth），test-gen detect existing style；fresh Genesis 的 `TestPlaceholder.swift.template` 該從 XCTest 換 Swift Testing（獨立小修，Codex 論點 7 + Gemini 開頭）。
- **infra（KurrentDB 依賴）**：create-happy-path test 需真 KDB → 標 integration test、`.tags(.integration)`，CI 環境無 DB 時 skip。in-memory repository abstraction 是更大的 codegen 改動，**本討論不解，標 open question**。
- **C4 ordering**：test-first 為主（scaffold + create-happy-path 在 fill 前），但採 Codex 修正 — backfill 用 `--backfill` flag + 低信任 warning，非「唯一」。

---

**Rejection log（HARD）**：

- ❌ **我自己 R1 的 C6「fail-loud 為主」**：拒絕。Gemini 論點 2 對 — error Given 的領域編排是**結構性**寫不出（不在 §6/§5/bundle/code），fail-loud 會殺掉所有 error-path 產出。降級為「只在 scenario 名都推不出時 fail-loud」。
- ❌ **我自己 R1「F3/F4 → 嚴格做 §6 method-X 就能餵 test-gen」**：部分拒絕。對 happy-path Examples 對（人補得出真值），對 error Given 錯（人 plan-time 也寫不出 config 踩線編排，Gemini 論點 2）。§6 嚴格化只解 happy-path，不解 error。
- ❌ **我自己 R1 隱含「test-gen = 完整 codegen」前提**：拒絕，改採 Gemini scaffold-emitter reframe。
- ❌ **Gemini 暗示的「test-gen 大半 net-negative 不如不做」的悲觀結論**：部分拒絕。scaffold-emitter + create-happy-path + fixture-reference 後，test-gen **有正值**（省 boilerplate + create test + 結構化 TODO 引導），不是 net-negative。Gemini 的悲觀建立在「全產完整 test」前提上，那前提被 scaffold-TODO 取代後不成立。

**部分採納（modify）**：
- 🟡 **Codex「setup catalog / fixture helper」**：採納為 Given gap 的橋（test-gen reference 既有 fixture，不自己生領域編排），但修改為「fixture library 由 human 維護、test-gen 只 reference 不生」。
- 🟡 **Codex C4「backfill 可支援」**：採納為 `--backfill` flag + 低信任 warning，非預設。

---

#### Gemini — R2

**淨立場：concede scaffold-emitter 值得做（C7 收斂），但加 3 個 evidence-backed must-have + 修正 value 敘事。**

1. **接受 Claude 反駁（net-positive），但 value breakdown 反過來**：durable win 是 **boilerplate scaffold**（每個 OC test 重複同一段 `@Suite(.serialized,.tags)` + `KurrentDBClient.localhost()` + `Repository(coordinator:.init(client:eventMapper:))` + `withTestBundle` envelope + id-minting — 100% 機械可生、regen-safe、易漏 `eventMapper:`/`.serialized`），**不是 create-happy-path**（那只 1/34 ≈ 3%）。novel contribution 是 structured TODO marker（把「沒人寫 test」這個隱形 gap 變成 greppable named obligation）。test-gen 本質是 **code-aware test-scaffold expander**，不是 test generator。

2. **marker-isolated in-file regen = fragile（證據反駁 Claude R2 drift 方案）**：human 填 error test 時 arrange/act/assert 是**交織的**（`TaxComplianceInvariantTests.swift:308-335`：`createAuditQuoting` + `editEstimatedRevenue(30_000_001)` arrange、`#expect(throws:){addAccounting(configs:)}` act、`error?.error==` assert — 領域知識 smeared 全 body，無法用 `// TODO-START/END` fence）。**robust 替代 = two-file ownership split**：`X.generated.swift`（machine-owned,每次全重生,含 scaffold + create-happy-path + 其餘 scenario 的 disabled pending stub）+ `X.authored.swift`（human-owned,機器永不寫,human 填真 test）。用 **scenario-name reconciliation**（§6 `@error Scenario` title 當 stable key,對齊 bundle-plan `--replan` 的 specId diff 機制）報 pending/authored/orphaned。

3. **test theater：scaffold-TODO 會「移動」theater 除非 pending stub 標對（MUST-FIX,最 load-bearing）**：空 `@Test func x(){}` 在 Swift Testing **是 pass（綠）** → IAM 7 UC ≈ 34 scenario,test-gen 後 ~33 假綠 + 1 真 = 比沒 test 更糟（CI/coverage 讀成「覆蓋了」）。既有 `TestPlaceholder.swift.template:4` 的 `XCTAssertTrue(true)` 已證明 default 會出錯。**強制**:pending stub = `@Test(.disabled("TODO(test): ..."))`（report 成 skipped 不是 passed）+ body 放 `Issue.record("pending")`（若有人移掉 .disabled 會 fail 不會假綠）。

4. **量化（IAM 真實 7 UC task spec）**：34 scenario（7 happy + 27 error）。**fully-runnable auto-gen = 1（create-happy-path,3%）**。6 個 update happy-path **不免費**（Given「profile 已存在」需先 call create fixture 帶**合法** input 過 3 invariant — 領域知識）。27 error = **0% auto**（`employeeNotActive` 的 Given 是中文 title `員工必須在職 fails`,到「arrange profile → set status .resigned → promoteUser → #expect(throws:)」無機械路徑;且 `UserAccessProfile.ensureInvariant()` 本身還是未填 GENESIS-STUB）。**誠實報告兩個數**:fully-runnable 3% / scaffold + 33 named disabled obligations = substantial。別讓「test-gen 跑完 swift test 綠」被讀成 coverage（~3% meaningful）。

5. **建議**:加一個 `genesis check-skills`-style 報告「N pending test obligations across M suites」讓 gap 持續可見,不被洗進綠 build。

**Evidence**：OC `SharedUtility/UsecaseCall/AuditQuoting.swift`（~1000 行手寫 fixture library）/ `TaxComplianceInvariantTests.swift:156-181`（error arrange）+ `:308-335`（interleaved，drift 證據）/ `CreateCompanyRegistrationQuotingUsecaseTests.swift:8-16`（boilerplate preamble）/ `TestPlaceholder.swift.template:4`（test theater default）/ `/tmp/genesis-iam-final/docs/tasks/{CreateUserAccessProfile,PromoteUser}.md`（§5/§6 量化 + `PromoteUser.md:87` 中文 title Given）/ `UserAccessProfile.swift:56-58`（ensureInvariant 未填 stub）。

#### Codex (GPT-5.4) — R2

⚠️ **未取得**：Codex R2 派至 `codex:codex-rescue` 後回報「task running in background」（async wrapper 行為），R2 synthesis 時尚未返回實際分析。per discuss skill tool-failure 透明度規則記錄於此，不美化。Codex R1 立場（fail-loud + setup catalog + 框架 detect + infra KurrentDB-only）已在記錄；R2 stress-test（marker 機制 robustness / Swift Testing 全換 vs detect / KurrentDB 是否毀掉 red-green 閉環）**未經第三方驗證**。下方 R2 共識對「marker 機制」與「red-green 閉環是否成立」標註「待 Codex 補」。

---

### Round 3 — Lock round（Claude facilitator）

**目的**：(1) 用 user 指向的 OC `AddTaxComplianceAuditUsecaseTests` 新證據鎖 infra open question；(2) 補 Codex 缺位；(3) 三方最終確認 D1-D8。

#### Claude (Opus 4.8) — R3 synthesis

**核心收斂：infra 鎖 (a) 真 KDB + `withTestBundle`，in-memory (b) 整條砍。連帶我上一輪 floated 的「codegen repo-coordinator 解耦」分支蒸發。**

R2 後 user 指向 OC `AddTaxComplianceAuditUsecaseTests.swift`，三個新證據決定性地收掉 open question #1：

**Finding A — OC 明知有 in-memory，仍刻意選真 KDB 測 usecase。**
- usecase test 全程真 KDB：`KurrentDBClient(.localhost())`（`AddTaxComplianceAuditUsecaseTests.swift:12`）、`AuditQuotingRepository(coordinator: .init(client:eventMapper:))`（:16）。
- 同一個 DDDKit 內就有 `InMemoryStorageCoordinator`（`swift-ddd-kit/Sources/EventSourcing/EventStorageCoordinator/InMemoryStorageCoordinator.swift`，註解明寫 "Suitable for testing"），OC **沒用**。
- OC 唯一 mock 的是 `MockStorage`（`SharedUtility/MockStorage.swift:9` — `StorageProtocol`，file-blob upload/download），**event store 從不 mock**。
- → 「OC ground truth」對 in-memory event store 是**明確拒絕**。走 (b) 會讓 test-gen 產出叉離 OC idiom + 白付 codegen 解耦 blast radius + 損 fidelity（`InMemoryStorageCoordinator` 的 revision 算法 `existing.count + events.count` 與 Kurrent 不同，protocol extension 自己警告 revision 語意差異需 override）。**(b) 砍。**

**Finding B — `withTestBundle` 正是我 R2 以為要靠 (b) 解的問題的真正解法。**
- 我 R2 把 red-green 卡點歸因成「沒 DB → red 混淆 → 要 in-memory 閉環」。錯。`withTestBundle`（`DDDKit/TestUtility/TestBundle.swift:96`）做的就是這件事：`generateAggregateRootId` 鑄唯一 UUID stream（:25-28）→ 測試間不撞；`cleanPhase: .both`（default）→ 開始前清 stream（:30-32）+ 結束後清（:105-107）。配 `@Suite(.serialized)` 共享一台 localhost KDB 可重複跑。
- → 「shared DB 撞 / 殘留 state」harness 已解。red-green **閉得起來**，前提是 localhost KDB（OC 一直接受的 dev/CI prerequisite，非工程繞過對象；CI 給 KDB service container）。

**Finding C — usecase 層 error test 比 Gemini R2 估的可 scaffold 得多。**
- Gemini R2「error Given 領域編排結構性寫不出、0% auto」的證據是 `TaxComplianceInvariantTests`（**aggregate-unit 層**）。但 user 指的這支是 **usecase 層**，error test 全是同一形狀：`withTestBundle { createX(fixture) → malformed input → #expect(throws:){ usecase.execute } → #expect(error?.error == .code) }`。
- 承載領域知識的只有兩點：fixture 帶哪個參數（`createAuditQuoting(accountingType: .managementAccount)` → `invalidAccountingType`，:97）、input 哪欄壞（`workItemTypes: []` → `noWorkItemsSelected`，:125）。這兩點正是 §6 human-confirmed Given 該講清楚的。
- → 只要 fixture catalog 在 + §6 Given 具體，test-gen 能把 usecase 層 error body scaffold 到接近完整，只剩參數值是 authored。Gemini「0% error auto」對 invariant-unit 層成立、**對 usecase 層被高估**。D4 的 value 量化要修正：error test 不是純空殼，是「scaffold + fixture-call + assert error code 結構完整，只缺 authored 參數值」。

**新 gap 清單（都不動 codegen 抽象，只 wiring）**：
| gap | 現況 | 補法 | owner |
|---|---|---|---|
| test target deps | 只有 `{TestDependencies}` placeholder，無 `TestUtility`/`KurrentDB`，scaffold 還是 XCTest `TestPlaceholder` | 加 `TestUtility` + `KurrentDB` 到 test target | 機器 |
| `withTestBundle` envelope + suite boilerplate | 無 | test-gen 機械生（純樣板，Gemini R2 的 durable win）| 機器 |
| fixture library（`createX` UsecaseCall）| 無 | **human-authored**，test-gen 只 reference（= D4(c)）| 人 |
| localhost KDB | dev/CI prerequisite | 文件化 + CI service container | 環境 |

repo 構造 recipe 生成的 code 已證可行：`ApiHandler.swift.template:11` 的 `coordinator: .init(client: kdbClient, eventMapper: {A}AggregateEventMapper())` 與 OC test :16 一模一樣 → test-gen 照抄、client 指 `.localhost()`、包 `withTestBundle`。

**Rejection log（HARD）**：
- ❌ **我自己（對話輪）的「兩層 (a)+(b)、傾向建 (b)」lean**：拒絕。Finding A 證 OC 刻意拒 in-memory event store；(b) 全是成本（叉離 idiom + blast radius + fidelity 損），砍。
- ❌ **我自己上輪「InMemoryStorageCoordinator 存在 → (b) 便宜 → 該建」的推理**：拒絕。「便宜」技術上對但方向錯 — 便宜不等於該做，OC ground truth 明示不做。
- ❌ **Gemini R2「error 0% auto、結構性寫不出」的全稱**：部分拒絕。對 invariant-unit 層成立，對 usecase 層（本討論 D5 主層）被高估（Finding C）。usecase error test 可 scaffold 到接近完整。
- ❌ **R2 open question #1 把 (a)/(b) 並列待決**：拒絕保留 — 證據已足，鎖 (a)。

**部分採納（modify）**：
- 🟡 **Gemini R2「fixture library human-maintained、test-gen 只 reference」**：採納且強化 — fixture catalog 是 Finding C 可 scaffold error test 的前提，列為 test-gen 硬上游依賴（無 fixture → error body 只能空殼）。
- 🟡 **Codex R1「KDB-backed only / in-memory 不自然」**：採納為正式決議（D9）— Codex R1 直覺與 Finding A 一致，R3 用 OC 證據坐實。

**待 Codex R3 / Gemini R3 確認**：(i) infra 鎖 (a) 是否同意；(ii) Finding C「usecase error 可 scaffold」是否過度樂觀（有沒有 usecase 層 error 也需多步 gnarly arrange 的反例）；(iii) D1-D8 final sign-off。

#### Codex (GPT-5.4) — R3

**立場**：同意 infra 鎖 (a)（real KDB + `withTestBundle`，非 in-memory event-store 分支）。**不同意 Finding C 的絕對措辭** — user 指的 `AddTaxComplianceAuditUsecaseTests` 近乎機械，但同目錄 sibling service-item usecase test 顯示**少數** error case 需 2-3 步序列 fixture call 或 branch-forcing setup。

1. **infra lock：OC 刻意對 usecase 測真 KDB，Genesis template 也硬綁同一 stack**。`AddTaxComplianceAuditUsecaseTests.swift:12-17` 建 `KurrentDBClient(.localhost())` + `AuditQuotingRepository(coordinator: .init(client:eventMapper:))`；同形見 `CreateAuditQuotingUsecaseTests.swift:12-17`、`DeleteAuditQuotingUsecaseTests.swift:11-16`。Genesis template 完全對齊：`Repository.swift.template:3-10`（Kurrent-locked）、`Usecase.swift.template:4-10`（綁具體 repo）、`ApiHandler.swift.template:9-16`（`.init(client:eventMapper:)`）。`MockStorage.swift:9-55` 只 mock `StorageProtocol`（file-blob），**不取代 event storage**。

2. **`InMemoryStorageCoordinator` 存在不推翻 lock**。DDDKit 確有它且標 "Suitable for testing"（`InMemoryStorageCoordinator.swift:4-10`），但 OC 不用於 usecase test，且 fidelity 不符：它 `newRevision = existing.count + events.count`（:18-26），protocol 自己警告非 count-based revision 需 override `afterRevision`（`EventStorageCoordinator.swift:11-18`），Kurrent 確實 override（讀 `.specified(revision+1)`，`KurrentStorageCoordinator.swift:88-95`）。**Hypothesis（scope 外但 surface）**：in-memory 仍是 **read-model/projector test** 的合法例外 — DDDKit 另有 `InMemoryReadModelStore.swift:4-20`，`StatefulEventSourcingProjector` 抽象在 `ReadModelStore` 而非具體 Kurrent repo（:16-23,37-55）。對 usecase test 不對，對 read-model lane 可能對。

3. **`withTestBundle` 才是 shared-DB 衛生的真解**：唯一 id（`TestBundle.swift:25-33`）+ default `cleanPhase:.both`（:75-91,96-107）+ OC 配 `@Suite(.serialized)`（`AddTaxComplianceAuditUsecaseTests.swift:9,27`）。證明 lock 該是「real KDB + harness」而非「解耦 repo 以躲 DB」。

4. **Finding C 對指定檔成立、當全稱則 false**。該檔每個 error test 同 near-template（`:63-245`）。但 sibling 有 named 反例：
   - `AddTaxComplianceAuditWithFilingMethodAdjustmentTests.swift:180-201`：先 `createAuditQuoting` → 再 `addAccounting` 逼出 WithFilingMethodAdjustment 分支 → 才 throw missing `startDate`。
   - `EditProfitseekingEnterpriseIncomeTaxFilingMethodUsecaseTests.swift:81-97,144-159`：locked/cannot-be-set error 需 `addTaxComplianceAudit` + `addAccounting` 才 throw。
   - `RemoveTaxComplianceAuditTests.swift:184-205`：`invalidEstimatedRevenue` 依賴**不**呼叫 `editEstimatedRevenue`、再 add 多個 item 才 throw。
   → Gemini「0% auto」對 usecase 層太悲觀，但 Claude「只一個 fixture 參數 + 一欄壞」太樂觀。證據支持的較強說法：**多數** usecase error test 在 fixture catalog 存在時可 scaffold，但**部分需多步 fixture recipe**（`AuditQuoting.swift:263-277,341-355,575-600,771-785` 那批 helper），非單一 fixture call。

5. **drift + 框架**：drift 站 Gemini（authored 邏輯整段交織，in-file marker 不可 fence，見 `EditProfitseeking...:81-97`、`RemoveTaxComplianceAuditTests.swift:184-205`）→ two-file ownership。**Hypothesis**：scenario-title-only reconcile 在 rename 下脆；若 bundle-plan 能 emit stable scenario id 就用 id，title 僅顯示。框架站**全換 Swift Testing**（OC 一致 `import Testing`/@Suite/#expect，`CreateAuditQuotingUsecaseTests.swift:1-10`；Genesis 僅 legacy XCTest placeholder `TestPlaceholder.swift.template:1-6`），detect 只當 migration fallback、非 locked design。

**D1-D9 sign-off**：D1 agree / D2 agree / D3 agree / **D4 amend**（bucket (c) 在 fixture catalog match 時應預填 fixture-call/throw/assert skeleton，非空白 TODO）/ D5 agree / D6 agree（`TestPlaceholder.swift.template:3-6` 已證 tautological pass 危險）/ **D7 amend**（two-file 是，reconcile 優先 stable scenario id、title fallback + orphan 報告）/ D8 agree（移 Swift Testing）/ **D9 agree**（usecase/application test 鎖 real KDB + `withTestBundle`；in-memory 視為獨立 read-model/projector lane，非這些 repo 的 event-store 替身）。

#### Gemini — R3

**淨立場**：concede infra lock，接受 Finding C 的層級區分（但加精確邊界），重申兩個 must-have。九條決策全 sign-off，一條 modify。

1. **infra lock (a) — CONCEDED**。放棄先前 in-memory 主張。Finding B（`TestBundle.swift:25-34` 唯一 UUID + `.both` cleanPhase）「完全解決」CI state-bleed/collision 顧慮，red-green 閉得起來。接受 Finding A：橋接 `InMemoryStorageCoordinator` 會注入分歧 revision 算法（`:24` `existing.count + events.count`）+ 叉離 OC idiom。**Residual risk（named, non-blocking）**：dev-onboarding tax — 無 localhost KDB 時 test 直接 crash。但對抗 repo 既定 docker-compose prerequisite 會造成更糟的碎裂現實，故判 non-blocking。支持 D9。

2. **Finding C — ACCEPTED with boundary refinement**。接受層級區分（usecase test 把 state-setup 與 execution 解耦，避開 invariant 層的交織 arrange/act/assert）。但 concession scoped — **「0% auto」是被結構性擊敗、非被 domain fidelity 擊敗**：
   - 機器 CAN emit：`withTestBundle` envelope、`let input = ...` boilerplate、`#expect(throws:) → error == .code` closure。
   - 機器 CANNOT know：`.invalidAccountingType` 需 fixture 種 `.managementAccount`（`:97`）、`.duplicateServiceItemId` 需失敗前先成功 execute 一次（`:63-86`）。
   - **不可化約的 authored residue = 「domain payload」**（fixture args + input mutations）。
   - 與 Codex 的多步反例一致：domain payload 有時是**多步 fixture recipe**，非單一 call。

3. **must-have 重申**：D6（anti-theater）不變且 load-bearing — 即使 template 更豐富，未填 TODO 仍可能靜默 pass，stub 必須 `.disabled` + `Issue.record` 直到 human 移除。D7（two-file split）不變且 load-bearing — template 現在帶 human 編輯的 inline args（如 `:97` `.managementAccount`），未來 `--replan` regen 會洗掉這些領域知識；in-file marker 無法在 `withTestBundle` closure 內安全 fence inline args。

4. **D1-D9 sign-off**：D1/D2/D3/D5/D6/D7/D8/D9 **agree**；**D4 modify** — output class (c) 不是「空 pending stub」，是「結構 template（`withTestBundle` + `#expect` envelope）缺 domain payload」，TODO marker 改 `// TODO(test): provide domain payload`。

**facilitator process note**：`gemini` CLI 拒 `--approval-mode yolo`（sandbox classifier 擋 analysis-only 的 autonomous mode），改用 default mode + `--skip-trust`，prompt 自足故無需 tool-access 即產出完整分析。

---

## 共識看板（R1 後）

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| C1 | 獨立 vs 併入 | 獨立 | 獨立 | 獨立 | **agreed**（evidence: usecase/api SKILL.md 只 in-place fill 不生新檔）|
| C2 | source of truth | spec 定 assertion / code 提供 signature | 同（界線在 execute body）| 同 + 讀 fixture helper | **agreed**（evidence: OC CreateAuditQuotingUsecaseTests build Input+Service）|
| C3 | certainty gate | 不二次 gate，要求 §6 concrete | 不二次 gate + TODO/skip 也 fail-loud | 不二次 gate 但不假裝 §6 足夠，標 human TODO | **majority**（都反對二次 gate；分歧在「§6 不足時 fail-loud vs scaffold-TODO」= C6）|
| C4 | TDD ordering | test-first（唯一）| test-first 預設 + --backfill 低信任 | test-first 但 error case fatalError→crash 非 clean red | **majority**（test-first 為主；Claude「唯一」被 Codex/Gemini 各打一洞）|
| C5 | 測試層級 | usecase 主 + domain unit 次 | usecase/app/api integration 主 | usecase 主 + 2 更正（框架/infra）| **majority**（usecase 為主一致；Codex+Gemini 加 XCTest→Swift Testing + KurrentDB 依賴兩個 ground-truth 修正）|
| C6 | Gherkin→Swift 機制 | R2 改：scaffold-TODO（撤回 fail-loud 為主）| fail-loud + setup catalog（R1；R2 未補）| scaffold-TODO，pending=`.disabled`+`Issue.record` | **majority→agreed-pending-Codex**（R2 Claude 撤回 fail-loud、與 Gemini 收斂到 scaffold-TODO；Codex R1 的 fail-loud 被 Gemini error-Given 結構性證據 override）|
| C7 | test-gen 是不是對的抽象 | R2 接受 reframe | （R2 未補）| concede 值得做（scaffold-emitter，非 full codegen）| **agreed-pending-Codex**（Claude + Gemini 收斂：test-gen = scaffold expander，create-happy-path 只 1/34）|
| C8* | **（emergent R2）drift regen 機制** | in-file marker | （R2 未補）| **in-file marker fragile（交織 arrange/act/assert）→ two-file ownership split + scenario-name reconcile** | **majority**（Gemini 證據駁倒 in-file marker；two-file split 待 Codex 驗）|
| C9* | **（emergent R2）test theater 防治** | （未明確）| （R2 未補）| pending stub MUST `.disabled`+`Issue.record`（空 @Test 會假綠）| **majority**（Gemini load-bearing must-fix，evidence: TestPlaceholder.template:4 已證 default 出錯）|

---

## 共識看板（R3 lock — Codex 補位後）

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| C1 | 獨立 vs 併入 | 獨立 | 獨立 | 獨立 | **agreed** |
| C2 | source of truth | spec 定 assertion / code+fixture 提供 signature | 同 | 同 | **agreed** |
| C3 | certainty gate | 不二次 gate | 不二次 gate | 不二次 gate | **agreed**（fail-loud vs scaffold-TODO 的分歧已被 C6 吸收解決）|
| C4 | TDD ordering | test-first 主 | test-first 預設 + --backfill | test-first 主 | **agreed**（test-first 為主、backfill 低信任 flag）|
| C5 | 測試層級 | usecase 主 | usecase/app/api 主 | usecase 主 | **agreed**（usecase/application 層為主，evidence: OC usecase test 三方引）|
| C6 | Gherkin→Swift 機制 | scaffold-TODO | scaffold-TODO（多步 fixture recipe 例外）| scaffold-TODO（domain payload 不可化約）| **agreed**（三方收斂 scaffold-TODO；fail-loud 只在 scenario 名都推不出）|
| C7 | test-gen 是不是對的抽象 | scaffold-emitter | scaffold-emitter | scaffold-emitter | **agreed**（evidence: OC fixture library + withTestBundle boilerplate = durable win）|
| C8* | drift regen 機制 | two-file split | **two-file split + stable scenario id reconcile** | two-file split（template 帶 inline authored args → 更需 two-file）| **agreed**（三方一致 two-file；reconcile key 用 stable id、title fallback）|
| C9* | test theater 防治 | 採納 | 採納（TestPlaceholder 已證危險）| MUST `.disabled`+`Issue.record` | **agreed**（三方一致，evidence: TestPlaceholder.swift.template:3-6）|
| C10* | **（emergent R3）infra：real KDB vs in-memory** | real KDB + withTestBundle，砍 (b) | 同（in-memory 僅 read-model/projector lane 合法）| concede real KDB（in-memory 損 fidelity + 叉離 idiom）| **agreed**（evidence: OC 只 mock file-blob、event store 從不 mock；InMemoryStorageCoordinator revision 算法分歧）|
| C11* | **（emergent R3）error test scaffold 程度** | 高（只缺 fixture 參數 + 壞欄）| 中（多數可，**部分需多步 fixture recipe**）| 結構性可、domain payload 不可化約 | **agreed**（收斂：envelope+#expect 結構可機械生，domain payload〔fixture args + input mutation，有時多步〕為 authored residue）|

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | test-gen 是**獨立 skill**（非併進 /usecase /api）| 2026-06-01 | R1 | 三方 agreed；fill skill 只 in-place 填、產 test 新檔是不同責任 |
| D2 | source of truth = **assertion 來自 spec(§6/§5)、signature 來自 code + 既有 fixture helper**；不讀 execute body 當 semantic source | 2026-06-01 | R1 | 三方 agreed |
| D3 | test-gen = **scaffold emitter，非 full codegen**（C7 reframe）| 2026-06-01 | R2 | 三方 agreed（R3 Codex 補位確認）|
| D4 | 產出三類：(a) Swift Testing suite scaffold/boilerplate(regen-safe) (b) create-UC happy-path 完整可跑 test (c) **其餘 = 結構 template（`withTestBundle` envelope + `#expect(throws:)` + assert error code skeleton）缺 domain payload**，marker `// TODO(test): provide domain payload`（fixture catalog match 時預填 fixture-call skeleton，reference 既有 fixture）| 2026-06-01 | R2→**R3 amend** | R3 Codex+Gemini：(c) 不是空 stub 是結構 template；domain payload（fixture args + input mutation，**有時多步 fixture recipe**）為 authored residue |
| D5 | C6 = **scaffold-TODO，非 fail-loud 為主**（fail-loud 只在 scenario 名都推不出）| 2026-06-01 | R2 | 三方 agreed（R3 Codex 確認）|
| D6 | pending stub **MUST `@Test(.disabled(...))` + `Issue.record` body**（防 test theater 假綠）| 2026-06-01 | R2 | 三方 agreed；evidence: `TestPlaceholder.swift.template:3-6` |
| D7 | drift regen = **two-file ownership split**（`.generated.swift` 全重生 / `.authored.swift` 機器永不寫）+ **stable scenario id reconcile（title 僅顯示、fallback）** + orphaned 報告不刪 | 2026-06-01 | R2→**R3 amend** | R3 Codex：title-only reconcile 在 rename 下脆，bundle-plan 應 emit stable scenario id；Gemini：template 帶 inline authored args 更證 two-file 必要 |
| D8 | 框架**全換 Swift Testing**（非 XCTest）；修 `TestPlaceholder.swift.template`；detect existing style 僅當 migration fallback、非 locked design | 2026-06-01 | R1+R2→**R3 strengthen** | 三方 agreed；R3 Codex 明確「全換、detect 只 fallback」|
| D9 | **infra = 真 KDB + `withTestBundle`**（usecase/application test）；**砍 in-memory (b) 分支 + 砍 codegen repo-coordinator 解耦**；localhost KDB 為 dev/CI prerequisite（CI 給 service container）| 2026-06-01 | **R3** | 三方 agreed；evidence: OC 只 mock file-blob（`MockStorage.swift:9`）、event store 從不 mock；`InMemoryStorageCoordinator` revision 算法與 Kurrent 分歧（`:24` vs `KurrentStorageCoordinator.swift:88-95`）|

---

## 開放問題（R3 後）

> R2 的 infra open question #1 + Codex R2 缺位（#4）已於 R3 關閉。剩下為 spec 階段 / 範圍外項。

1. **[spec 階段] read-model/projector test lane**：Codex R3 指出 in-memory 對 **read-model/projector** test 仍合法（DDDKit 有 `InMemoryReadModelStore` + `StatefulEventSourcingProjector` 抽象在 `ReadModelStore`，非具體 Kurrent repo）。D9 只鎖 usecase/application 層為 real KDB；read-model 層的 test infra 是否走 in-memory 留 spec 階段決（本討論 scope 聚焦 §6 usecase behavior，read-side 另論）。
2. **[spec 階段] D4 (c) 預填程度**：fixture catalog match 時要預填多少 — 只填單一 `createX` call skeleton，還是嘗試推多步 recipe？Codex 的多步反例（WithFilingMethodAdjustment / EditProfitseeking / RemoveTaxComplianceAudit）顯示推多步有風險，傾向只填單步 + marker，多步留 authored。實作時定。
3. **[範圍外] runner**：誰讀 task spec runbook + 派 test-gen / 跑 pending-obligation 報告（Gemini 的 `genesis check-skills`-style「N pending test obligations across M suites」report）— 屬 orchestrator 議題，另議。
4. **[依賴] fixture library 上游**：test-gen 的 error/update test scaffold 依賴 human-authored fixture library（OC `SharedUtility/UsecaseCall/` pattern）存在。無 fixture → error body 只能空殼。fixture library 由誰／何時建（手寫 vs 另一個 skill）未定。

---

## 下次討論指引

### 進度摘要
**討論收斂，consensus 達成（R3 lock round 結束）。** 三方對 C1-C11 全 agreed。D1-D9 全數 sign-off（D4/D7 R3 amend、D8 strengthen、D9 R3 新增鎖 infra）。R2 缺位的 Codex 已於 R3 補位並坐實 infra 鎖 (a)、補 Finding C 多步反例。下一步是**進 write-spec**（test-gen skill spec），非再開討論輪。

### 待處理事項
依 plan→spec→impl 流程，下一步 write-spec：把 D1-D9 轉成 test-gen SKILL.md 規範。spec 階段需收掉開放問題 #1（read-model lane）/ #2（D4 (c) 預填程度）/ #4（fixture library 上游 owner）。#3 runner 屬另議。

### 閱讀建議
- 本檔 R3（Claude synthesis + Codex + Gemini）+ 決策紀錄 D1-D9
- OC `AddTaxComplianceAuditUsecaseTests.swift`（usecase error test 形狀 — D4 (c) 結構 template 來源）
- OC `SharedUtility/UsecaseCall/AuditQuoting.swift`（fixture library + 多步 recipe — D4 domain payload / 開放 #4）
- DDDKit `TestUtility/TestBundle.swift`（withTestBundle harness — D9 infra）
- Codex 指的多步反例：`AddTaxComplianceAuditWithFilingMethodAdjustmentTests.swift:180-201`、`RemoveTaxComplianceAuditTests.swift:184-205`

### 注意事項
explore mode 收斂為 consensus。infra 鎖 (a) 後，先前 floated 的 codegen repo-coordinator 解耦分支正式作廢（不要在 spec/impl 復活）。read-model test lane 的 in-memory 例外是 spec 階段議題、非推翻 D9。
