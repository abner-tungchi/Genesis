# Phase 1.r — /bundle-plan skill（bundle → N 份 per-UC task spec）

## 來源

討論：`docs/discussions/2026-05-28-phase-1q-bundle-plan-skill-migration.md`（D1-D7 locked /bundle-plan 設計 + Open2/Open3 本 task 收斂）

依賴 Phase（全 done）：phase-1q（`genesis bundle-parse` CLI — 本 skill 的權威 parser 前置）、phase-1p（write DTO）、phase-1l1（codegen injection）。

本 task 收斂的 open question（discussion 留到 spec 階段）：
- **Open2.1**：UC identity 用 `useCaseSpecId` UUID（rename 不破壞 mapping）。
- **Open2.2**：內容 diff 逐欄比對 input / emittedEvent / eventPayload。
- **Open2.3**：done task 對應 UC 改了 → 產 amendment task + 原 task 標 `needs-update`（不無聲改已 ship code 對應的 spec）。
- **Open3**：`/bundle-plan` 與 `write-ddd-spec` **分流** — `/bundle-plan` 吃 bundle 批次、`write-ddd-spec` 無 bundle 時 manual single-UC。`/bundle-plan` 自己實作 method X，不包 write-ddd-spec（後者 interactive per-UC，批次包它違反 method X batch 精神）。

## 目標

新增 `/bundle-plan` skill（住 `Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md`），把一份 Cosmogony bundle JSON 拆成 **N 份 per-UC task spec MD**（每 write UC 一份，寫到 generated project 的 `docs/tasks/<UseCaseName>.md`），每份是 contract-first 8-section spec。§1/§2/§7/§3 從 bundle 機械填，§5/§6 由 LLM 推測一版 → user 逐 UC 確認（method X，D5）。產出的 task spec 同時是 runbook（給 user 追 progress）+ skill input（給 `/usecase` `/api` 等 fill skill 讀）（D6）。

`/bundle-plan` 是 **plan-only**（D1）— 不呼叫 `genesis new`、不 emit Swift code。codegen 仍由 user 手動跑 CLI。

支援 `--replan`（D4）：bundle 改後對比上次產出，diff 出 added / modified / removed UC，產 amendment task。

## 介面合約（Interface Contract）

### Skill frontmatter

```markdown
---
name: bundle-plan
description: Genesis planning skill. Inside (or pointed at) a Genesis-bootstrapped project, /bundle-plan <bundle.json> splits a Cosmogony bundle into N per-UC contract-first task specs under docs/tasks/, filling §1/§2/§3/§7 mechanically from the bundle and §5/§6 via LLM-inference + per-UC user confirmation (plan-time gap fill). Plan-only — never runs codegen. Supports --replan to diff a changed bundle against existing task specs. Requires `genesis bundle-parse` (Phase 1.q).
argument-hint: <bundle.json> [--replan]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---
```

### 輸入解析

`$ARGUMENTS` 形式：
| 形式 | 處理 |
|---|---|
| `<bundle.json>` | 全新 plan：對 bundle 內每個 write UC 產 task spec |
| `<bundle.json> --replan` | diff 模式：對比既有 `docs/tasks/*.md` 與新 bundle |
| 空 | exit 1，hint 用法 |

`bundle.json` 路徑不存在 → exit 1。

### Phase 0 — 取得權威 parse 結果（用 Phase 1.q CLI）

**不自己解析 bundle JSON**。呼叫 `genesis bundle-parse <bundle.json>`，拿 stdout 的 canonical FullBundle JSON（Open5=c）。`genesis` binary 不在 PATH → exit 1 hint `run 'genesis install-skills' first or check PATH`。bundle-parse exit != 0 → 把其 stderr 透傳給 user 後 exit（bundle invalid，user 先修 bundle）。

從 parsed JSON 取：`context` / `aggregates[]` / `useCases[]`（含 `useCaseSpecId` / `useCase` / `aggregate` / `input[]` / `emittedEvent` / `eventPayload[]` / `preconditions[]`）/ `aggregates[].invariants[]`。

### Phase 1 — 定位 generated project + 既有 task specs

- task spec 目標目錄 = generated project 的 `docs/tasks/`（D7）。若 cwd 不是 generated project root（無 `.ai/contexts/` 或 `Package.swift`）→ exit 1 hint 指明應在 generated project 內跑。
- 全新 plan：`docs/tasks/` 不存在則 `mkdir -p`。
- `--replan`：讀既有 `docs/tasks/*.md` 的 frontmatter（`useCaseSpecId` / `status`）建立 specId → 既有 spec 的 map。

### Phase 2 — write UC 篩選 + 排序（D2 / D3）

- 篩 write UC：`useCase` lowercased **不**以 `get` / `list` / `find` 開頭（read UC 不產 task spec — 留 read-side path）。
- 排序（D3 sequential）：create UC（prefix `create` / `establish`）排在同 aggregate 的其他 UC 之前。task spec frontmatter 記 `order: N`（1-based）讓 user 知道執行順序。

### Phase 3 — 每 write UC 機械填 §1/§2/§3/§7

對每個 write UC：
- **§1 Goal**：`<verb 中文化(useCase)> <aggregate>，發出 <emittedEvent> event`。
- **§2 Bundle Reference（auto）**：input fields（name + type）/ emittedEvent / eventPayload（name + type）/ `useCaseSpecId` / `aggregateSpecId`（traceability）。
- **§3 Invariants**：從 `aggregates[].invariants[]` 機械填（該 UC 所屬 aggregate 的 invariants，列 name + errorCode + rules）。
- **§7 Cross-aggregate Effects**：從 bundle 結構推（同 emittedEvent 被哪些 ReadModel / 其他 aggregate 訂閱 — 從 readModels[].eventRefs 反查）。

### Phase 4 — §5/§6 LLM 推測 + 逐 UC 確認（method X，D5）

對每個 write UC（**plan 階段批次思考，一次處理完所有 UC 的確認**）：
- **§5 Error Cases**：LLM 依 §3 invariants 推一版 error case 表（每 invariant → 一個 domain error case + 對應 HTTP status；加 `aggregateNotFound` 若非 create UC）。印給 user → user 確認 / 修改 → 寫入。
- **§6 Gherkin Scenarios**：LLM 推 happy path（Scenario Outline + Examples）+ 每個 §5 error 一個 `@error Scenario`。印給 user → 確認 / 修改 → 寫入。
- user 完全沒補某段（直接 enter 跳過）→ 標 `TODO` 不留空白。

確認流程一次走完所有 UC（method X：plan 是 batch 思考時機，不在後續 execute 時零碎打斷）。

### Phase 5 — 寫 task spec MD

每 UC 寫 `docs/tasks/<UpperCamelUseCase>.md`，frontmatter：
```yaml
---
useCase: <Aggregate>.<useCase>
useCaseSpecId: <uuid>           # Open2.1 identity anchor
aggregate: <Aggregate>
sourceBundle: <bundle path>
order: <N>                       # D3 sequential
status: ready                    # ready | needs-update | superseded
created: <YYYY-MM-DD>
runbook:                         # D6: skill input + runbook 雙角色
  - run /usecase <useCase>
  - run /api <useCase>
  - run swift test
---
```
body = §1-§8 contract-first（§4 High-level Goal / §8 Notes 可選）。

**conflict check**：同名 spec 已存在（非 --replan）→ 列出問 user overwrite / skip。

### Phase 6 — `--replan` diff（D4 / Open2）

對比新 bundle 的 write UC（by `useCaseSpecId`，Open2.1）與既有 `docs/tasks/*.md` frontmatter 的 `useCaseSpecId`：

| 情況 | 判定 | 動作 |
|---|---|---|
| **新 UC** | specId 在 bundle 有、既有 spec 無 | append 新 task spec（走 Phase 3-5）|
| **modified UC** | specId 兩邊都有，但 input/emittedEvent/eventPayload 逐欄比對（Open2.2）有差 | 看既有 spec status：`ready`（未 done）→ 重寫該 spec + 保持 ready；非 ready（已被 /pickup 跑過）→ **產 amendment task** `docs/tasks/<UC>-amendment-<date>.md`（列 changed fields）+ 原 spec status 改 `needs-update`（Open2.3）|
| **removed UC** | specId 既有 spec 有、bundle 無 | 原 spec status 改 `superseded`（不刪檔，保留歷史）|
| **unchanged UC** | specId 兩邊都有、逐欄無差 | skip，不動 |

diff 完印 summary（N added / M modified / K removed / unchanged）。

### Framework 備註

- `genesis bundle-parse` 是唯一 bundle 解析入口（Phase 1.q ship）— skill 不自己 parse JSON schema，消除 drift。
- task spec 格式沿用 `write-ddd-spec` 的 8-section 慣例（互通），但本 skill 是 bundle-wide 批次 + method X 確認流程，不呼叫 `write-ddd-spec`（Open3 分流）。
- read UC 不產 task spec（write-side only，與既有 `/api` `/usecase` scope 一致）。

## 改動檔案

### 新增（1 skill + 安裝自動）

| File | Change |
|---|---|
| `Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md` | **新檔** — `/bundle-plan` skill 全文（上述 Phase 0-6）|

`SkillInstaller.bundledSkillNames()` 自動掃 `Templates/skills/` 子目錄 → 加此檔後 `bundle-plan` 自動進安裝名單，**無需改 SkillInstaller / InstallSkillsCommand 邏輯**。

### Test 改動（既有 count assertion 受影響）

| File | Change |
|---|---|
| `Tests/GenesisCoreTests/SkillInstallerTests.swift` | `testBundledSkillNamesReturnsSixSkills` 期望 set 加 `"bundle-plan"`（9 → 10）；`testInstallIntoEmptyDir` count 9 → 10；`testInstallSkipsExisting` count 8 → 9 |
| `Tests/GenesisIntegrationTests/InstallSkillsCommandTests.swift` | `expectedSkills` 視需要加 `bundle-plan`（目前該 array 是子集抽查，非全集 — 確認後決定加不加；若加要確保 install 後該 skill dir 存在）|

## 實作步驟

### Step 1：寫 `bundle-plan/SKILL.md`

1. 建目錄 `Sources/GenesisCore/Resources/Templates/skills/bundle-plan/`。
2. 寫 SKILL.md：frontmatter（name/description/argument-hint/disable-model-invocation/allowed-tools）+ Phase 0-6 完整指示（依介面合約）。
3. 對齊既有 fill-skill 的寫法慣例（exit code 約定、語意錨點、`> Genesis version: {GenesisVersion}` header — 注意此 placeholder 因 raw copyItem 不會被 render，沿用既有 skill 同樣處理即可，不在本 task 修）。

### Step 2：更新 skill count tests

1. `SkillInstallerTests`：3 處 count + name set 更新（+bundle-plan）。
2. `InstallSkillsCommandTests`：若 `expectedSkills` 要加 bundle-plan 則加，並確認 install 後 `bundle-plan/SKILL.md` 存在。

### Step 3：本地 verify

```bash
swift build
swift test    # skill count tests 對齊新數量

# skill 進安裝名單
TMPHOME=$(mktemp -d)
HOME="$TMPHOME" swift run genesis install-skills 2>&1 | grep -q 'bundle-plan'
test -f "$TMPHOME/.claude/skills/bundle-plan/SKILL.md"
rm -rf "$TMPHOME"

# bundle-parse 串接 sanity（skill Phase 0 依賴它）
swift run genesis bundle-parse Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len([u for u in d["useCases"] if not u["useCase"].lower().startswith(("get","list","find"))]), "write UCs")'
```

## 失敗路徑

| 條件 | skill 行為 |
|---|---|
| `$ARGUMENTS` 空 | exit 1 + 用法 hint |
| `bundle.json` 不存在 | exit 1 |
| `genesis` 不在 PATH | exit 1 + hint install-skills / PATH |
| `genesis bundle-parse` exit != 0（bundle invalid）| 透傳 stderr + exit（user 先修 bundle）|
| cwd 非 generated project（無 `.ai/contexts/` / `Package.swift`）| exit 1 + hint 應在 project 內跑 |
| 全新 plan 撞同名既有 spec | 問 user overwrite / skip（非靜默覆蓋）|

## 不改動的部分

### CLI / installer

- `SkillInstaller` / `InstallSkillsCommand` / `CheckSkillsCommand` / `BundleParseCommand` — 不動（bundle-plan 靠既有 install 機制自動納入）。
- `genesis new` — 不動（plan 與 codegen 解耦，D1）。
- `FullBundle` / `BundleParser` — 不動（透過 `genesis bundle-parse` 消費，不直接呼叫）。

### 既有 skill

- `write-ddd-spec` SKILL.md — **不動、不 deprecate**（Open3 分流，互補保留）。
- `/usecase` `/api` `/presenter-fill` `/readmodel-mutation` SKILL.md — 不動（它們是 task spec 的下游 fill skill，本 task 不改其行為）。

### Non-goals（行為層）

- 本 task **不**做 codegen（`/bundle-plan` plan-only，D1）。
- 本 task **不**改 `write-ddd-spec`（Open3 分流保留）。
- 本 task **不**產 read UC 的 task spec（write-side only）。
- 本 task **不**實作 task spec 執行 runner（執行靠 `/pickup` / fill skill；本 skill 只產 spec）。
- 本 task **不**處理 aggregate 大改造 / UC 大規模重構的 replan（D4 範圍：add / modify / remove UC happy path；aggregate state 大改放 Phase 1.r.1）。
- 本 task **不**改 SKILL.md 的 `{GenesisVersion}` placeholder render 機制（既有 raw copyItem 行為，沿用）。

## 已知限制

- **`--replan` modified-UC 判定靠逐欄比對**：input/emittedEvent/eventPayload 改了才算 modified；§5/§6（user 補的業務）的 staleness 不偵測（bundle 沒這資訊）。user 重 review §5/§6 是 amendment task 的責任。
- **UC identity 綁 `useCaseSpecId`**：若 Cosmogony 重新生成 bundle 導致 specId 變（理論上不該，UUID 穩定），replan 會誤判全 removed + 全 added。依賴 Cosmogony specId 穩定性。
- **method X 確認流程 token 成本**：N 個 UC × §5+§6 兩段確認，大 bundle（10+ UC）plan session 會長。這是 D5 拍板的 trade-off（plan-time batch 優於 execute-time 零碎打斷）。
- **read UC 完全不產 task spec**：read-side 開發目前無對應 batch planner（`/presenter-fill` 是 per-UC fill）。未來若要 read-side bundle-plan 另開。
- **不驗 task spec 下游可被 fill skill 正確消費**：本 task 只產 spec；spec 內容是否讓 `/usecase` `/api` 正確 fill 要 Layer 3 dogfood 驗（Human 補做）。

### 依賴關係

- 前置（hard depends_on）：無 hard 阻塞。
- 軟相依（已 done）：phase-1q（`genesis bundle-parse` — 本 skill Phase 0 依賴）。
- 後續（unblocks）：generated project 的 per-feature 開發 workflow（plan → 逐 task /pickup 或 fill skill）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

swift build 2>&1 | tail -3
# 期望: Build complete!

swift test 2>&1 | tail -5
# 期望: 全 pass（含更新後的 skill count tests）

# skill 檔存在 + frontmatter 正確
test -f Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md
grep -q 'name: bundle-plan' Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md
grep -q 'disable-model-invocation: true' Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md
grep -q 'genesis bundle-parse' Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md

# bundledSkillNames 含 bundle-plan（透過既有 installer）
TMPHOME=$(mktemp -d)
HOME="$TMPHOME" swift run genesis install-skills 2>&1 | tail -2
test -f "$TMPHOME/.claude/skills/bundle-plan/SKILL.md"
rm -rf "$TMPHOME"

# skill 涵蓋 4 個收斂決策的關鍵字（語意檢查）
grep -q 'useCaseSpecId' Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md      # Open2.1
grep -q 'needs-update' Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md       # Open2.3
grep -q 'superseded' Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md         # Open2.3 removed
grep -qE 'plan-only|不.*codegen|never.*codegen' Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md  # D1
```

### Human 補做（需要人類介入）

- [ ] 拿真實 Cosmogony bundle（`~/Downloads/Cosmogony IAMContext bundle (2).json`）跑一次 `/bundle-plan`，確認：產出 7 份 write UC task spec（IAM 全 write）、§1/§2/§3/§7 機械填正確、§5/§6 LLM 推測合理、create UC `order:1`。
- [ ] 跑 `/bundle-plan --replan`（改一個 UC input 後），確認 modified UC 偵測正確 + amendment / needs-update 行為符合 Open2.3。
- [ ] 確認產出的 task spec 能被 `/usecase` `/api` 當 input 正確 fill（Layer 3 dogfood）。
- [ ] 確認 `/bundle-plan`（批次）與 `write-ddd-spec`（single-UC manual）並存時 user 不混淆（Open3 分流體感）。
