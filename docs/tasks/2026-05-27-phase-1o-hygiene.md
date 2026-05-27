# Phase 1.o — Hygiene phase (F2 / F3a-c / F5 — OC alignment + TODO marker unify + event.yaml map shape)

## 來源

討論：`docs/discussions/2026-05-27-phase-1o-hygiene.md`

依賴 Phase（全 done）：phase-1l（Usecase Input OC alignment）、phase-1n（type ownership routing）、2026-05-26-usecase-skill（/usecase skill v1）。

合做 dogfood findings：F2 + F3a-c + F5（原 F3 認知錯誤已 reframe，詳討論 MD § 業務認知修正）。

## 目標

統一 codegen 輸出與 OC ground truth + DDD-kit upstream sample 對齊，解決 dogfood Layer 2 留下的 3 個 hygiene 缺口（合計 5 個小 fix）：

1. Service 從 `class` 改成 OC convention 的 `struct`
2. Usecase protocol syntax 從 `Usecase<I, O>` 改成 OC 用的 `Usecase where Input == I, Output == O`
3. Usecase extension execute() stub 統一 marker 為 `fatalError("TODO(/usecase skill)")`（對齊 /api /presenter-fill /readmodel-mutation 三個 fill skill 既有 pattern）+ 移除 `// GENESIS-STUB:` 註解
4. event.yaml properties 從 array shape `- name: X\n  type: "Y"` 改成 DDD-kit upstream sample 一致的 map shape `X: "Y"`（全部 type value 加 double-quote）
5. /usecase skill SKILL.md 同步更新 detection markers 避免 codegen 改後 skill 找不到 fill target

---

## 介面合約

### 修改：Service.swift.template

新 contract（D2 lock）：

```swift
import DDDKit

package struct {UC}Service: {UC}Usecase {
    package let repository: {Aggregate}Repository

    package init(repository: {Aggregate}Repository) {
        self.repository = repository
    }
}
```

差異：`package final class` → `package struct`。其他內容（import、property、init）不變。

**所有權明示**：Service struct 永遠是空殼（只有 init + stored properties），業務邏輯永遠住在 `extension {UC}Usecase` 的 default `execute()` 實作裡。**`/usecase` skill fill target 是 protocol extension，不是 Service**。Phase 1.l 已確認此 OC pattern。

### 修改：Usecase.swift.template

新 contract（D3 + D4 lock）：

```swift
import DDDKit
{SharedImport}

package protocol {UC}Usecase: Usecase where Input == {UC}Input, Output == {UC}Output {
    var repository: {Aggregate}Repository { get }
}

extension {UC}Usecase {
    package func execute(input: {UC}Input) async throws -> {UC}Output {
        fatalError("TODO(/usecase skill): pattern is repository.find → aggregate.{useCaseCamelCase}(...) → repository.save → return Output")
    }
}
```

差異：
- protocol declaration：`: Usecase<{UC}Input, {UC}Output>` → `: Usecase where Input == {UC}Input, Output == {UC}Output`
- extension execute() body：移除 `// GENESIS-STUB: ...` 註解 + 移除 `fatalError("not implemented")`，替換為單行 `fatalError("TODO(/usecase skill): pattern is ...")`

**所有權明示**：`{useCaseCamelCase}` 與 `{SharedImport}` 既有 placeholder 由 `UseCaseRenderer.renderUsecase` 傳入。本 phase 不新增 placeholder。

### 修改：`AggregateRenderer.renderEventBlock` properties 輸出

新 contract（D5 lock）：

**Per-field emission（payload non-empty 分支）**：

```swift
// Before
propLines.append("    - name: \(field.name)")
propLines.append("      type: \"\(resolved)\"")

// After
propLines.append("    \(field.name): \"\(resolved)\"")
```

**Fallback emission（payload empty 分支）**：

```swift
// Before
propLines.append("    - name: \(alias)")
propLines.append("      type: \"String\"")

// After
propLines.append("    \(alias): \"String\"")
```

**輸出範例**：

```yaml
# Before (current array shape)
properties:
  - name: userId
    type: "String"
  - name: permissions
    type: "[String]"

# After (Phase 1.o map shape, all values quoted)
properties:
  userId: "String"
  permissions: "[String]"
```

**Quote 規則**：所有 type value 無條件加 double-quote（per D5 user 拍板 = B 全部加 quote）。Reason：邏輯簡單、無需動態 YAML special char 偵測、避免 `[String]` / `Set<X>` 被 YAML parser 解為 flow sequence。

**Container types 仍包含 special char**（`[`、`<`、`>`、`?`）— quote 包住後 YAML parser 視為 plain string，正確。

**deletedEvent 分支不受影響**：既有 `\(deletedEventTypeName):\n  kind: deletedEvent\n` 直接 hardcode，無 properties，無需改動。

### 修改：/usecase skill SKILL.md detection markers

新 detection 規則（D6 lock）：

| 狀態 | 偵測規則 | 行為 |
|---|---|---|
| 已填 | 不含 `fatalError("TODO(/usecase skill)")`，且含 `repository.find` 或 `try <A>(id:` + `repository.save` 或 `repository.delete` | exit 0 skip |
| 未填 | 含 `fatalError("TODO(/usecase skill)")` | 套 pattern fill |

差異：
- 「未填」由原本「`fatalError("not implemented")` + `// GENESIS-STUB:` 註解」雙重 marker → 單一 `fatalError("TODO(/usecase skill)")` marker
- 「已填」由原本「無 `fatalError("not implemented")`」→「無 `fatalError("TODO(/usecase skill)")`」
- description 第一段 + Step 規則 + 範例 fill body 所有 `fatalError("not implemented")` / `GENESIS-STUB:` 字串全部對齊新 marker

### Framework 備註

- 不涉及 Swift ArgumentParser / SwiftNIO 等 framework 改動
- DDD-kit 0.3.0 `DomainEventGeneratorPlugin` 接受兩種 event.yaml 格式（array shape + map shape 都跑），本 phase 切到 map shape **無 backward compat 問題**
- Swift `protocol Foo: Bar<X, Y>` 與 `protocol Foo: Bar where X == ..., Y == ...` 兩種 syntax compile 結果語意完全等價，無 framework 限制

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Service.swift.template` | `package final class` → `package struct`（D2） |
| `Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template` | protocol syntax `Usecase<I,O>` → `Usecase where Input == I, Output == O`（D3）+ extension execute() body unify marker（D4） |
| `Sources/GenesisCore/AggregateRenderer.swift` | `renderEventBlock` 兩處 propLines.append 改 array → map shape（D5） |
| `Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md` | detection markers + description + 範例 fill body 全部對齊新 marker（D6） |
| `Tests/GenesisCoreTests/AggregateRendererTests.swift` | `testEventYamlQuotesContainerTypes` 期望值更新：`type: "[String]"` → `permissions: "[String]"` 等 map shape assertion |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | 若有 assertion 依賴 Service `class` 字串或 Usecase `Usecase<I,O>` 字串需更新；新增 assertion 確認 `package struct ...Service` 與新 protocol syntax 出現 |

### Affected call sites（非改動，但受影響）

- `Sources/GenesisCore/UseCaseRenderer.swift` `renderUsecase` / `renderService` — caller 不改動（只是讀新 template，placeholder substitution 邏輯不變）
- `Sources/GenesisCore/Resources/Templates/v0.1/CLAUDE.md.template` 內「fatalError("not implemented")」字串作為**convention reference 描述**（廣義 stubs 概念，並非 skill detection 字串）— 保留，不在 Phase 1.o scope
- `Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template` / `CommandExtension.swift.template` / `ValueObject.swift.template` 內既有的 `// GENESIS-STUB:` 註解 + `fatalError("not implemented")` — 這些是 user / 未來 skill fill target，**不在 Phase 1.o scope**（per Non-goals）
- `Sources/GenesisCore/AggregateRenderer.swift` 內 `lines.append("    case placeholder  // GENESIS-STUB: no invariants declared in bundle")` 為 enum case placeholder，非 fill target — 保留

---

## 實作步驟

### Step 1：`Service.swift.template` — class → struct

1. 找到 `package final class {UC}Service: {UC}Usecase {`
2. 替換為 `package struct {UC}Service: {UC}Usecase {`
3. body 其他 3 行（property + init）不動

### Step 2：`Usecase.swift.template` — protocol syntax + extension execute body

1. 找到 `package protocol {UC}Usecase: Usecase<{UC}Input, {UC}Output> {`
2. 替換為 `package protocol {UC}Usecase: Usecase where Input == {UC}Input, Output == {UC}Output {`
3. 在 extension 區塊找到三行：
   ```
       package func execute(input: {UC}Input) async throws -> {UC}Output {
           // GENESIS-STUB: pattern is `repository.find → aggregate.{useCaseCamelCase}(...) → repository.save → return Output`.
           fatalError("not implemented")
       }
   ```
4. 替換為：
   ```
       package func execute(input: {UC}Input) async throws -> {UC}Output {
           fatalError("TODO(/usecase skill): pattern is repository.find → aggregate.{useCaseCamelCase}(...) → repository.save → return Output")
       }
   ```

### Step 3：`AggregateRenderer.renderEventBlock` — map shape

1. 找到 `renderEventBlock` private static 函數內 `for field in payload` 迴圈
2. **Branch A（payload 非空）**：兩行 `propLines.append("    - name: \(field.name)")` + `propLines.append("      type: \"\(resolved)\"")` 替換為單行 `propLines.append("    \(field.name): \"\(resolved)\"")`
3. **Branch B（payload empty fallback，`if propLines.isEmpty`）**：兩行 `propLines.append("    - name: \(alias)")` + `propLines.append("      type: \"String\"")` 替換為單行 `propLines.append("    \(alias): \"String\"")`
4. 函數其他邏輯（template loading + render）不動

### Step 4：`/usecase` SKILL.md — detection markers + description + fill examples

1. **description 第一段（frontmatter `description:` 之後第一行）**：
   - 找：`fills the \`fatalError("not implemented")\` GENESIS-STUB in \`{UC}Usecase.swift\` extension's \`execute(input:)\` body`
   - 改：`fills the \`fatalError("TODO(/usecase skill)")\` stub in \`{UC}Usecase.swift\` extension's \`execute(input:)\` body`

2. **Step 段「對 {UC}Usecase.swift 內 ...」**：
   - 找：`把 Phase 1.g/1.h 留下的 \`fatalError("not implemented")\` GENESIS-STUB 替換為 OC pattern`
   - 改：`把 Phase 1.g/1.h 留下的 \`fatalError("TODO(/usecase skill)")\` stub 替換為 OC pattern`

3. **「只動」段落**：
   - 找：`extension default execute() body 的 \`fatalError("not implemented")\` 替換`
   - 改：`extension default execute() body 的 \`fatalError("TODO(/usecase skill)")\` 替換`

4. **detection table（已填 / 未填）**：
   - 「已填」一列：`且**無** \`fatalError("not implemented")\`` → `且**無** \`fatalError("TODO(/usecase skill)")\``
   - 「未填」一列：`含 \`fatalError("not implemented")\` + \`// GENESIS-STUB:\` 註解` → `含 \`fatalError("TODO(/usecase skill)")\``

5. **scan/全文核對**：SKILL.md 內所有 `fatalError("not implemented")` 字串 + `GENESIS-STUB` 字串都對齊新 marker（單 marker 概念）

**Caution**：SKILL.md 不可破壞「3 patterns（Create / Update / Delete）」分類邏輯，detection 規則改變僅限於 marker 字串本身。

### Step 5：`AggregateRendererTests.swift` — `testEventYamlQuotesContainerTypes` assertion 更新

1. 找到 testEventYamlQuotesContainerTypes 函數
2. 替換 assertion：
   - 移除 `XCTAssertTrue(yaml.contains("type: \"[String]\""), ...)` 與 `XCTAssertTrue(yaml.contains("type: \"String\""))`
   - 加入 `XCTAssertTrue(yaml.contains("permissions: \"[String]\""), "map shape: container types must be quoted")` （`permissions` 為 iam-bundle UserAccessProfile state 的 collection field 名）
   - 加入 `XCTAssertTrue(yaml.contains("userId: \"String\""), "map shape: scalar types still quoted per Phase 1.o D5")`
3. 其他 assertion（`PrivilegeGranted:`、`kind: ...`、`alias: ...`、`UserAccessProfileDeleted:`、`kind: deletedEvent`）保留 — 不受 properties shape 影響
4. testDeletedEventYamlOmitsAliasAndProperties 不動（既有 assert 已用 `properties:` 字串檢查 deletedEvent 內無 properties，新 shape 不影響此 assertion 意圖）

### Step 6：`NewCommandTests.swift` — Service struct + protocol syntax assertion

1. Grep `Service.swift` content assertions（如果有）— 若有 `package final class XService` 字串斷言，改 `package struct XService`
2. 新增（如果沒有的話）一個 light-touch assertion 在 `testGenesisNewIAMBundleEndToEnd` 或類似既有的「黃金路徑」test 內：
   ```swift
   let svcContent = try String(contentsOf: tmpDir.appendingPathComponent("Sources/UserAccessProfileAggregate/Usecase/Service/CreateUserAccessProfileService.swift"), encoding: .utf8)
   XCTAssertTrue(svcContent.contains("package struct CreateUserAccessProfileService"), "Phase 1.o D2: Service is struct not class")
   XCTAssertFalse(svcContent.contains("package final class CreateUserAccessProfileService"), "Phase 1.o D2: no class form")

   let ucContent = try String(contentsOf: tmpDir.appendingPathComponent("Sources/UserAccessProfileAggregate/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileUsecase.swift"), encoding: .utf8)
   XCTAssertTrue(ucContent.contains("Usecase where Input == CreateUserAccessProfileInput, Output == CreateUserAccessProfileOutput"), "Phase 1.o D3: where-clause protocol syntax")
   XCTAssertTrue(ucContent.contains("fatalError(\"TODO(/usecase skill)"), "Phase 1.o D4: unified TODO marker")
   XCTAssertFalse(ucContent.contains("fatalError(\"not implemented\")"), "Phase 1.o D4: no legacy marker")
   XCTAssertFalse(ucContent.contains("GENESIS-STUB:"), "Phase 1.o D4: no GENESIS-STUB comment in Usecase")
   ```
3. 路徑可用 `find` 對應實際 codegen 結構（aggregate 目錄底下的 Usecase/ subfolder pattern）。若實際 codegen 路徑不同（如 Usecase/Port/In 結構），調整為實際路徑。

---

## 失敗路徑

主要錯誤傳播鏈：

### Template substitution fail（既有機制保留）

- `TemplateRenderer.render` 對 Service / Usecase template 內 `{UC}` / `{Aggregate}` / `{SharedImport}` / `{useCaseCamelCase}` placeholder 仍正常 substitute
- 若 placeholder 漏傳，rendered output 仍含 `{X}` literal → 既有 `precondition(unresolvedVariables.isEmpty)` 機制觸發 — 不可恢復 build-time error
- Phase 1.o 不新增 placeholder，所以這條路不會新觸發

### /usecase skill detection 誤判（重要 — 已透過 D6 解決）

- 若 SKILL.md 沒同步更新 marker，skill 會用舊 marker 搜，永遠找不到 `fatalError("not implemented")`（已被改成 `TODO(/usecase skill)`）→ skill 認為「已填」，silent skip，user 看不到 fill 行為
- 對策：D6 同 PR 強制更新 SKILL.md，避免拆分兩 phase。**Step 4 必做**。
- 驗收：「Agent 必做」內 grep SKILL.md 確認新 marker 字串 + 確認舊 marker 字串完全消失

### event.yaml DDD-kit parser fail（理論上不可能）

- DDD-kit `DomainEventGeneratorPlugin` 接受 array + map 兩種 properties shape
- 新 shape 全 value 加 quote → YAML parser 視為 plain string，無 flow-sequence 誤判風險
- 不會拋 plugin error；若拋，是 DDD-kit upstream regression 而非 Genesis 端問題

### Genesis project user 已部分 fill 後 re-run /usecase skill 的相容性

- 既有 Genesis project（Phase 1.l/1.m 之前生）裡 Usecase.swift 含舊 marker `fatalError("not implemented")` + `// GENESIS-STUB:`
- Phase 1.o 後 /usecase skill 僅認新 marker → 老檔被誤判「已填」silent skip
- **本 phase 接受此 backward incompat**（per 約束「沒有 backward compat 包袱：Phase 1.l/1.m 剛 ship，無『舊版生成的 Genesis project』回收問題」）
- User 處理方式：重跑 `genesis new`（生成端會用新 marker 重 emit），或手動把舊 marker 改新（簡單 sed 一次）

---

## 不改動的部分

- `Aggregate.swift.template` 內既有 `// GENESIS-STUB:` 註解 + `fatalError("not implemented")` — 是 user / 未來 Aggregate skill fill target，**不在 Phase 1.o scope**
- `CommandExtension.swift.template` 內同上 — 不在 scope
- `ValueObject.swift.template` 內同上 — 不在 scope
- `AggregateRenderer.swift` 內 `case placeholder  // GENESIS-STUB: no invariants declared in bundle` 字串 — 是 enum case placeholder，非 fill target
- `CLAUDE.md.template` 內 `fatalError("not implemented")` convention 描述 — 是廣義專案文件，不是 skill detection 字串
- 其他 /api / /presenter-fill / /readmodel-mutation 三個 fill skill 既有 marker 已用 `TODO(/<skill>)` pattern，**不需改動**
- 整個 `SwiftTypeResolver` / `AdapterApplier` / `BundleParser` / `OpenApiYamlRenderer` / `PackageRenderer` / `NewCommand` 主流程
- DTOs / ReadModels / Presenters / Server emit
- `genesis install-skills` 流程（將 /usecase SKILL.md 同步安裝到 ~/.claude/skills/usecase/ — 既有 install-skills 邏輯自動處理）

### Non-goals（行為層）

- 本 task **不**改變 /usecase skill 的 3 patterns（Create / Update / Delete）分類邏輯
- 本 task **不**改變 codegen 結構（Service / Usecase / event.yaml 目錄路徑）
- 本 task **不**新增 Service variant（OC 部分 Service 多帶 `validator` dependency，本 phase 不支援，留 v2）
- 本 task **不**統一其他 template 的 `fatalError("not implemented")` marker（Aggregate / Command / ValueObject — 各自 fill flow 待未來 skill 實作再決定 marker convention）
- 本 task **不**改 DDD-kit `event-generator-config.yaml` 內容（只改 event.yaml 本身）
- 本 task **不**改變 Cosmogony emit 行為
- 本 task **不**支援 backward compat 處理舊版 Genesis 生成的 project（per 約束）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# Build + 全 test suite
swift build 2>&1 | tail -5
# 期望: "Build complete!"

swift test 2>&1 | tail -10
# 期望: "Test Suite ... passed" 0 failures

# D2 — Service struct (not class)
grep -q 'package struct {UC}Service: {UC}Usecase' Sources/GenesisCore/Resources/Templates/v0.1/Service.swift.template
! grep -q 'package final class {UC}Service' Sources/GenesisCore/Resources/Templates/v0.1/Service.swift.template

# D3 — Usecase protocol syntax (where clause)
grep -q 'Usecase where Input == {UC}Input, Output == {UC}Output' Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template
! grep -q 'Usecase<{UC}Input, {UC}Output>' Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template

# D4 — Usecase extension stub: unified marker only, no legacy
grep -q 'fatalError("TODO(/usecase skill)' Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template
! grep -q 'fatalError("not implemented")' Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template
! grep -q 'GENESIS-STUB' Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template

# D5 — AggregateRenderer renderEventBlock map shape
# Source-level grep skipped intentionally (Swift string interpolation escaping unreliable in grep);
# E2E grep on emitted event.yaml file below covers this.
! grep -F '"    - name: \(field.name)"' Sources/GenesisCore/AggregateRenderer.swift

# D6 — /usecase SKILL.md unified detection markers
grep -q 'TODO(/usecase skill)' Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md
! grep -qF 'fatalError("not implemented")' Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md
! grep -q 'GENESIS-STUB' Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md

# E2E — genesis new with iam-bundle.json emits correct shapes
TMPDIR=$(mktemp -d)
swift run genesis new IAMContext \
    --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json \
    --output "$TMPDIR" --no-git --skip-build 2>&1 | tail -3

# Service struct emission
grep -q 'package struct CreateUserAccessProfileService' "$TMPDIR/Sources/UserAccessProfileAggregate/Usecase/Service/CreateUserAccessProfileService.swift"
! grep -q 'package final class CreateUserAccessProfileService' "$TMPDIR/Sources/UserAccessProfileAggregate/Usecase/Service/CreateUserAccessProfileService.swift"

# Usecase protocol where clause + new TODO marker
UCFILE=$(find "$TMPDIR/Sources/UserAccessProfileAggregate" -name "CreateUserAccessProfileUsecase.swift" | head -1)
test -n "$UCFILE"
grep -q 'Usecase where Input == CreateUserAccessProfileInput, Output == CreateUserAccessProfileOutput' "$UCFILE"
grep -q 'fatalError("TODO(/usecase skill)' "$UCFILE"
! grep -q 'fatalError("not implemented")' "$UCFILE"
! grep -q 'GENESIS-STUB' "$UCFILE"

# event.yaml map shape
EYFILE="$TMPDIR/Sources/UserAccessProfileAggregate/event.yaml"
test -f "$EYFILE"
grep -qE '^\s+permissions: "\[String\]"' "$EYFILE"
grep -qE '^\s+userId: "String"' "$EYFILE"
! grep -qE '^\s+- name: ' "$EYFILE"

rm -rf "$TMPDIR"
```

### Human 補做（需要人類介入）

- [ ] 拿 user real bundle `~/Downloads/IAM Context Bundle.json` 重跑 `genesis new IAMContext --from-bundle ... --no-git --skip-build` 目視確認：
  - `Sources/UserAccessProfileAggregate/Usecase/Service/CreateUserAccessProfileService.swift` 為 `package struct`
  - `Sources/UserAccessProfileAggregate/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileUsecase.swift` protocol 含 `Usecase where Input == ..., Output == ...`，extension execute() body 為單行 `fatalError("TODO(/usecase skill): pattern is ...")`
  - `Sources/UserAccessProfileAggregate/event.yaml` properties 區塊為 `<fieldName>: "<type>"` map shape，無 `- name:` array shape
  - stderr 應仍含 Phase 1.n 的 EmployeeStatus warning（不受 Phase 1.o 影響）
- [ ] 進 `~/.claude/skills/usecase/SKILL.md` 確認 install-skills 後內容與 Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md byte-identical（既有 SkillInstaller 不變，自動 mirror）

---

## 已知限制

- **Backward compat 不處理**：舊版 Genesis 生成的 project 內含舊 marker `fatalError("not implemented")` + `// GENESIS-STUB:`，Phase 1.o 後 /usecase skill 對舊 project silent skip。User 須重跑 `genesis new` 或手動更新 marker。
- **Aggregate / Command / ValueObject 的 fatalError marker 仍是舊 pattern**：本 phase 只統一 Usecase 一個，因為 Usecase 是唯一已 ship 的 fill skill target；其他 3 個 template 等對應 skill 實作時才一起改。
- **不支援 Service 多 dependency 變體**：OC 部分 Service 帶 `validator: RecipientQuotingCaseValidator`，本 phase 不支援，留 v2 / Phase 1.p 起再做。
- **OC 對齊範圍限於 syntax + struct**：Service struct + protocol where-clause 是表面對齊；更深的 OC pattern（如 cross-aggregate validator 注入）不在 scope。

### 依賴關係

- 前置：無 hard depends_on（Phase 1.l/1.m/1.n 全 done）
- 後續：Phase 1.p 候選 — Service multi-dependency variant / Aggregate skill / Command skill / 真實 dogfood Layer 3
