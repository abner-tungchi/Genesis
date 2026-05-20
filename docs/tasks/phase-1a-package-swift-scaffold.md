# Phase 1.a — Genesis CLI 骨架 + `genesis new` 最小可行 Package.swift 渲染

> ⚠️ **Superseded in part by `dddkit-correction` (2026-05-14)**
>
> 本 spec 的 DDDKit 依賴宣告（kit URL / version / platforms / `package:` identity）已由 `docs/tasks/dddkit-correction.md` 修訂。本 spec 內的下列字串為**歷史紀錄**，不再代表當前正確值：
>
> - `Mendesky/DDDKit` URL → 正確：`gradyzhuo/swift-ddd-kit`
> - `from: "1.12.4"` → 正確：`from: "0.3.0"`
> - `.iOS(.v16)` platform → 已移除（採 macOS-only）
> - 「DDDKit 真實 repo：`.../Mendesky/DDDKit/Package.swift`」 ground truth 路徑 → 正確 ground truth 是 OC `.build/checkouts/swift-ddd-kit/`
>
> 受影響段落以 inline ⚠️ 標記。當前 SSOT 為 `docs/architecture.md` §10.1 + `dddkit-correction` spec。

## 來源

- Plan：`/Users/abnertsai/.claude/plans/tool-tool-lexical-hamming.md` §2.1, §2.3, §5（Phase 0 鎖定值 + Phase 1.a 範圍）
- Architecture：`docs/architecture.md` §3（專案結構 SSOT）、§5.1（command surface）、§7（transaction safety）
- Decisions：`docs/decisions.md` D5、D7、D11（M1）、D12（已被 Phase 0 修訂為 binary release）
- Phase 0 resolutions：`~/.claude/projects/-Users-abnertsai-JiaBao-Mendesky-Genesis/memory/project_phase0_resolutions.md`
- Bundle sample：`/Users/abnertsai/Downloads/IAM Context Bundle.json`
- DDDKit 真實 repo：`/Users/abnertsai/JiaBao/Mendesky/DDDKit/Package.swift` <!-- ⚠️ superseded by `dddkit-correction`: 正確 ground truth 為 OC checkouts 內的 gradyzhuo/swift-ddd-kit 0.3.0；Mendesky/DDDKit 是讀錯 fork -->

---

## 目標

建立 Genesis CLI 的最小可運行骨架，包含：(1) Genesis 自身的 SwiftPM repo 結構（CLI entry、core 邏輯 library、template 資源），(2) `genesis new <ContextName> --from-bundle <path>` 指令的端到端管線，但**只負責產出單一 `Package.swift`**（內含正確的 DDDKit dependency 與 Phase 0 鎖定的平台/語言版本）並通過 `swift package resolve` 驗證。Aggregate 萃取、Sources/ 樹、manifest、adapter、skill 安裝皆延後到 Phase 1.b/1.c/1.d。此 task 是後續 Phase 1 子階段的脊椎 — 提供 BundleParser / TemplateRenderer / GitPreflight 三個會被反覆使用的內部 module。

---

## 介面合約（Interface Contract）

### CLI：`genesis new`

**簽章**：

```
genesis new <ContextName> --from-bundle <path> [--output <dir>] [--no-git]
```

| 參數 | 型別 | 必須 | 規則 |
|------|------|------|------|
| `<ContextName>` | positional `String` | ✓ | regex `^[A-Z][A-Za-z0-9]*$`（PascalCase identifier） |
| `--from-bundle <path>` | `String` | ✓ | 必須是 existing file；副檔名建議 `.json` 但不強制 |
| `--output <dir>` | `String` | ✗ | default = current working directory；不存在則 `mkdir -p` 建立 |
| `--no-git` | flag | ✗ | true → 跳過所有 git pre-flight |

**Exit codes**：

| Code | 意義 |
|------|------|
| 0 | 成功 |
| 1 | 使用者錯誤（檔案不存在 / bundle 格式錯 / output dir 已含 Package.swift / ContextName 不合法） |
| 2 | 系統錯誤（檔案系統權限 / `swift package resolve` 失敗 / 寫檔失敗） |
| 3 | Git pre-flight 失敗（非 git repo 且未 `--no-git` / working tree dirty） |

**stdout / stderr 行為**：
- stdout：成功時印 `✓ Genesis: wrote Package.swift to <abs-path>`；不印任何 skill 名稱（D24 「CLI never prints skill names」）
- stderr：所有 error 訊息含具體原因（bundle 缺哪個欄位、git status 哪一行 dirty 等）
- 不在 verbose 模式外印任何 progress（CLI 安靜原則）

**Framework 備註**（swift-argument-parser 1.3+）：
- `<ContextName>` 用 `@Argument` declared 為 `var contextName: String`，因為 required positional 預設不是 optional
- `--from-bundle` 用 `@Option(name: .customLong("from-bundle"))`
- `--no-git` 用 `@Flag` 直接取 `Bool`
- ArgumentParser 的 validation hook (`func validate()`) 用來檢查 ContextName regex 與 `--from-bundle` 檔案存在

---

### Internal module：`GenesisCore.MinimalBundle`

```swift
public struct MinimalBundle: Sendable, Equatable {
    public let manifestVersion: Int
    public let bundleId: String
    public let context: String
}
```

**不變量**：所有 stored property non-optional；解析失敗就 throw，不留 partial state。

---

### Internal module：`GenesisCore.BundleParser`

```swift
public enum BundleParser {
    public static func parseMinimal(at url: URL) throws -> MinimalBundle
}
```

**行為**：
1. 讀檔（失敗 → `GenesisError.bundleNotFound(url)`）
2. `JSONDecoder` decode 到一個 internal `Envelope` struct（top-level keys：`manifestVersion`, `bundleId`, `context`，其他欄位**全部忽略**）
3. JSON 格式錯 / 缺欄位 / 型別錯 → `GenesisError.bundleInvalid(reason: String)`，reason 必須說明哪個 key 出問題（如 `"missing required key: context"`）
4. 不解析 `aggregates / useCases / dtos / readModels`（**Phase 1.b 任務**）

🔴 **所有權明示**：BundleParser 只負責 read+parse；檔案是否存在的 user-friendly check 由 ArgumentParser `validate()` 先擋一道，內部 parser 仍要 throw 完整錯誤（雙重防線）。

---

### Internal module：`GenesisCore.TemplateRenderer`

```swift
public enum TemplateRenderer {
    public static func render(template: String, vars: [String: String]) -> RenderResult
}

public struct RenderResult: Sendable {
    public let output: String
    public let unresolvedVariables: [String]  // 模板裡有但 vars 沒給的
}
```

**行為**：
1. 對 input string 用 regex `\{([A-Za-z][A-Za-z0-9_]*)\}` 找變數
2. 對每個 match，若 vars dict 有 key → 取代為值；無 key → **保留原樣**並加入 `unresolvedVariables`
3. 不 throw — 渲染問題透過 `RenderResult` 回報（caller 決定要不要 escalate）

**Phase 1.a 不支援**（避免引入複雜度）：
- 條件式（`{if ...}`）
- 迴圈（`{for ...}`）
- 巢狀變數（`{outer.inner}`）
- Mustache / Stencil 等 framework

Phase 1.b 若有 looping aggregate targets 需要，會升級到支援 array 變數的版本（但 API 維持 additive）。

---

### Internal module：`GenesisCore.GitPreflight`

```swift
public enum GitPreflight {
    public static func check(at path: URL, skip: Bool) throws
}
```

**行為**：
1. `skip == true` → 立即 return（no-op）
2. 跑 `git rev-parse --is-inside-work-tree` (cwd = `path`)；非 0 → `GenesisError.gitPreflightFailed(reason: "not inside git work tree at \(path.path)")`
3. 跑 `git status --porcelain` (cwd = `path`)；任何輸出 → `GenesisError.gitPreflightFailed(reason: "working tree has uncommitted changes: <first 200 chars>")`
4. **不** stash、**不** check overlap（這些 D7 完整版要求留給 Phase 1.c 或 Phase 3 的 `apply` 指令）

🔴 **所有權明示**：GitPreflight 純做 read-only check；後續 rollback 邏輯（`git checkout` / `fs unlink`）由 `NewCommand` 的 error handler 負責，**不**在 GitPreflight 內。

---

### Internal module：`GenesisCore.GenesisError`

```swift
public enum GenesisError: Error, Equatable, Sendable {
    case bundleNotFound(URL)
    case bundleInvalid(reason: String)
    case outputDirHasConflict(path: URL, conflict: String)  // 例如 conflict = "Package.swift"
    case gitPreflightFailed(reason: String)
    case swiftPackageResolveFailed(stderr: String)
    case fileSystemFailed(operation: String, underlying: String)
    case contextNameInvalid(value: String)  // ⚠️ Phase 1.a 不從 Sources/ 內 throw（regex 失敗走 ArgumentParser.ValidationError）；保留 case 供 Phase 1.b+ 若有 deeper context name 業務檢查時使用
}
```

**對應 exit code**（由 `Genesis.main` 集中對照表負責）：

| Error case | Exit code | 來源 |
|-----------|-----------|------|
| `bundleNotFound`, `bundleInvalid`, `contextNameInvalid`, `outputDirHasConflict` | 1 | user error |
| `fileSystemFailed`, `swiftPackageResolveFailed` | 2 | system error |
| `gitPreflightFailed` | 3 | git pre-flight |
| `ArgumentParser.ValidationError`（args sanity / regex 不符） | 1 | parser-level |
| 其他 unexpected | 2 | fallback |

---

### Resource：`Templates/v0.1/Package.swift.template`

> ⚠️ **Superseded by `dddkit-correction`**：以下 template 樣本中的 `Mendesky/DDDKit` URL、`from: "1.12.4"`、`.iOS(.v16)` 已過時。當前正確內容見 `dddkit-correction` Step 1 與該 task 完成後的 template 實檔。

**內容**：

```swift
// swift-tools-version: 6.0
// Generated by Genesis v{GenesisVersion}. Do not edit this header manually.
import PackageDescription

let package = Package(
    name: "{ContextName}",
    platforms: [
        .macOS(.v15),
        .iOS(.v16),
    ],
    products: [
        // Phase 1.b will populate per-aggregate libraries here.
    ],
    dependencies: [
        .package(url: "https://github.com/Mendesky/DDDKit.git", from: "1.12.4"),
    ],
    targets: [
        // Phase 1.b will populate per-aggregate targets here.
    ],
    swiftLanguageModes: [.v5]
)
```

**變數合約**：
- `{ContextName}`：來自 CLI arg（**不是** bundle.context，見 Step 6.6 衝突處理）
- `{GenesisVersion}`：來自 build-time injected constant（`GenesisCore.version`），預設 `"0.1.0-phase1a"`

**Phase 1.a 不變動的不變量**：
- `swift-tools-version: 6.0` — 不可動（DDDKit 自身用 6.0）
- `.macOS(.v15)`, `.iOS(.v16)` — 對齊 DDDKit `Package.swift` 平台需求 <!-- ⚠️ superseded by `dddkit-correction`: gradyzhuo kit 宣告 `.iOS(.v18)` 下界 + OC ground truth macOS-only → 採 macOS-only，移除 `.iOS(.v16)` -->
- `from: "1.12.4"` — Phase 0 鎖定的 latest stable tag <!-- ⚠️ superseded by `dddkit-correction`: 正確值 `from: "0.3.0"`（gradyzhuo/swift-ddd-kit），1.12.4 是讀錯 fork -->
- `products: []` 和 `targets: []` — 故意空，**Phase 1.b 才填**

---

## 改動檔案

所有檔案皆為 Phase 1.a **新增**（Genesis repo 自身 from-scratch）。

| 檔案路徑 | 改動描述 |
|---------|---------|
| `Package.swift` | Genesis CLI 自身 SwiftPM manifest（swift-tools 6.0，依賴 swift-argument-parser；executable target `genesis` + library target `GenesisCore` + 兩個 test target） |
| `Sources/Genesis/Genesis.swift` | CLI entry：`@main struct Genesis: AsyncParsableCommand`，定義 `commandConfiguration` 含 `subcommands: [NewCommand.self]` |
| `Sources/Genesis/Commands/NewCommand.swift` | `genesis new` 子命令：parse args、orchestrate pipeline、map errors → exit codes |
| `Sources/GenesisCore/BundleParser.swift` | 最小 bundle JSON 解析（公開 API：`parseMinimal(at:)`） |
| `Sources/GenesisCore/MinimalBundle.swift` | `struct MinimalBundle { manifestVersion, bundleId, context }` |
| `Sources/GenesisCore/TemplateRenderer.swift` | `{var}` 字串取代渲染引擎 |
| `Sources/GenesisCore/GitPreflight.swift` | `git rev-parse` + `git status --porcelain` 兩道檢查 |
| `Sources/GenesisCore/GenesisError.swift` | 公用 error enum |
| `Sources/GenesisCore/Version.swift` | `public enum GenesisCore { public static let version = "0.1.0-phase1a" }` |
| `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template` | 上述 template 內容（透過 SwiftPM resource bundle 取用） |
| `Tests/GenesisCoreTests/BundleParserTests.swift` | minimal parse 的 happy path + 各種錯誤 fixture |
| `Tests/GenesisCoreTests/TemplateRendererTests.swift` | 變數取代、未解析變數回報、無變數 passthrough |
| `Tests/GenesisCoreTests/GitPreflightTests.swift` | 用 tmpdir + 真實 git init 跑 happy / dirty / non-repo 三案例 |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | E2E：跑 `genesis new` 二進位 → 檢查 Package.swift 內容 + `swift package resolve` 成功 |
| `Tests/GenesisIntegrationTests/Fixtures/minimal-bundle.json` | 手工 minimal bundle（只有三個 top-level key） |
| `Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json` | 從 `~/Downloads/IAM Context Bundle.json` 複製進 fixtures |
| `Tests/GenesisIntegrationTests/Fixtures/malformed-bundle.json` | 缺 `context` key 的 fixture |

🔴 **呼叫端清單**（Phase 1.a 後會被 Phase 1.b 重用的 module）：
- `BundleParser.parseMinimal` — Phase 1.b 會新增 `parseFull` sibling API，**不替換** `parseMinimal`
- `TemplateRenderer.render` — Phase 1.b 會升級支援 array 變數，**API 維持 additive**
- `GitPreflight.check` — Phase 1.c 的 `apply --only-new` 會直接重用此函數，不修改

---

## 實作步驟

### Step 1：Genesis CLI 自身 Package.swift

1. swift-tools: `5.10` 或 `6.0`（建議 `5.10` 因為 Genesis 自己只是 CLI 工具，不需要 DDDKit 6.0 features；可降低 maintainer 端 Xcode 版本要求 — **此處與 generated Package.swift 的 6.0 是兩件事**）
2. Platforms：`.macOS(.v13)`（Genesis 自己跑在哪裡都行；v13+ 因為 swift-argument-parser）
3. Dependencies：
   - `.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")`
4. Targets：
   - `.executableTarget(name: "Genesis", dependencies: ["GenesisCore", .product(name: "ArgumentParser", package: "swift-argument-parser")])`
   - `.target(name: "GenesisCore", resources: [.copy("Resources/Templates")])`
   - `.testTarget(name: "GenesisCoreTests", dependencies: ["GenesisCore"])`
   - `.testTarget(name: "GenesisIntegrationTests", dependencies: ["GenesisCore"], resources: [.copy("Fixtures")])`

### Step 2：BundleParser.parseMinimal

```swift
public static func parseMinimal(at url: URL) throws -> MinimalBundle {
    // 2.1 先做 fs 區分：not-found vs is-directory vs permission/IO
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if !exists {
        throw GenesisError.bundleNotFound(url)
    }
    if isDirectory.boolValue {
        throw GenesisError.bundleInvalid(reason: "path is a directory, not a JSON file: \(url.path)")
    }

    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        // 此時檔案存在且非目錄，read 失敗代表權限或 IO 問題，不是 not-found
        throw GenesisError.fileSystemFailed(operation: "read bundle", underlying: error.localizedDescription)
    }

    struct Envelope: Decodable {
        let manifestVersion: Int?
        let bundleId: String?
        let context: String?
    }

    let envelope: Envelope
    do {
        envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
        throw GenesisError.bundleInvalid(reason: "JSON malformed: \(error.localizedDescription)")
    }

    guard let manifestVersion = envelope.manifestVersion else {
        throw GenesisError.bundleInvalid(reason: "missing required key: manifestVersion")
    }
    guard let bundleId = envelope.bundleId, !bundleId.isEmpty else {
        throw GenesisError.bundleInvalid(reason: "missing or empty required key: bundleId")
    }
    guard let context = envelope.context, !context.isEmpty else {
        throw GenesisError.bundleInvalid(reason: "missing or empty required key: context")
    }
    return MinimalBundle(manifestVersion: manifestVersion, bundleId: bundleId, context: context)
}
```

**錯誤分類規則**（避免 user/system error 混淆）：
- 檔案不存在 → `bundleNotFound`（user error，exit 1）
- 路徑是目錄 → `bundleInvalid`（user error，exit 1）
- 存在但讀不到（權限、IO） → `fileSystemFailed`（system error，exit 2）
- 讀到但 JSON 格式爛 → `bundleInvalid`（user error，exit 1）
- 結構缺欄位 → `bundleInvalid`（user error，exit 1）

**Edge case**：若 JSON 是有效的但 top-level 是 array 不是 object → `JSONDecoder` 自然 throw → 進 `bundleInvalid` catch → reason 含 underlying decode error。可接受。

### Step 3：TemplateRenderer.render

**演算法**：先掃出所有變數名，再對每個變數用 `String.replacingOccurrences` 做整段替換。**不要**用 regex match-then-mutate 的方式，那會碰到索引漂移問題。

```swift
public static func render(template: String, vars: [String: String]) -> RenderResult {
    let pattern = try! NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9_]*)\\}")
    let allVarNames: Set<String> = Set(
        pattern.matches(in: template, range: NSRange(template.startIndex..., in: template))
            .compactMap { Range($0.range(at: 1), in: template).map { String(template[$0]) } }
    )
    var output = template
    var unresolved: [String] = []
    for varName in allVarNames.sorted() {
        if let value = vars[varName] {
            output = output.replacingOccurrences(of: "{\(varName)}", with: value)
        } else {
            unresolved.append(varName)
        }
    }
    return RenderResult(output: output, unresolvedVariables: unresolved)
}
```

**為什麼用 String.replacingOccurrences 而非 NSRegularExpression.replaceMatches**：後者每替換一次後，index 跟原 NSString 不同步，需要從尾向前 mutate 才安全；前者語意是「全文 literal 替換」，沒有 index 問題。Phase 1.a 變數數量極少（兩個），效能不是瓶頸。

### Step 4：GitPreflight.check

**Scope 決策**：Phase 1.a 的 `git status --porcelain` **限制在 output dir 之下**（用 pathspec），**不**檢查整個 repo。理由：
- `genesis new` 只動 output dir 內的 `Package.swift` 一個檔
- 若 user 在大型 repo 內某個 subdir 跑 `genesis new`，repo 其他地方的 in-progress 工作不應該擋這個指令
- Phase 1.c 的 `apply` 指令會延伸到多檔，那時再考慮是否要升級到 repo-wide 檢查（D7 完整版）

```swift
public static func check(at path: URL, skip: Bool) throws {
    guard !skip else { return }

    // 4.1 確認 path 存在（caller 應該已建立，但雙保險）
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue else {
        throw GenesisError.gitPreflightFailed(reason: "output path does not exist or is not a directory: \(path.path)")
    }

    // 4.2 在 path 內判斷是否為 git work tree
    let isRepo = runGit(args: ["rev-parse", "--is-inside-work-tree"], cwd: path)
    guard isRepo.exitCode == 0, isRepo.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
        throw GenesisError.gitPreflightFailed(reason: "not inside git work tree at \(path.path); pass --no-git to bypass")
    }

    // 4.3 限制 status scope 到 path（pathspec "."）
    let status = runGit(args: ["status", "--porcelain", "--", "."], cwd: path)
    guard status.exitCode == 0 else {
        throw GenesisError.gitPreflightFailed(reason: "git status failed: \(status.stderr)")
    }
    if !status.stdout.isEmpty {
        let preview = String(status.stdout.prefix(200))
        throw GenesisError.gitPreflightFailed(reason: "uncommitted changes inside \(path.path):\n\(preview)")
    }
}

// runGit 內部用 Foundation.Process 跑 /usr/bin/env git
```

**Edge case**：path 不存在 → 4.1 守衛擋下，throw `gitPreflightFailed` 明確訊息（不要讓 `Process.run` 跑在不存在 cwd 後爆 obscure error）。

### Step 5：寫死的 Template Resource

把上方「介面合約 > Resource」段的 template 內容存成 `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template`。透過 SwiftPM `resources: [.copy("Resources/Templates")]` 機制 bundle 進 GenesisCore。

讀取方式：

```swift
public enum TemplateLoader {
    public static func loadPackageSwiftTemplate(version: String = "v0.1") throws -> String {
        guard let url = Bundle.module.url(forResource: "Package.swift", withExtension: "template",
                                          subdirectory: "Templates/\(version)") else {
            throw GenesisError.fileSystemFailed(operation: "loadTemplate", underlying: "missing Templates/\(version)/Package.swift.template in bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
```

### Step 6：NewCommand 主流程

🔴 **執行順序原則**：
- **所有檢查（validate 階段 + run 早期）必須完成後才動檔案系統**（含 `createDirectory`）。
- 否則 git preflight / bundle parse 失敗會留下 partial state（空目錄）。
- 唯一可被 rollback 的 mutation = `Package.swift` 寫檔；其餘步驟保持 read-only。

```swift
struct NewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Bootstrap a Swift DDD project from a Cosmogony bundle.")

    @Argument(help: "Pascal-cased context name (e.g. IAMContext).") var contextName: String
    @Option(name: .customLong("from-bundle"), help: "Path to Cosmogony bundle JSON.") var fromBundle: String
    @Option(name: .customLong("output"), help: "Output directory (default: current).") var output: String?
    @Flag(name: .customLong("no-git"), help: "Skip git pre-flight checks.") var noGit: Bool = false

    // ArgumentParser 的 validate() 只能 throw ValidationError；正規化錯誤訊息由 Genesis.main 統一處理
    func validate() throws {
        // 6.1 ContextName regex
        let regex = try NSRegularExpression(pattern: "^[A-Z][A-Za-z0-9]*$")
        let range = NSRange(contextName.startIndex..., in: contextName)
        if regex.firstMatch(in: contextName, range: range) == nil {
            throw ValidationError("ContextName must be PascalCase identifier matching ^[A-Z][A-Za-z0-9]*$; got '\(contextName)'.")
        }
        // 6.2 bundle 路徑非空（更深的 fs check 留給 run()，因為 ValidationError 沒對應 exit code 1 範疇）
        if fromBundle.isEmpty {
            throw ValidationError("--from-bundle path cannot be empty")
        }
    }

    func run() async throws {
        // ===== Phase 1：所有 read-only 檢查（不動 fs） =====

        // 6.3 解析 output dir 路徑（不建立）
        let outputURL = URL(fileURLWithPath: output ?? FileManager.default.currentDirectoryPath)

        // 6.4 Bundle parse（read-only）
        let bundleURL = URL(fileURLWithPath: fromBundle)
        let bundle = try BundleParser.parseMinimal(at: bundleURL)

        // 6.5 ContextName 衝突警告：CLI arg vs bundle.context（CLI arg 為 SSOT）
        if bundle.context != contextName {
            FileHandle.standardError.write(Data(
                "⚠️ ContextName mismatch: CLI arg '\(contextName)' overrides bundle.context '\(bundle.context)'\n".utf8
            ))
        }

        // 6.6 Render template（純 string 運算，read-only）
        let template = try TemplateLoader.loadPackageSwiftTemplate()
        let result = TemplateRenderer.render(template: template, vars: [
            "ContextName": contextName,
            "GenesisVersion": GenesisCore.version,
        ])
        if !result.unresolvedVariables.isEmpty {
            FileHandle.standardError.write(Data(
                "⚠️ unresolved template variables: \(result.unresolvedVariables.joined(separator: ", "))\n".utf8
            ))
        }

        // ===== Phase 2：輕量 fs 檢查（仍不寫檔） =====

        // 6.7 output dir 存在性確認 / 紀錄是否需要建立（建立操作放到 Phase 3）
        let didExistBefore = FileManager.default.fileExists(atPath: outputURL.path)
        var dirCreatedByThisRun = false

        // 6.8 衝突檢查：若 outputURL 已存在，必須非含 Package.swift
        let packageSwiftURL = outputURL.appendingPathComponent("Package.swift")
        if didExistBefore && FileManager.default.fileExists(atPath: packageSwiftURL.path) {
            throw GenesisError.outputDirHasConflict(path: outputURL, conflict: "Package.swift")
        }

        // ===== Phase 3：mutation（用 defer + flag 保證 rollback） =====

        do {
            // 6.9 真正建立 output dir（若不存在）
            if !didExistBefore {
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                dirCreatedByThisRun = true
            }

            // 6.10 Git pre-flight（必須在 dir 存在之後）
            //   - 此 check 是 read-only；失敗的話只需要 rollback dir（沒寫任何檔）
            try GitPreflight.check(at: outputURL, skip: noGit)

            // 6.11 寫 Package.swift
            do {
                try result.output.write(to: packageSwiftURL, atomically: true, encoding: .utf8)
            } catch {
                throw GenesisError.fileSystemFailed(operation: "write Package.swift", underlying: error.localizedDescription)
            }

            // 6.12 swift package resolve 驗證
            let resolve = runSwift(args: ["package", "resolve"], cwd: outputURL)
            if resolve.exitCode != 0 {
                // 6.13 Rollback Package.swift（dir rollback 走外層 catch）
                try? FileManager.default.removeItem(at: packageSwiftURL)
                throw GenesisError.swiftPackageResolveFailed(stderr: resolve.stderr)
            }

            // 6.14 成功訊息
            print("✓ Genesis: wrote Package.swift to \(packageSwiftURL.path)")
        } catch {
            // 6.15 統一 dir rollback：只 rollback 本次建立的 dir，且必須仍為「空目錄」
            if dirCreatedByThisRun {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: outputURL.path)) ?? []
                if contents.isEmpty {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                // 若不是空的（例如 git init 已產生 .git），保留以避免誤刪
            }
            throw error
        }
    }
}
```

🔴 **Rollback 保證細則**：
- **dir rollback 條件**（6.15）：當且僅當 `dirCreatedByThisRun == true` **且** dir 內為空時才刪。若 git preflight 跑了 `git init`（不在此 spec 範圍，但未來變動需注意）或別處意外塞檔進來，**保留** dir 不刪，避免誤刪 user data。
- **Package.swift rollback 條件**（6.13）：寫成功後 resolve 失敗才刪。

🔴 **Error → ExitCode 對照表（由 Genesis.swift @main entry 處理）**：

**主流程必須 override `AsyncParsableCommand.main()` 為自製版本**，不能用 ArgumentParser 內建 main，理由：
- 內建 main 對 `ValidationError` 走 `exit(64)` (UNIX `EX_USAGE`)，但 Genesis 要把 user error 統一為 exit 1
- 內建 main 對其他 error 走 `exit(1)`，但 Genesis 要區分 1 / 2 / 3
- 因此必須自製 main 集中對照表

```swift
@main
struct Genesis: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genesis",
        subcommands: [NewCommand.self]
    )

    // ⚠️ 必須 override；不要用 ArgumentParser 預設 main()
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as GenesisError {
            FileHandle.standardError.write(Data("✗ \(error.userMessage)\n".utf8))
            exit(error.exitCode)
        } catch let error as ValidationError {
            // ArgumentParser parse / validate 階段的錯誤統一視為 exit 1（user error）
            FileHandle.standardError.write(Data("✗ \(error.message)\n".utf8))
            exit(1)
        } catch {
            // 其他未預期錯誤
            FileHandle.standardError.write(Data("✗ unexpected error: \(error)\n".utf8))
            exit(2)
        }
    }
}

extension GenesisError {
    var exitCode: Int32 {
        switch self {
        case .bundleNotFound, .bundleInvalid, .contextNameInvalid, .outputDirHasConflict: return 1
        case .fileSystemFailed, .swiftPackageResolveFailed: return 2
        case .gitPreflightFailed: return 3
        }
    }
    var userMessage: String { /* switch → 友善訊息 */ }
}
```

🔴 **介面合約補充：args sanity check 一律放 `run()` 開頭，不放 `validate()`**：
- **實作期間發現的偏差（2026-05-14）**：ArgumentParser 把 `validate()` 拋的 `ValidationError` 包進 internal `CommandError(parserError: .userValidationError(...))`，custom `main` 的 `catch let error as ValidationError` 無法捕獲（`CommandError` 不是 public type 無法 pattern match）。實證：debug print 顯示 `caught CommandError: ...`。
- 結論：規則調整為 **`validate()` 留空**（或不寫），所有 sanity check（regex、空字串、檔案存在）一律放 `run()` 早期，throw `GenesisError`，這樣才能命中我們自製 main 的 exit code 對照表。
- ContextName regex 不符 → `throw GenesisError.contextNameInvalid(value:)`
- `--from-bundle` 空字串 → `throw GenesisError.bundleInvalid(reason:)`
- 深層 fs / 業務檢查 → 同樣 `run()` 內 throw `GenesisError`
- **唯一例外**：若未來要利用 ArgumentParser 預設行為（自動印 usage、走 exit 64），可在 `validate()` throw `ValidationError`，但那條路徑會繞過 GenesisError exit-code 表。Phase 1.a 不採用。

### Step 7：測試

🔴 **執行模型分工**（必須遵守）：
- **Unit tests**（`GenesisCoreTests`）：直接呼叫 `GenesisCore` 內 public API（`BundleParser.parseMinimal`、`TemplateRenderer.render`、`GitPreflight.check`）。**不**經過 CLI / `NewCommand`。
- **Integration tests**（`GenesisIntegrationTests`）：用 `Foundation.Process` **launch 已 build 好的 `genesis` 二進位檔**（路徑透過 `Bundle.module` 或 SwiftPM `productsDirectory` 取得）。
  - ❌ **嚴禁** `swift run genesis ...` — 會在 `swift test` 內遞迴 invoke SwiftPM，超 brittle 且狂跑 build
  - ❌ **嚴禁**直接 call `NewCommand().run()` — 跳過 `validate()`、parser 階段、stdout/stderr 格式化、exit code mapping，無法保證端對端正確

範例 helper（放 `Tests/GenesisIntegrationTests/Support/CLIRunner.swift`）：

```swift
import Foundation

struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum CLIRunner {
    static func genesisBinaryURL() -> URL {
        // SwiftPM 在測試時把 build 產物放在 productsDirectory
        // 透過 Bundle.main.bundleURL 推導
        var url = Bundle.main.bundleURL
        // .xctest bundle → productsDirectory
        while url.lastPathComponent.hasSuffix(".xctest") || url.pathExtension == "xctest" {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("genesis")
    }

    static func run(_ args: [String], cwd: URL? = nil) throws -> CLIResult {
        let process = Process()
        process.executableURL = genesisBinaryURL()
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
```

**Unit tests**（`GenesisCoreTests`，直接 call API）：
1. `BundleParserTests.testParseHappyPath` — `minimal-bundle.json` fixture，assert 三個欄位
2. `BundleParserTests.testParseFromRealIAMBundle` — `iam-bundle.json`，assert `context == "IAMContext"`，**不**檢查 aggregates
3. `BundleParserTests.testMissingContext` — `malformed-bundle.json`，assert throw `bundleInvalid` reason 含 `"context"`
4. `BundleParserTests.testPathIsDirectory` — 傳一個目錄路徑，assert throw `bundleInvalid` reason 含 `"directory"`
5. `BundleParserTests.testPathNotFound` — 傳不存在路徑，assert throw `bundleNotFound`
6. `TemplateRendererTests.testSingleVar` — `"hello {name}"` + `["name": "world"]` → `"hello world"`, unresolved empty
7. `TemplateRendererTests.testMissingVar` — `"hello {name}"` + `[:]` → `"hello {name}"`, unresolved `["name"]`
8. `TemplateRendererTests.testMultipleVarsAndDup` — `"{a} {a} {b}"` + `["a": "1", "b": "2"]` → `"1 1 2"`
9. `GitPreflightTests.testCleanRepo` — tmpdir + `git init` + 不動 → check 通過
10. `GitPreflightTests.testDirtyRepo` — tmpdir + git init + 寫一個檔但不 commit → throw `gitPreflightFailed` 含 `"uncommitted"`
11. `GitPreflightTests.testNonRepo` — tmpdir 不 git init → throw `gitPreflightFailed` 含 `"not inside git work tree"`
12. `GitPreflightTests.testSkipFlag` — dirty repo + `skip: true` → no throw
13. `GitPreflightTests.testPathNotExist` — 傳不存在路徑 + `skip: false` → throw `gitPreflightFailed` 含 `"does not exist"`

**Integration tests**（`GenesisIntegrationTests`，**用 `CLIRunner` 跑 binary**）：

14. `NewCommandTests.testEndToEndHappyPath` — tmpdir + `git init` + `CLIRunner.run(["new", "IAMContext", "--from-bundle", iamBundlePath, "--output", tmpdir.path])`：
    - assert `exitCode == 0`
    - assert tmpdir/Package.swift 存在
    - assert 內容含 `name: "IAMContext"`, `from: "1.12.4"`, `.macOS(.v15)`, `.iOS(.v16)`
    - assert `stdout` 含 `"wrote Package.swift to"`
15. `NewCommandTests.testBundleNotFound` — 傳不存在路徑 → `exitCode == 1`，stderr 含 `"does not exist"` 或 `"not found"`
16. `NewCommandTests.testMalformedBundle` — `malformed-bundle.json` → `exitCode == 1`，stderr 含 `"missing"` 或 `"context"`
17. `NewCommandTests.testOutputHasPackageSwift` — output dir 預先放 `Package.swift` → `exitCode == 1`，stderr 含 `"Package.swift"`
18. `NewCommandTests.testDirtyGit` — tmpdir + git init + 寫個 stray file 不 commit → `exitCode == 3`，stderr 含 `"uncommitted"`
19. `NewCommandTests.testNoGitFlag` — non-git tmpdir + `--no-git` → `exitCode == 0`
20. `NewCommandTests.testInvalidContextName` — `genesis new lowercase --from-bundle ...` → `exitCode == 1`，stderr 含 `"PascalCase"`
21. `NewCommandTests.testContextNameOverridesBundleContext` — bundle.context = `"Foo"`、CLI arg = `"Bar"` → exitCode 0, Package.swift 內 `name: "Bar"`, stderr 含 `"mismatch"`
22. `NewCommandTests.testRollbackOnResolveFail` — 寫一個合法 minimal bundle 但讓 swift package resolve 失敗（暫時做法：fixture 用一個會解析錯誤的「壞 dep template」變體；或 mock `runSwift` — 因為 mock 較難，本案例可標 `[Human 補做]` 視驗證需求）
23. `NewCommandTests.testDirRollbackOnPreflightFail` — output dir 不存在 + git 環境會讓 preflight 失敗（在 non-git parent 跑、`--no-git` 沒開）→ exit 3 後 outputURL **不存在**（被 rollback）

**Test 注意事項**：
- 跑 integration test 前 `genesis` 必須先 build；可在 `Package.swift` 加 `.testTarget` dependencies 或在 CI 流程顯式跑 `swift build` 再 `swift test`
- `CLIRunner` 找 binary 的路徑邏輯要驗證在 macOS / Linux 是否一致（Phase 1.a 只測 macOS，Linux 留給未來）

---

## 失敗路徑

依執行順序（Step 6 Phase 1/2/3）整理：

```
[Phase 1：純 read-only，無 fs mutation，失敗時無 rollback 需求]

A. NewCommand.validate() 階段
   - ContextName regex 不符 → throw ValidationError("PascalCase...")
   - --from-bundle 空字串 → throw ValidationError
   → Genesis.main() catch ValidationError → 寫 stderr → exit 1

B. NewCommand.run() Phase 1 (6.3-6.6)
   - bundleURL fs check 失敗 → BundleParser raise
     - 路徑不存在 → bundleNotFound → exit 1
     - 路徑是目錄 → bundleInvalid → exit 1
     - 讀檔權限/IO 失敗 → fileSystemFailed → exit 2
     - JSON malformed / 缺欄位 → bundleInvalid → exit 1
   - TemplateLoader 找不到 resource → fileSystemFailed → exit 2
   → Genesis.main() catch GenesisError → exit per table

[Phase 2：read-only fs check]

C. outputDirHasConflict（6.8）
   - output dir 已存在且含 Package.swift → throw outputDirHasConflict
   → Genesis.main() catch → exit 1
   → 不需 rollback（沒寫任何東西）

[Phase 3：mutation 階段]

D. createDirectory 失敗（6.9）
   - 權限不足 / 父目錄不存在 → throw fileSystemFailed
   → outer catch 跑 dir rollback 邏輯 → dirCreatedByThisRun = false（還沒 set true）→ 不會誤刪
   → Genesis.main() catch → exit 2

E. GitPreflight.check 失敗（6.10）
   - non-git work tree → gitPreflightFailed → exit 3
   - working tree dirty (output dir scope) → gitPreflightFailed → exit 3
   - path doesn't exist (4.1 守衛) → gitPreflightFailed → exit 3
   → outer catch：若 dirCreatedByThisRun，dir 為空就刪；否則保留
   → Genesis.main() catch → exit 3

F. Package.swift 寫檔失敗（6.11）
   - 權限 / 磁碟滿 → throw fileSystemFailed
   → outer catch：dir rollback 同 E
   → exit 2

G. swift package resolve 失敗（6.12-6.13）
   - 網路問題、DDDKit url 寫錯、tag 不存在
   → 6.13 內 try? removeItem(packageSwiftURL) — rollback 剛寫的檔
   → throw swiftPackageResolveFailed
   → outer catch：此時 Package.swift 已被刪、若 dirCreatedByThisRun 且 dir 為空就刪 dir
   → exit 2

[Non-fatal warnings]

H. unresolvedVariables 非空 → stderr warn + exit 0
   - 實務上 Phase 1.a template 只有 ContextName + GenesisVersion 兩個變數，兩者都會 resolve；此分支為防呆
I. bundle.context ≠ ContextName CLI arg → stderr warn + exit 0
   - CLI arg 視為 SSOT
```

🔴 **Rollback 規則總表**：

| 階段 | 失敗事件 | dir rollback | file rollback |
|------|---------|--------------|---------------|
| Phase 1 (validate / read-only) | any | N/A（沒 set dirCreatedByThisRun） | N/A |
| Phase 3 createDirectory 失敗 | throw fileSystemFailed | N/A（throw 發生在 set 之前） | N/A |
| Phase 3 GitPreflight 失敗 | gitPreflightFailed | 是（若 dirCreatedByThisRun 且為空） | N/A |
| Phase 3 write Package.swift 失敗 | fileSystemFailed | 是（同上） | N/A（write atomic 失敗 = 檔不存在） |
| Phase 3 swift package resolve 失敗 | swiftPackageResolveFailed | 是（同上，rollback dir 前先 rollback file） | 是（內層先 remove file） |

---

## 不改動的部分

由於 Phase 1.a 是 Genesis repo 起始 commit，**沒有**「不改動」的既有檔案。

### Non-goals（行為層）

**本 task 不包含**：
- Aggregate / use case / event / DTO 萃取（→ Phase 1.b）
- Sources/{Aggregate}Aggregate/ 樹的任何檔案（→ Phase 1.b）
- event.yaml 寫檔（→ Phase 1.b）
- `.scaffold-manifest.json` 寫檔（→ Phase 1.c，D5）
- `swift-adapter.yaml` 讀取或寫檔（→ Phase 1.c，D6）
- `.ai/contexts/<Aggregate>/` 業務文件骨架（→ Phase 1.c）
- `README.md` / `CLAUDE.md` 樣板輸出（→ Phase 1.b 順便做）
- 設定 `DomainEventGeneratorPlugin` 到 generated target（→ Phase 1.b，因為 Phase 1.a 還沒 target）
- `Tests/{Context}Tests/` 樹輸出（→ Phase 1.b）
- `projections/` / `scripts/` 樹輸出（→ Phase 1.b 或更後）
- `genesis install-skills`（→ Phase 1.d，D10）
- `genesis install-mcp`（→ Phase 2，D29 revised）
- `genesis diff` / `apply` / `adapter`（→ Phase 3）
- `genesis plan-canvas-sync` / `verify-canvas`（→ Phase 4，D33）
- `--interactive` 模式（→ Phase 3）
- `--with-mcp` 旗標（→ Phase 2）
- 升級 swift-tools 6.0 features（generated Package.swift 用 6.0 是因為 DDDKit 需要；Genesis 自身可繼續用 5.10）
- GitHub Action / binary release pipeline（→ Phase 1 收尾或 Phase 2 開頭，獨立 task）
- Mustache / Stencil 等模板引擎（Phase 1.a 故意用最簡 string replace）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# A1. Genesis 自身能編譯
swift build -c release --product genesis

# A2. 全部單元測試 + 整合測試通過
swift test

# A3. Template 內容鎖定值都在
# ⚠️ Superseded by `dddkit-correction`: 下列 4 行的 `1.12.4` / `.iOS(.v16)` / `Mendesky/DDDKit.git`
#    為原 Phase 1.a 鎖定值，已由 `dddkit-correction` 修訂為 `0.3.0` / 無 .iOS / `gradyzhuo/swift-ddd-kit.git`。
#    執行本 task 的當下這些 grep 仍會 pass（template 文字一致），但「正確值」以
#    `dddkit-correction` Step 1 為準。本 A3 段落保留為歷史紀錄。
grep -F 'swift-tools-version: 6.0' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F 'from: "1.12.4"' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F '.macOS(.v15)' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F '.iOS(.v16)' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F 'Mendesky/DDDKit.git' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F '{ContextName}' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template

# A4. Template 不該有的東西
! grep -F 'swift-tools-version: 5.' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
! grep -F 'DDDCore' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template  # 只能依賴 DDDKit aggregate

# A5. 每個 GenesisError case 都有實際 throw 點
grep -RE 'throw\s+GenesisError\.bundleNotFound' Sources/
grep -RE 'throw\s+GenesisError\.bundleInvalid' Sources/
grep -RE 'throw\s+GenesisError\.outputDirHasConflict' Sources/
grep -RE 'throw\s+GenesisError\.gitPreflightFailed' Sources/
grep -RE 'throw\s+GenesisError\.swiftPackageResolveFailed' Sources/
grep -RE 'throw\s+GenesisError\.fileSystemFailed' Sources/

# A5b. contextNameInvalid 雖宣告但 Phase 1.a 改由 validate() throw ValidationError，
#       所以這個 case 在 Sources/ 內不需要實際 throw 點（留給後續若有 deep check 再用）
#       grep 不命中是預期；只要 enum case 存在即可
grep -RE 'case\s+contextNameInvalid' Sources/GenesisCore/GenesisError.swift

# A6. CLI 不能印 skill 名稱（D24）
! grep -RE '"(usecase|readmodel|write-ddd-spec|event-storming|api|strict-review)"' Sources/Genesis/

# A7. 範例 IAM bundle fixture 在
test -f Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json

# A8. Integration test 不能用 swift run 或直接呼叫 NewCommand
! grep -RE 'swift\s+run\s+genesis' Tests/GenesisIntegrationTests/
! grep -RE 'NewCommand\(\).*\.run\(\)|NewCommand\(\)\.run' Tests/GenesisIntegrationTests/

# A9. CLIRunner helper 存在且用 Process
grep -RE 'class\s+Process|Process\(\)' Tests/GenesisIntegrationTests/Support/

# A10. 自製 main 必須存在（不能用 ArgumentParser 預設）
grep -RE 'static\s+func\s+main\s*\(\s*\)\s*async' Sources/Genesis/Genesis.swift
```

### Human 補做（需要人類介入）

- [ ] 在乾淨 tmpdir + `git init` 後跑 `swift run genesis new IAMContext --from-bundle <real path to IAM bundle>`，**目測** Package.swift 內容（特別是 ContextName 替換對、DDDKit pin 對）
- [ ] 在剛產生的 dir 跑 `swift package resolve`，**確認 DDDKit 真的從 GitHub 拉得下來**（網路問題、SSH key、Personal Access Token 等實境問題）<!-- ⚠️ superseded by `dddkit-correction`: kit 改為 `gradyzhuo/swift-ddd-kit` 0.3.0；原文 `DDDKit 1.12.4` 為過時值 -->
- [ ] 故意給壞掉的 bundle（top-level 是 array、空檔案、亂碼）跑 `genesis new`，確認 exit code 為 1 且 stderr 訊息**可讀**（描述哪個 key 缺什麼）
- [ ] 在 working tree dirty 的 git repo 跑 `genesis new`，確認 exit code 3 + stderr 提示 `--no-git` 旗標
- [ ] 重複跑兩次 `genesis new` 同 dir，第二次確認 exit code 1 + 訊息含 `"Package.swift already exists"`
- [ ] `genesis new lowercase ...` 確認 exit code 1 + 訊息提示 PascalCase regex
- [ ] 確認 stdout 成功訊息是**一行**且不含 skill 名稱、不含 verbose progress 噪音

---

## 已知限制

- **Phase 1.a 產出的 Package.swift `products: []` 和 `targets: []` 都是空**，所以 `swift build` 在使用者端的專案會「沒事可做」。Phase 1.a 驗證只跑 `swift package resolve`（驗 dep 解析），不跑 `swift build`。這是預期行為，**Phase 1.b 填 aggregate target 後才有東西可 build**。
- **Template engine 不支援條件/迴圈**。Phase 1.b 若需要 per-aggregate target 迭代會升級，但 API 維持 additive。
- **`--dry-run` 不在 Phase 1.a**。Phase 3 加 `apply --dry-run` 時會把 dry-run 抽到共用 module。
- **D7 的 stash 機制未實作**。Phase 1.a 只有單檔寫入，rollback 等於刪檔；stash 留給 Phase 1.c 後（檔案數成長時）。
- **DDDCore 可見性未驗證**：Phase 0 觀察到 OC 範例同時 `import DDDCore` + `import DDDKit`，但 DDDKit 的 Package.swift 只把 DDDKit 列為 library product。Phase 1.a 不需要在 generated Package.swift 加 DDDCore，因為**還沒寫 Sources/ Swift 檔**。Phase 1.b 寫 Sources/ 時若 import 失敗，再決定是 PR DDDKit 加 product 還是 generated Package.swift 顯式加 product。
- **GenesisCore.version `"0.1.0-phase1a"` 是硬編碼**。Phase 1 收尾前要改成從 build-time 注入（git tag / SemVer）。
- **依賴關係**：無前置 task；本 task 為 Phase 1 起始點。
- **後續 task**：
  - `phase-1b-aggregate-extraction.md` — 萃取 aggregates / useCases / dtos，填 products + targets + Sources/
  - `phase-1c-adapter-and-manifest.md` — swift-adapter.yaml 整合 + `.scaffold-manifest.json`
  - `phase-1d-install-skills.md` — `genesis install-skills` 指令
