# Phase 1.f — Genesis bootstrap ContextShared infra

## 來源

討論：`docs/discussions/2026-05-18-phase-1f-context-shared-infra.md`

Ground truth refs：
- Gemini facts report 2026-05-18（OC OCShared/ 26 file inventory + classification）
- Codex audit of `/api` skill v1 spec（揭露 H3 + H5：ApplicationService 與 Iso8601ParsingError 缺漏）
- OC source: `/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/OCShared/`
- Phase 1.e 既有結構：`Sources/GenesisCore/Resources/Templates/v0.1/`

## 目標

Genesis Phase 1.f 在 `Sources/{Ctx}Shared/` 自動 bootstrap 8 個 Swift 檔 + 1 個 README，補上 `ApplicationService` 協議、`ContextError<E>` wrapper、`Iso8601ParsingError` + `Date.parseIso8601` helpers、`ProjectionReadInconsistency`、`InvalidDecimalStringError`、3 個 String extensions — 全部 OC `OCShared/` CORE/CONVENTION 層 verbatim 或 minor 改寫。完成後 `/api` / `/usecase` / `/readmodel` 等 per-feature skills 可依賴這些 infra 存在；解除 `/api` skill v1 spec 的 H3/H5 blocker；不破壞 Phase 1.e 既有 build verification (`/tmp/phase1e-manual` swift build 仍通過)。

---

## 介面合約（Interface Contract）

### Genesis 產出的 `{Ctx}Shared/` 目錄結構（Phase 1.f 改後）

```
Sources/{Ctx}Shared/
├── README.md                              # Genesis-authored charter
├── ApplicationService.swift               # protocol
├── ContextError.swift                     # generic wrapper
├── Iso8601.swift                          # Iso8601ParsingError + Date helpers (no TZ default)
├── InvalidDecimalStringError.swift        # marker error
├── ProjectionReadInconsistency.swift      # read-side error
├── String+IsBlank.swift                   # CONVENTION
├── String+PascalCase.swift                # CONVENTION
├── String+StrippingPrefix.swift           # CONVENTION
│
└── <DTO>.swift                            # bundle-driven DTOs (Phase 1.b legacy, unchanged)
```

新增 8 個 Swift 檔 + 1 個 README，皆 `package` access。bundle-driven DTO emission（Phase 1.b 既有）**不動**。

### File contracts（per-file）

**`ApplicationService.swift`** — verbatim except doc comment (中→英)：
```swift
/// Application service protocol bridging API transport and domain. Write-model and read-model adapters both conform.
package protocol ApplicationService {
    associatedtype Input
    associatedtype Output

    func execute(input: Input) async throws -> Output
}
```

**`ContextError.swift`** — verbatim from OC. Generic `ContextError<ErrorType: Error & Equatable>` with `Source` enum + custom `Equatable` (ignores message/source/timestamp, compares only `error`). Used by Usecase / ApiHandler / ApiComponents+ApiError. Imports `Foundation` only.

**`Iso8601.swift`** — **modified** from OC `Date+ISO8601.swift`：
- KEEP: `Iso8601ParsingError`、`Date(iso8601:timeZone:)`、`Date.iso8601String(timeZone:)`、`Date.parseIso8601(_:timeZone:)` (both overloads)、`ISO8601DateFormatter` convenience init
- DROP: `TimeZoneConstants.taipei`、`Calendar.taipei`（Taiwan-conventional，不 generic）
- CHANGE: 所有 `timeZone: TimeZone = TimeZoneConstants.taipei` 預設改 `timeZone: TimeZone = .gmt`（forward-safe；user 若要 project-wide TZ，自行加 `TimeZoneConstants.swift` + 改 call sites）

**`InvalidDecimalStringError.swift`** — 從 OC `Decimal+Parsing.swift` 萃取，僅 marker struct：
```swift
import Foundation

package struct InvalidDecimalStringError: Error {
    package init() {}
}
```

不 bootstrap `Decimal.parse(_:)` helper（OC 也沒有；user 自行加）。檔名改為 `InvalidDecimalStringError.swift`（OC `Decimal+Parsing.swift` misleading；只有 error type 沒 parsing helper）。

**`ProjectionReadInconsistency.swift`** — verbatim。零 import 依賴。

**`String+IsBlank.swift`** — verbatim。含全形空格 awareness（Taiwan-conventional 但無害）。

**`String+PascalCase.swift`** — verbatim。

**`String+StrippingPrefix.swift`** — verbatim。

**`README.md`** — Genesis-authored，neutral 英文。frontmatter 含 `generated: <date> / generator: Genesis v0.1.0-phase1f / context: {ContextName}`。

### `GenesisCoreVersion.current` bump

- 從 `"0.1.0-phase1e"` → `"0.1.0-phase1f"`
- 影響：Phase 1.e 的 `checkExistingManifestVersion` preflight 會拒絕舊 phase1e manifest 的 dir 重跑（per Phase 1.e Step 11；預期行為）
- error message 已含「remove the directory or use a different --output」hint，user 自行處理

### `SharedTargetRenderer` extension

新增方法/邏輯（不破壞既有 DTO/customType emission）：

```swift
public enum SharedTargetRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter
    ) throws -> [(path: String, content: String, role: String)] {
        // Phase 1.f: 在原 DTO/customType emission 邏輯後，總是 emit 9 個 infra 檔
        var outputs: [(String, String, String)] = []
        outputs.append(contentsOf: try renderBundleDtosAndCustomTypes(bundle: bundle, contextName: contextName, adapter: adapter))
        outputs.append(contentsOf: try renderInfraFiles(contextName: contextName))
        return outputs
    }

    // Existing DTO/customType emission becomes a private helper renderBundleDtosAndCustomTypes
    private static func renderBundleDtosAndCustomTypes(...) throws -> [(String, String, String)] { ... }

    // Phase 1.f new: emits 9 infra files unconditionally
    private static func renderInfraFiles(contextName: String) throws -> [(String, String, String)] { ... }
}
```

`renderInfraFiles` 對 9 個 template 各做：
- For 8 .swift template 檔：`TemplateLoader.loadTemplate(name: "Shared/<Name>.swift", ext: "template")` → 內容直接 emit（無 placeholder 需替換 in v1）
- For `README.md.template`：`TemplateRenderer.render(template:, vars: ["ContextName": contextName, "GenesisVersion": GenesisCoreVersion.current])`

返回 (path, content, role) tuples，role 用 `"sharedInfra"`（新 role，與 Phase 1.b 既有 `"customEnum"` / `"valueObject"` / `"idWrapper"` / `"dto"` 並列）。

### `PackageRenderer.needsShared` 改動

```swift
// Phase 1.f: infra is universal — Shared/ target ALWAYS needed.
// (Phase 1.e: needsShared = !bundle.dtos.isEmpty || !adapter.customTypes.isEmpty;
//  Phase 1.f drops the conditional — Shared target always emitted because infra is unconditional.)
let needsShared = true
```

同步改：`NewCommand.needShared` 條件（line `let needShared = ...`）一律 true。

副作用：原本沒 DTO 也沒 customTypes 的 bundle 也會建 `{Ctx}Shared` target。OK — 因為 infra 是 universal needed。

### 命名空間衝突排查

`Sources/{Ctx}Shared/` 既有 emission（bundle DTO + customType）的檔名清單來自：
- DTO names from `bundle.dtos[]` (e.g. `EmployeeStatus.swift`)
- customType names from `adapter.customTypes[]`（user yaml-authored）

infra 加進來的 9 個檔名：
- `ApplicationService.swift`、`ContextError.swift`、`Iso8601.swift`、`InvalidDecimalStringError.swift`、`ProjectionReadInconsistency.swift`、`String+IsBlank.swift`、`String+PascalCase.swift`、`String+StrippingPrefix.swift`、`README.md`

衝突檢測：若 user adapter yaml 中有 customType 名為 `ApplicationService`/`ContextError`/etc.（極不太可能），`SourceWriter.checkNoConflicts` 會 catch；Phase 1.f 不主動加額外 validation（既有 conflict gate sufficient）。

### Framework 限制

- All bootstrap files use `package` access — requires they all live in same SwiftPM package as the consuming aggregate targets（Phase 1.e PackageRenderer 已 cover）
- `ContextError.Source` enum has `actor` / `class` / `struct` / `enum` as backtick-escaped case names — must preserve verbatim
- `Iso8601.swift` uses `Date` + `TimeZone` + `ISO8601DateFormatter`，全部 cross-platform Foundation（macOS + Linux swift-corelibs-foundation 皆支援）

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/ApplicationService.swift.template` | **新檔** — verbatim from OC，doc comment 中譯英 |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/ContextError.swift.template` | **新檔** — verbatim from OC |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template` | **新檔** — OC `Date+ISO8601.swift` 萃取（移除 TimeZoneConstants.taipei + Calendar.taipei，timezone 預設改 `.gmt`） |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/InvalidDecimalStringError.swift.template` | **新檔** — OC `Decimal+Parsing.swift` 萃取，僅 marker error |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/ProjectionReadInconsistency.swift.template` | **新檔** — verbatim from OC |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/String+IsBlank.swift.template` | **新檔** — verbatim from OC |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/String+PascalCase.swift.template` | **新檔** — verbatim from OC |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/String+StrippingPrefix.swift.template` | **新檔** — verbatim from OC |
| `Sources/GenesisCore/Resources/Templates/v0.1/Shared/README.md.template` | **新檔** — Genesis-authored neutral charter，含 `{ContextName}` + `{GenesisVersion}` placeholder |
| `Sources/GenesisCore/SharedTargetRenderer.swift` | refactor `render(...)`：拆 existing logic 為 `renderBundleDtosAndCustomTypes`；加 `renderInfraFiles(contextName:)`；總是 emit infra 檔 |
| `Sources/GenesisCore/PackageRenderer.swift` | `needsShared` 改 `true` always（Phase 1.f: infra 永遠需要 Shared target） |
| `Sources/Genesis/Commands/NewCommand.swift` | `needShared` 鏡像改 `true` always |
| `Sources/GenesisCore/Version.swift` | `GenesisCoreVersion.current`: `"0.1.0-phase1e"` → `"0.1.0-phase1f"` |
| `Tests/GenesisCoreTests/SharedTargetRendererTests.swift` | 加 5 個測試：infra 檔皆 emit；contextName placeholder 正確替換；role = `"sharedInfra"`；bundle 無 DTO 時 infra 仍 emit；existing DTO emission regression |
| `Tests/GenesisCoreTests/PackageRendererTests.swift` | **既有 `testTypedStructDoesNotForceSharedTarget` invert**：Phase 1.f 改 `needsShared = true` always，原斷言「no DTO + no customType → 不產 Shared lib」已不成立。改測「典型 IAM 場景 Shared library 存在」（regression 仍 cover Shared 結構正確） |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | `testFullBundleEndToEnd` 加 9 個 infra file existence assertions；既有 `testEndToEndSwiftPackageResolveAndBuild` regression（warm cache 應仍 build 通過） |
| `Sources/GenesisCore/SourceWriter.swift` | 加 `checkNoPlannedDuplicates()` 或在 `plan(relativePath:content:)` 內偵測同一 run 內重複 path → throw `GenesisError.outputDirHasConflict(path: root, conflict: "duplicate planned path: <path>")`。防止 infra filename 撞 user customType name 時 silent overwrite |
| `Sources/Genesis/Commands/NewCommand.swift` | `checkExistingManifestVersion` 錯誤訊息改 version-generic（不寫死 phase1e wording） + 既有 needsShared 改動（前述）|
| `docs/decisions.md` | 加 Phase 1.f ratification entry（仿 D24/Phase 1.e ratification 格式） |
| `docs/architecture.md` | §3 path layout 補 `{Ctx}Shared/` 內 infra 9 個檔；§10.2 引用「ContextShared infra 由 Phase 1.f 提供」 |

**已確認不需改動**（write-spec step 3b 已逐一檢視）：
- `BundleParser` / `FullBundle`（無 schema change）
- `AggregateRenderer` / `ProjectionModelRenderer` / `UseCaseRenderer`（不引用新 infra）
- 既有 `DtoRenderer.swift`（bundle DTO emission 邏輯，Phase 1.b 既有，不影響）
- 既有 customType emission `SharedTargetRenderer.renderEnum/renderValueObject/renderIdWrapper` 私有 helpers
- `SourceWriter` / `GitPreflight` / `ProcessRunner` / `ManifestRenderer`（行為不變）
- Aggregate / Repository / event.yaml / projection-model.yaml templates（Phase 1.e 既有，infra 是 sibling target 不影響 aggregate compile）

---

## 實作步驟

### Step 1 — 寫 9 個 template 檔到 `Templates/v0.1/Shared/`

1. `mkdir -p Sources/GenesisCore/Resources/Templates/v0.1/Shared/`
2. 對每個 OC source file，用 Read 確認 verbatim，然後 Write 對應 .template 檔到 Shared/。
3. **逐檔注意**：
   - `ApplicationService.swift.template`：把 OC 中文 doc-comment 改英文（其餘 verbatim）
   - `ContextError.swift.template`：verbatim（含 `Source.actor` 等 backtick-escaped case 名）
   - `Iso8601.swift.template`：從 OC `Date+ISO8601.swift` 拷貝後修改 — 移除 `TimeZoneConstants` enum + `Calendar.taipei` extension，4 個 method 的 `timeZone: TimeZone = TimeZoneConstants.taipei` → `timeZone: TimeZone = .gmt`
   - `InvalidDecimalStringError.swift.template`：only `import Foundation` + struct decl
   - `ProjectionReadInconsistency.swift.template`：verbatim（含 doc comment）
   - 3 個 String extensions：verbatim
   - `README.md.template`：寫 frontmatter (`generator: Genesis v{GenesisVersion}` / `context: {ContextName}` / `generated: {Date}`) + Genesis 版 charter（neutral 英文，3 個 yes/no 加入判準、9 個 infra 檔清單）

### Step 2 — refactor `SharedTargetRenderer.render`

1. 讀現有 `SharedTargetRenderer.swift` 的 `render(...)` 完整邏輯
2. 將既有 byName 構建 + emit custom types + emit bundle.dtos 邏輯**整段移**到新 `private static func renderBundleDtosAndCustomTypes(bundle:contextName:adapter:) throws -> [(String, String, String)]`
3. 新增 `private static func renderInfraFiles(contextName: String) throws -> [(String, String, String)]`：
   ```
   let sharedDir = "Sources/\(contextName)Shared"
   var outputs: [(String, String, String)] = []
   
   // 8 Swift infra files: load template, write as-is (no placeholder substitution needed)
   for fileName in ["ApplicationService.swift", "ContextError.swift", "Iso8601.swift",
                    "InvalidDecimalStringError.swift", "ProjectionReadInconsistency.swift",
                    "String+IsBlank.swift", "String+PascalCase.swift", "String+StrippingPrefix.swift"] {
       let template = try TemplateLoader.loadTemplate(name: "Shared/\(fileName)", ext: "template")
       outputs.append(("\(sharedDir)/\(fileName)", template, "sharedInfra"))
   }
   
   // README.md with placeholder substitution.
   // ⚠️ vars dict MUST include all 3 keys ContextName/GenesisVersion/Date — README template uses all 3;
   // missing one would leave `{Date}` unresolved in output, caught by `unresolvedVariables.isEmpty` assertion.
   let readmeTemplate = try TemplateLoader.loadTemplate(name: "Shared/README.md", ext: "template")
   let readmeRendered = TemplateRenderer.render(
       template: readmeTemplate,
       vars: [
           "ContextName": contextName,
           "GenesisVersion": GenesisCoreVersion.current,
           "Date": String(ISO8601DateFormatter().string(from: Date()).prefix(10))
       ]
   )
   precondition(readmeRendered.unresolvedVariables.isEmpty,
                "README.md.template has unresolved placeholder(s): \(readmeRendered.unresolvedVariables)")
   outputs.append(("\(sharedDir)/README.md", readmeRendered.output, "sharedInfra"))
   
   return outputs
   ```
4. 主 `render(...)` 改為：
   ```
   public static func render(bundle:contextName:adapter:) throws -> [(String, String, String)] {
       var outputs: [(String, String, String)] = []
       outputs.append(contentsOf: try renderBundleDtosAndCustomTypes(bundle: bundle, contextName: contextName, adapter: adapter))
       outputs.append(contentsOf: try renderInfraFiles(contextName: contextName))
       return outputs
   }
   ```
5. ⚠️ TemplateLoader 加載 `Shared/<file>.swift` 形式 — 確認 `TemplateLoader.loadTemplate` 支援 subdirectory（Phase 1.e 已加 `Shared/<file>` 模式於 `PackageSharedProduct.swift.template` 用法，無需新加 API）

### Step 3 — `PackageRenderer` + `NewCommand` 改 needsShared always-true

1. `PackageRenderer.render`：
   ```diff
   - let needsShared = !bundle.dtos.isEmpty
   -     || !adapter.customTypes.isEmpty
   + // Phase 1.f: infra is universal — Shared target ALWAYS needed.
   + let needsShared = true
   ```
2. `NewCommand.run`：相同改動於 `let needShared = ...` 那行
3. Phase 1.e 既有的 condition 變 dead code — 移除而非 commented out（per CLAUDE.md「avoid backwards-compat shims」）

### Step 4 — Version bump

1. `Sources/GenesisCore/Version.swift`：`"0.1.0-phase1e"` → `"0.1.0-phase1f"`
2. 既有 `checkExistingManifestVersion` 對舊 phase1e manifest 直接 reject — 預期行為（不改）

### Step 5 — 測試補完

新增到 `Tests/GenesisCoreTests/SharedTargetRendererTests.swift`：

1. `testInfraFilesAlwaysEmitted`：bundle 含 DTO 時，paths 應含 9 個 infra 檔（除 bundle DTO + customType 外）
2. `testInfraFilesEmittedWithoutDTOs`：bundle 無 DTO 也無 customType 時，paths 仍含 9 個 infra 檔（needsShared always true → infra emit）
3. `testInfraFileContentApplicationService`：載 `ApplicationService.swift` 內容，含 `package protocol ApplicationService`、`associatedtype Input`、`associatedtype Output`、`func execute(input: Input)`
4. `testInfraFileContentContextError`：含 `package struct ContextError<ErrorType: Error & Equatable>`、`enum Source`、`static func == `
5. `testInfraFileContentIso8601NoTaipei`：`Iso8601.swift` 內容不含 `TimeZoneConstants` / `Calendar.taipei`，但含 `Iso8601ParsingError`、`Date.parseIso8601`
6. `testInfraFileReadmeHasContextPlaceholder`：`README.md` 內容含 contextName (e.g. "IAMContext")，且**不**含 `{ContextName}` 未替換 placeholder
7. `testInfraRoleIsSharedInfra`：all 9 emitted files have `role == "sharedInfra"`

新增到 `Tests/GenesisIntegrationTests/NewCommandTests.swift`：

8. `testFullBundleEndToEnd` 補 9 個 infra file existence assertions（path: `Sources/IAMContextShared/<name>`）
9. `testEndToEndSwiftPackageResolveAndBuild` 既有 env-gated test：應仍通過（infra 是 pure types，不引新依賴）

### Step 6 — Same-run duplicate planned path detection

**問題**：`SourceWriter.checkNoConflicts` 偵測 existing files-on-disk conflict，但若同一 `genesis new` 內兩個 renderer plan 同一 relative path，第二個 plan 會 silently overwrite 第一個（plan dict 用 path 為 key）。infra filename 撞 user customType name 時（極不太可能但 schema-permissive）→ silent infra loss。

1. 修 `SourceWriter.swift`：
   - 在 `plan(relativePath:content:)` 內偵測 `planned[url] != nil` → throw `GenesisError.outputDirHasConflict(path: root, conflict: "duplicate planned path: \(relativePath)")`
   - 或新加 `checkNoPlannedDuplicates()` 方法（在 `commit()` 前呼叫）
2. 加單元測試 `SourceWriterTests.testDuplicatePlannedPathThrows`：兩次 plan 相同 path → throw `outputDirHasConflict`
3. 補加錯誤訊息可讓 user 追蹤撞名來源（提示「check adapter customTypes for collision with Phase 1.f infra names」）

### Step 7 — Generic `checkExistingManifestVersion` error wording

1. `NewCommand.checkExistingManifestVersion` 既有錯誤訊息（Phase 1.e Step 11 加的）寫死 phase1e migration wording。改為 version-generic：
   ```
   "templateVersion='\(existingVersion)' is incompatible with current Genesis '\(GenesisCoreVersion.current)'. " +
   "Genesis does not support in-place template migration; " +
   "remove the directory or use a different --output."
   ```
2. 不再提 specific 「Phase 1.e moved aggregate to Entity/」字眼（每 phase bump 後不能再對；Genesis 不提供 migration guide）

### Step 8 — Docs

1. `docs/decisions.md`：加 Phase 1.f ratification entry：

   | Phase 1.f | **ContextShared infra bootstrap**：Genesis 在 `Sources/{Ctx}Shared/` 自動生 `ApplicationService.swift` 協議 + `ContextError.swift` generic wrapper + `Iso8601.swift` (Iso8601ParsingError + Date.parseIso8601 helpers, no TZ default) + `ProjectionReadInconsistency.swift` + `InvalidDecimalStringError.swift` + 3 個 String extensions + `README.md` — 全部對齊 OC `OCShared/` CORE/CONVENTION classification (per Gemini facts report 2026-05-18)。`needsShared` 改 always true。Genesis version → `0.1.0-phase1f`。**影響**：解除 `/api` skill v1 spec 的 H3+H5 blocker；後續 `/usecase` / `/readmodel` skills 可依賴此 infra 存在。Skip list：DtoConversionError（cases reference OC DTOs）、TimeZoneConstants.taipei + Calendar.taipei（Taiwan-conventional）、AggregateRootNames + 13 個 OC business DTOs。 | Phase 1.f ratification (2026-05-18) |

2. `docs/architecture.md`：
   - §3 Project structure：在 `{Shared}/` 行下補展開：
     ```
     ├── {Shared}/                            # Context-level shared (Phase 1.f infra)
     │   ├── ApplicationService.swift         # AS protocol
     │   ├── ContextError.swift               # generic error wrapper
     │   ├── Iso8601.swift                    # ISO8601 helpers + parsing error
     │   ├── InvalidDecimalStringError.swift  # marker error
     │   ├── ProjectionReadInconsistency.swift # read-side drift signal
     │   ├── String+IsBlank.swift             # convention helpers
     │   ├── String+PascalCase.swift
     │   ├── String+StrippingPrefix.swift
     │   ├── README.md                        # module charter
     │   └── <DTO>.swift                      # bundle-driven (Phase 1.b)
     ```
   - §10.2 加 note：「ContextShared infra（`ApplicationService` / `ContextError` / `Iso8601ParsingError` 等）由 Phase 1.f bootstrap；per-feature skills 可依賴它們存在」

---

## 失敗路徑

新增（皆既有 GenesisError case 重用，無新 case）：

- TemplateLoader 找不到 `Shared/<file>.swift.template` → 既有 `GenesisError.fileSystemFailed(operation: "load template", underlying:)`（exit 2）
- SourceWriter conflict（user dir 內既有同名檔）→ 既有 `GenesisError.outputDirHasConflict(path:, conflict:)`（exit 1）
- Phase 1.e manifest-version preflight reject（phase1e manifest 重跑）→ 既有 `GenesisError.outputDirHasConflict`（exit 1，stderr 含 incompatible-version hint）

既有失敗路徑不變：bundleNotFound (exit 1)、bundleInvalid (exit 1)、gitPreflightFailed (exit 3)、swiftPackageResolveFailed (exit 2)、swiftBuildFailed (exit 2)、fileSystemFailed (exit 2)。

---

## 不改動的部分

- `BundleParser` / `FullBundle` / 全部 spec types（無 schema change）
- `AggregateRenderer` / `ProjectionModelRenderer` / `UseCaseRenderer` / `DtoRenderer`
- 既有 customType emission helpers（`renderEnum` / `renderValueObject` / `renderIdWrapper` in `SharedTargetRenderer`）
- `SourceWriter` / `GitPreflight` / `ProcessRunner` / `ManifestRenderer`
- Aggregate / Repository / event.yaml / projection-model.yaml templates
- Phase 1.e 既有 path layout（`Entity/`、`Usecase/Port/Out/`、`Adapter/` 等）
- `genesis install-skills` 行為
- CLI flags（`--skip-build`、`--no-git`、`--adapter` 等）
- `GenesisError` enum cases（重用既有）

### Non-goals（行為層）

- 本 task 不 bootstrap `DtoConversionError`（cases reference OC DTOs；無 generic 等價物；defer 給 `/api` 或 future `/dto-union` skill）
- 本 task 不 bootstrap `TimeZoneConstants.taipei` + `Calendar.taipei`（Taiwan-conventional；user 自加）
- 本 task 不 bootstrap OC business DTOs（AggregateRootNames、QuotingBundleType、ConfigKey/Value、Pricing 等 13 個 skip list）
- 本 task 不 bootstrap FileType / FileTypeDto（presupposes file uploads；future `/file` skill）
- 本 task 不寫 `Decimal.parse(_:)` 完整 throwing helper（只 ship marker error）
- 本 task 不寫 ContextShared 的 unit tests（cheap defer；spec acceptance spot-check 即可）
- 本 task 不修 `/api` skill v1 spec（Phase 1.f 完之後另起 task revise）
- 本 task 不破壞 Phase 1.b/1.c 既有的 DTO/customType emission
- 本 task 不引入新 GenesisError case
- 本 task 不引入新 CLI flag
- 本 task 不改 bundle schema（FullBundle / BundleParser / aggregate.identity / readModels 等）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# A1. Genesis 自身能編譯
swift build -c release --product genesis

# A2. 全部 unit + integration tests 通過
swift test

# A3. 9 個 template 檔存在於 v0.1/Shared/
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/ApplicationService.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/ContextError.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/InvalidDecimalStringError.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/ProjectionReadInconsistency.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/String+IsBlank.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/String+PascalCase.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/String+StrippingPrefix.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Shared/README.md.template

# A4. Template 內容鎖定（key symbols）
grep -F 'package protocol ApplicationService' Sources/GenesisCore/Resources/Templates/v0.1/Shared/ApplicationService.swift.template
grep -F 'package struct ContextError<ErrorType: Error & Equatable>' Sources/GenesisCore/Resources/Templates/v0.1/Shared/ContextError.swift.template
grep -F 'package struct Iso8601ParsingError' Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template
grep -F 'package static func parseIso8601' Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template
grep -F 'package struct InvalidDecimalStringError' Sources/GenesisCore/Resources/Templates/v0.1/Shared/InvalidDecimalStringError.swift.template
grep -F 'package struct ProjectionReadInconsistency' Sources/GenesisCore/Resources/Templates/v0.1/Shared/ProjectionReadInconsistency.swift.template

# A5. Iso8601.swift.template 移除 Taipei timezone defaults
! grep -F 'TimeZoneConstants' Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template
! grep -F 'Calendar.taipei' Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template
! grep -F 'Asia/Taipei' Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template
grep -F '.gmt' Sources/GenesisCore/Resources/Templates/v0.1/Shared/Iso8601.swift.template

# A6. README.md.template 含 placeholders
grep -F '{ContextName}' Sources/GenesisCore/Resources/Templates/v0.1/Shared/README.md.template
grep -F '{GenesisVersion}' Sources/GenesisCore/Resources/Templates/v0.1/Shared/README.md.template
grep -F '{Date}' Sources/GenesisCore/Resources/Templates/v0.1/Shared/README.md.template

# A7. SharedTargetRenderer 新增 renderInfraFiles + 重構主 render
grep -F 'renderInfraFiles' Sources/GenesisCore/SharedTargetRenderer.swift
grep -F 'renderBundleDtosAndCustomTypes' Sources/GenesisCore/SharedTargetRenderer.swift

# A8. PackageRenderer + NewCommand needsShared 改 always true
grep -F 'let needsShared = true' Sources/GenesisCore/PackageRenderer.swift
grep -F 'let needShared = true' Sources/Genesis/Commands/NewCommand.swift
! grep -F '!bundle.dtos.isEmpty' Sources/GenesisCore/PackageRenderer.swift
! grep -F '!adapter.customTypes.isEmpty' Sources/GenesisCore/PackageRenderer.swift

# A9. Version bump
grep -F '0.1.0-phase1f' Sources/GenesisCore/Version.swift
! grep -F '0.1.0-phase1e' Sources/GenesisCore/Version.swift

# A10. Docs ratification
grep -F 'Phase 1.f' docs/decisions.md
grep -F 'ContextShared infra' docs/decisions.md
grep -F 'ApplicationService.swift' docs/architecture.md
grep -F 'Phase 1.f' docs/architecture.md

# A11. e2e — 重產 /tmp/phase1f-test，infra 9 個檔出現在 IAMContextShared/
rm -rf /tmp/phase1f-test && mkdir /tmp/phase1f-test
( cd /tmp/phase1f-test && git init -q )
BIN="$(swift build -c release --product genesis --show-bin-path)/genesis"
"$BIN" new IAMContext --from-bundle "Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json" --output /tmp/phase1f-test --skip-build
test -f /tmp/phase1f-test/Sources/IAMContextShared/ApplicationService.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/ContextError.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/Iso8601.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/InvalidDecimalStringError.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/ProjectionReadInconsistency.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/String+IsBlank.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/String+PascalCase.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/String+StrippingPrefix.swift
test -f /tmp/phase1f-test/Sources/IAMContextShared/README.md
# 既有 DTO 仍 emit
test -f /tmp/phase1f-test/Sources/IAMContextShared/EmployeeStatus.swift
# README placeholder 替換（全部 placeholder 必須 resolved）
grep -F 'IAMContext' /tmp/phase1f-test/Sources/IAMContextShared/README.md
grep -F '0.1.0-phase1f' /tmp/phase1f-test/Sources/IAMContextShared/README.md
! grep -F '{ContextName}' /tmp/phase1f-test/Sources/IAMContextShared/README.md
! grep -F '{GenesisVersion}' /tmp/phase1f-test/Sources/IAMContextShared/README.md
! grep -F '{Date}' /tmp/phase1f-test/Sources/IAMContextShared/README.md

# A12. e2e — swift package resolve passes（warm cache 快；新 infra 是 pure types 無新依賴）
( cd /tmp/phase1f-test && swift package resolve )

# A13. SharedTargetRendererTests 新增測試通過
swift test --filter SharedTargetRendererTests
```

### Human 補做（需要人類介入）

- [ ] 跑 `cd /tmp/phase1f-test && swift build`（warm cache 應 <2 min）— 確認新生成的 infra 不破壞 aggregate / shared / test target build。若 fail → spec 必有缺陷（如 access modifier 錯、import 缺）
- [ ] 跑 `GENESIS_RUN_E2E_BUILD=1 swift test --filter testEndToEndSwiftPackageResolveAndBuild`（Phase 1.e env-gated test，warm cache 應快）— regression check
- [ ] 視覺檢查 `/tmp/phase1f-test/Sources/IAMContextShared/README.md` 的可讀性 / 中英文選用 / 結構合理
- [ ] 視覺檢查 9 個 infra 檔的內容：與 OC `OCShared/` 對應檔 verbatim 比對（除 Iso8601 timezone 改動 + ApplicationService doc-comment 中英 + README 全 Genesis-authored 外，其他應一致）
- [ ] 用「無 DTO 也無 customType」的最小 bundle 跑 `genesis new`，確認 Shared/ target 仍 emit + 含 9 個 infra（per `needsShared = true` always）

---

## 已知限制

1. **`Decimal.parse(_:)` helper 缺**：只 ship `InvalidDecimalStringError` marker；user 自行加 throwing wrapper（OC 也沒）。Phase 2 候選補。
2. **`TimeZoneConstants.taipei` / `Calendar.taipei` 不 ship**：Taiwan-conventional；user 若需 project-wide TZ，自行加 `TimeZoneConstants.swift` + 改 `Iso8601.swift` call sites（或保留 `.gmt` default）。Phase 1.g 候選評估 bundle.yaml 加 `projectTimezone:` 欄位。
3. **`DtoConversionError` 不 ship**：cases reference OC business DTOs；無 generic 等價物。`/api` skill / `/dto-union` skill 在偵測到 cross-aggregate union DTO 時 per-bundle 生成。
4. **`ProjectionReadInconsistency` 早 ship**：雖然主要 `/readmodel` skill 用，現 ship 比 later patch 便宜；19 LoC 零依賴。
5. **Genesis-authored README 是 neutral 英文**：若 user 偏好中英對照或本地化，自行 fork。
6. **needsShared 改 always true 副作用**：原本沒 DTO 也沒 customTypes 的 bundle 也會建 `{Ctx}Shared/` target — OK 因為 infra 是 universal。SwiftPM extra target overhead 可忽略（per OC 設置幾無感）。
7. **phase1e → phase1f manifest 升級**：既有 phase1e dir 重跑直接被 `checkExistingManifestVersion` reject（per Phase 1.e Step 11）；user 須 remove dir 重跑。Phase 1.f 不提供 in-place migration。
8. **OC `String+IsBlank` 含全形空格 awareness**：Taiwan-conventional；user 若不需可自行刪該 line（或整檔），無 build impact。Genesis 全 ship 是因為 zero-cost 且台灣 user 受益。
9. **無 unit test for ContextError 自定 `Equatable` 語意**：OC `Equatable` 忽略 message/source/timestamp 只比 error，行為非顯而易見。Phase 1.f 不寫專屬測試（會增加 spec scope），但 README 須 call out 此語意以避誤用。
10. **Genesis bundled skills 不受 Phase 1.f 影響**：`/api` / `/readmodel` / `/usecase` 等 skill 仍 placeholder（Phase 1.d 既有）；Phase 1.f 只解 infra blocker，skill 內容由各 skill task（如 /api skill v1）負責。
11. **`.gmt` Linux 相容性未實證**：spec 預設 `parseIso8601` 用 `TimeZone.gmt`。macOS Foundation + 較新 Linux swift-corelibs-foundation 都應支援；本 task 不專屬 Linux CI verify（user 端 build 過即視為通過）。若 fail，最低 fallback 改 `TimeZone(identifier: "GMT")!`。
12. **依賴關係**：本 task `depends_on: ["phase-1e-aggregate-alignment"]`（已 done）。完成後 unblocks `2026-05-18-api-skill`（status: draft → revise H1/H2/H4 + M1/M2 + L1 → ready）。
