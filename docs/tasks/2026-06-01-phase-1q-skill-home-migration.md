# Phase 1.q — Skill home migration 收尾（version drift 偵測 + bundle-parse CLI + project-local 警告）

## 來源

討論：`docs/discussions/2026-05-28-phase-1q-bundle-plan-skill-migration.md`（13 decisions locked）

依賴 Phase（全 done）：phase-1l1（codegen injection）、phase-1p（write DTO + mapper）、phase-1p1（structured TODO marker）。

## 目標

Phase 1.q discussion 的 skill home migration 部分**已實裝 80%**（D8 `~/.claude/skills/` scope / D9 `genesis new` 不 emit skill / D10 `install-skills` 命令 / D11 overwrite policy / Open4 跨 OS 用 `$HOME` env 解決）。本 task 收尾剩餘 3 個 delta，全部是 **CLI-side 新增**，不動任何 skill SKILL.md 行為（遵守 discussion Non-goal「只搬家不改 skill 邏輯」）：

1. **版本 drift 偵測**（D12 part 2 / Open1）：`genesis --version` 目前不可用（root CommandConfiguration 缺 `version:`）。修好它 + `install-skills` 寫版本戳記 + 新 `genesis check-skills` 命令比對 binary 版本 vs 已安裝 skill 版本，回報 in-sync / stale。
2. **`genesis bundle-parse <path>` CLI**（Open5 = (c)）：把 `BundleParser.parseFull` 結果以 stable JSON 印到 stdout。讓未來所有 skill（`/bundle-plan`, `/usecase` 等）走單一權威 parser，消除 per-skill parsing drift。
3. **project-local skill 警告**（D13）：`install-skills` 跑完掃描常見 project 路徑，若發現殘留的 project-local Genesis skill（會 shadow 全局版）→ stderr 警告 + 提供移除指令，不自動刪。

**`/bundle-plan` skill 本身（discussion 問題 1 / D1-D7）不在本 task** — 留 Phase 1.r。本 task 是 migration infra 收尾，為 1.r 鋪路（bundle-parse CLI 是 1.r 的前置）。

## 介面合約（Interface Contract）

### 修改 1：`Genesis.swift` — root command 加 `version`

`CommandConfiguration` 加 `version: GenesisCoreVersion.current`，使 `genesis --version` 印出版本字串（current = `0.1.0-phase1k2`）。

```swift
static let configuration = CommandConfiguration(
    commandName: "genesis",
    abstract: "Bootstrap a Swift DDD/ES project from a Cosmogony Event Storming bundle.",
    version: GenesisCoreVersion.current,   // ← Phase 1.q
    subcommands: [NewCommand.self, InstallSkillsCommand.self, CheckSkillsCommand.self, BundleParseCommand.self]
)
```

ArgumentParser 內建 `--version` handler 認 `version:` field（既有 `Self.exit(withError:)` fallthrough 已 handle CleanExit）。

合約：
- `genesis --version` → stdout 印 `0.1.0-phase1k2`，exit 0。
- 不影響既有 `--help` / subcommand parsing。

### 修改 2：`InstallSkillsCommand` — 寫版本戳記

`SkillInstaller.install` 成功後，在 target skills dir 寫一個 sidecar `.genesis-skills-version` 純文字檔（單行 = 安裝當下的 `GenesisCoreVersion.current`）。

合約：
- 檔案路徑：`<targetDir>/.genesis-skills-version`（如 `~/.claude/skills/.genesis-skills-version`）。
- 內容：單行版本字串，無 trailing 結構（純 `GenesisCoreVersion.current`）。
- 寫入時機：`SkillInstaller.install` 回傳後、report 前（即使部分 skill failed 也寫 — 戳記代表「這次 install 用的 binary 版本」）。
- sidecar 不算 skill（dotfile，`bundledSkillNames()` 的 scan 已 filter 非 SKILL.md dir，不受影響）。

### 新增 3：`CheckSkillsCommand`（`genesis check-skills`）

新檔 `Sources/Genesis/Commands/CheckSkillsCommand.swift`。

```swift
struct CheckSkillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-skills",
        abstract: "Check whether installed skills are in sync with the current genesis binary."
    )

    @Option(name: .customLong("scope"), help: "user (default) or project.")
    var scope: InstallSkillsCommand.ScopeOption = .user

    @Option(name: .customLong("project-dir"), help: "Project root (only for --scope project; default: cwd).")
    var projectDir: String?

    func run() async throws { ... }
}
```

合約：
- target dir 解析邏輯**與 `InstallSkillsCommand` 完全一致**（`$HOME` 為基底、scope user/project、project-dir 驗證）— 抽共用 helper 避免 drift（見實作步驟）。
- 讀 `<targetDir>/.genesis-skills-version`：
  - 檔案不存在 → stdout 印 `⚠ skills not installed (no .genesis-skills-version found at <path>); run 'genesis install-skills'`，**exit 2**。
  - 存在且內容 == `GenesisCoreVersion.current` → stdout 印 `✓ skills in sync (version <X>)`，exit 0。
  - 存在但內容 != current → stdout 印 `⚠ skills stale: installed <old> vs binary <current>; run 'genesis install-skills --force'`，**exit 2**。
- 版本比對為**精確字串相等**（非 SemVer range）。理由：version 字串是 phase-tagged（`0.1.0-phase1k2`）非乾淨 SemVer；skill 由同一 binary 的 bundle 複製出，永遠跟 binary 同源，所以「相同 = 同步、不同 = 需重裝」精確相等即足夠，不需 range 比較。

### 新增 4：`BundleParseCommand`（`genesis bundle-parse <path>`）

新檔 `Sources/Genesis/Commands/BundleParseCommand.swift`。

```swift
struct BundleParseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-parse",
        abstract: "Parse a Cosmogony bundle JSON and emit the canonical FullBundle as JSON to stdout."
    )

    @Argument(help: "Path to the bundle JSON file.")
    var bundlePath: String

    func run() async throws { ... }
}
```

合約：
- 讀 `bundlePath` → `BundleParser.parseFull(at:)` → 把回傳的 `FullBundle` encode 成 JSON 印到 stdout（pretty-printed，sorted keys 為 stable diff）。
- bundle invalid / not found → 走既有 `GenesisError` 路徑（main 的 error → exit code 對映已 handle：bundleInvalid → exit 1, bundleNotFound → exit 1）。
- stdout 只有 JSON（無 banner / progress），方便 skill / pipe 消費。stderr 可有 BundleParser 既有的 derive warning（如 `⚠ ReadModel ... derived key`）。
- JSON shape = `FullBundle` 的 Codable 表示。**`FullBundle.swift` 內全部 16 個 public 型別都要加 `Encodable`**（`FullBundle` transitively encode 它們全部，漏一個就 compile fail）。完整名單：`FullBundle` / `ReadModelSpec` / `ReadModelKey` / `ReadModelStoredField` / `ReadModelEventRef` / `AggregateSpec` / `UseCaseSpec` / `DtoSpec` / `FieldSpec` / `InvariantSpec` / `InvariantRule` / `PresenterSpec` / `PresenterInput` / `PresenterInputField` / `PresenterOutputKind`（enum，已 `: String` → 自動 Encodable）/ `PresenterOutput` / `PresenterEndpoint`。目前皆 `Sendable, Equatable`，改 `Sendable, Equatable, Encodable`。

### 新增 5：`InstallSkillsCommand` — project-local skill 掃描 + 警告（D13）

`install-skills` 跑完 report 後（user scope only），掃描常見 project 根目錄，偵測殘留的 project-local Genesis skill。

合約：
- 掃描路徑：`$HOME` 下的 `JiaBao/` 子樹（discussion D13 寫死此路徑；single-user 場景）。用 `FileManager` enumerator 找 `*/.claude/skills/<genesisSkillName>/` 其中 `genesisSkillName ∈ {usecase, api, presenter-fill, readmodel-mutation, bundle-plan}`（Genesis 出的 skill 名單，從 `SkillInstaller.bundledSkillNames()` 取得，避免 hardcode drift）。
- 每發現一個 project-local skill → stderr 印：
  ```
  ⚠ Found project-local Genesis skills at <path>/.claude/skills/.
    These will SHADOW global skills. Consider removing manually:
      rm -rf <path>/.claude/skills/{<names>}
  ```
- 不自動刪（D13 明確 — user 可能改過 / 在用）。
- 掃描失敗（路徑不存在 / 權限）→ silent skip，不影響 install 主流程 exit code。
- 僅 `--scope user` 時掃描；`--scope project` 時跳過（project install 本就是要放 project-local，不該警告自己）。

### Framework 備註

- `genesis --version` 靠 ArgumentParser `version:` field，零自訂邏輯。
- 版本戳記用 dotfile sidecar（非改 SKILL.md content）— 因 `SkillInstaller.install` 是 raw `copyItem`，SKILL.md 內 `{GenesisVersion}` placeholder 不會被 render；sidecar 避開此問題，且不污染 skill 內容。
- `bundle-parse` 重用既有 `BundleParser.parseFull` — 不複製 parsing 邏輯，CLI 是 thin wrapper。

## 改動檔案

### Source（5 files，~120 行）

| File | Change |
|---|---|
| `Sources/Genesis/Genesis.swift` | root CommandConfiguration 加 `version:` + 註冊 2 個新 subcommand |
| `Sources/Genesis/Commands/InstallSkillsCommand.swift` | (a) install 成功後寫 `.genesis-skills-version` sidecar / (b) user scope 跑完掃 project-local skill 警告 / (c) target-dir 解析抽共用 helper（給 CheckSkills 共用）|
| `Sources/Genesis/Commands/CheckSkillsCommand.swift` | **新檔** — 版本 drift 偵測 |
| `Sources/Genesis/Commands/BundleParseCommand.swift` | **新檔** — bundle → JSON CLI |
| `Sources/GenesisCore/FullBundle.swift` | `FullBundle` + 巢狀 spec 型別加 `Encodable` conformance（目前 `Sendable, Equatable`，加 `, Encodable`）|

### Test（2 files，~120 行）

| File | Change |
|---|---|
| `Tests/GenesisCoreTests/SkillInstallerTests.swift` | 加 sidecar 寫入 test（install 後 `.genesis-skills-version` 存在且內容 == current）|
| `Tests/GenesisIntegrationTests/`（新檔 `CliVersionAndBundleParseTests.swift` 或併入既有）| `genesis --version` / `check-skills`（in-sync / stale / not-installed 三態）/ `bundle-parse`（valid bundle → JSON parse-back 一致 + invalid → exit 1）E2E |

### Affected call sites（非改動，但受影響）

- `InstallSkillsCommand.ScopeOption` enum 被 `CheckSkillsCommand` 經 `InstallSkillsCommand.ScopeOption` 限定名引用。目前 `enum ScopeOption: String, ExpressibleByArgument` 為 struct 內 internal nested type，same-module 跨 command 引用合法，**不需移出或改 access level**。

## 實作步驟

### Step 1：`FullBundle.swift` — 加 `Encodable`

1. `FullBundle.swift` 內**全部 16 個** public struct/enum（完整名單見介面合約「新增 4」），conformance 從 `Sendable, Equatable` 改 `Sendable, Equatable, Encodable`。逐個加，漏一個 transitively encode 會 compile fail。
2. 所有 stored property 型別皆 `Encodable`-able（String / Int / Bool / [..] / optional / 巢狀 spec / `PresenterOutputKind` 是 `: String` enum）— Swift 自動合成 `Encodable`，無需手寫 `encode(to:)`。
3. `TypeOwnership`（在 `TypeOwnershipResolver.swift`，非 FullBundle.swift）**不是** FullBundle stored property，不需動。
4. `swift build` 驗證合成成功。

### Step 2：`Genesis.swift` — version + subcommand 註冊

1. `CommandConfiguration` 加 `version: GenesisCoreVersion.current`。
2. `subcommands:` 加 `CheckSkillsCommand.self`, `BundleParseCommand.self`。
3. `import GenesisCore` 已存在（GenesisCoreVersion 可見）。

### Step 3：共用 target-dir 解析 helper

1. 把 `InstallSkillsCommand.run` 內的 target-dir 解析邏輯（scope → URL）抽成共用 static func（Genesis target 內新檔 `SkillTargetResolver.swift`）。
2. signature：`static func resolveTargetDir(scope: InstallSkillsCommand.ScopeOption, projectDir: String?) throws -> URL`。
3. **`ScopeOption` enum 保持 nested 在 `InstallSkillsCommand` 內、不移動** — `CheckSkillsCommand` 透過 `InstallSkillsCommand.ScopeOption` 直接引用（same-module nested type access 合法）。
4. `InstallSkillsCommand` 改用此 helper（行為不變，純 refactor）。

### Step 4：`InstallSkillsCommand` — sidecar 戳記 + project-local 警告

1. `SkillInstaller.install` 回傳後，寫 `<targetDir>/.genesis-skills-version`（內容 `GenesisCoreVersion.current + "\n"`）。寫入失敗 → stderr warn 但不改 exit code（戳記非關鍵路徑）。
2. `--scope user` 時，install report 後呼叫新 helper `scanProjectLocalSkills(home:bundledNames:)`：
   - enumerate `$HOME/JiaBao/` 下 `*/.claude/skills/<name>/`（name ∈ bundledNames）。
   - 每命中印 D13 格式 stderr warning。
   - 任何 FS error → silent skip。

### Step 5：`CheckSkillsCommand.swift` — 新檔

1. 用 Step 3 helper 解析 targetDir。
2. 讀 `<targetDir>/.genesis-skills-version`：不存在 → exit 2 + 提示 install；內容 == current → exit 0 in-sync；!= → exit 2 + 提示 install --force。
3. 三態 stdout message 依介面合約。

### Step 6：`BundleParseCommand.swift` — 新檔

1. `BundleParser.parseFull(at: URL(fileURLWithPath: bundlePath))`。
2. `JSONEncoder` with `.prettyPrinted` + `.sortedKeys` → encode FullBundle → print to stdout。
3. error 走既有 GenesisError → main 對映 exit code（不自訂）。

### Step 7：Tests

1. `SkillInstallerTests`：加 `testInstallWritesVersionSidecar` — install 後 sidecar 存在 + 內容 == `GenesisCoreVersion.current`。
2. 新 integration test：
   - `testVersionFlag` — `genesis --version` stdout 含 `0.1.0-phase1k2`，exit 0。
   - `testCheckSkillsNotInstalled` — 空 dir → exit 2 + "not installed"。
   - `testCheckSkillsInSync` — install 後 check → exit 0 + "in sync"。
   - `testCheckSkillsStale` — install 後手動改 sidecar 內容 → check → exit 2 + "stale"。
   - `testBundleParseValid` — 跑 iam-cosmogony-bundle.json → stdout JSON 可 decode 回 + context == IAMContext。
   - `testBundleParseInvalid` — malformed bundle → exit 1。

### Step 8：本地 verify

```bash
swift build
swift test

# version
swift run genesis --version    # → 0.1.0-phase1k2

# install + check round-trip（用臨時 HOME 避免污染真實 ~/.claude）
TMPHOME=$(mktemp -d)
HOME="$TMPHOME" swift run genesis install-skills    # writes ~/.claude/skills + sidecar
HOME="$TMPHOME" swift run genesis check-skills       # → ✓ in sync
test -f "$TMPHOME/.claude/skills/.genesis-skills-version"

# bundle-parse
swift run genesis bundle-parse Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json | head -20
rm -rf "$TMPHOME"
```

## 失敗路徑

### `check-skills`

| 條件 | 行為 |
|---|---|
| sidecar 不存在 | stdout warn + exit 2 |
| sidecar 內容 != current | stdout stale warn + exit 2 |
| `--scope project` + `--project-dir` 不存在 | 既有 `bundleInvalid` → exit 1（重用 install 同 validation）|

### `bundle-parse`

| 條件 | 行為 |
|---|---|
| 檔案不存在 | `GenesisError.bundleNotFound` → exit 1 |
| JSON malformed / schema invalid | `GenesisError.bundleInvalid` → exit 1 |
| parse OK | JSON to stdout + exit 0 |

### `install-skills` sidecar 寫入失敗

非關鍵路徑 → stderr warn，**不改** install 本身 exit code（install 成功就 0、有 skill failed 就 2，與 sidecar 無關）。

## 不改動的部分

### Skill SKILL.md 內容

- **不動任何 skill 的 SKILL.md 行為 / 邏輯**（discussion Non-goal「只搬家不改 skill」）。版本 drift 偵測走 CLI-side `check-skills`，不在 skill 內加 Step 0。
- 不 render SKILL.md 內 `{GenesisVersion}` placeholder（既有 raw copyItem 行為保留；本 task 不碰）。

### 既有 CLI 行為

- `genesis new` — 完全不動。
- `install-skills` 既有 scope / force / report 行為 — 保留，只 append sidecar 寫入 + project-local 掃描。
- `SkillInstaller.install` 既有 install 邏輯 — 不動（sidecar 寫入在 command layer，非 installer layer）。

### Phase 1.r 範疇

- `/bundle-plan` skill 本身 — 不在本 task（discussion D1-D7）。
- bundle diff replan（D4 / Open2）— Phase 1.r。
- `/bundle-plan` vs `write-ddd-spec` 共存（Open3）— Phase 1.r。

### Non-goals（行為層）

- 本 task **不**改任何 skill SKILL.md 的 fill 邏輯。
- 本 task **不**做 brew post-upgrade hook（D12 part 1 — Homebrew tap formula 改動，不在 Genesis source repo）。
- 本 task **不**自動刪 project-local skill（D13 — 只警告）。
- 本 task **不** render SKILL.md placeholder（既有 copyItem 行為保留）。
- 本 task **不**實作 `/bundle-plan` skill（Phase 1.r）。
- 本 task **不**做 SemVer range 比對（精確字串相等即足夠，version 字串是 phase-tagged）。

## 已知限制

- **`check-skills` 是 phase-exact 比對**：version 字串每個 phase 都會變（`0.1.0-phase1k2` → 下個 phase 變字串），所以每次 Genesis binary 升級後 `check-skills` 都會報 stale 直到 user 重跑 `install-skills --force`。這是預期行為（提醒 user 重裝），非 bug。未來若改用乾淨 SemVer + 只在 bundle-schema-breaking 時 bump，可改 range 比對減少 noise。
- **project-local 掃描寫死 `$HOME/JiaBao/`**：D13 single-user 假設。其他 user 的 project 樹不在此路徑下不會被掃到 — 可接受（single-machine 場景）。未來多 root 可加 config。
- **`bundle-parse` JSON shape 綁 `FullBundle` Codable 合成**：欄位改名 / 增刪會改變 output JSON shape。消費端（Phase 1.r `/bundle-plan`）需視此為 stable contract，跟 bundle schema 同等管控。Phase 1.q 不額外加 schema version 到 output（FullBundle 已有 manifestVersion 可辨識）。
- **D12 part 1（brew auto-install）不在本 task**：是 Homebrew tap formula 的 post-install hook，屬 release infra 非 source code。`check-skills` 是其 backup；user 手動裝舊 binary 時靠 `check-skills` 抓 drift。

### 依賴關係

- 前置（hard depends_on）：無（Phase 1.l1/1.p/1.p1 全 done）。
- 軟相依（soft depends_on，已 done）：
  - discussion D8-D11 + Open4 已實裝（`InstallSkillsCommand` / `SkillInstaller` 既有）。
- 後續（unblocks）：
  - **Phase 1.r `/bundle-plan` skill** — 用 `genesis bundle-parse` 當權威 parser（Open5 = (c) 的 downstream consumer）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

swift build 2>&1 | tail -5
# 期望: "Build complete!"

swift test 2>&1 | tail -10
# 期望: 全 pass 0 failures

# 修改 1：genesis --version 可用
swift run genesis --version 2>&1 | grep -q '0.1.0-phase1k2'

# 修改 1：root config 含 version + 註冊新 subcommand
grep -q 'version: GenesisCoreVersion.current' Sources/Genesis/Genesis.swift
grep -q 'CheckSkillsCommand.self' Sources/Genesis/Genesis.swift
grep -q 'BundleParseCommand.self' Sources/Genesis/Genesis.swift

# 新增 3：check-skills command 存在
test -f Sources/Genesis/Commands/CheckSkillsCommand.swift
grep -q 'commandName: "check-skills"' Sources/Genesis/Commands/CheckSkillsCommand.swift

# 新增 4：bundle-parse command 存在
test -f Sources/Genesis/Commands/BundleParseCommand.swift
grep -q 'commandName: "bundle-parse"' Sources/Genesis/Commands/BundleParseCommand.swift

# 修改 5：FullBundle Encodable
grep -q 'Encodable' Sources/GenesisCore/FullBundle.swift

# E2E round-trip（臨時 HOME 隔離）
TMPHOME=$(mktemp -d)
HOME="$TMPHOME" swift run genesis install-skills 2>&1 | tail -2
test -f "$TMPHOME/.claude/skills/.genesis-skills-version"
grep -q '0.1.0-phase1k2' "$TMPHOME/.claude/skills/.genesis-skills-version"
HOME="$TMPHOME" swift run genesis check-skills 2>&1 | grep -q 'in sync'

# stale 偵測
echo "0.0.0-old" > "$TMPHOME/.claude/skills/.genesis-skills-version"
set +e
HOME="$TMPHOME" swift run genesis check-skills 2>&1 | grep -q 'stale'
STALE_HIT=$?
set -e
test "$STALE_HIT" = "0"

# bundle-parse → JSON
swift run genesis bundle-parse Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["context"]=="IAMContext"'

rm -rf "$TMPHOME"
```

### Human 補做（需要人類介入）

- [ ] 確認 `genesis install-skills` 跑在真實 `~/.claude/skills/` 後，既有 4 個 fill skill + 未來 bundle-plan 都正常被 Claude Code 載入（skill registry 認得）。
- [ ] 確認 project-local 警告在真實有殘留 project skill 的環境會觸發（dogfood 用過 `genesis new` 舊版的 project 若還有 `.claude/skills/`）。
- [ ] 跟 Homebrew tap formula 維護者（user 自己）確認 D12 part 1 brew post-upgrade hook 是否要加 `genesis install-skills` auto-run。
