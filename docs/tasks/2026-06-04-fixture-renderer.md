# FixtureRenderer — codegen bare UsecaseCall fixtures（test Given 的機械上游）

## 來源

討論：`docs/discussions/2026-06-04-fixture-codegen-vs-skill.md`（consensus，3-lens adversarial + synthesis；FORK VERDICT = **codegen, not a skill**，D1–D9）。user 已拍板 3 開放問題（no-stub / `<A>.swift`+`<A>Fixtures.presets.swift` / create+update+delete）。

## 目標

test-gen 的 Lane-B JUDGMENT Given（與 invariant-TDD）依賴 fixture（`createX(...)` 等 UsecaseCall helper）來鋪前置狀態，但目前 **genesis new 不產 fixture**，test-gen 只在 thunk 訊息 emit fixture 名。本 task 讓 `genesis new` **codegen 出 bare single-UC fixture wrapper**（每 aggregate 一檔），使 test-gen 的 thunk 所命名的 fixture 在 `genesis new` 完成當下就**編得過、可被呼叫**，把 Lane-B Given 的「人要先發明並寫出 fixture」這半機械化掉。依 codegen-vs-retrofit D1（deterministic→codegen）：bare wrapper 是 bundle/signature 的純函數，故走 renderer 而非 skill。

---

## 介面合約（Interface Contract）

### `FixtureRenderer.render(...)`（新 renderer，mirror `UseCaseRenderer`）

```
public enum FixtureRenderer {
    public static func render(
        bundle: FullBundle,
        adapter: Adapter,
        contextName: String
    ) throws -> [(path: String, content: String, role: String)]
}
```

- 對 `bundle.aggregates` 每個 aggregate，收集 `bundle.useCases.filter { $0.aggregateSpecId == aggregate.aggregateSpecId }`；**若該 aggregate 無 useCase → 不產該檔**（不回 tuple）。回傳 0..N 個 tuple（每個有 useCase 的 aggregate 一個）。
- 每檔：`path = "Tests/\(contextName)Tests/SharedUtility/UsecaseCall/\(aggregate.name).swift"`，`role = "fixture"`。
- throws：`GenesisError.bundleInvalid` 當某 useCase 的 `aggregateSpecId` 在 `bundle.aggregates` 找不到（鏡像 `UseCaseRenderer.swift:22-26`）；`SwiftTypeResolver.resolve` 對無法解析型別 throw → 直接傳播（與 UseCaseRenderer 同）。

### 每個 fixture function（per useCase）

```swift
@discardableResult
func <ucCamel>(<canonicalParams>, repository: <A>Repository) async throws -> String? {
    let output = try await <ucName>Service(repository: repository).execute(input: .init(<initArgs>))
    return output.id
}
```

- `ucName = CaseTransformer.upperCamel(useCase.useCase)`；`ucCamel = CaseTransformer.lowerCamel(useCase.useCase)`。**fixture 名 = `ucCamel`**（OC parity：UC `CreateAuditQuoting` → `createAuditQuoting`；`EditTotalAssets` → `editTotalAssets`）。
- `<A> = aggregate.name`。
- **`<canonicalParams>` 與 `<initArgs>` 必須與 `UseCaseRenderer.renderInput` 產的 `<UC>Input.init` 完全對齊**（Swift labeled init 需同序）—— 用**同一份 canonical 欄位推導**：
  - `aggIdName = aggregate.identityName`（`aggregate` = 該 useCase 對應的 AggregateSpec）。
  - `businessFields = useCase.input.filter { $0.name != aggIdName && $0.name != "operatorId" }`。
  - `canonicalFields = [FieldSpec(name: aggIdName, rawType: "String")] + businessFields + [FieldSpec(name: "operatorId", rawType: "String")]`（**逐字鏡像 `UseCaseRenderer.swift:91-94`**）。
  - 每欄型別 `resolved = try SwiftTypeResolver.resolve(rawType: field.rawType, knownCustomTypes: knownCustomTypes, adapter: adapter)`，`knownCustomTypes = bundle.dtoTypeNames.union(adapter.customTypes.map { $0.name })`（鏡像 `UseCaseRenderer.swift:17`）。
  - `canonicalParams = canonicalFields.map { "\($0.name): \(resolved)" }.joined(separator: ", ")`；`initArgs = canonicalFields.map { "\($0.name): \($0.name)" }.joined(separator: ", ")`。
  - `repository: <A>Repository` 為**最後一個** param（OC parity）。
- 回傳 `output.id`（`<UC>Output.id` 型別 = `String?`，見 `UsecaseOutput.swift.template`）→ fixture 回傳 `String?`，標 `@discardableResult`。
- **uniform across create/update/delete**：fixture body 一律 `Service(repository:).execute(input:)`；create/update/delete 的分派已在 codegen 的 `execute()` body 內（`buildExecuteBody`），fixture **不**需要分派。read-side query 不在 `bundle.useCases`（在 `bundle.readModels`/`presenters`）→ 自動不產 fixture。

### 檔案 header（D3 honesty signpost，取代被否決的 preset stub）

檔首註解（**load-bearing**：因 user 決定不 emit preset stub，「defaults 放哪」的 signpost 改由此 header 承載）：

```swift
// GENESIS-GENERATED — regenerated wholesale by `genesis new`. Do NOT edit, and do NOT add defaults or
// presets here: a default value (e.g. status = .established) silently smuggles a "which invariants are
// reachable" decision into an ergonomic helper. For ergonomic defaults/presets, create a human-owned
// sibling `<A>Fixtures.presets.swift` (named overloads delegating to these bare wrappers); Genesis never
// generates or overwrites that file.
```

### imports（每檔）

`import Foundation`（Decimal/Date 等）+ `import <A>Aggregate`（`<UC>Service` / `<A>Repository` / `<UC>Input` / `<UC>Output` 皆 `package`，同 package 的 test target 以**普通 `import` 即可見** package symbol，免 `@testable`）+ `sharedImport`（**逐字鏡像 `AggregateRenderer.swift:24-25` 的條件式**：`(!bundle.dtos.isEmpty || !adapter.customTypes.isEmpty) ? "import \(contextName)Shared" : ""` —— **是條件式、非恆有**：無 DTO/customType 時為空字串。注意：Shared *target* 在 NewCommand 恆 emit，但 *import line* 條件式。IAM cosmogony bundle 有 2 DTOs → fixture 會帶 `import IAMContextShared`（未用到也無害，scratch build 確認無 error/warning）。

### 所有權明示

- `<UC>Input.init` 的欄位集 **由 `UseCaseRenderer.renderInput` 擁有**；FixtureRenderer 的 `.init(...)` args 是其消費者，兩者**必須用同一份 canonical 欄位推導**（同序、同型別解析）。**STRONGLY prefer 抽出共用 helper**（如 `UseCaseRenderer.canonicalInputFields(useCase:agg:)`）供 renderInput 與 FixtureRenderer 共用 —— 這是 single source，編譯期就鎖。**若選擇複製那 4 行 filter**：(1) 兩處互註「與 renderInput 耦合，改一處要改兩處」；(2) **golden 測 #7 變強制**，且須對比 **REAL `UseCaseRenderer.render(...)` 產的 `<UC>Input.init` 行**（非手寫期望）—— 否則 renderInput 改動不會編譯失敗、只會讓 fixture 的 `.init` 在**下游生成專案** build 時 mis-order args（離 renderer 很遠的 silent drift）。`[inferred]` extract-vs-copy 為實作選擇；spec 的硬不變量是「args match `<UC>Input` by construction」。

### Framework / 編譯約束

- fixture **必須在 test target（`Tests/`）**，不可在 `Sources/`：`<UC>Input`/`<A>Repository` 是 `package`，`Sources/` 內的非-package func 以 package 型別當 param 會編譯失敗（`parameter uses a package type`）。test target 同 package → `import <A>Aggregate` 取得 package 可見性（feasibility lens 已實測）。
- fixture 是真 `execute()` 呼叫，**非** `genesisTODO(` thunk，且在 `@Test` 之外（SharedUtility 檔無 `@Test`）→ `genesis verify` FIX-2 不會誤判它為 test-side hole（鏡像 VerifyChecker preamble-skip）。domain 未填時 fixture 的 execute 丟 `GenesisTODO` → 用到它的 test R-SUT 紅（乾淨）。

---

## 改動檔案

| 檔案 | 改動描述 |
|------|----------|
| `Sources/GenesisCore/FixtureRenderer.swift` | **新增** renderer：per-aggregate 收集其 useCases → 組 bare wrapper 檔（header + imports + 每 UC 一個 `@discardableResult func`）。 |
| `Sources/Genesis/Commands/NewCommand.swift` | **編輯**：在 §2.4（test placeholder）後加 §2.4.1，`for file in try FixtureRenderer.render(bundle:adapter:contextName:) { try plan(file.path, file.content, file.role) }`。 |
| `Sources/GenesisCore/UseCaseRenderer.swift` | **編輯（建議）**：抽 `canonicalInputFields(...)` 共用 helper（FixtureRenderer + renderInput 共用），或保持私有並由 FixtureRenderer 複製 + 互註耦合。`[inferred]` |
| `Tests/GenesisCoreTests/FixtureRendererTests.swift` | **新增** golden-file 單測（見驗收）。 |
| `Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md` | **編輯**（見 Step 4 逐條）：釘 `<fixtureName>` = `ucCamel`；**刪除 stale「fixture 不存在時自行補」指示**（codegen 後該話錯）；normalize `create<A>` → `ucCamel`；註明 fixture 於 genesis-new 已存在、test-gen **consume 不 emit**。 |
| `Sources/Genesis/Commands/NewCommand.swift`（call site of `plan`）| 無額外改動，沿用既有 `plan(...)` + `taggedFiles`（manifest 收 role `fixture`）。 |

---

## 實作步驟

### Step 1：`FixtureRenderer.swift`

1. `public enum FixtureRenderer`，`public static func render(bundle:adapter:contextName:) throws -> [(String,String,String)]`。
2. 計 `knownCustomTypes = bundle.dtoTypeNames.union(adapter.customTypes.map { $0.name })`；計 `sharedImport = (!bundle.dtos.isEmpty || !adapter.customTypes.isEmpty) ? "import \(contextName)Shared" : ""`（**逐字鏡像 `AggregateRenderer.swift:24-25`**；條件式，非恆有）。
3. `for aggregate in bundle.aggregates`：
   - `ucs = bundle.useCases.filter { $0.aggregateSpecId == aggregate.aggregateSpecId }`；空 → `continue`（不產檔）。
   - 對每個 `uc in ucs`：
     - 用 `aggregate.identityName` 當 `aggIdName`（注意：`aggregate` 即此迴圈的 AggregateSpec；其 `aggregateSpecId` == uc.aggregateSpecId，已由 filter 保證 → 不需再 `first(where:)` 找，但若選擇 per-uc 找則鏡像 `UseCaseRenderer.swift:22-26` 的 not-found throw）。
     - 算 `canonicalFields`（逐字鏡像 `UseCaseRenderer.swift:91-94`）；每欄 `SwiftTypeResolver.resolve(...)`。
     - 組 func 字串：`@discardableResult\nfunc \(ucCamel)(\(canonicalParams), repository: \(A)Repository) async throws -> String? {\n    let output = try await \(ucName)Service(repository: repository).execute(input: .init(\(initArgs)))\n    return output.id\n}`。
   - 組檔內容：header 註解 + `import Foundation` + `import \(aggregate.name)Aggregate` + （非空時）`sharedImport` + 空行 + funcs（以 `\n\n` 分隔）。
   - append `("Tests/\(contextName)Tests/SharedUtility/UsecaseCall/\(aggregate.name).swift", content, "fixture")`。
4. 回傳累積的 tuple 陣列。

### Step 2：NewCommand 接線

在 `// 2.4 Test placeholder` 區塊**之後**插入：
```swift
// 2.4.1 Fixture wrappers (codegen UsecaseCall helpers for test Givens) — per aggregate with use cases
for file in try FixtureRenderer.render(bundle: bundle, adapter: adapter, contextName: contextName) {
    try plan(file.path, file.content, file.role)
}
```
（沿用既有 `plan` → SourceWriter.plan + `taggedFiles`（manifest 收 role `fixture`）；regenerated wholesale，version-conflict 由既有 manifest sha256/`checkExistingManifestVersion` 守。）

### Step 3：golden-file 單測 `FixtureRendererTests.swift`

in-process 跑 `FixtureRenderer.render(...)` 於 fixture bundle，grep 產出字串斷言（offline，真 gate）：
1. **create** UC → `func createX(... <aggId>: String, ..., operatorId: String, repository: XRepository) async throws -> String?` + body `XService(repository: repository).execute(input: .init(...))` + `return output.id`。
2. **update** UC → 同形（含 business 欄位、型別經 SwiftTypeResolver 解析正確，如 `Decimal`/custom type）。
3. **delete** UC → 同形（uniform，body 不分支）。
4. **multi-aggregate** bundle → 每 aggregate 一個 `<A>.swift`、彼此獨立（cross-agg 不互相 import）。
5. fixture 名 == `ucCamel`（非含 aggregate 的全字串）。
6. header signpost 在（grep `regenerated wholesale` + `Fixtures.presets.swift`）。
7. **（drift gate，強制）** `.init(...)` 的 arg 序與 `UseCaseRenderer.render` 同 UC 產的 `<UC>Input.init` param 序一致 —— **in-process 跑 REAL `UseCaseRenderer.render(...)` 抓其 `<UC>Input.init` param 行，與 FixtureRenderer 的 `.init(...)` args 逐一對比**（非手寫期望），讓 renderInput drift fail 在 Genesis 自己的 CI。
8. read-side（只有 readModels、無 useCases 的 aggregate）→ **不產** fixture 檔。

### Step 4：test-gen SKILL naming pin + 修掉 stale 指示

D4「naming MUST agree with test-gen's thunk」須完整套用 —— **逐條**改 `test-gen/SKILL.md`（grep 確認行號可能漂移，用語意錨點）：
- **(a) `<fixtureName>` = `ucCamel`**：thunk 訊息規則處（現 `<fixtureName>` 為 unbound placeholder）釘明 = `CaseTransformer.lowerCamel(useCase)`，使 `call <fixtureName>(…)` 解析到 codegen'd fixture。
- **(b) 刪除 stale「fixture 不存在」指示（載重）**：現行 `.authored.swift` 空殼註解有「fixture 不存在時自行補 UsecaseCall helper（test-gen 不生 fixture body）」—— FixtureRenderer codegen 後此話**錯了**。改為「fixture 由 FixtureRenderer 於 `genesis new` 已 codegen 到 `Tests/<Ctx>Tests/SharedUtility/UsecaseCall/<A>.swift`；test-gen / human 只 **consume**（呼叫），**不** author bare wrapper（要 ergonomic preset 才手寫 `<A>Fixtures.presets.swift`）」。
- **(c) normalize `create<A>` 引用**：現行範例用 `create<A>` —— 注意 `create<A>` 只在 **create UC** 巧合等於 `ucCamel`（verb 內嵌 aggregate 名），非通則；改用 `ucCamel` 或明標此 create-UC 巧合。
- **(d) 不動** line ~302「/fixture-gen … 皆 defer」（與本 spec 的 migration-only 立場一致）。

---

## 失敗路徑

| 條件 | 行為 |
|------|------|
| aggregate 無 useCase | 不產該 aggregate 的 fixture 檔（skip，非 error）|
| useCase.aggregateSpecId 不在 bundle.aggregates | `throw GenesisError.bundleInvalid(reason:)`（鏡像 UseCaseRenderer；render 整體失敗 → NewCommand rollback）|
| 欄位型別無法解析 | `SwiftTypeResolver.resolve` throw → 傳播 → NewCommand rollback（與既有 renderer 同）|
| domain 未填、fixture 被 test 呼叫 | fixture 的 `execute()` 丟 `GenesisTODO`（catch-ladder 原樣傳出）→ 呼叫它的 test R-SUT 紅（乾淨、可診斷）。fixture 檔本身編得過。|
| regen 既有專案 | fixture 檔 wholesale 重生（machine-owned, role `fixture`）；human 的 `<A>Fixtures.presets.swift` 不在 manifest → 不被碰。|

---

## 不改動的部分

- `VerifyChecker.swift`（fixture 對 FIX-2 不可見，已確認；不需改）。
- `Service.swift.template` / `UsecaseInput.swift.template` / `UsecaseOutput.swift.template`（fixture 是它們的消費者，不改 template）。
- `UseCaseRenderer` 的 `<UC>Service`/`<UC>Input`/`<UC>Output`/execute 行為（FixtureRenderer 只讀其產物形狀；唯一可能的編輯是抽共用 canonical-fields helper，純 refactor 不改行為）。
- 既有 `plan`/SourceWriter/ManifestRenderer 機制（沿用，role 多一種 `fixture`）。

### Non-goals（行為層）

- **不**產 baseline-judgment defaults 或 curated presets（人手在 sibling `<A>Fixtures.presets.swift` author；本 task 不產該檔、不產 stub —— user 拍板 no-stub）。
- **不**產 multi-step chain fixture（呼叫順序是 judgment，人手組）。
- **不**決定 cross-aggregate 的 fixture 呼叫順序（每 aggregate 各產自己的 bare wrapper；consuming @Suite 持第二 repository + 順序由人）。
- **不**做 `/fixture-gen` skill（codegen 取代它；skill 僅 migration-only niche，本 task 不建）。
- **不**做 `/fill-given`、**不**做參數矩陣（`@Test(arguments:)`）展開。
- **不**改 test-gen 的 2-lane emit 邏輯（只釘命名 + 標 consume-not-emit）。

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test --filter FixtureRendererTests 2>&1 | tail -5   # 新 golden 單測全綠

# regen IAM（--skip-build）→ 驗 fixture 檔產出 + 形狀
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1
FX="$TMP/Tests/IAMContextTests/SharedUtility/UsecaseCall/UserAccessProfile.swift"
test -f "$FX"                                                  # fixture 檔存在
grep -q '@discardableResult' "$FX"
grep -q 'func createUserAccessProfile(' "$FX"                  # 命名 = ucCamel
grep -q 'func promoteUser(' "$FX"
grep -q 'Service(repository: repository).execute(input: .init(' "$FX"
grep -q 'return output.id' "$FX"
grep -q 'import UserAccessProfileAggregate' "$FX"
grep -q 'regenerated wholesale' "$FX"                          # header signpost
grep -q 'Fixtures.presets.swift' "$FX"
! ( grep -vE '^[[:space:]]*//' "$FX" | grep -qE '= \.[a-zA-Z]+\b' )  # bare：無參數預設值（先剝 // 註解再驗；否則 header 範例 'status = .established' 會誤判 FAIL）
( cd "$TMP" && swift build 2>&1 | tail -2 )                    # fixture 檔編得過（需網路抓 DDDKit）
rm -rf "$TMP"
```

### Human 補做（需要人類介入）

- [ ] 對 IAMContext（aggregate = **UserAccessProfile**；iam-cosmogony-bundle 只有這一個 aggregate）一個 Lane-B error scenario：在 `.authored.swift` 的 Given 呼叫 codegen'd fixture（如 `createUserAccessProfile(...)`）→ 確認編得過、test R-SUT 紅（fixture 的 execute 丟 GenesisTODO）→ `/domain-fill` 後轉綠。預期：fixture 讓 Given 的「呼叫前置 UC」那半不用人寫。
- [ ] 手 author 一個 `<A>Fixtures.presets.swift` named overload（delegating to bare wrapper）→ regen → 確認 preset 檔**未被覆寫**、bare 檔重生。
- [ ] 確認多 aggregate 專案每 aggregate 一個 `UsecaseCall/<A>.swift`、cross-agg fixture 用第二 repository（人手組）可編。

---

## 已知限制

- **bare wrapper 冗長**：每參必填、零預設（honest），呼叫端比 OC 帶預設的 helper 囉嗦；ergonomics 由人手 `<A>Fixtures.presets.swift` named overload 補（user 拍板 no-stub → 該檔不自動產，靠 bare 檔 header signpost 指路）。
- **header signpost 是唯一的「defaults 放哪」提示**（無 stub 檔）；若 header 被忽略，人仍可能在 call site 散落硬塞值 —— 與 OC 單點 preset 紀律相比較弱，接受。
- **cross-aggregate 順序 / multi-step chain / baseline 值 = judgment**，留人 / 未來 `/fill-given`，不在本 task。
- **drift soft-enforced**：machine `<A>.swift`（role `fixture`）wholesale 重生；human preset sibling 靠 manifest role 區分、Phase-4 偵測網未上前為 convention-enforced（同 test-gen 兩檔分離的軟性 caveat）。
- **canonical-fields 耦合**：fixture `.init(...)` 與 `<UC>Input.init` 必須同序；靠共用 helper 或互註人工維持（golden 測 #7 鎖 by-construction）。

### 依賴關係
- **來源共識**：`docs/discussions/2026-06-04-fixture-codegen-vs-skill.md`（D1–D9 + user 拍板）。
- **軟相依（done）**：Phase 1.x（`buildExecuteBody` 的 execute orchestration + catch-ladder rethrow GenesisTODO）、Phase 1.y（GenesisTODO throw-marker + genesis verify）、Phase 1.z（test-gen enabled-red：thunk 命名 fixture 的消費端）。
- **解鎖**：test-gen Lane-B Given 的機械半 + invariant-TDD loop（fixture 在 genesis-new 時即存在）。
- **後續**：`/fill-given`（用 codegen'd fixture 名 transcribe 人口述的 Given）；human preset 檔慣例；（migration-only）`/fixture-gen` skill for legacy 專案。
