---
name: test-gen
description: Genesis test scaffolding skill. Inside a Genesis-bootstrapped project, /test-gen <task-spec.md> turns a bundle-plan per-UC task spec (§6 Gherkin / §5 error cases) into a two-file-split Swift Testing test — <UC>Tests.generated.swift (machine-owned, regenerated wholesale) + <UC>Tests.authored.swift (human-owned, never overwritten). Emits a real-KurrentDB + withTestBundle scaffold per OC ground truth. Scaffold emitter — does NOT fill execute bodies, does NOT run tests, does NOT read execute body as a semantic source. Supports --regen to re-emit the generated half + reconcile by scenario name.
argument-hint: <task-spec.md> [--regen]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# /test-gen — turn a per-UC task spec into a two-file-split Swift Testing test

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

把一份 `/bundle-plan` 產的 per-UC task spec（`docs/tasks/<UC>.md`）轉成 **two-file-split 的 Swift Testing 測試**：

- `Tests/<contextName>Tests/<ucPascal>Tests.generated.swift` — **機器擁有，每次整檔重生**。含 `@Suite` scaffold + boilerplate（kdbClient + repository init）+ create UC 的完整 happy-path test + 其餘每個 §6 scenario 的 `@Test(.disabled(...))` 結構 stub。
- `Tests/<contextName>Tests/<ucPascal>Tests.authored.swift` — **人類擁有，機器永不覆寫**。人在這裡填真 test（補 Given 的領域編排 / fixture）。

test-gen 是 **scaffold emitter，不是 full codegen**：唯一機械完整可跑的是 **create UC 的 happy-path**；其餘 scenario 一律是結構 template（缺 domain payload，留人補）。誠實認知：「`swift test` 跑完綠」≠ coverage — pending 是 *skipped* 不是 covered。

### 絕對約束（不可違反）

- **scaffold-only** — 絕不跑 `swift test`、絕不 fill domain `execute()` body、絕不呼叫 `/usecase` `/api`。本 skill 只產 test 檔。
- **不被 impl 綁架（D2）** — assertion 來自 task spec 的 §6/§5；呼叫機制（Input 欄位 / Service init / Output 欄位）來自 generated code 的 **type signature**。**絕不讀 `execute()` body 的 branch/catch 當 expected behavior 來源**。
- **two-file ownership（D7）** — `.generated.swift` 整檔重生；`.authored.swift` 機器**只讀不寫**（連 `--regen` 都只報告 reconcile）。
- **反 test theater（D6）** — pending stub **必須** `@Test(.disabled("..."))` + body 放 `Issue.record(...)`。**禁止**空 `@Test func x(){}`（Swift Testing 空 test 會 pass = 假綠）。
- **real KurrentDB（D9）** — 照 OC ground truth 用 `KurrentDBClient(settings: .localhost())` + `withTestBundle`。**不**引 in-memory event store。localhost KDB 是 dev/CI prerequisite。

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

## Phase 0 — 讀 task spec（不讀 bundle、不讀 impl 邏輯）

Read task spec MD，取：
- frontmatter：`useCase` / `aggregate` / `useCaseSpecId`。
- **§3 Invariants**：name / errorCode / rules。
- **§5 Error Cases**：每條 `條件 | Domain Error=ContextError<<A>Error>.<errorCode> | HTTP` — 映射到 `#expect(throws:)` 的 error code 斷言。
- **§6 Test Scenarios（Gherkin）**：happy path（Scenario Outline + Examples）+ `@error Scenario` 群。

§6 **完全空白 / 連 scenario 名都無**（非標 `TODO` 而是整段缺）→ **fail-loud**：印
```
test gen aborted: task spec §6 has no scenarios. Run /bundle-plan §6 confirmation first.
```
然後 exit（D5：fail-loud **僅**在「scenario 名都推不出」時）。§6 標 `TODO`（有 scenario 名、缺具體值）→ **不** fail-loud，照 (c) 類 disabled scaffold（這是常態，scaffold-TODO 為主）。

## Phase 1 — 定位 generated project + 讀 callable surface（不讀 execute body）

- 確認 cwd 是 generated project root：存在 `.ai/contexts/` **或** `Package.swift`。否則 **exit 1**：`not inside a Genesis-bootstrapped project; cd into the generated project root first`。
- 讀以下 **signature only**（D2 界線：可讀「怎麼 call」，不讀 execute body 的 branch/catch 當 expected behavior）：
  - `<ucPascal>Input.swift` — 建構 Input 要哪些 field + type（含 `operatorIdField` / `aggIdField`）。
  - `<ucPascal>Service`（usecase 的 concrete service type）— 怎麼 init、`execute(input:)` 簽名。
  - `<ucPascal>Output.swift` — assert 拿哪些欄位。
  - `<A>Repository` 的 init 形狀 — 照既有 `ApiHandler` 的 repository 構造 recipe（見 Phase 2）。
- Glob 既有 `Tests/<contextName>Tests/<ucPascal>Tests.generated.swift` / `.authored.swift` 判斷是新建還是 regen。

## reconcile key（D7；先 title-based，stable-id 待上游）

reconcile 的 key = **scenario 名**：把 §6 每個 `Scenario` / `@error Scenario` 的 title 機械 sanitize 成 Swift backtick 函數名（如 `` `add when accounting type is invalid throws error` ``）。

bundle-plan **目前不 emit scenario id**，故先用 title-derived 名當 key（rename 會誤判 — 見「已知限制」）。**預留** stable-id：在每個 generated stub 上加 `// test-gen-scenario-id: <id>` 註解欄位；未來 bundle-plan emit id 後改用 id（title 僅顯示）。本版實作 title-based。

## Phase 2 — emit `<ucPascal>Tests.generated.swift`（machine-owned，全重生）

> **互斥前置（D7 載重點）**：先讀 `.authored.swift`（若存在）既有 `@Test func` 名集合 = `authoredNames`（只讀不寫）。emit 時 **§6 scenario 名 ∈ `authoredNames` 的一律跳過**（human 已接管，機器不再出 disabled stub），避免兩檔重複 emit / 編譯衝突。

固定結構（純機械、regen-safe — 這是 durable win）：

```swift
// GENESIS-GENERATED — do not edit. Regenerated by /test-gen.
// Author real tests in <ucPascal>Tests.authored.swift (this file is overwritten on --regen).
import Testing
import DDDKit
import KurrentDB
import TestUtility
import <contextName>          // 或 import <A>Aggregate（依 generated 模組劃分）

@Suite(.serialized)
struct <ucPascal>Tests {
    let kdbClient = KurrentDBClient(settings: .localhost())
    let repository: <A>Repository

    init() {
        // 照 ApiHandler 的 repository 構造 recipe；<A>AggregateEventMapper 由 DDDKit build plugin 生成（package access，同 package test target 可見）。
        self.repository = <A>Repository(coordinator: .init(client: kdbClient, eventMapper: <A>AggregateEventMapper()))
    }

    // ── create UC happy-path：唯一機械完整可跑（僅當本 UC 是 create UC）──
    @Test func `<happy scenario name>`() async throws {
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

    // ── 其餘每個 §6 scenario（含 @error）：結構 template，缺 domain payload（D4 (c)）──
    @Test(.disabled("TODO(test): provide domain payload — author this in <ucPascal>Tests.authored.swift"))
    func `<error scenario name>`() async throws {
        // test-gen-scenario-id: <id-if-available>
        Issue.record("pending: author Given (fixture args + input mutation) for <error scenario name>")
        // try await withTestBundle(client: kdbClient) { bundle in
        //   // single-step fixture placeholder — 多步 recipe（先 createX 再 addY…）留 authored
        //   // let <aggId> = await bundle.generateAggregateRootId(for: <A>.self)
        //   // try await create<A>(…, repository: repository)   // ← human-authored fixture（不存在自行補 UsecaseCall helper）
        //   let input = <ucPascal>Input(/* domain payload — 故意壞的欄位 */)
        //   let error = await #expect(throws: ContextError<<A>Error>.self) {
        //       _ = try await <ucPascal>Service(repository: repository).execute(input: input)
        //   }
        //   #expect(error?.error == .<errorCode from §5>)
        // }
    }
}
```

規則細節：
- `@Suite(.serialized)`：共享一台 localhost KDB 必須序列化（OC ground truth）。
- **create UC**（`ucCamel` prefix `create`/`establish`）才 emit 上面完整 happy-path test。**非 create UC** 的 happy path 也需先 `create<A>` fixture 鋪「aggregate 已存在」→ 故非 create 的 happy path 也走 (c) 類 disabled stub（fixture 是 authored）。
- 每個 §5 error → 一個 `@Test(.disabled)` stub，`#expect(throws:)` 的 error code 從 §5 機械映射。
- **絕不**省略 `.disabled` 或 `Issue.record`（D6）。
- 整檔「先組完整內容再一次寫入」（不 in-place patch，避免半寫）。

## Phase 3 — `.authored.swift`（human-owned，機器永不覆寫，D7）

- **不存在** → 建**空殼**（只一次）：
  ```swift
  // Human-authored tests. /test-gen NEVER overwrites this file.
  // 把要手寫的 scenario 從 <ucPascal>Tests.generated.swift 搬來這裡填真 test。
  // fixture 不存在時，自行補 UsecaseCall helper（如 create<A>(…, repository:)），test-gen 不生 fixture body。
  import Testing
  import DDDKit
  import KurrentDB
  import TestUtility
  import <contextName>

  @Suite(.serialized)
  struct <ucPascal>AuthoredTests {
      let kdbClient = KurrentDBClient(settings: .localhost())
      let repository: <A>Repository
      init() {
          self.repository = <A>Repository(coordinator: .init(client: kdbClient, eventMapper: <A>AggregateEventMapper()))
      }
      // 例：把某個 §6 @error scenario 的真 test 填在這裡，函數名與 §6 scenario 同名。
  }
  ```
  **不**預放 per-scenario placeholder（pending scenario 一律以 disabled stub 留在 `.generated.swift`）。
- **已存在** → **完全不動**，只讀 `authoredNames` 供 Phase 2 互斥跳過。

## Phase 4 — reconcile 報告（一般跑 + `--regen` 皆印）

對照 §6 scenario 集合 vs `authoredNames`，印**報告**（**絕不**寫 `.authored.swift`）：

| 情況 | 判定 | 處理 |
|------|------|------|
| **pending** | §6 有、`authoredNames` 無 | `.generated.swift` 為 disabled stub；計數 |
| **authored** | §6 有、`authoredNames` 有 | `.generated` 跳過該 scenario（Phase 2 互斥）；計數 |
| **orphaned** | `authoredNames` 有、§6 無對應 | 報告「§6 已移除該 scenario，**不刪**你的 authored test，請人工確認」|

印 summary：`<N> pending / <M> authored / <K> orphaned`，並提醒：pending 在 `swift test` 是 **skipped 不是 covered**。

## Framework constraints（沿用，不可破壞）

- **Swift Testing（非 XCTest）**：`import Testing` + `@Suite` / `@Test` / `#expect` / `#require` / `Issue.record` / `@Test(.disabled(...))`。隨 Swift 6.0+ toolchain ship，generated Package 無需額外 package 依賴。
- **`withTestBundle`** 來自 DDDKit `TestUtility` product（generated Package test target 須依賴它，Phase 1.s 已在 codegen 加入）。
- **`<A>AggregateEventMapper`** 由 DDDKit build plugin 生成、`package` access、同 package test target 可見 — test 直接呼叫即可。
- **real KurrentDB 是硬 prerequisite**：create-happy-path test 需 localhost KDB 跑著；無 DB 時該 test red/error 與「沒填」不可區分 → 文件化為 dev/CI prerequisite，**不**引 in-memory（D9）。

## 與其他 skills 的關係

- 上游：`/bundle-plan` 產的 per-UC task spec（§6 是 human-confirmed intent — test-gen 的 source of truth）。
- sibling：`/usecase` / `/api`（fill execute body；test-gen 與它們**分流**，讀 task spec 產 test 檔是另一條責任，不呼叫它們）。
- 下游：human 在 `.authored.swift` 補 Given 領域編排 + fixture → 跑 `swift test`（需 localhost KDB）。
- 解耦：test-gen 不跑 codegen、不 fill execute body、不執行測試 —— 只產 test 骨架。
