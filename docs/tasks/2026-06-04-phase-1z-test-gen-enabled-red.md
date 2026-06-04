# Phase 1.z — test-gen 真 test（enabled-red 2-lane）+ genesis verify FIX-1/FIX-2

## 來源

討論：`docs/discussions/2026-06-03-test-gen-real-test-redesign.md`（R2 consensus + **Round 3 post-Phase-1.y 再驗證**，adversarial workflow 3 lens + 實測 swiftc 6.2.3）。Round 3 裁決：R2 的「fill-state ladder + fatalError-thunk + disabled-until-filled」被 1.y 翻掉（GenesisTODO 編得過 / genesis verify 排除 .disabled）→ reframe 成 **runtime-red ladder**，**HOLDS 但有 3 個強制 honesty fix（FIX-1/2/3）**。currently-shipped `test-gen/SKILL.md` 已對 1.y 壞掉（emit .disabled → genesis verify 整批判 uncovered）→ 本 phase 是**修復 + 升級**。

## 目標

把 test-gen 從「空殼 scaffold（~3% runnable，其餘 .disabled）」升級成 **enabled-red 真 test**：每個 §6 scenario emit 一個 **enabled、編得過、跑起來紅**的 test，紅在對的地方，逐 usecase 增量 TDD（紅→填→綠），對齊 user 心智模型（event-storming → genesis new → 寫不變量 → 看 test 紅 → 填 → 綠）。honesty 靠 `genesis verify`（兩個正交 gate），不靠 `.disabled`。

**v1 user 拍板**：現在就 ship（id-placeholder workaround，不 block bundle-plan stable-id）；**不**做 KDB oracle；**不**做 /fixture-gen（獨立 sibling defer）。

## 載重事實（Round 3 親驗，spec 依賴；swiftc 6.2.3 + 真 SwiftPM Testing target）

1. **typed throwing thunk 編得過 + 乾淨紅**：`let input: <UC>Input = try genesisTODO("…")`（或 `try { throw GenesisTODO.notImplemented("…") }()`）type-complete（bound var 帶具體型別，後面 `input.field` member access type-check 過）**且** runtime throw 乾淨傳出（不 crash）。**對照**：`let input: X = { fatalError("…") }()` 在 enabled test 跑到 → **SIGABRT exit 133 殺整 runner**。→ `fatalError → throwing-GenesisTODO` **強制，非裝飾**。
2. **洞必須是 typed value**：bare `throw` 在前、後面引用未宣告符號 → `cannot find input in scope`（Codex 舊發現存活 1.y）。
3. **R-SUT 乾淨紅**：`#expect(throws: ContextError<<A>Error>.self){ execute }` 收到 GenesisTODO → `expected ... ContextError<...> but notImplemented of type GenesisTODO thrown instead`；value-capture `error?.error` 為 nil。correct-type 才綠。
4. **catch-ladder 把 GenesisTODO 原樣傳出**：`UseCaseRenderer.buildExecuteBody` 的 `} catch let error as GenesisTODO { throw error }` 在 catch-all 之前（1.y shipped）→ command/when/create-init 丟的 GenesisTODO **型別活著穿過 execute 到 test**。**catch-ladder 在 `Sources/<A>Aggregate/Usecase/Port/In/<UC>/<UC>Usecase.swift`**（execute 是 Usecase protocol-extension 的 body）—— **不是** `<UC>Service.swift`（後者由 `Service.swift.template` 生，只有 repository + init 的 thin conforming struct，無 execute body / 無 catch）。**spec INVARIANT**：test-gen SKILL 須以 grep 斷言這條 ladder 順序、且 grep 對的檔（`<UC>Usecase.swift`，**非** `<UC>Service.swift`）（若被 reorder，R-SUT 紅會悄悄變成 opaque DDDError，所有 error test 的 `#expect(throws: ContextError)` 反而遮住洞）。
5. **DDDError value-capture 無需 Equatable**：`let error = await #expect(throws: DDDError.self){…}; #expect(error?.code == .aggregateNotFound)` 通過（`.code` 是可比 enum）→ D4 的 ContextError 與 DDDError 兩分支**統一**成同一 value-capture 模板。
6. **`package GenesisTODO` 對同 package test target 可見**（SE-0386；build+link+run 驗）。
7. **genesis verify 兩個 honesty 漏洞**（本 phase 修）：`referencesCode` **非 string-literal-aware**（VerifyChecker.swift:104 自承）；marker 掃描 **Sources/ only**（VerifyChecker.swift:34）。
8. **未宣告 `@Tag` → 整 target 編不過**（無 .disabled 吸收 → 比舊世界更嚴）→ tag-decl emission 強制。

## 介面合約（Interface Contract）

### 2-lane emit 規則（取代 D1 3-tier / D3 3-template）

emit 決策是 **2-way**（非 3 body-template）：

| Lane | scenario | emit | 紅 stage |
|---|---|---|---|
| **A MECHANICAL** | create-happy（含 derived-payload）、aggregate-not-found | **full enabled body**，無 judgment 洞 | 1-stage（R-SUT）→ 綠 |
| **B JUDGMENT** | input-value error、act-sequence error、prior-state error | **assertion envelope + typed-throwing-thunk 洞**，**絕不** fabricated act body | 2-stage（R-ARRANGE → fill-given → R-SUT）→ 綠 |

**Lane A — create-happy**（OC `CreateAuditQuotingUsecaseTests` 形）：`withTestBundle{ bundle in }` + `bundle.generateAggregateRootId(for: <A>.self)` / `generateId(for:)` 鑄 id → `<UC>Input(business fields…, operatorId:)` → `<UC>Service(repository:).execute(input:)` → `#expect(output.id == <aggId>)` → `let agg = try #require(try await repository.find(byId: <aggId>))` → §6 happy Then 機械可斷的 state assert。R-SUT 紅（execute 丟 GenesisTODO）直到 domain 填。**例外（明文）**：create UC 若 **payload ⊆ input（無 derived field）**，designated init 是機械 live + ensureInvariant no-op → create-happy **立即綠、零 domain 填**；若該 create 有 create-time invariant，它**不被** happy path 抵 —— 由它自己的 **Lane-B error test**（帶 live `#expect(throws:)`）擔。

**Lane A — aggregate-not-found**（全機械、無 Given）：不存在的 id → 統一 value-capture：`let error = await #expect(throws: DDDError.self){ let _: <UC>Output = try await usecase.execute(input: input) }; #expect(error?.code == .aggregateNotFound)`（predicate-closure 為 optional alternate，非必須）。

**Lane B — input-value error**：emit envelope live、洞在 Given+input：
```swift
@Test func `<scenario name>`() async throws {
    try await withTestBundle(client: kdbClient) { bundle in
        // GENESIS-ARRANGE: dictate Given(fixture+args) and the input value that trips <code, 非點形式>
        let input: <UC>Input = try genesisTODO("GENESIS-ARRANGE: <UC> + value tripping <code 非點形式>; call <fixtureName>(…) first if prior-state needed")
        let usecase = <UC>Service(repository: repository)
        let error = await #expect(throws: ContextError<<A>Error>.self) {
            let _: <UC>Output = try await usecase.execute(input: input)
        }
        #expect(error?.error == .<§5 errorCode>)   // ← live, enabled；coverage 由它賺，非 thunk 字串
    }
}
```

**Lane B — act-sequence / prior-state（FIX-3：sequence-shaped，不可塌成 single-input thunk）**：emit 結構骨架（例 duplicate）：
```swift
@Test func `<duplicate scenario>`() async throws {
    try await withTestBundle(client: kdbClient) { bundle in
        let input: <UC>Input = try genesisTODO("GENESIS-ARRANGE: input + the prior call(s) that make the 2nd execute trip <code 非點形式>")
        let usecase = <UC>Service(repository: repository)
        let _: <UC>Output = try await usecase.execute(input: input)   // 第一次（成功的前置）
        let error = await #expect(throws: ContextError<<A>Error>.self) {
            let _: <UC>Output = try await usecase.execute(input: input)   // 第二次（觸發）
        }
        #expect(error?.error == .<§5 errorCode>)
    }
}
```
prior-state 同理 emit「前置 fixture call(s) 留 thunk + 目標 execute + envelope」的 ordered 骨架。**unknown locus → Lane B thunk（forced，絕不 fabricated body）**。

**positive-arrange 守則（D5b，存活）**：非-create 的 Lane-B error test 在**填 Given 時**（人手 author 或後續 /fill-given），須在 fixture arrange 後、triggering execute 前加 `_ = try #require(try await repository.find(byId: <aggId>))`。理由：`error?.error == .code` 只擋「丟到別的 ContextError code」（adjacent collision）與「丟 DDDError 型別不符」；它**不擋**「arrange 沒生效 / aggregate 根本不存在 → SUT 因 aggregateNotFound 等 wrong-shape 理由丟」偽裝成目標 invariant。positive-arrange `#require` 讓 mis-arrange **大聲失敗**。v1 emit 的 scaffold 在 thunk 訊息提示此守則；materialize Given 時落實。（D5b 在 Round 3 保留〔disposition「(b)(c)(d) 存活」〕。）

### @Suite 骨架（保留自現行 SKILL Phase 2，每檔必 emit）

每個 `<ucPascal>Tests.generated.swift` / `.authored.swift` emit 的 suite struct（缺則 test 編不起來）：
```swift
@Suite(.serialized, .tags(.<agg>))
struct <ucPascal>Tests {
    let kdbClient: KurrentDBClient = .init(settings: .localhost())
    let repository: <A>Repository
    init() {
        self.repository = <A>Repository(coordinator: .init(client: kdbClient, eventMapper: <A>AggregateEventMapper()))
    }
    // … @Test funcs（Lane A full body / Lane B envelope+thunk）…
}
```
`.serialized`（共享一台 localhost KDB 必序列化）+ `.tags(.<agg>)`（須先在 GenesisTestSupport.swift emit tag-decl，見下）。`<A>AggregateEventMapper` 由 DDDKit build plugin 生、package access、同 package test target 可見。

### 洞表示（universal hole form）

- **free-func thunk helper**（FIX-1：用 **lowercase** `genesisTODO(` 形，避開 Sources marker grep 的 `GenesisTODO.notImplemented` PascalCase-dot；**定義在 test target**。modifier 用 **plain/internal `func`**（非 `package`）—— 只在 test target 內用，test target 不被依賴，internal 足夠；audit 實證 `package`/internal 皆編得過、`package` 只是多餘 scope）：
  ```swift
  /// Genesis test-arrange hole. An enabled test calling this is RED (throws) until you author the real
  /// arrange (hand-author in <UC>Tests.authored.swift, or a future /fill-given skill).
  /// genesis verify flags any genesisTODO( call left in an enabled @Test as a remaining test-side hole.
  func genesisTODO<T>(_ message: String) throws -> T { throw GenesisTODO.notImplemented(message) }
  ```
- **thunk 訊息（FIX-1 強制）**：以 `GENESIS-ARRANGE:` sentinel 開頭（greppable，`swift test`-only 讀者可分辨「scaffold 洞」vs「真失敗」）+ locus hint + 需要的 fixture 名；**絕不含字面 `.<errorCode>` token**（用非點形式如 `tripping duplicateServiceItemId`）。
- **絕不 fatalError**（載重事實 1）。

### 錯誤模板統一（D4）

單一 value-capture 模板，參數化 `(error-type, member-path, expected-case)`：
- invariant：`ContextError<<A>Error>` / `.error` / `.<§5 code>`。
- infra not-found：`DDDError` / `.code` / `.aggregateNotFound`。

### Tag 註冊（D5d 強制）

emit `@Suite(.serialized, .tags(.<agg>))` 的同時，於 test target emit（idempotent，缺才補）：
```swift
import Testing
extension Tag { @Tag static var <agg>: Self }
```
（多 aggregate：append 缺的 tag，不重複宣告。）

### test-target 支援檔（SKILL 首跑 emit，idempotent）

`Tests/<contextName>Tests/GenesisTestSupport.swift`：`genesisTODO<T>` helper + `extension Tag`。**只 emit 在 test target**（FIX-1：放 Sources 會被 marker grep 永久誤報）。已存在 → 只補缺的 Tag，不覆寫。

### 兩檔分離（D8，保留）

- `Tests/<ctx>Tests/<ucPascal>Tests.generated.swift`：機器擁有，整檔重生，**plain enabled tests（無 .disabled / 無 Issue.record）** —— Lane A full body / Lane B envelope+thunk。
- `Tests/<ctx>Tests/<ucPascal>Tests.authored.swift`：人擁有，機器**永不覆寫**（`--regen` 只 reconcile 報告）。人（手 author Lane-B Given，或後續 /fill-given）把填好的 scenario 寫這、`.generated` 以 scenario-id 互斥跳過。
- reconcile key：scenario 名（title-derived）+ 每 stub `// test-gen-scenario-id:` placeholder（bundle-plan emit 真 id 前禁 rename func 名）。

### genesis verify 強化（real Swift code，本 phase 的機器可驗核心）

**新 helper `stripStringLiterals(_:)`**：剝除 `"..."` 字串字面（比照既有 `stripComments`，非 string-literal-aware 是 VerifyChecker.swift:104 自承的 residual）。**須在三處套用**（audit 實證：只套 referencesCode 不夠）：
- (i) **`.disabled` 排除檢查之前**（region 傳走前）—— 否則 thunk 訊息含 token `.disabled`（如 `genesisTODO("…account .disabled trips foo")`）會讓**整個 enabled @Test 段被誤判為 disabled 而 silently 丟掉** → 連帶吃掉它的 FIX-2 洞與 FIX-1 coverage。剝字串後該 region 不再被誤排除，而真的 `@Test(.disabled(...))` attribute（裸 code 非字串）仍被偵測。
- (ii) **`referencesCode` 比對 `.<code>` 之前**（FIX-1 coverage）—— thunk 訊息/註解裡的 `.code` token 不算 coverage，coverage 只由 live assertion 賺。
- (iii) **FIX-2 `genesisTODO(` / `GenesisTODO.notImplemented` hole 比對之前** —— 字串裡提到 `genesisTODO(`（如文件字串）不算 live 洞；真的 `try genesisTODO("…")` 呼叫仍算。

**FIX-2 — Tests-side 洞 gate**：`VerifyChecker.Result` 加 `remainingTestHoles: [Hole]`。`Hole` 只有 `file` + `snippet`（無 line 欄位）→ **不能直接 reuse `enabledTestRegions`**（它回 `[String]`、在 loop 內丟掉 URL）→ **新增 file-retaining traversal**（如 `remainingTestHoles(in testsRoot)`：iterate `swiftFiles`、留 rel-path、`stripComments` 後 `stripStringLiterals`、以 `@Test` 切段、drop `.disabled` 段、收非註解的 `genesisTODO(` / `GenesisTODO.notImplemented` 行成 `Hole(file:snippet:)`）。可選：把 `enabledTestRegions` 重構成共用 `[(file, region)]` core 供 coverage 與 hole-scan 共用。`passed` = `remainingMarkers.isEmpty && uncoveredInvariants.isEmpty && remainingTestHoles.isEmpty`。`VerifyCommand` 分類列印 + exit 2。
（`genesisTODO<T>` 的**定義**是 free-func 非 @Test 段、且在 GenesisTestSupport.swift〔零 @Test 段〕→ 不被計；helper 在 Tests/ → 不被 Sources marker grep 計。）

### 不變（不碰）

- test-gen 是 **SKILL，非 codegen**（無 TestRenderer）。
- 不 fill execute/domain body、不呼叫 `/usecase` `/api` `/domain-fill`、不跑 `swift test`。**firewall（精確界線）**：**可讀** `<UC>Input` / `<UC>Service` / `<UC>Output` 的**型別 signature**（怎麼 call —— 建構 Input 要哪些 field、Service 怎麼 init、Output 拿哪些欄位）；**不讀** `execute()` body 的 branch/catch 當 expected behavior（否則 test 變成 re-confirm impl 非 spec）。assertion 來自 task spec §5/§6，呼叫機制來自 type signature。
- 真 localhost KurrentDB test 模型（D9，不引 in-memory）。
- 1.y 的 GenesisTODO/catch-ladder/genesis verify 既有行為（只**擴**，不改既有語意）。

## 改動檔案

| 檔案 | 改動 | 步 |
|---|---|---|
| `Sources/GenesisCore/VerifyChecker.swift` | helper `stripStringLiterals`（套於 (i) `.disabled` 排除前 (ii) `referencesCode` 比對前 (iii) FIX-2 hole 比對前）；FIX-2（`Result.remainingTestHoles` + 新 file-retaining `remainingTestHoles(in:)` traversal〔不 reuse `enabledTestRegions`，它丟檔名〕 + `passed` 納入）| 1,2 |
| `Sources/Genesis/Commands/VerifyCommand.swift` | 列印 `remainingTestHoles` 類別 + 任一非空 exit 2 | 3 |
| `Tests/GenesisCoreTests/VerifyCheckerTests.swift` | +FIX-1 regression（字串內 `.code` 不算 cover）；+FIX-2 regression（Tests/ enabled @Test 內 `genesisTODO(` → remainingTestHoles；comment/disabled 內不算）| 1,2 |
| `Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md` | **全重寫**：2-lane enabled-red + throwing-thunk + FIX-1 字串規則 + FIX-3 sequence-shape + D4 統一模板 + Tag/GenesisTestSupport emission + 兩檔 + id-placeholder reconcile + firewall + green-verify+red-test 文件 + catch-ladder grep-pin | 4 |
| `Sources/GenesisCore/Resources/Templates/v0.1/CLAUDE.md.template` | 加「`genesis verify` 須接 CI（honesty 收斂到它）；`verify` 在開發全程紅（Sources marker / test-side Given 洞 / 未覆蓋 invariant 任一在即紅），全填才綠；verify 綠後 `swift test` 仍紅 = Given 語意錯（查 --fill-given provenance）或 KDB down」| 5 |
| `Sources/GenesisCore/Resources/Templates/v0.1/README.md.template` | **無條件**新增 `## Verify (CI gate)` 段（現行 README 無 verify 段 → 不可條件式跳過，否則 CI-gate 要求只剩 CLAUDE.md 一處，與「已知限制」矛盾）| 5 |
| `Tests/GenesisCoreTests/SkillInstallerTests.swift` | skill 數不變則不動（test-gen 仍是同一 skill）| — |

## 實作步驟（ordered）

1. **STEP 1** VerifyChecker：加 `stripStringLiterals(_:)`；套於 **(i) `.disabled` 排除檢查前**（region 傳走前）+ **(ii) `referencesCode` 比對 `.<code>` 前**。+ VerifyCheckerTests：`testStringLiteralCodeDoesNotCover`（enabled test 只有 `genesisTODO("… .badCode …")` 字串、無 live assertion → uncovered）、`testThunkMessageWithDisabledTokenNotFalseExcluded`（thunk 訊息含 token `.disabled` → 該 enabled @Test 段仍被掃〔coverage + hole〕、不被誤排除；真 `@Test(.disabled(...))` 仍排除）。
2. **STEP 2** VerifyChecker FIX-2：`Result` 加 `remainingTestHoles: [Hole]`；**新 file-retaining traversal `remainingTestHoles(in:)`**（iterate `swiftFiles` 留 rel-path、`stripComments` + `stripStringLiterals`、`@Test` 切段、drop `.disabled` 段、收非註解 `genesisTODO(`/`GenesisTODO.notImplemented` → `Hole(file:snippet:)`）—— **不**直接 reuse `enabledTestRegions`（回 `[String]` 丟檔名）；`passed` 納入。+ VerifyCheckerTests：`testEnabledTestHoleFlagged`（enabled @Test 內 `genesisTODO(` → remainingTestHoles 含之）、`testDisabledOrCommentedHoleNotFlagged`、`testStringLiteralGenesisTODOMentionNotFlagged`（字串裡提 `genesisTODO(` 不算洞）。
3. **STEP 3** VerifyCommand：分段列印 markers / uncovered invariants / **test holes**；任一非空 → exit 2。
4. **STEP 4** test-gen SKILL.md 全重寫（上面介面合約全納入：2-lane / throwing-thunk / FIX-1 字串規則 / FIX-3 sequence-shape / D4 統一模板 / **@Suite 骨架 recipe** / Tag-decl + GenesisTestSupport emission / positive-arrange 守則(D5b) / 兩檔 / id-placeholder reconcile / catch-ladder grep-pin 對 `<UC>Usecase.swift`；刪除舊 .disabled+Issue.record 模型 §；保留輸入解析 / 名稱推導 / Phase 0 讀 task spec / firewall〔讀 signature 不讀 execute body〕）。
5. **STEP 5** docs sync：CLAUDE.md.template（verify 全程紅→全填綠、CI gate）+ **README.md.template 無條件加 `## Verify (CI gate)` 段**。
6. **STEP 6** 驗證：`swift build` + `swift test` 全綠（含新 VerifyChecker 測）；手刻一個 enabled-red 測 fixture（envelope+thunk）餵 VerifyChecker 確認 FIX-1（字串不算 cover）/ FIX-2（thunk 洞被抓）行為對。

## 失敗路徑 / 行為表

| 條件 | 行為 |
|---|---|
| 生成的 enabled test、domain 未填 | R-SUT 紅（execute 丟 GenesisTODO，`#expect(throws: ContextError)` 失敗）;增量 TDD ✓ |
| Lane B test、Given 未填（thunk 在） | R-ARRANGE 紅（thunk throw，`GENESIS-ARRANGE:` 訊息）;`genesis verify` 報 remainingTestHoles(FIX-2) |
| Given 填好（手 author 或後續 /fill-given）、domain 未填 | R-SUT 紅（非綠）—— 乾淨 red→red→green TDD |
| enabled test 只有字串內 `.code`、無 live assertion | `genesis verify` **不**算 cover（FIX-1）→ uncoveredInvariants 報之 |
| no-derived create-happy | 立即綠（mechanical init + no-op ensureInvariant）;create-time invariant 由自己的 Lane-B test 擔 |
| 未宣告 @Tag | 整 target 編不過 → SKILL 強制 emit tag-decl |
| KDB down | 全 suite 紅（與 R-SUT/R-ARRANGE 紅不可分）—— v1 接受 + 文件標（KDB hard prereq）|

## 不改動 / Non-goals（v1 邊界，user 已拍板）

- **/fill-given 互動 elicitation skill**：v1 **不做**（mirror /domain-fill 的 transcription-only secretary）。v1 = test-gen **emit** enabled-red 2-lane scaffold；Lane-B 的 Given 由人**手動 author 在 `.authored.swift`**（thunk 的 `GENESIS-ARRANGE:` 訊息指引要 dictate 什麼、要呼叫哪個 fixture、要加 positive-arrange #require）。`genesis verify` FIX-2 擋未填的 thunk。/fill-given（AskUserQuestion 秘書 + causal-why provenance）為後續 phase。
- **KDB-run oracle**：v1 **不做**（Q1 defer）。靠人審 Lane-B Given（手 author 時記錄為何此值/此序觸發此 invariant）。revisit 為 post-/domain-fill confirmation gate。
- **/fixture-gen**：v1 **不做**（獨立 sibling defer；standalone vs --fixtures submode 之後再決定 = Q3）。v1 只在 thunk 訊息 emit「需要但不存在的 fixture 名」placeholder（fail-loud，不合成）。
- **bundle-plan stable scenario-id**：v1 **不做**（Q4 ship-now；用 title + id-placeholder workaround）。
- **read-model / query / projection test lane**：defer（scope = usecase/application layer）。
- **adapter/Api/Presenter-layer 洞**（仍 `fatalError("TODO(/api skill)")`，由 /api /presenter-fill 填）：out of scope。
- `@Test(arguments:)` parameterization：v1 emit 單一代表 case + `// GENESIS-TODO: parameterize` marker（不靜默 under-cover）。
- **不**改 1.y 既有 GenesisTODO/catch-ladder/ensureInvariant 行為（只擴 genesis verify）。

## 驗收標準

### Agent 必做（機器可執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test 2>&1 | tail -5   # 全 pass（含新 VerifyChecker FIX-1/FIX-2 regression）

# FIX-1：thunk 字串內 .code 不算 cover（單測斷言）
# FIX-2：enabled @Test 內 genesisTODO( → remainingTestHoles（單測斷言）

# SKILL self-consistency（重寫後）：
SK=Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md
grep -q 'genesisTODO' "$SK"                        # throwing-thunk 形在
# 負向 grep 用 line-scoped（^\s*）—— prose 可提舊 model 名（如解釋「本版移除 @Test(.disabled)+Issue.record」），
# 只禁它們以 emit-template 行出現（audit 實證 blanket negative 會 false-fail 忠實重寫）：
! grep -qE '^\s*Issue\.record\(' "$SK"             # 不以 Issue.record 當 emit lane（prose 提及 OK）
! grep -qE '^\s*@Test\(\.disabled' "$SK"           # 不以 .disabled 當預設 emit lane（prose 提及 OK）
grep -q 'catch let error as GenesisTODO' "$SK"     # catch-ladder grep-pin invariant 文件化
grep -q 'Usecase.swift' "$SK"                      # catch-ladder grep-pin 指向對的檔（<UC>Usecase.swift 非 <UC>Service.swift）
grep -q 'GENESIS-ARRANGE' "$SK"                    # sentinel 訊息規則在
grep -q 'GenesisTestSupport' "$SK"                 # helper emission 在
grep -qE 'AggregateEventMapper|@Suite\(\.serialized' "$SK"  # @Suite 骨架 recipe 在
```

### Human 補做（dogfood）

- [ ] 對 IAMContext（EmployeeAccess）一個 usecase 跑 `/test-gen`：產 enabled test → `swift test` 看 R-SUT 紅（GenesisTODO）→ `/domain-fill` 填 → 轉綠（增量）。
- [ ] 一個 error scenario：看 R-ARRANGE 紅（`GENESIS-ARRANGE:` thunk）→ 手 author Given+值 + positive-arrange #require 到 `.authored.swift` → R-SUT 紅 → 填 domain → 綠。
- [ ] `genesis verify`：未填 thunk 在 → 報 remainingTestHoles（FIX-2）；故意把 assertion 註解掉只留字串 `.code` → 報 uncovered（FIX-1）；全填 → 過。
- [ ] act-sequence（duplicate）scenario：確認 emit 的是 sequence-shaped（兩 execute）非 single-execute（FIX-3）。

## 已知限制

- honesty 收斂到 `genesis verify` 單一 gate（無 `.disabled` 在 `swift test` 的第二訊號）→ **v1 要求**把 verify 接進 generated project CI（CLAUDE.md.template + README 文件化）。
- R-ARRANGE vs R-SUT 紅僅**部分**可分（皆帶 `notImplemented`）；靠 failure shape（"Caught error" at func brace vs "Expectation failed … thrown instead" at #expect line）+ `GENESIS-ARRANGE:` sentinel 字串辨識。
- 「填的 Given 忠實但語意錯（觸發到別的真 invariant，或 arrange 沒生效）」的假綠：v1 無 KDB oracle 擋（Q1 defer）→ 靠 **positive-arrange #require（D5b）** + 人審。釐清：**code-collision 不是** false-green vector —— `error?.error == .code` 對「丟到 adjacent ContextError code」結構性擋住（不符即紅）、「丟 DDDError」型別不符也紅（Round 3 lens 嘗試打破未果）；真正殘留的是「arrange 沒生效 → SUT 因 aggregateNotFound 等 wrong-shape 丟、卻碰巧被當目標」這類，由 D5b 的 positive-arrange `#require` 擋。
- 弱化 test（人手把 `#expect(error?.error == .code)` 改 `#expect(true)`）：FIX-1 補回部分警報（code 被提及卻無真 expectation 可被 lint），但仍是 convention 非 binary-enforced（同 1.y 立場）。
- marker/test-hole count == 0 ≠ done（還要 assertion 綠 + genesis verify 過）。

### 依賴關係

- **重整/修復**：test-gen R2（`2026-06-03-test-gen-real-test-redesign.md` D1-D8，Round 3 reframe 後）。currently-shipped test-gen SKILL.md（已對 1.y 壞掉）。
- **軟相依（done）**：Phase 1.y（GenesisTODO throw-marker + genesis verify + catch-ladder）、1.x（execute orchestration codegen）、1.s（test target + TestUtility 依賴）。
- **擴**：1.y 的 VerifyChecker（加 FIX-1/FIX-2，不改既有語意）。
- 後續：/fill-given elicitation skill（mirror /domain-fill）；/fixture-gen sibling（Q3）；bundle-plan stable scenario-id（Q4）；KDB-run oracle（Q1，post-domain-fill）；read-model test lane；adapter/presenter fatalError → throw-marker。
