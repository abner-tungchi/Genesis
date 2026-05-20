# Phase 1.d — `genesis install-skills` 指令

## 來源

- Plan：`/Users/abnertsai/.claude/plans/tool-tool-lexical-hamming.md` §2.6（install-skills 細節：預設 scope user-global、`--scope project`、來源 `Templates/skills/`、6 個 skill）、§4 roadmap
- Architecture：`docs/architecture.md` §5.1（`genesis install-skills` 規格）、§9（Skill installation model：§9.1 storage / §9.2 source / §9.3 update）
- Decisions：`docs/decisions.md` D10（skill bundle 隨 Genesis 版本走，無獨立版本）、D24（CLI 不印 skill name — 本 spec 釐清其真實意圖見「目標」段）
- Phase 1.a/b/c 已實作 modules：`Sources/Genesis/Genesis.swift`（CLI entry，custom main，`subcommands: [NewCommand.self]`）、`Sources/Genesis/Commands/NewCommand.swift`（subcommand 範例）、`Sources/GenesisCore/GenesisError.swift`、`Sources/GenesisCore/SourceWriter.swift`、`Sources/GenesisCore/TemplateLoader.swift`（`Bundle.module` resource 存取範例）
- Phase 1.c registry：`docs/tasks/registry/phase-1c-adapter-and-manifest.json` status=`done`

---

## 目標

讓使用者跑 `genesis install-skills` 把 Genesis repo 自帶的 Claude Code skill bundles 複製到 `~/.claude/skills/`（user-global，預設）或 `<project>/.claude/skills/`（per-project）。這是「`genesis new` 產出 stub 專案 → Claude Code skills 接手填業務邏輯」鏈條的另一半：沒有這些 skill，使用者拿到 scaffold 後無法用 `/usecase`、`/readmodel`、`/api` 等指令。Phase 1.d 只負責**複製機制**（enumerate bundled skills → copy → 衝突處理 → 結果摘要），skill 內容本身先放 minimal placeholder，真正的 skill 內容是後續工作。

🔴 **D24 釐清 — 需上游 ratify**（codex M5）：D24「CLI never prints skill names」原文不分指令。本 spec 把它窄化為「**`genesis new` bootstrap 流程**不印 skill name；`install-skills` 作為 skill 管理指令本身印出安裝清單是合理的」。**這是對 ratified decision 的範圍變更，不只是釐清** — 因此 Phase 1.d 的「改動檔案」清單**包含更新 `docs/decisions.md` D24 條目與 `docs/architecture.md` §9**，把這個窄化正式寫入決策紀錄（ratify）。使用者已在 Phase 1.d kickoff 明確指示採此解讀，使用者即決策權威；實作時把這條 ratification 寫進文件，讓決策一致而非「spec 偷改決策」。

---

## 介面合約（Interface Contract）

### CLI：`genesis install-skills`（新 subcommand）

```
genesis install-skills [--scope <user|project>] [--project-dir <path>] [--force]
```

| 參數 | 型別 | 必須 | 規則 |
|------|------|------|------|
| `--scope <user\|project>` | `String` | ✗ | 預設 `user`。`user` → `$HOME/.claude/skills/`；`project` → `<project-dir>/.claude/skills/` |
| `--project-dir <path>` | `String` | ✗ | **僅** `--scope project` 時允許；`--scope user` 時若帶此 flag → **validation error**（codex H2）；`--scope project` 時預設為 current working directory |
| `--force` | flag | ✗ | 預設 false。false：目標已存在同名 skill 目錄則跳過並記錄；true：先刪除該 skill 目錄再複製 |

**Exit codes**：

| Code | 意義 | 來源 |
|------|------|------|
| 0 | 全部 skill 都成功安裝或跳過（無失敗） | normal |
| 1 | 使用者錯誤：`--project-dir` 路徑不存在/非目錄；`--scope user` 同時帶 `--project-dir`；`$HOME` 未設定且 `--scope user` | `GenesisError` → `Genesis.main` |
| 2 | 系統錯誤：bundled skills 找不到 / 複製失敗 / 建立目標目錄失敗 / 目標 root 是 symlink | `GenesisError` → `Genesis.main` |
| 64 | `--scope` 非法值（非 `user`/`project`） | **ArgumentParser 自身 usage error**（`ExpressibleByArgument` enum 在 parse 階段 reject，不經 `GenesisError`）|

🔴 **exit code 一致性釐清**（codex M6）：`--scope` 非法值是 ArgumentParser **parse 階段**錯誤，走內建 usage-error 路徑（exit 64），**不是** `GenesisError` exit 1。原 spec 表格混淆兩者，已更正。`--project-dir` 任何字串都能 parse，要到 `run()` 才驗證，那才是 `GenesisError` exit 1。

**stdout 行為**：

成功（無 `failed`）：
```
✓ Genesis: installed 4, skipped 2, overwritten 0 skill(s) into /Users/<user>/.claude/skills/
  installed:   api, event-storming, readmodel, strict-review
  skipped:     usecase, write-ddd-spec  (already exist; pass --force to overwrite)
```

部分失敗（`failed` 非空，codex M4）：banner 改用 `⚠️` 而非 `✓`，且失敗清單同時印 stderr：
```
⚠️ Genesis: installed 3, skipped 1, overwritten 0, FAILED 2 skill(s) into /Users/<user>/.claude/skills/
  installed:   api, event-storming, readmodel
  skipped:     usecase
  failed:      strict-review, write-ddd-spec  (see stderr)
```
（stderr 另印每個 failed skill 的 reason）

- 若 `installed` / `skipped` / `overwritten` / `failed` 任一為空，該行省略
- **banner 的 `✓` vs `⚠️` 由「`failed` 是否為空」決定，且整個摘要在所有 skill 跑完、結果確定後才印**（不可能先印 `✓` 再補 stderr 失敗）

**Framework 備註**（swift-argument-parser 1.3+）：
- `--scope` 用 `@Option` + custom `ScopeOption: String, ExpressibleByArgument` enum（`user` / `project`）讓 ArgumentParser 自動驗證合法值；非法值由 ArgumentParser 報 usage error
- `--project-dir` 用 `@Option(name: .customLong("project-dir"))`
- `--force` 用 `@Flag(name: .customLong("force"))`
- 沿用 Phase 1.a 慣例：sanity check 放 `run()` 開頭 throw `GenesisError`，**不**放 `validate()`（ArgumentParser 會把 validate() 拋的 error 包進 internal CommandError）

🔴 **不需要 git pre-flight**：`~/.claude/skills/` 與 `<project>/.claude/skills/` 都不保證是 git work tree。`install-skills` **不呼叫 `GitPreflight.check`**（與 `genesis new` 不同）。

---

### Internal module：`GenesisCore.SkillInstaller`（新）

```swift
public struct SkillInstallSummary: Sendable, Equatable {
    public let installed: [String]      // skill names newly copied
    public let skipped: [String]        // already existed, no --force
    public let overwritten: [String]    // already existed, --force replaced
    public let failed: [(skill: String, reason: String)]   // copy failed
}

public enum SkillInstaller {
    /// Enumerates bundled skills and installs each into `targetSkillsDir`.
    /// - targetSkillsDir: absolute URL to the `skills/` directory (e.g. ~/.claude/skills).
    ///   Created (with intermediate dirs) if it does not exist.
    /// - force: when true, an existing same-named skill directory is removed then re-copied.
    public static func install(into targetSkillsDir: URL, force: Bool) throws -> SkillInstallSummary

    /// Lists the skill bundle names shipped inside Genesis's resource bundle.
    /// Throws `skillBundleNotFound` when the bundled `Templates/skills/` dir is missing/empty.
    public static func bundledSkillNames() throws -> [String]
}
```

**`bundledSkillNames` 行為**：
1. 取 `Bundle.module.resourceURL` → append `Templates/skills`（與 Phase 1.a/b/c 的 `Templates/v0.1` 平行；都在 `.copy("Resources/Templates")` 打包進來的目錄樹下）
2. 用 `FileManager.contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])` 列項目
3. 對每個項目，**整合性驗證**（codex L7）：必須是 (a) 真目錄、(b) **非** symbolic link、(c) 該目錄內含 `SKILL.md` 檔。三者任一不符 → 跳過該項目（不視為 skill）
4. 全部跑完後若 valid skill 數為 0 → throw `GenesisError.skillBundleNotFound(reason:)`
5. 回傳 sorted valid skill 目錄名陣列

**`install` 行為**：
1. 呼 `bundledSkillNames()` 取清單
2. **目標 root 安全檢查**（codex M3）：若 `targetSkillsDir` 已存在，必須是「真目錄且非 symbolic link」；若它是 symlink 或非目錄 → throw `GenesisError.fileSystemFailed(operation: "validate target skills dir", underlying: "... is a symlink or not a directory")`（exit 2）。理由：symlink root 會讓所有寫入被重導到別處，超出宣稱的安全邊界
3. 若 `targetSkillsDir` 不存在 → `createDirectory(withIntermediateDirectories: true)`；失敗 → throw `fileSystemFailed`
4. 對每個 skill `s`：
   - `dest = targetSkillsDir/<s>`
   - 用 `FileManager.fileExists(atPath:isDirectory:)` + `isSymbolicLink` 判定 `dest` 狀態：
     - **不存在** → `copyItem(at: bundledSkillURL, to: dest)`，成功 → `installed += s`，失敗 → `failed += (s, reason)`
     - **存在、是 symlink 或非目錄**（type confusion）→ **不論 force 與否，一律 `failed += (s, "existing entry is a symlink or not a directory; remove it manually")`**（codex M3：`--force` 不可盲刪非目錄 entry）
     - **存在、是真目錄、`!force`** → `skipped += s`
     - **存在、是真目錄、`force`** → `removeItem(at: dest)` 然後 `copyItem`，成功 → `overwritten += s`，失敗 → `failed += (s, reason)`
5. 回傳 `SkillInstallSummary`

🔴 **所有權明示 / 安全邊界**（codex M3 強化）：
- `SkillInstaller` 只在 `targetSkillsDir` **之下**寫入；`--force` 的 `removeItem` **只刪 `targetSkillsDir/<skillName>/`** 且**該 entry 必須先確認是真目錄**（非 symlink、非 file）— 永不盲刪
- `targetSkillsDir` root 本身若是 symlink → **拒絕執行**（throw），不在 symlink 後面寫入
- 跨 skill **無 rollback**：skill 之間獨立，skill 3 失敗不影響 skill 1-2 已安裝的結果（best-effort，與 `genesis new` 的 atomic 全有全無不同 — 這是刻意的設計選擇，因為 skill 是獨立單元）
- `install` **不刪** `targetSkillsDir` 內非 Genesis 管理的東西（使用者自己放的 skill / 其他工具放的 skill 都不動）

---

### Internal module：`GenesisCore.GenesisError`（修改）

新增 cases：

```swift
case skillBundleNotFound(reason: String)
case skillInstallFailed(skill: String, underlying: String)
```

**Exit code 對照**（更新）：

| Error case | Exit |
|-----------|------|
| `bundleNotFound`, `bundleInvalid`, `contextNameInvalid`, `outputDirHasConflict`, `adapterNotFound`, `adapterInvalid`, `adapterIncompatible` | 1 |
| `fileSystemFailed`, `swiftPackageResolveFailed`, `swiftBuildFailed`, `skillBundleNotFound`, `skillInstallFailed` | 2 |
| `gitPreflightFailed` | 3 |

🔴 **`skillInstallFailed` 的角色**：`SkillInstaller.install` 對「單一 skill 複製失敗」**不 throw**，而是記進 `summary.failed[]`（best-effort）。`skillInstallFailed` enum case 保留給 caller（`InstallSkillsCommand`）在所有 skill 都跑完、發現 `summary.failed` 非空時，**選擇性** throw 用（讓 exit code 變 2 + 統一錯誤格式）；或 caller 直接寫 stderr + `genesisExit(2)`。實作期擇一，spec 不強制。

---

### Internal module：`Genesis.Commands.InstallSkillsCommand`（新 subcommand）

與 `NewCommand` 平行的 `AsyncParsableCommand`。`run()` 流程：

1. **Phase 0 — sanity**：
   - `--scope` 已由 ArgumentParser 的 `ExpressibleByArgument` enum 保證合法（非法值在 parse 階段就被 reject，exit 64）
   - 🔴 **codex H2**：若 `--scope user` 同時帶了 `--project-dir`（`projectDir != nil`）→ throw `GenesisError.bundleInvalid(reason: "--project-dir is only valid with --scope project")`。**不是** silent ignore — 對一個寫使用者 home 的指令，這種誤用必須 fail-fast，否則使用者以為寫進專案、其實寫進真實 home
   - 若 `--scope project`：解析 `--project-dir`（預設 cwd）→ 必須存在且是目錄（且非 symlink），否則 throw `GenesisError.bundleInvalid(reason: "...")`
2. **Phase 1 — 解析 target dir**：
   - 🔴 **codex H1**：`user` scope 的 home **用 `$HOME` env var 解析**，**不用** `FileManager.homeDirectoryForCurrentUser`。理由：codex 實測 `homeDirectoryForCurrentUser` 在 macOS Foundation **不認 `$HOME` override**（用 `getpwuid` 拿真實 home）— 這會讓測試無法安全 sandbox，且偏離 Unix 慣例。改用 `ProcessInfo.processInfo.environment["HOME"]`：
     - `$HOME` 有值 → `URL(fileURLWithPath: home).appendingPathComponent(".claude/skills")`
     - `$HOME` 未設定 → throw `GenesisError.bundleInvalid(reason: "$HOME is not set; cannot resolve user scope")`（exit 1）
   - `project` → `URL(fileURLWithPath: projectDir).appendingPathComponent(".claude/skills")`
3. **Phase 2 — install**：`let summary = try SkillInstaller.install(into: targetDir, force: force)`
4. **Phase 3 — 回報**（codex M4：成功/失敗確定後才印 banner）：
   - **先**判斷 `summary.failed.isEmpty`
   - 空 → 印 `✓` banner + installed/skipped/overwritten 行 → exit 0
   - 非空 → 印 `⚠️` banner（含 `FAILED N`）+ 各分類行（含 `failed:` 行）到 stdout，**並**把每個 failed skill 的 reason 印 stderr → `genesisExit(2)`

🔴 **`$HOME`-based home 解析是 production + test 共用路徑**：production 跑 `genesis install-skills` 時 shell 本來就有 `$HOME`；test 透過 `Process.environment` 注入假的 `$HOME` 指向 tmpdir。兩邊走同一段 code，行為一致。

---

### Resource bundle：`Sources/GenesisCore/Resources/Templates/skills/`（新目錄）

與 `Templates/v0.1/` 平行，一樣靠 `Package.swift` 既有的 `.copy("Resources/Templates")` 打包。結構：

```
Resources/Templates/skills/
├── event-storming/SKILL.md
├── write-ddd-spec/SKILL.md
├── usecase/SKILL.md
├── readmodel/SKILL.md
├── api/SKILL.md
└── strict-review/SKILL.md
```

每個 `SKILL.md` 是 **minimal placeholder**（Phase 1.d 不寫真實 skill 內容）：

```markdown
---
name: <skill-name>
description: Placeholder skill bundled by Genesis. Real content to be authored separately.
---

# <skill-name>

This is a placeholder SKILL.md installed by `genesis install-skills`.
The actual skill logic for `<skill-name>` will be authored in a later phase.
```

🔴 **6 個 skill 名稱固定**（對齊 architecture.md §9 + plan §2.6）：`event-storming` / `write-ddd-spec` / `usecase` / `readmodel` / `api` / `strict-review`。`SkillInstaller.bundledSkillNames()` 動態 enumerate，所以**將來新增第 7 個 skill 只需放目錄、不需改 code**。

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---------|---------|
| `Sources/GenesisCore/SkillInstaller.swift` | **新增**：`SkillInstallSummary` struct + `SkillInstaller.install` / `bundledSkillNames` |
| `Sources/GenesisCore/GenesisError.swift` | **修改**：新增 `skillBundleNotFound` / `skillInstallFailed` case + exit code 表 + userMessage |
| `Sources/Genesis/Commands/InstallSkillsCommand.swift` | **新增**：`InstallSkillsCommand` AsyncParsableCommand subcommand |
| `Sources/Genesis/Genesis.swift` | **修改**：`subcommands: [NewCommand.self, InstallSkillsCommand.self]` |
| `Sources/GenesisCore/Resources/Templates/skills/event-storming/SKILL.md` | **新增**：placeholder |
| `Sources/GenesisCore/Resources/Templates/skills/write-ddd-spec/SKILL.md` | **新增**：placeholder |
| `Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md` | **新增**：placeholder |
| `Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md` | **新增**：placeholder |
| `Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md` | **新增**：placeholder |
| `Sources/GenesisCore/Resources/Templates/skills/strict-review/SKILL.md` | **新增**：placeholder |
| `Tests/GenesisCoreTests/SkillInstallerTests.swift` | **新增**：bundledSkillNames / install happy / skip / force / symlink-reject / type-confusion-reject |
| `Tests/GenesisIntegrationTests/Support/CLIRunner.swift` | **修改**：`run()` 新增 optional `environment: [String: String]? = nil` 參數（additive；nil = 繼承當前 env）；用於 `$HOME` override 測試 |
| `Tests/GenesisIntegrationTests/InstallSkillsCommandTests.swift` | **新增**：CLI e2e — project scope / --force / 重複安裝 skip / invalid project-dir / `--scope user --project-dir` reject / user scope（用 `$HOME` env override 指向 tmpdir）|
| `docs/decisions.md` | **修改**：D24 條目補上 ratification — 「`install-skills` 作為 skill 管理指令印出安裝清單不違反 D24；D24 限定 `genesis new` bootstrap 流程」（codex M5；使用者已授權此 ratification） |
| `docs/architecture.md` | **修改**：§9 加一句說明 `install-skills` 的 stdout 會列出 installed/skipped/overwritten skill 名稱（與 §5.1 D24 釐清一致） |

🔴 **不影響的 call sites**：`NewCommand` 完全不動（`install-skills` 是獨立 subcommand，不整合進 `genesis new`）。`Genesis.main` 的 custom error-mapping 邏輯不動（新 error case 走既有 `error.exitCode` 對照表）。`CLIRunner` 的修改是 additive — 既有所有呼叫 `CLIRunner.run(args)` 的 Phase 1.a/b/c integration test 不受影響（`environment` 有 default nil）。

---

## 實作步驟

### Step 1：6 個 placeholder SKILL.md

按 §「Resource bundle」的格式各寫一個 minimal placeholder。內容極簡，重點是「目錄存在 + 至少一個檔」讓 `SkillInstaller` 有東西可複製。

### Step 2：`SkillInstaller`

```swift
public static func bundledSkillNames() throws -> [String] {
    guard let resourceRoot = Bundle.module.resourceURL else {
        throw GenesisError.skillBundleNotFound(reason: "Bundle.module has no resourceURL")
    }
    let skillsDir = resourceRoot.appendingPathComponent("Templates/skills", isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: skillsDir.path, isDirectory: &isDir), isDir.boolValue else {
        throw GenesisError.skillBundleNotFound(reason: "bundled Templates/skills directory not found at \(skillsDir.path)")
    }
    let entries = try FileManager.default.contentsOfDirectory(
        at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    // codex L7: validate each entry is a real dir, NOT a symlink, and contains SKILL.md
    let validSkills = entries.filter { url in
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }
        let skillMd = url.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: skillMd.path)
    }
    if validSkills.isEmpty {
        throw GenesisError.skillBundleNotFound(reason: "Templates/skills contains no valid skill directories (each must be a non-symlink dir with SKILL.md)")
    }
    return validSkills.map { $0.lastPathComponent }.sorted()
}

public static func install(into targetSkillsDir: URL, force: Bool) throws -> SkillInstallSummary {
    let names = try bundledSkillNames()
    let resourceRoot = Bundle.module.resourceURL!   // bundledSkillNames already validated
    let skillsDir = resourceRoot.appendingPathComponent("Templates/skills", isDirectory: true)

    // codex M3: reject symlinked / non-dir target root before any mutation
    var rootIsDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: targetSkillsDir.path, isDirectory: &rootIsDir) {
        let rootValues = try? targetSkillsDir.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rootValues?.isSymbolicLink == true || !rootIsDir.boolValue {
            throw GenesisError.fileSystemFailed(
                operation: "validate target skills dir",
                underlying: "\(targetSkillsDir.path) is a symlink or not a directory"
            )
        }
    } else {
        do {
            try FileManager.default.createDirectory(at: targetSkillsDir, withIntermediateDirectories: true)
        } catch {
            throw GenesisError.fileSystemFailed(operation: "create skills dir", underlying: error.localizedDescription)
        }
    }

    var installed: [String] = [], skipped: [String] = [], overwritten: [String] = []
    var failed: [(String, String)] = []

    for name in names {
        let src = skillsDir.appendingPathComponent(name, isDirectory: true)
        let dest = targetSkillsDir.appendingPathComponent(name, isDirectory: true)

        var destIsDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dest.path, isDirectory: &destIsDir)
        let destIsSymlink = (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true

        if exists && (destIsSymlink || !destIsDir.boolValue) {
            // codex M3: type confusion — never blindly removeItem a file/symlink
            failed.append((name, "existing entry is a symlink or not a directory; remove it manually"))
            continue
        }
        if exists && !force {
            skipped.append(name)
            continue
        }
        do {
            if exists {  // && force && real dir
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            if exists { overwritten.append(name) } else { installed.append(name) }
        } catch {
            failed.append((name, error.localizedDescription))
        }
    }
    return SkillInstallSummary(installed: installed, skipped: skipped, overwritten: overwritten, failed: failed)
}
```

🔴 **`removeItem` 安全性**：`dest` 永遠是 `targetSkillsDir/<name>`，`name` 來自 `bundledSkillNames()`（Genesis 自家 resource bundle 的目錄名，不是使用者輸入），不可能是 `..` 或絕對路徑 → 不會 path-escape。**且 `removeItem` 前已確認 `dest` 是真目錄**（非 symlink、非 file）— codex M3 的 type-confusion 防線。

### Step 3：`GenesisError` 新 case

加 `skillBundleNotFound` / `skillInstallFailed`，更新 `exitCode` switch 與 `userMessage` switch（兩個都要新增 case，否則 Swift exhaustive switch 編譯失敗 — 沿用 Phase 1.a 慣例不靠 `default`）。

### Step 4：`InstallSkillsCommand`

```swift
struct InstallSkillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-skills",
        abstract: "Install bundled Claude Code skills into ~/.claude/skills or a project."
    )

    enum ScopeOption: String, ExpressibleByArgument {
        case user, project
    }

    @Option(name: .customLong("scope"), help: "user (default) or project.")
    var scope: ScopeOption = .user

    @Option(name: .customLong("project-dir"), help: "Project root (only for --scope project; default: cwd).")
    var projectDir: String?

    @Flag(name: .customLong("force"), help: "Overwrite existing same-named skills.")
    var force: Bool = false

    func run() async throws {
        // Phase 0: sanity
        if scope == .user, projectDir != nil {
            throw GenesisError.bundleInvalid(reason: "--project-dir is only valid with --scope project")
        }

        // Phase 1: resolve target dir
        let targetDir: URL
        switch scope {
        case .user:
            // codex H1: use $HOME (overridable for tests), NOT homeDirectoryForCurrentUser
            guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
                throw GenesisError.bundleInvalid(reason: "$HOME is not set; cannot resolve user scope")
            }
            targetDir = URL(fileURLWithPath: home).appendingPathComponent(".claude/skills", isDirectory: true)
        case .project:
            let root = URL(fileURLWithPath: projectDir ?? FileManager.default.currentDirectoryPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                throw GenesisError.bundleInvalid(reason: "--project-dir does not exist or is not a directory: \(root.path)")
            }
            targetDir = root.appendingPathComponent(".claude/skills", isDirectory: true)
        }

        // Phase 2: install
        let summary = try SkillInstaller.install(into: targetDir, force: force)

        // Phase 3: report (codex M4 — decide success/failure FIRST, then pick banner)
        let hasFailure = !summary.failed.isEmpty
        var lines: [String] = []
        if hasFailure {
            lines.append(
                "⚠️ Genesis: installed \(summary.installed.count), skipped \(summary.skipped.count), "
                + "overwritten \(summary.overwritten.count), FAILED \(summary.failed.count) skill(s) into \(targetDir.path)"
            )
        } else {
            lines.append(
                "✓ Genesis: installed \(summary.installed.count), skipped \(summary.skipped.count), "
                + "overwritten \(summary.overwritten.count) skill(s) into \(targetDir.path)"
            )
        }
        if !summary.installed.isEmpty {
            lines.append("  installed:   \(summary.installed.joined(separator: ", "))")
        }
        if !summary.skipped.isEmpty {
            lines.append("  skipped:     \(summary.skipped.joined(separator: ", "))  (already exist; pass --force to overwrite)")
        }
        if !summary.overwritten.isEmpty {
            lines.append("  overwritten: \(summary.overwritten.joined(separator: ", "))")
        }
        if hasFailure {
            lines.append("  failed:      \(summary.failed.map { $0.skill }.joined(separator: ", "))  (see stderr)")
        }
        print(lines.joined(separator: "\n"))

        if hasFailure {
            for (skill, reason) in summary.failed {
                FileHandle.standardError.write(Data("✗ failed to install '\(skill)': \(reason)\n".utf8))
            }
            genesisExit(2)
        }
    }
}
```

### Step 5：`Genesis.swift` subcommands

```swift
subcommands: [NewCommand.self, InstallSkillsCommand.self]
```

### Step 6：Tests

**Unit（`SkillInstallerTests`）**：
1. `testBundledSkillNamesReturnsSixSkills` — `bundledSkillNames()` 回傳含 6 個預期名稱
2. `testInstallIntoEmptyDir` — 空 tmpdir → 全部 `installed`，`skipped`/`overwritten`/`failed` 空
3. `testInstallSkipsExisting` — 先手動建一個 `<tmpdir>/usecase/` → install 後 `usecase` 在 `skipped`
4. `testInstallForceOverwrites` — 先建一個 `<tmpdir>/usecase/marker.txt` → `install(force: true)` 後 `usecase` 在 `overwritten` 且 `marker.txt` 不見了（被整個 replace）
5. `testInstallCreatesTargetDirWhenMissing` — `targetSkillsDir` 不存在 → install 後存在
6. `testInstallRejectsSymlinkRoot` — `targetSkillsDir` 是指向別處的 symlink → `install` throw `fileSystemFailed`（codex M3）
7. `testInstallRejectsTypeConfusedEntry` — 先建一個 `<tmpdir>/usecase`（**檔案**，不是目錄）→ install 後 `usecase` 在 `failed`，且該檔**沒被刪**（即使 `force: true`，codex M3）

**Integration（`InstallSkillsCommandTests`）— 用 `CLIRunner` 跑 binary**：
8. `testInstallProjectScope` — tmpdir 當 project root，`install-skills --scope project --project-dir <tmpdir>` → `<tmpdir>/.claude/skills/` 內有 6 個 skill 目錄；exit 0
9. `testInstallProjectScopeIdempotentSkip` — 跑兩次 `--scope project` → 第二次 exit 0 且 stdout 含 `skipped`
10. `testInstallProjectScopeForce` — 跑一次後 `--force` 再跑 → stdout 含 `overwritten`
11. `testInvalidProjectDir` — `--scope project --project-dir /no/such/path` → exit 1
12. `testUserScopeWithProjectDirRejected` — `--scope user --project-dir <tmpdir>` → exit 1，stderr 含 `--project-dir is only valid with --scope project`（codex H2）
13. `testUserScopeWithHomeOverride` — 透過 `CLIRunner.run(environment:)` 注入 `HOME=<tmpHome>`，跑 `--scope user`（不帶 project-dir）→ `<tmpHome>/.claude/skills/` 內有 6 個 skill；exit 0

🔴 **`testUserScopeWithHomeOverride` 改用 `$HOME`**（codex H1）：InstallSkillsCommand 用 `ProcessInfo.processInfo.environment["HOME"]` 解析 user home（**不是** `FileManager.homeDirectoryForCurrentUser` — codex 實測後者不認 `$HOME` override，會寫到真實 home，危險）。`CLIRunner.run` 加 optional `environment: [String: String]? = nil` 參數（additive；nil = 繼承當前 env），test 傳入 `["HOME": tmpHome.path]`（建議也帶上 `PATH` 等必要 env 確保 binary 跑得起來 — 實作期確認 Process 預設行為）。

---

## 失敗路徑

```
[Phase 0: sanity]
A. --scope 非法值 → ArgumentParser parse 階段 usage error → exit 64（非 GenesisError 路徑）
B. --scope user 且帶 --project-dir → throw bundleInvalid → Genesis.main catch → exit 1（codex H2）
C. --scope project 且 --project-dir 不存在 / 非目錄 → throw bundleInvalid → exit 1

[Phase 1: 解析 target dir]
D. --scope user 且 $HOME 未設定 → throw bundleInvalid → exit 1（codex H1）
   （其餘無 fs mutation）

[Phase 2: SkillInstaller.install]
E. bundledSkillNames：resource bundle 內 Templates/skills 不存在 / 無 valid skill → throw skillBundleNotFound → exit 2
F. targetSkillsDir 已存在但是 symlink / 非目錄 → throw fileSystemFailed → exit 2（codex M3）
G. createDirectory(targetSkillsDir) 失敗（權限）→ throw fileSystemFailed → exit 2
H. 單一 skill：dest 是 symlink/file（type confusion）→ 不 throw、不刪，記進 summary.failed[]（codex M3）
I. 單一 skill copyItem 失敗 → 不 throw，記進 summary.failed[]（best-effort 繼續其他 skill）

[Phase 3: 回報]
J. summary.failed 非空 → InstallSkillsCommand 印 `⚠️` banner + stdout failed 行 + stderr 逐項 reason + genesisExit(2)
K. summary.failed 空 → 印 `✓` banner → exit 0
```

🔴 **無 rollback**：`install-skills` 跨 skill 是 best-effort（skill 彼此獨立），**刻意不做** atomic 全有全無。失敗的 skill 列在 `failed[]`，成功的留著。使用者可修正問題後 `--force` 重跑。這跟 `genesis new`（單一專案要嘛全產要嘛全 rollback）是不同的設計取捨，spec 明確記載此差異。

---

## 不改動的部分

- `NewCommand`（`genesis new` 完全不動）
- `Genesis.main` 的 custom error → exit-code mapping 邏輯（新 error case 走既有 `error.exitCode` 對照表，不需改 main）
- Phase 1.a/b/c 既有 84 個 test 全部維持綠
- `SourceWriter` / `BundleParser` / `AdapterYamlParser` / 所有 renderer — 完全不碰
- `Templates/v0.1/`（generated-project templates）— 不動；Phase 1.d 只在 `Templates/` 下新增平行的 `skills/` 子目錄
- Genesis 自身 `Package.swift` — **不需改**（`.copy("Resources/Templates")` 已涵蓋新增的 `Resources/Templates/skills/`）

🔴 **`docs/decisions.md` D24 + `docs/architecture.md` §9 會被修改**（codex M5 ratification）— 這兩份不在「不改動」清單，見「改動檔案」段。

### Non-goals（行為層）

本 task **不包含**：
- `genesis update-skills` 指令（architecture §9.3）— Phase 1.d 只做 install
- skill 內容本身的撰寫 — Phase 1.d 只放 minimal placeholder SKILL.md
- `genesis install-mcp`（→ Phase 2）
- `genesis new --with-skills` 整合（install-skills 維持獨立指令；未來整合留後續）
- per-project skill 客製化偵測（architecture §11 open Q4 — 「使用者改過 skill，Genesis 新版怎麼辦」）
- skill 版本衝突偵測 / skill 版本號管理
- skill bundle 跨 skill 的 atomic rollback（刻意 best-effort）
- git pre-flight（`~/.claude/skills/` 不保證是 git repo）
- skill 安裝後的 `~/.claude/settings.json` 註冊（Claude Code 自動 discover `~/.claude/skills/` 下的 skill，不需註冊）
- 安裝進度條 / verbose 模式
- 並行多個 `install-skills` 跑同一 `targetSkillsDir` 的 locking（codex Q9：殘留 low-priority race，Phase 1.d 不處理）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# D1. release build
swift build -c release --product genesis

# D2. Phase 1.a/b/c 既有 84 test 全綠
swift test --filter GenesisCoreTests
swift test --filter GenesisIntegrationTests

# D3. Phase 1.d 新單元測試全綠
swift test --filter SkillInstallerTests

# D4. Phase 1.d 新整合測試全綠
swift test --filter InstallSkillsCommandTests

# D5. 6 個 placeholder SKILL.md 都在
test -f Sources/GenesisCore/Resources/Templates/skills/event-storming/SKILL.md
test -f Sources/GenesisCore/Resources/Templates/skills/write-ddd-spec/SKILL.md
test -f Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md
test -f Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md
test -f Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md
test -f Sources/GenesisCore/Resources/Templates/skills/strict-review/SKILL.md

# D6. GenesisError 新 case 有 throw 點
grep -RE 'throw\s+GenesisError\.skillBundleNotFound' Sources/

# D7. Genesis.swift 註冊 InstallSkillsCommand
grep -F 'InstallSkillsCommand.self' Sources/Genesis/Genesis.swift

# D8. SkillInstaller 介面存在
grep -RE 'public static func install\(into' Sources/GenesisCore/SkillInstaller.swift
grep -RE 'public static func bundledSkillNames\(\) throws' Sources/GenesisCore/SkillInstaller.swift

# D9. install-skills 不呼叫 GitPreflight（不保證 git repo）
! grep -F 'GitPreflight' Sources/Genesis/Commands/InstallSkillsCommand.swift

# D10. install-skills 不整合進 NewCommand（保持獨立）
! grep -F 'SkillInstaller' Sources/Genesis/Commands/NewCommand.swift

# D11. e2e — project scope（用 tmpdir，不碰真實 ~/.claude）
T=$(mktemp -d)
/Users/abnertsai/JiaBao/Mendesky/Genesis/.build/release/genesis install-skills --scope project --project-dir "$T"
echo "exit: $?"   # 必須 0
test -d "$T/.claude/skills/usecase"
test -d "$T/.claude/skills/event-storming"
test -f "$T/.claude/skills/usecase/SKILL.md"

# D12. e2e — 重複安裝 idempotent skip
/Users/abnertsai/JiaBao/Mendesky/Genesis/.build/release/genesis install-skills --scope project --project-dir "$T" 2>&1 | grep -F 'skipped'

# D13. e2e — invalid project-dir
/Users/abnertsai/JiaBao/Mendesky/Genesis/.build/release/genesis install-skills --scope project --project-dir /no/such/genesis/path; echo "exit: $?"  # 必須 1

# D14. e2e — --scope user 帶 --project-dir 被 reject（codex H2）
/Users/abnertsai/JiaBao/Mendesky/Genesis/.build/release/genesis install-skills --scope user --project-dir "$T" 2>&1 | grep -F 'only valid with --scope project'
rm -rf "$T"

# D15. e2e — user scope 用 $HOME override（不碰真實 home，codex H1）
H=$(mktemp -d)
HOME="$H" /Users/abnertsai/JiaBao/Mendesky/Genesis/.build/release/genesis install-skills --scope user
echo "exit: $?"  # 必須 0
test -d "$H/.claude/skills/usecase"
rm -rf "$H"

# D16. InstallSkillsCommand 用 $HOME（不用 homeDirectoryForCurrentUser）
grep -F 'environment["HOME"]' Sources/Genesis/Commands/InstallSkillsCommand.swift
! grep -F 'homeDirectoryForCurrentUser' Sources/Genesis/Commands/InstallSkillsCommand.swift

# D17. SkillInstaller 有 symlink / type-confusion 防線（codex M3）
grep -F 'isSymbolicLink' Sources/GenesisCore/SkillInstaller.swift

# D18. decisions.md D24 已 ratify install-skills 印 skill name（codex M5）
grep -F 'install-skills' docs/decisions.md
```

### Human 補做（需要人類介入）

- [ ] 手動跑 `genesis install-skills`（**不帶任何 flag，預設 user scope**），確認 `~/.claude/skills/` 內出現 6 個 skill 目錄（注意：這會真的寫進你的 home — 跑前先確認沒有同名衝突，或用測試帳號）
- [ ] 確認 stdout 摘要格式：`installed N, skipped M, overwritten K`，且 installed / skipped 各行列出 skill 名稱
- [ ] 對某個剛裝好的 skill 目錄手動改一個檔，再跑一次（不帶 `--force`）→ 確認該 skill 進 `skipped`、改的內容**沒被覆寫**
- [ ] 同上情境改帶 `--force` → 確認該 skill 進 `overwritten`、改的內容**被覆寫回 placeholder**
- [ ] 確認 `~/.claude/skills/` 下使用者自己原本放的其他 skill（非 Genesis 的）**完全沒被動到**
- [ ] 開 Claude Code，確認剛安裝的 placeholder skill 能被 `/` 列出來（驗證目錄結構 + SKILL.md frontmatter 被 Claude Code 認得）
- [ ] 在一個非 git 目錄跑 `install-skills --scope project --project-dir <該目錄>`，確認**不會**因為不是 git repo 而失敗（驗證 install-skills 真的沒做 git pre-flight）

---

## 已知限制

- **skill 內容是 placeholder**：6 個 SKILL.md 只是 minimal 佔位，真實 skill 邏輯是後續工作。`install-skills` 的複製機制不依賴 skill 內容品質
- **無 `update-skills`**：使用者已安裝後，Genesis 出新版 skill，得手動 `--force` 重裝；智慧 update（保留使用者客製化）留 architecture §9.3 的後續工作
- **`--force` 是整目錄 replace**：使用者若在某 skill 目錄內加了自己的檔案，`--force` 會連同那些檔一起刪掉重來（architecture §11 open Q4 的客製化偵測未實作）
- **跨 skill best-effort，無 atomic rollback**：與 `genesis new` 不同，刻意取捨（skill 彼此獨立）
- **`--scope user` 寫進真實 `~/.claude/skills/`**：unit/integration test 一律用 tmpdir 或 `HOME` env override，**絕不**讓自動化測試碰真實 home
- **不註冊到 `~/.claude/settings.json`**：依賴 Claude Code 自動 discover `~/.claude/skills/` — 若未來 Claude Code 改成需要顯式註冊，此 spec 要再開 task
- **依賴關係**：前置 task = `phase-1c-adapter-and-manifest`（status: `done`）
- **後續 task**：
  - `phase-2-mcp` — `genesis install-mcp` + `genesis new --with-mcp`
  - `phase-3-diff-apply` — `genesis diff` / `apply` / `adapter` / `update-skills`
  - `phase-4-canvas-sync` — `genesis plan-canvas-sync` / `verify-canvas`
  - 真實 skill 內容撰寫（獨立於 Genesis CLI roadmap 之外的工作）
