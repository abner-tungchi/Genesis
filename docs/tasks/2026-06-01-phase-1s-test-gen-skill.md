# Phase 1.s — test-gen skill（task spec §6 → two-file-split Swift Testing 測試骨架）

## 來源

討論：`docs/discussions/2026-06-01-test-gen-skill-design.md`（D1-D9 consensus，R3 lock round 結束，三方 agreed）

依賴 Phase（全 done）：phase-1r（`/bundle-plan` — 產 per-UC task spec，是 test-gen 的 input）、phase-1q（`genesis bundle-parse` — bundle-plan 的權威 parser，間接相依）。

本 task 收斂的 open question（discussion 留 spec 階段）：

- **Open#1（read-model/projector test lane）→ OUT of scope**：D9 只把 **usecase/application 層** test 鎖 real KDB。read-model/projector 的 test infra（Codex R3 指出 DDDKit 有 `InMemoryReadModelStore` + `StatefulEventSourcingProjector` 抽象在 `ReadModelStore`，in-memory 對該層合法）另開 Phase，本 task 不碰。test-gen 只消費 write UC 的 task spec（bundle-plan 本來就不產 read UC task spec）。
- **Open#2（D4 (c) 預填程度）→ 只預填單步 fixture call skeleton**：Codex R3 反例證實部分 error case 需多步 fixture recipe（`createX` + `addAccounting` + …）。test-gen **不嘗試機械推多步 recipe**（推錯比留白更糟）；(c) 類 scenario 只預填單一 `createX` fixture call placeholder + `#expect(throws:)` 結構，多步編排留 authored。
- **Open#4（fixture library owner）→ human-authored，test-gen 只 reference**：test-gen 不生 fixture body。若所需 fixture helper 不存在，test-gen 在 `.authored.swift` 留一個 named fixture-call placeholder + TODO marker，**不**自己合成領域編排。專屬 fixture-gen skill（若要）另議。

## 目標

新增 `test-gen` skill（住 `Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md`），把 `/bundle-plan` 產的 per-UC task spec（§6 Gherkin / §5 error cases / §3 invariants）轉成 **two-file-split 的 Swift Testing 測試骨架**，對齊 OC ground truth（real KurrentDB + `withTestBundle` harness），且**不被 impl 綁架**（assertion 來自 spec §6/§5、callable surface 來自 generated code 的 type signature、**不讀 execute body 當 semantic source**）。

解決的缺口：§6 是 human-confirmed 的 intended behavior，目前沒有任何 skill 把它機械消費成 test code。test-gen 定位為 **scaffold emitter（非 full codegen，D3）**：機械生 boilerplate scaffold + create-UC happy-path 完整 test + 其餘 scenario 的結構 template（缺 domain payload，留 human 補）。

本 task 含兩個 codegen 前置（test-gen 產出要能編譯/對齊框架，硬耦合故併入）：**D8** 把 `TestPlaceholder.swift.template` 從 XCTest 換 Swift Testing；**D9** 讓 generated test target 取得 `TestUtility`（`withTestBundle` 所在 product）依賴。

## 介面合約（Interface Contract）

### Skill frontmatter

```markdown
---
name: test-gen
description: Genesis test scaffolding skill. Inside a Genesis-bootstrapped project, /test-gen <task-spec.md> turns a bundle-plan per-UC task spec (§6 Gherkin / §5 error cases) into a two-file-split Swift Testing test: <UC>Tests.generated.swift (machine-owned, regenerated wholesale) + <UC>Tests.authored.swift (human-owned, never overwritten). Emits real-KurrentDB + withTestBundle scaffold per OC ground truth. Scaffold emitter — does NOT fill execute bodies, does NOT run tests, does NOT read execute body as semantic source. Supports --regen to re-emit the generated half + reconcile by scenario id.
argument-hint: <task-spec.md> [--regen]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---
```

### 輸入解析

`$ARGUMENTS` 形式：
| 形式 | 處理 |
|---|---|
| `<task-spec.md>` | 對該 task spec 的 UC 產 two-file-split test（`.generated.swift` 重生、`.authored.swift` 不存在才建空殼）|
| `<task-spec.md> --regen` | 只重生 `.generated.swift` + 對 `.authored.swift` 做 scenario-id reconcile 報告 |
| 空 | exit 1，hint 用法 |

`task-spec.md` 路徑不存在 → exit 1。

### 輸入正規化（名稱 / 路徑推導，impl 須一致）

從 task spec frontmatter（bundle-plan 產，格式 `useCase: <Aggregate>.<useCase>`）推導：
- `ucFull` = frontmatter `useCase`（如 `UserAccessProfile.promoteUser`）。
- `ucCamel` = `ucFull` 取 `.` 之後的後綴（如 `promoteUser`）。**create 判定用 `ucCamel`**（lowercased prefix `create`/`establish`），**不**用含 aggregate 的全字串。
- `ucPascal` = UpperCamel(`ucCamel`)（如 `PromoteUser`）— 用於 `@Test` struct / 檔名。
- `<A>` = frontmatter `aggregate`；`contextName` = generated project 的 context 名（從 `.ai/contexts/` 或 Package.swift product 名取）。
- `operatorIdField` / `aggIdField`：**讀 `<ucPascal>Input.swift` 的 stored property 取得**（不重新推導 codegen 注入規則）— `operatorId` 為名為 `operatorId` 的 field（恆存在）；`aggIdField` 為 aggregate identity field（非 create UC 的 Input 才有，名稱依 aggregate `identityName`，如 `userAccessProfileId`）。
- **輸出路徑固定**：`Tests/<contextName>Tests/<ucPascal>Tests.generated.swift` + `Tests/<contextName>Tests/<ucPascal>Tests.authored.swift`（對齊現行 placeholder test 落點）。

### Phase 0 — 讀 task spec（不讀 bundle、不讀 impl 邏輯）

Read task spec MD，取：
- frontmatter：`useCase` / `aggregate` / `useCaseSpecId`（reconcile identity anchor）。
- §3 Invariants（name / errorCode / rules）。
- §5 Error Cases（每條 `條件 | Domain Error=ContextError<<A>Error>.<errorCode> | HTTP` — 映射到 `#expect(throws:)` 的 error code 斷言）。
- §6 Test Scenarios（Gherkin）：happy path（Scenario Outline + Examples）+ `@error Scenario` 群。

§6 **完全空白 / 連 scenario 名都無**（非 `TODO` 而是整段缺）→ **fail-loud**（D5：fail-loud 僅在「scenario 名都推不出」時）：印 `task spec §6 has no scenarios; run /bundle-plan §6 confirmation first` 後 exit。§6 標 `TODO`（有 scenario 名、缺具體值）→ 不 fail-loud，照 (c) 類 scaffold（這是常態，scaffold-TODO 為主，D5）。

### Phase 1 — 定位 generated project + 讀 callable surface（不讀 execute body）

- 確認 cwd 是 generated project root（存在 `.ai/contexts/` 或 `Package.swift`）。否則 exit 1，hint 應在 generated project 內跑。
- 讀以下 **signature only**（D2 界線：可讀「怎麼 call」，不讀 execute body 的 branch/catch 當 expected behavior）：
  - `<UC>Input.swift`（建構 Input 要哪些 field + type）。
  - `<UC>Service`（或 usecase 的 concrete service type — 怎麼 init、`execute(input:)` 簽名）。
  - `<UC>Output.swift`（assert 拿什麼欄位）。
  - `<Aggregate>Repository` 的 init 形狀（照既有 `ApiHandler.swift.template` 的 repository 構造 recipe：`coordinator: .init(client: kdbClient, eventMapper: <A>AggregateEventMapper())`；`<A>AggregateEventMapper` 由 DDDKit build plugin 生成、`package` access、同 package test target 可見）。
- Glob 既有 `Tests/<Context>Tests/<UC>Tests.generated.swift` / `<UC>Tests.authored.swift` 判斷是新建還是 regen。

### Phase 2 — emit `<UC>Tests.generated.swift`（machine-owned，全重生）

固定結構（純機械、regen-safe，這是 durable win — Gemini R3 論點 1）：

1. **imports**：`import Testing` / `import DDDKit` / `import KurrentDB` / `import TestUtility` / `import <ContextName>`（或 `import <Aggregate>Aggregate`）。
2. **`@Suite(.serialized, .tags(...))`** struct `<UC>Tests`：照 OC `AddTaxComplianceAuditUsecaseTests` 形狀 — `.serialized`（共享一台 localhost KDB 必須序列化）。
3. **boilerplate preamble**：`let kdbClient = KurrentDBClient(settings: .localhost())` + `let repository: <A>Repository`，`init()` 內 `repository = <A>Repository(coordinator: .init(client: kdbClient, eventMapper: <A>AggregateEventMapper()))`（照 ApiHandler recipe，client 指 `.localhost()`）。
4. **create UC happy-path（唯一機械完整可跑，D4 (b)；其餘 scenario 一律 (c) 類，非完整 test）**：當該 UC 是 create UC（`ucCamel` lowercased prefix `create`/`establish`，見輸入正規化）→ emit 完整 `@Test func`：`withTestBundle(client: kdbClient){ bundle in` → 用 `bundle.generateAggregateRootId(for: <A>.self)` + `bundle.generateId(for:)` 鑄 id（operatorId 等）→ build `<ucPascal>Input`（business fields 由 Input signature 機械填、`operatorIdField` 帶鑄出的 id）→ `let output = try await usecase.execute(input:)` → `#expect` output + `try #require(try await repository.find(byId:))` 斷言 event persisted `}`。
5. **其餘每個 §6 scenario（D4 (c) — 結構 template 缺 domain payload）**：emit
   ```swift
   @Test(.disabled("TODO(test): provide domain payload"))
   func `<scenario name>`() async throws {
       Issue.record("pending: author Given (fixture args + input mutation) for <scenario>")
       // try await withTestBundle(client: kdbClient) { bundle in
       //   <single-step createX fixture placeholder — multi-step recipe 留 authored>
       //   let input = <UC>Input(/* domain payload */)
       //   let error = await #expect(throws: ContextError<<A>Error>.self) { try await usecase.execute(input: input) }
       //   #expect(error?.error == .<errorCode from §5>)
       // }
   }
   ```
   - **test theater 防治（D6，load-bearing）**：pending stub **必須** `@Test(.disabled(...))`（report 成 skipped，非 passed）**且** body 放 `Issue.record(...)`（若有人移掉 `.disabled` 會 fail 不會假綠）。**禁止**空 `@Test func x(){}`（Swift Testing 空 test = pass = 假綠）。
   - error scenario 的 `#expect(throws:)` + error code 從 §5 機械映射；happy 的 act/assert 結構照 create 版但 Given 留 placeholder。
6. **檔頭 marker**：`// GENESIS-GENERATED — do not edit; regenerated by /test-gen. Author tests in <UC>Tests.authored.swift`。

### reconcile key（D7；先 title-based，stable-id 待上游）

reconcile 的 key = **scenario 名**：把 §6 每個 Scenario / `@error Scenario` 的 title 機械 sanitize 成 Swift `@Test func` 名（如 `` `add when accounting type is invalid throws error` ``）。bundle-plan **目前不 emit scenario id**，故先用 title-derived 名當 key（rename 會誤判 — 見已知限制）。**未來**若 bundle-plan emit stable scenario id，test-gen 在每個 stub 上加 `// test-gen-scenario-id: <id>` 註解，reconcile 改用 id（title 僅顯示）；本 task 先實作 title-based、預留 id 註解欄位。

### Phase 3 — `.authored.swift` 與 `.generated.swift` 的互斥分割（D7 載重點）

**核心規則（避免重複 emit / 編譯衝突）**：一個 §6 scenario 只能存在於兩檔之一。
1. 讀 `.authored.swift`（若存在）既有 `@Test func` 名集合 = `authoredNames`（**只讀不寫**）。
2. **Phase 2 emit `.generated.swift` 時，§6 scenario 名 ∈ `authoredNames` 的 → 跳過不 emit**（human 已在 authored 接管，機器不再出 disabled stub）；其餘才 emit（create-happy-path 完整 / 其餘 disabled stub）。
3. `.authored.swift` 處理：
   - 不存在 → 建**空殼**（imports + `@Suite struct <ucPascal>AuthoredTests` + 引導註解：「把要手寫的 scenario 從 generated 搬來這裡填；機器永不覆寫本檔；fixture 不存在時自行補 UsecaseCall helper」）。**不**預先放 per-scenario placeholder（pending scenario 一律以 disabled stub 留在 `.generated.swift`）。
   - 已存在 → **完全不動**（只讀取 `authoredNames` 供步驟 2）。

> fixture 缺失提示放在 `.generated.swift` 對應 disabled stub 的**註解內**（`// <single-step createX fixture placeholder>`），不另開 authored placeholder（解 Codex review 的「空殼 vs named placeholder」歧義）。

### Phase 4 — reconcile 報告（`--regen` 與一般跑皆印）

`.generated.swift` 整檔重生（machine-owned，無 reconcile 風險）。對照 §6 scenario 集合 vs `authoredNames`，印**報告**（不改 `.authored.swift`）：
| 情況 | 判定 | 動作 |
|---|---|---|
| pending | §6 有、`authoredNames` 無 | 在 `.generated.swift` 為 disabled stub；報告計數 |
| authored | §6 有、`authoredNames` 有 | `.generated` 跳過該 scenario（步驟 2）；報告計數 |
| orphaned | `authoredNames` 有、§6 無對應 | 報告「K orphaned（§6 已移除該 scenario，**不刪**你的 authored test，請人工確認）」|

印 summary：`<N> pending / <M> authored / <K> orphaned`。**絕不**寫 `.authored.swift`。

### Framework 備註

- **Swift Testing（非 XCTest）**：`import Testing` + `@Suite` / `@Test` / `#expect` / `#require` / `Issue.record` / `@Test(.disabled(...))`。Swift Testing 隨 Swift 6.0+ toolchain ship，generated Package（`swift-tools-version: 6.0`）無需額外 package 依賴。
- **`withTestBundle`** 來自 DDDKit 的 `TestUtility` product（`.library(name: "TestUtility")`），須在 test target 依賴（見 D9 改動）。
- **real KurrentDB 是硬 prerequisite**（D9）：create-happy-path test 需 localhost KDB 跑著；無 DB 時該 test red/error 與「沒填」不可區分 → 文件化為 dev/CI prerequisite（CI 給 KDB service container），**不**引 in-memory（D9 砍 (b)）。
- **不被 impl 綁架（D2）**：只讀 Input/Service/Output signature，**不**讀 `execute()` body 的邏輯當 expected behavior 來源。

## 改動檔案

### 新增 / 修改

| 檔案 | 改動描述 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md` | **新檔** — `/test-gen` skill 全文（Phase 0-4，介面合約所述）|
| `Sources/GenesisCore/Resources/Templates/v0.1/TestPlaceholder.swift.template` | **D8** — XCTest → Swift Testing（`import Testing` + `@Suite`/`@Test`；移除 `XCTAssertTrue(true)` tautology，改成 `.disabled` placeholder 或最小可跑 `@Test` 不假綠）|
| `Sources/GenesisCore/PackageRenderer.swift` | **D9** — `testDeps`（目前只列 `<Aggregate>Aggregate` target）加 `.product(name: "TestUtility", package: "swift-ddd-kit")`。DDDKit 的 `TestUtility` target **自身依賴** `KurrentDB` product，故加 TestUtility 即把 `KurrentDBClient` 帶進 test target module graph → `import KurrentDB` 應可解析。若實測仍不可解析 `[inferred]`：補 direct `KurrentDB` package + test-target product 依賴，**package identity 用該 DDDKit 版本實際 resolve 的 upstream（版本相依，impl 時以編譯為準，勿硬寫）** |
| `Tests/GenesisCoreTests/SkillInstallerTests.swift` | skill 數 10 → 11：`bundledSkillNames` 期望 set 加 `"test-gen"`；`installIntoEmptyDir` count 10 → 11；`installSkipsExisting` count 9 → 10 |
| `Tests/GenesisIntegrationTests/InstallSkillsCommandTests.swift` | `expectedSkills` 子集抽查視需要加 `test-gen`（確認 install 後 `test-gen/SKILL.md` 落地）|

### 受影響的 call site（不需改但列出）

- `SkillInstaller.bundledSkillNames()` 自動掃 `Templates/skills/` 子目錄 → 加 `test-gen/` 後自動進安裝名單，**無需改 installer 邏輯**（同 bundle-plan）。
- `PackageRenderer` 的 `TestTargetBlock` render 路徑：testDeps 字串改變只擴充內容，不改 render 機制。

## 實作步驟

### Step 1：寫 `test-gen/SKILL.md`

1. 建目錄 `Sources/GenesisCore/Resources/Templates/skills/test-gen/`。
2. 寫 SKILL.md：frontmatter（介面合約所列）+ Phase 0-4 完整指示。
3. 對齊既有 fill-skill 寫法慣例（exit code 約定、語意錨點、`> Genesis version: {GenesisVersion}` header；`{GenesisVersion}` placeholder 因 raw copyItem 不 render，沿用既有 skill 處理，不在本 task 修）。
4. 關鍵約束務必寫進 skill：(a) `.generated.swift` 全重生 / `.authored.swift` 機器永不寫（D7）；(b) pending stub MUST `.disabled` + `Issue.record`（D6）；(c) 只讀 signature 不讀 execute body（D2）；(d) create UC 才有完整 happy-path、其餘 (c) 類結構 template（D4）；(e) §6 整段空才 fail-loud（D5）。

### Step 2：`TestPlaceholder.swift.template` 換 Swift Testing（D8）

1. 讀現行 template（`import XCTest` + `XCTestCase` + `XCTAssertTrue(true)`）。
2. 改為 `import Testing` + `@Suite struct <ContextName>PlaceholderTests`（保留 `{ContextName}` placeholder），內含一個 `@Test(.disabled("replace when /usecase fills logic"))` 的 placeholder（**不**用 `#expect(true)` tautology — 對齊 D6 反 test-theater 精神：placeholder 該 skipped 而非假綠）。
3. 確認 render 後不破壞既有 `genesis new` test target 編譯（Swift Testing 隨 toolchain，無新 package 依賴）。

### Step 3：`PackageRenderer` testDeps 加 TestUtility（D9）

1. 定位 `PackageRenderer` 組 `testDeps` 的那行（目前 `bundle.aggregates.map { "\"\($0.name)Aggregate\"" }.joined(...)` — 只列 aggregate target）。
2. 在 join 的字串集合加入 `.product(name: "TestUtility", package: "swift-ddd-kit")`（DDDKit 已宣告為 `.library` product，generated Package 的 `dependencies` 已含 `swift-ddd-kit`，無需加新 package）。
3. 驗證 generated 專案 test target `import KurrentDB` + `import TestUtility` 皆可解析：DDDKit 的 `TestUtility` target 自身依賴 `KurrentDB` product，加 TestUtility product 即把 KurrentDB 帶入 test target → `import KurrentDB` 應可達。**若**實測不可達 `[inferred]`：補 direct `KurrentDB` package + product 依賴；**package identity 用該 DDDKit 版本實際 resolve 的 upstream**（版本相依，0.3.0 當前為 `swift-kurrentdb`，但 impl 以 `swift build` 編譯結果為準，勿在 spec 硬鎖）。
4. PackageTestTarget template 的 `dependencies: [{TestDependencies}]` 不改（只擴充傳入字串）。

### Step 4：skill count tests

1. `SkillInstallerTests`：`bundledSkillNames` set 加 `"test-gen"`；`installIntoEmptyDir` 10 → 11；`installSkipsExisting` 9 → 10。
2. `InstallSkillsCommandTests`：若 `expectedSkills` 抽查要加 test-gen 則加，並確認 install 後 `test-gen/SKILL.md` 存在。

### Step 5：本地 verify（見驗收標準 Agent 必做）

## 失敗路徑

| 條件 | skill / codegen 行為 |
|---|---|
| `$ARGUMENTS` 空 | exit 1 + 用法 hint |
| `task-spec.md` 不存在 | exit 1 |
| cwd 非 generated project（無 `.ai/contexts/` / `Package.swift`）| exit 1 + hint 應在 project 內跑 |
| task spec §6 整段無 scenario（連名都無）| **fail-loud**：印 `run /bundle-plan §6 confirmation first` 後 exit（D5：僅此情況 fail-loud）|
| task spec §6 標 `TODO`（有名缺值）| 不 fail-loud → 照 (c) 類 disabled scaffold（常態）|
| `<UC>Tests.authored.swift` 已存在 | **永不覆寫**（D7）；`--regen` 也只報告 reconcile |
| 所需 fixture helper 不存在 | 在 `.authored.swift` 留 named placeholder + TODO，**不**自合成 fixture body（Open#4）|
| generated test 需真 KDB 但無 localhost KDB | 該 test red/error（dev prerequisite，非 skill bug）— 文件化提醒 |

錯誤傳播：skill 偵測前置不滿足 → 印 hint → exit（不產半成品 test 檔）。`.generated.swift` 重生採「先組完整內容再整檔寫」（不 in-place patch，避免半寫）。

## 不改動的部分

### codegen 抽象（D9 鎖定後明確不動）

- `Repository.swift.template`（`KurrentStorageCoordinator` Kurrent-locked）/ `Usecase.swift.template`（綁具體 `<A>Repository`）— **不動**。D9 砍掉「repo-coordinator 解耦」分支，repository 維持 Kurrent-locked 是正確設計，不為了 in-memory 而改。
- `BundleParser` / `FullBundle` — 不動（test-gen 讀 task spec MD，不解析 bundle JSON）。
- `genesis new` / `genesis bundle-parse` CLI — 不動。

### 既有 skill

- `/usecase` / `/api` / `/bundle-plan` / `/presenter-fill` / `/readmodel-mutation` / `write-ddd-spec` SKILL.md — 不動。test-gen 與它們分流並存（test-gen 讀 task spec 產 test 檔，是另一條責任）。

### Non-goals（行為層）

- 本 task **不**做 in-memory event store abstraction（D9 砍 (b)）。
- 本 task **不**做 codegen repo-coordinator 解耦（D9）。
- 本 task **不**生 fixture library body（Open#4：human-authored；test-gen 只 reference / 留 placeholder）。
- 本 task **不**產 read-model / projector test（Open#1 defer）。
- 本 task **不**嘗試機械推多步 fixture recipe（Open#2：只預填單步，多步留 authored）。
- 本 task **不**讀 `execute()` body 當 expected-behavior 來源（D2）。
- 本 task **不**自己跑 `swift test`、**不** fill execute body（test-gen 只產 test 骨架，不驅動 impl、不執行）。
- 本 task **不**保證非 create UC 的 test 開箱可跑（誠實：fully-runnable 僅 create-happy-path，其餘是 scaffold + authored domain payload）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

swift build 2>&1 | tail -3
# 期望: Build complete!

swift test 2>&1 | tail -5
# 期望: 全 pass（含更新後 skill count tests）

# skill 檔存在 + frontmatter
test -f Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md
grep -q 'name: test-gen' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md
grep -q 'disable-model-invocation: true' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md

# skill 覆蓋關鍵決策（語意 symbol 檢查，非計數）
grep -q '.generated.swift' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md   # D7 two-file
grep -q '.authored.swift' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md     # D7 two-file
grep -q 'Issue.record' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md        # D6 anti-theater
grep -q '.disabled' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md           # D6 anti-theater
grep -q 'withTestBundle' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md      # D9 real-KDB harness
grep -qE 'execute body|execute\(\) body|不讀.*body' Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md  # D2 不綁 impl

# D8: TestPlaceholder 換 Swift Testing（import Testing 存在、import XCTest 不存在）
grep -q 'import Testing' Sources/GenesisCore/Resources/Templates/v0.1/TestPlaceholder.swift.template
! grep -q 'import XCTest' Sources/GenesisCore/Resources/Templates/v0.1/TestPlaceholder.swift.template

# D9: PackageRenderer testDeps 含 TestUtility
grep -q 'TestUtility' Sources/GenesisCore/PackageRenderer.swift

# skill 進安裝名單 + 落地
TMPHOME=$(mktemp -d)
HOME="$TMPHOME" swift run genesis install-skills 2>&1 | tail -2
test -f "$TMPHOME/.claude/skills/test-gen/SKILL.md"
rm -rf "$TMPHOME"

# generated 專案 test target 帶新依賴 + TestPlaceholder 為 Swift Testing（D8 + D9 端到端）
# 注意：--output 即 project root（Package.swift / Tests 直接落在 $TMP 下，非 $TMP/IAMContext）；temp dir 非 git repo 故需 --no-git。
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -2
grep -q 'TestUtility' "$TMP"/Package.swift                     # D9: testDeps 含 TestUtility
grep -rq 'import Testing' "$TMP"/Tests                         # D8: placeholder 是 Swift Testing
! grep -rq 'import XCTest' "$TMP"/Tests                        # D8: 無殘留 XCTest
rm -rf "$TMP"
```

> 註：`genesis new <Pascal> --from-bundle <path> --output <dir> --skip-build --no-git` 為現行 CLI 介面（`NewCommand`）。`--output` 即 project root。`--skip-build` 跳過 `swift build`（resolve 仍跑），避免 CI 抓 DDDKit 網路相依；`--no-git` 因 temp dir 非 git work tree。test target 完整編譯驗證放 Human 補做（需網路 + localhost KDB）。已實跑驗證：生成 test target deps = `["UserAccessProfileAggregate", .product(name: "TestUtility", package: "swift-ddd-kit")]`、`Tests/IAMContextTests/PlaceholderTests.swift` 為 `import Testing` + `@Suite` + `Issue.record`。

### Human 補做（需要人類介入）

- [ ] 拿真實 IAM task spec（`/tmp/genesis-iam-final/docs/tasks/CreateUserAccessProfile.md` 等，bundle-plan 已產）跑 `/test-gen`，確認：產出 `<UC>Tests.generated.swift` + `<UC>Tests.authored.swift` 兩檔；create UC 的 happy-path test 結構完整（build Input → execute → assert）；其餘 scenario 為 `@Test(.disabled(...))` + `Issue.record` stub。
- [ ] 啟動 localhost KurrentDB 後跑 create-happy-path test，確認可實際 green（驗 real-KDB + withTestBundle 路徑成立）。
- [ ] 確認 pending stub 在 `swift test` report 成 **skipped 不是 passed**（移掉某個 `.disabled` 後該 test 應 fail 於 `Issue.record`，驗反 test-theater）。
- [ ] 改 task spec §6（加 / 刪一個 scenario）後跑 `/test-gen --regen`，確認 `.generated.swift` 重生但 `.authored.swift` **完全不被改寫**，reconcile summary（pending / authored / orphaned）正確。
- [ ] 對齊 OC idiom 體感：生成 test 的 `@Suite`/preamble/`withTestBundle` 與 OC `AddTaxComplianceAuditUsecaseTests` 風格一致。

## 已知限制

- **fully-runnable auto-gen 僅 create-happy-path（誠實量化）**：IAM 7 UC ≈ 34 scenario，機械完整可跑僅 1（create happy path）。其餘 = boilerplate scaffold + `@Test(.disabled)` 結構 template + authored domain payload。**「`swift test` 跑完綠」≠ coverage** — pending 是 skipped 不是 covered。test-gen 的 durable win 是 boilerplate scaffold + 把「沒人寫 test」變成 greppable 的 named disabled obligation（非 create test 本身）。
- **real KurrentDB 是硬 prerequisite（D9 residual risk）**：無 localhost KDB → create-happy-path test red 與「沒填」不可區分。接受為 dev/CI prerequisite（同 OC），不引 in-memory。
- **fixture library 是硬上游依賴**：error / update scenario 的 Given 領域編排需 human-authored fixture（OC `SharedUtility/UsecaseCall/` pattern）。test-gen 只 reference，fixture 不存在 → error body 停在 placeholder（Open#4）。
- **多步 fixture recipe 留 authored**：Codex R3 反例（需 `createX` + `addAccounting` + … 多步才觸發某 error）— test-gen 不機械推多步，留 human（Open#2）。
- **read-model / projector test 未覆蓋**：Open#1 defer，本 task 只 usecase/application 層。
- **`--regen` reconcile 用 scenario id / title**：bundle-plan 若未 emit stable scenario id，fallback 用 title 當 key，scenario rename 會誤判 orphaned + pending（標註提醒，不自動刪 authored）。

### 依賴關係

- 軟相依（已 done）：phase-1r（`/bundle-plan` — 產 test-gen 的 input task spec）、phase-1q（`genesis bundle-parse` — bundle-plan 前置，間接）。
- 無 hard 阻塞（test-gen 讀既有 task spec MD，不需新 CLI 能力）。
- 後續（unblocks）：generated project 的 per-UC test 開發 workflow（bundle-plan → test-gen scaffold → human author Given → /usecase /api fill → green）。
