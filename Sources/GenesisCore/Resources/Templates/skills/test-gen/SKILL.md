---
name: test-gen
description: Genesis test-generation skill (enabled-red 2-lane emitter). Inside a Genesis-bootstrapped project, /test-gen <task-spec.md> turns a bundle-plan per-UC task spec (§6 Gherkin / §5 error cases) into REAL Swift Testing tests that COMPILE and run RED until you fill them (incremental TDD). Two lanes — MECHANICAL (create-happy incl derived-payload + aggregate-not-found = full enabled body, red because the SUT throws GenesisTODO until /domain-fill) and JUDGMENT (input-value / act-sequence / prior-state error = live assertion envelope + a typed throwing genesisTODO(...) arrange-thunk standing in for the whole Given, red until you author it). Two-file split (<UC>Tests.generated.swift machine-owned, regenerated wholesale + <UC>Tests.authored.swift human-owned, never overwritten). Scaffold emitter — does NOT fill execute bodies, does NOT run tests, does NOT read the execute body as a semantic source. genesis verify gates remaining holes (Sources markers + uncovered invariants + test-side Given holes).
argument-hint: <task-spec.md> [--regen]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# /test-gen — turn a per-UC task spec into REAL (enabled-red) Swift Testing tests

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

把一份 `/bundle-plan` 產的 per-UC task spec（`docs/tasks/<UC>.md`）轉成 **enabled-red 的 Swift Testing 測試**：每個 §6 scenario 產一個 **enabled、編得過、跑起來紅**的 test，紅在對的地方，讓人逐 usecase 做增量 TDD（紅 → 填 → 綠）。輸出 two-file split：

- `Tests/<contextName>Tests/<ucPascal>Tests.generated.swift` — **機器擁有，每次整檔重生**。含 `@Suite` 骨架 + 每個 scenario 的 enabled test（MECHANICAL lane = 完整 body / JUDGMENT lane = live assertion envelope + arrange-thunk 洞）。
- `Tests/<contextName>Tests/<ucPascal>Tests.authored.swift` — **人類擁有，機器永不覆寫**。人把 JUDGMENT lane 的 Given（fixture call + 觸發值 + positive-arrange）填在這裡。

### 兩個正交 gate（先建立心智模型）

- **`swift test`** = 「domain + Given 填了沒」。新生成的 test 都是**紅**的：
  - **R-SUT 紅**：test 全填好但 domain 未填 → `execute` 丟 `GenesisTODO.notImplemented` → `#expect(throws: ContextError<X>)` 失敗（乾淨紅）。`/domain-fill` 填掉 → 轉綠。
  - **R-ARRANGE 紅**：JUDGMENT lane 的 Given 還沒 author → `genesisTODO("GENESIS-ARRANGE: …")` thunk throw（乾淨紅，不 crash）。人 author Given → 變 R-SUT 紅 → 填 domain → 綠。
- **`genesis verify`** = 「test 骨架結構誠實完整」。**開發全程紅**（殘留 Sources marker / 未覆蓋 invariant / 未填的 test-side Given thunk 任一在即紅），全填才綠。verify 綠後若 `swift test` 還紅 → Given 語意錯或 localhost KDB 沒開。

test-gen 是 **scaffold emitter，不是 full codegen**，也**不**跑 test、**不**填 domain、**不**呼叫 `/usecase` `/api` `/domain-fill`。

### 絕對約束（不可違反）

- **enabled-red，不用 `.disabled`** — 每個 scenario 一律 emit **enabled** `@Test`。**絕不**以 `.disabled` 為預設 lane（它與 `genesis verify` 衝突：verify 排除 disabled test → disabled stub 會讓 invariant 被判 uncovered）。舊版的 disabled-stub + `Issue.record` 模型**已廢除**。
- **洞 = typed throwing `genesisTODO(...)` thunk，絕不 `fatalError`** — enabled test 跑到 `fatalError` 會 **crash 整個 test runner（SIGABRT）**；throwing thunk 只乾淨紅一個 test。洞**必須是 typed value**（`let input: <UC>Input = try genesisTODO("…")`）—— bare `throw` 後面引用未宣告符號會編不過（`cannot find input in scope`），破壞整 target。
- **不被 impl 綁架（firewall）** — assertion 來自 task spec §6/§5；呼叫機制（建構 Input 要哪些 field / Service 怎麼 init / Output 拿哪些欄位）來自 generated code 的 **type signature**。**可讀 signature（怎麼 call），絕不讀 `execute()` body 的 branch/catch 當 expected behavior 來源**（否則 test 變成 re-confirm impl 非 spec）。
- **coverage 由 live assertion 賺，不由字串** — thunk 訊息**絕不含字面 `.<errorCode>` token**（用非點形式，如 `tripping duplicateServiceItemId`）。`genesis verify` 的 coverage 比對會剝字串字面 → `.code` 在 thunk 訊息裡不算覆蓋；真正覆蓋來自 emit 的 live `#expect(error?.error == .<code>)`。
- **two-file ownership** — `.generated.swift` 整檔重生；`.authored.swift` 機器**只讀不寫**（連 `--regen` 都只報告 reconcile）。
- **real KurrentDB** — 照 OC ground truth 用 `KurrentDBClient(settings: .localhost())` + `withTestBundle`。**不**引 in-memory event store。localhost KDB 是 dev/CI prerequisite。

## 輸入解析

`$ARGUMENTS`：
| 形式 | 處理 |
|------|------|
| `<task-spec.md>` | 對該 UC 產 two-file split（`.generated.swift` 重生、`.authored.swift` 不存在才建空殼）|
| `<task-spec.md> --regen` | 只重生 `.generated.swift` + 對 `.authored.swift` 做 scenario reconcile 報告 |
| 空 / 無路徑 | **exit 1**：`usage: /test-gen <task-spec.md> [--regen]` |

`task-spec.md` 路徑不存在 → **exit 1**：`task spec not found: <path>`。

## 輸入正規化（名稱 / 路徑推導，務必一致）

從 task spec frontmatter（bundle-plan 產，格式 `useCase: <Aggregate>.<useCase>`）推導：

- `ucFull` = frontmatter `useCase`（如 `UserAccessProfile.promoteUser`）。
- `ucCamel` = `ucFull` 取 `.` 之後的後綴（如 `promoteUser`）。**create 判定一律用 `ucCamel`**（lowercased prefix `create` / `establish`），**不**用含 aggregate 的全字串。
- `ucPascal` = UpperCamel(`ucCamel`)（如 `PromoteUser`）— 用於 struct 名 / 檔名。
- `<A>` = frontmatter `aggregate`。
- `contextName` = generated project 的 context 名（從 `.ai/contexts/` 目錄名或 `Package.swift` 的 product 名取）。
- `operatorIdField` / `aggIdField` = **讀 `<ucPascal>Input.swift` 的 stored property 取得**（不重推 codegen 注入規則）：`operatorId` 為名為 `operatorId` 的 field（恆存在）；`aggIdField` 為 aggregate identity field（非 create UC 的 Input 才有，名稱依 aggregate `identityName`，如 `userAccessProfileId`）。
- **輸出路徑固定**：
  - `Tests/<contextName>Tests/<ucPascal>Tests.generated.swift`
  - `Tests/<contextName>Tests/<ucPascal>Tests.authored.swift`
  - `Tests/<contextName>Tests/GenesisTestSupport.swift`（共用支援檔，首跑建、之後 idempotent 補）

## Phase 0 — 讀 task spec（不讀 bundle、不讀 impl 邏輯）

Read task spec MD，取：
- frontmatter：`useCase` / `aggregate` / `useCaseSpecId`。
- **§3 Invariants**：name / errorCode / rules。
- **§5 Error Cases**：每條 `條件 | Domain Error=ContextError<<A>Error>.<errorCode> | HTTP` — 映射到 `#expect(error?.error == .<errorCode>)` 的 error code 斷言。
- **§6 Test Scenarios（Gherkin）**：happy path（Scenario Outline + Examples）+ `@error Scenario` 群。

§6 **完全空白 / 連 scenario 名都無**（非標 `TODO` 而是整段缺）→ **fail-loud**：印
```
test gen aborted: task spec §6 has no scenarios. Run /bundle-plan §6 confirmation first.
```
然後 exit。§6 標 `TODO`（有 scenario 名、缺具體值）→ **不** fail-loud，照 JUDGMENT lane（這是常態）。

## Phase 1 — 定位 generated project + 讀 callable surface（signature only，firewall）

- 確認 cwd 是 generated project root：存在 `.ai/contexts/` **或** `Package.swift`。否則 **exit 1**：`not inside a Genesis-bootstrapped project; cd into the generated project root first`。
- 讀以下 **signature only**（firewall：讀「怎麼 call」，不讀 execute body 的 branch/catch 當 expected behavior）：
  - `<ucPascal>Input.swift` — 建構 Input 要哪些 field + type（含 `operatorIdField` / `aggIdField`）。
  - `<ucPascal>Service`（usecase 的 concrete service type）— 怎麼 init、`execute(input:)` 簽名。
  - `<ucPascal>Output.swift` — assert 拿哪些欄位。
  - `<A>Repository` 的 init 形狀 — 照下方 @Suite 骨架 recipe。
- Glob 既有 `Tests/<contextName>Tests/<ucPascal>Tests.generated.swift` / `.authored.swift` 判斷是新建還是 regen。

## reconcile key（先 title-based，stable-id 待上游）

reconcile 的 key = **scenario 名**：把 §6 每個 `Scenario` / `@error Scenario` 的 title 機械 sanitize 成 Swift backtick 函數名。bundle-plan **目前不 emit scenario id**，故先用 title-derived 名當 key。**預留** stable-id：在每個 generated test 上加 `// test-gen-scenario-id: <id>` 註解欄位；bundle-plan emit id 前**禁 rename** 函數名（rename 會誤判 orphan）。

## @Suite 骨架 recipe（每檔必 emit，否則 test 編不起來）

```swift
// GENESIS-GENERATED — do not edit. Regenerated by /test-gen.
// Author real Given/tests in <ucPascal>Tests.authored.swift (this file is overwritten on --regen).
import Testing
import DDDKit
import KurrentDB
import TestUtility
import <contextName>          // 或 import <A>Aggregate（依 generated 模組劃分）

@Suite(.serialized, .tags(.<agg>))
struct <ucPascal>Tests {
    let kdbClient: KurrentDBClient = .init(settings: .localhost())
    let repository: <A>Repository

    init() {
        // 照 ApiHandler 的 repository 構造 recipe；<A>AggregateEventMapper 由 DDDKit build plugin 生成（package access，同 package test target 可見）。
        self.repository = <A>Repository(coordinator: .init(client: kdbClient, eventMapper: <A>AggregateEventMapper()))
    }
    // … @Test funcs（lane 見下）…
}
```
- `.serialized`：共享一台 localhost KDB 必須序列化（OC ground truth）。
- `.tags(.<agg>)`：`<agg>` = lowerCamel(aggregate)。須先在 `GenesisTestSupport.swift` 宣告 tag（見下）—— **未宣告的 `@Tag` 會讓整 target 編不過**。
- 整檔「先組完整內容再一次寫入」（不 in-place patch，避免半寫）。

## 2-lane emit 規則（核心）

emit 決策是 **2-way**（不是挑 3 個 body-template）：MECHANICAL 全 body、JUDGMENT envelope + thunk 洞。**unknown locus → JUDGMENT lane（絕不捏造 body）**。

### Lane A — MECHANICAL（full enabled body，1-stage R-SUT 紅）

**create-happy**（`ucCamel` prefix `create`/`establish`）：
```swift
@Test func `<happy scenario name>`() async throws {
    // test-gen-scenario-id: <id-if-available>
    try await withTestBundle(client: kdbClient) { bundle in
        let <aggId> = await bundle.generateAggregateRootId(for: <A>.self)
        let operatorId = await bundle.generateId(for: "operatorId")
        // … 其餘 business id 用 bundle.generateId(for:) 鑄
        let input = <ucPascal>Input(/* business fields from Input signature */, operatorId: operatorId)
        let output = try await <ucPascal>Service(repository: repository).execute(input: input)
        #expect(output.id == <aggId>)
        let aggregate = try #require(try await repository.find(byId: <aggId>))
        #expect(/* 從 §6 happy Then 機械可斷的欄位 */)
    }
}
```
- create-happy（含 **derived-payload**）一律 emit enabled。derived-field 的 create-init 會丟 `GenesisTODO`（經 catch-ladder 原樣傳出）→ R-SUT 紅直到 `/domain-fill`。
- **例外**：create UC 若 payload ⊆ input（無 derived field），designated init 是機械 live + ensureInvariant no-op → 此 happy test **立即綠、零 domain 填**。若該 create 有 create-time invariant，它**不被** happy path 抵 —— 由它自己的 **Lane-B error test**（帶 live `#expect(throws:)`）擔。
- **非 create UC 的 happy path** 需先呼叫 create UC 的 **codegen'd fixture**（名 = 該 create UC 的 ucCamel，如 `createX`）鋪「aggregate 已存在」→ 屬 JUDGMENT lane（fixture 是 Given）。

**aggregate-not-found**（全機械、無 Given）：不存在的 id → 統一 value-capture（見「錯誤模板統一」）：
```swift
@Test func `<not found scenario>`() async throws {
    try await withTestBundle(client: kdbClient) { bundle in
        let <aggId> = await bundle.generateAggregateRootId(for: <A>.self)
        let operatorId = await bundle.generateId(for: "operatorId")
        let input = <ucPascal>Input(/* 用 <aggId> 等，aggregate 不存在 */, operatorId: operatorId)
        let usecase = <ucPascal>Service(repository: repository)
        let error = await #expect(throws: DDDError.self) {
            let _: <ucPascal>Output = try await usecase.execute(input: input)
        }
        #expect(error?.code == .aggregateNotFound)
    }
}
```

### Lane B — JUDGMENT（live assertion envelope + thunk 洞，2-stage R-ARRANGE → R-SUT → 綠）

**input-value error**：envelope live、洞在 Given+input：
```swift
@Test func `<error scenario name>`() async throws {
    // test-gen-scenario-id: <id-if-available>
    try await withTestBundle(client: kdbClient) { bundle in
        // GENESIS-ARRANGE: author the Given(fixture+args) and the input value that trips <code 非點形式>
        let input: <ucPascal>Input = try genesisTODO("GENESIS-ARRANGE: <ucPascal> input tripping <code 非點形式>; call <fixtureName>(…, repository: repository) first if prior-state needed")
        let usecase = <ucPascal>Service(repository: repository)
        let error = await #expect(throws: ContextError<<A>Error>.self) {
            let _: <ucPascal>Output = try await usecase.execute(input: input)
        }
        #expect(error?.error == .<§5 errorCode>)   // ← live, enabled；coverage 由它賺
    }
}
```

**act-sequence / prior-state（sequence-shaped，不可塌成 single-input thunk）**：trip 在「重複」或「前置狀態」而非單一壞欄位 → emit 結構骨架（例 duplicate：execute 兩次）：
```swift
@Test func `<duplicate scenario>`() async throws {
    try await withTestBundle(client: kdbClient) { bundle in
        let input: <ucPascal>Input = try genesisTODO("GENESIS-ARRANGE: input + the prior call(s) that make the 2nd execute trip <code 非點形式>")
        let usecase = <ucPascal>Service(repository: repository)
        let _: <ucPascal>Output = try await usecase.execute(input: input)   // 第一次（成功的前置）
        let error = await #expect(throws: ContextError<<A>Error>.self) {
            let _: <ucPascal>Output = try await usecase.execute(input: input)   // 第二次（觸發）
        }
        #expect(error?.error == .<§5 errorCode>)
    }
}
```
prior-state 同理：emit「前置 fixture call(s) 留 thunk + 目標 execute + envelope」的 ordered 骨架。**絕不**對 act-sequence/prior-state emit single-execute body（那是更逼真的謊：編得過、跑得動、甚至會紅）。

**positive-arrange 守則（非-create Lane-B）**：人**填 Given 時**（在 `.authored.swift`），須在 fixture arrange 後、triggering execute 前加：
```swift
_ = try #require(try await repository.find(byId: <aggId>))
```
理由：`error?.error == .code` 只擋「丟到別的 ContextError code」與「丟 DDDError 型別不符」；它**不擋**「arrange 沒生效 / aggregate 根本不存在 → SUT 因 aggregateNotFound 等 wrong-shape 丟」偽裝成目標 invariant。positive-arrange `#require` 讓 mis-arrange 大聲失敗。emit 時在 thunk 訊息提示此守則。

## 洞表示（universal hole form）

- **typed throwing thunk**：`let <name>: <Type> = try genesisTODO("GENESIS-ARRANGE: …")`。type-complete（bound var 帶具體型別 → 後面 member access / 傳入 closure 都 type-check）+ runtime 乾淨 throw（不 crash）。
- **訊息規則**：以 `GENESIS-ARRANGE:` sentinel 開頭（greppable，`swift test`-only 讀者可分辨「scaffold 洞」vs「真失敗」）+ 要 dictate 什麼（fixture 名、序列、觸發值）。**絕不含字面 `.<errorCode>` token**（用非點形式）。
- **絕不 `fatalError`**。
- helper `genesisTODO<T>` 定義在 test target（見 GenesisTestSupport.swift）。
- **fixture 名 = 前置 UC 的 ucCamel**（thunk 訊息的 `<fixtureName>` 即 `CaseTransformer.lowerCamel(useCase)`，如 `createX`/`editX`）—— 由 **FixtureRenderer 在 `genesis new` 已 codegen** 到 `Tests/<Ctx>Tests/SharedUtility/UsecaseCall/<A>.swift`。thunk 訊息引用該名即可；test-gen **只 consume（呼叫）fixture，不 emit / 不 author bare wrapper**。

## 錯誤模板統一（D4）

單一 value-capture 模板，依 `(error-type, member-path, expected-case)` 套：
- invariant：`#expect(throws: ContextError<<A>Error>.self){…}` + `#expect(error?.error == .<§5 code>)`。
- infra not-found：`#expect(throws: DDDError.self){…}` + `#expect(error?.code == .aggregateNotFound)`（`DDDError` 不需 Equatable，`.code` 是可比 enum；OC 也有 predicate-closure 形 `await #expect(performing:throws:)` 作 optional alternate）。

## GenesisTestSupport.swift（共用支援檔，首跑建、idempotent）

`Tests/<contextName>Tests/GenesisTestSupport.swift`：
```swift
import Testing
import <A>Aggregate     // GenesisTODO（package enum）在 aggregate module，同 package test target 可見

/// Genesis test-arrange hole. An enabled test calling this is RED (throws) until you author the real
/// arrange in <UC>Tests.authored.swift. genesis verify flags any genesisTODO( left in an enabled @Test.
func genesisTODO<T>(_ message: String) throws -> T { throw GenesisTODO.notImplemented(message) }

extension Tag { @Tag static var <agg>: Self }
```
- `func`（plain/internal）即可——只在 test target 內用。**不可放 Sources/**（其 body 含 `GenesisTODO.notImplemented`，會被 `genesis verify` 的 Sources marker grep 永久誤報）。
- **單一 aggregate import**：`GenesisTODO` 是 **per-aggregate** 的 `package enum`（codegen 每個 aggregate module 各一份）。此共用檔只 `import` **一個** `<A>Aggregate`；若專案多 aggregate **不要**在此檔加第二個 `import <B>Aggregate`（會 `ambiguous use of 'notImplemented'` → 整 test target 編不過）。thunk 丟哪個 aggregate 的 `GenesisTODO` 無所謂（它在 test-function 層 throw，永遠到不了任何 execute() catch-ladder）。真要多 import 就 module-qualify：`throw <A>Aggregate.GenesisTODO.notImplemented(message)`。
- **idempotent**：已存在 → 只 **append 缺的 `@Tag static var <agg>`**（多 aggregate 共用此檔；**只加 tag-decl，不加 import**），不重複宣告、不覆寫 helper。

## catch-ladder grep-pin（INVARIANT，emit 後驗）

R-SUT 乾淨紅依賴 `<UC>Service.execute` 把 `GenesisTODO` 原樣傳出。這條 catch-ladder 在 **`Sources/<A>Aggregate/Usecase/Port/In/<ucPascal>/<ucPascal>Usecase.swift`**（execute 是 Usecase protocol-extension body）—— **不是** `<ucPascal>Service.swift`（後者只是 repository+init 的 thin conforming struct）。emit 後以 grep 斷言該檔含：
```
catch let error as GenesisTODO
```
且它在 catch-all（`catch { throw DDDError.executeUsecaseFailed }`）**之前**。若缺 / 順序錯 → 警告：「R-SUT 紅會被包成 opaque DDDError，error test 的 #expect(throws: ContextError) 反而遮住洞 —— 需先修 codegen / 重生」。**不自行修改該檔**（codegen 範疇）。

## Phase 2 — emit `.generated.swift`（machine-owned，全重生）

> **互斥前置（two-file 載重點）**：先讀 `.authored.swift`（若存在）既有 `@Test func` 名集合 = `authoredNames`（只讀不寫）。emit 時 **§6 scenario 名 ∈ `authoredNames` 的一律跳過**（human 已接管），避免兩檔重複 emit / 編譯衝突。

組裝：@Suite 骨架 + 每個 §6 scenario 依 2-lane 規則 emit enabled `@Test`。整檔一次寫入。確保（emit 前自檢）：
- 每個 §5 invariant errorCode 都有**一個 enabled** test 帶 live `#expect(error?.error == .<code>)`（讓 `genesis verify` 算覆蓋）。
- JUDGMENT lane test 的洞是 `genesisTODO("GENESIS-ARRANGE: …")`、訊息無字面 `.code`。
- 無 `.disabled` 預設 lane、無以 emit-line 形式出現的舊式 placeholder 結構。

## Phase 3 — `.authored.swift`（human-owned，機器永不覆寫）

- **不存在** → 建**空殼**（只一次）：
  ```swift
  // Human-authored tests. /test-gen NEVER overwrites this file.
  // 把 JUDGMENT lane 的 Given 填在這裡：複製對應 scenario（同名函數）過來，把 genesisTODO("GENESIS-ARRANGE: …")
  // 洞換成真 arrange（鑄 id + 呼叫 codegen'd fixture，如 createX(…, repository: repository) + 建 Input + positive-arrange #require）。
  // fixture 由 FixtureRenderer 於 `genesis new` 已 codegen 到 Tests/<Ctx>Tests/SharedUtility/UsecaseCall/<A>.swift
  // （名 = UC 的 ucCamel）；test-gen / 你只 consume（呼叫），不 author bare wrapper。要 ergonomic preset 才手寫 sibling <A>Fixtures.presets.swift。
  import Testing
  import DDDKit
  import KurrentDB
  import TestUtility
  import <contextName>

  @Suite(.serialized, .tags(.<agg>))
  struct <ucPascal>AuthoredTests {
      let kdbClient: KurrentDBClient = .init(settings: .localhost())
      let repository: <A>Repository
      init() {
          self.repository = <A>Repository(coordinator: .init(client: kdbClient, eventMapper: <A>AggregateEventMapper()))
      }
      // 例：把某個 §6 @error scenario 的真 test 填在這裡，函數名與 §6 scenario 同名。
  }
  ```
- **已存在** → **完全不動**，只讀 `authoredNames` 供 Phase 2 互斥跳過。

## Phase 4 — reconcile 報告（一般跑 + `--regen` 皆印）

對照 §6 scenario 集合 vs `authoredNames`，印**報告**（**絕不**寫 `.authored.swift`）：

| 情況 | 判定 | 處理 |
|------|------|------|
| **pending** | §6 有、`authoredNames` 無 | `.generated.swift` 為 enabled-red（MECHANICAL R-SUT / JUDGMENT R-ARRANGE）；計數 |
| **authored** | §6 有、`authoredNames` 有 | `.generated` 跳過該 scenario（Phase 2 互斥）；計數 |
| **orphaned** | `authoredNames` 有、§6 無對應 | 報告「§6 已移除該 scenario，**不刪**你的 authored test，請人工確認」|

印 summary：`<N> pending / <M> authored / <K> orphaned`，並提醒：
- 新生成 test 是**紅**的（MECHANICAL: R-SUT；JUDGMENT: R-ARRANGE），這是正常 pre-fill 狀態。
- 下一步：`/domain-fill` 填 domain（清 R-SUT 紅）；JUDGMENT lane 的 Given 手動 author 到 `.authored.swift`（清 R-ARRANGE 紅）。
- `genesis verify` 會擋殘留洞（Sources marker / 未覆蓋 invariant / test-side genesisTODO thunk）。

## Framework constraints（沿用，不可破壞）

- **Swift Testing（非 XCTest）**：`import Testing` + `@Suite` / `@Test` / `#expect` / `#require`。隨 Swift 6.0+ toolchain ship，generated Package 無需額外 package 依賴。
- **`withTestBundle`** 來自 DDDKit `TestUtility` product（generated Package test target 須依賴它，Phase 1.s 已在 codegen 加入）。
- **`<A>AggregateEventMapper`** 由 DDDKit build plugin 生成、`package` access、同 package test target 可見。
- **`GenesisTODO`** 是 aggregate module 的 `package enum`（同 package test target 可見）；`genesisTODO<T>` thunk helper 在 test target 包它。
- **real KurrentDB 是硬 prerequisite**：enabled test 都會跑（沒 .disabled 吸收）→ 無 DB 時整 suite 紅、與 R-SUT/R-ARRANGE 紅不可分。文件化為 dev/CI prerequisite，**不**引 in-memory。

## 與其他 skills 的關係

- 上游：`/bundle-plan` 產的 per-UC task spec（§6 是 human-confirmed intent — test-gen 的 source of truth）。
- sibling：`/usecase` / `/api`（fill execute body）/ `/domain-fill`（填 domain 洞，清 R-SUT 紅）。test-gen 與它們**分流**，只產 test 檔、不呼叫它們。
- 下游：human 在 `.authored.swift` 補 JUDGMENT lane 的 Given（fixture 編排 + 觸發值 + positive-arrange）；`/domain-fill` 填 domain；跑 `swift test`（需 localhost KDB）；`genesis verify` 當 release/CI gate。
- 後續（未在本 skill）：`/fill-given`（互動 elicitation 秘書，mirror /domain-fill，把人口述的 Given transcribe 進 `.authored`）、`/fixture-gen`（機械生 bare fixture wrapper）—— 皆 defer。
