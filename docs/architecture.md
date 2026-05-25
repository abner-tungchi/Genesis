# Genesis Architecture

This document distills decisions D1–D33 from the source discussions into a single architecture spec for the Genesis CLI. It is forward-looking and implementation-oriented; the discussion logs are the historical record.

**Sources**: `docs/discussions/2026-05-12-*.md` (D1–D14), `docs/discussions/2026-05-13-*.md` (D15–D33).

---

## 1. Mission

Bridge **Cosmogony Event Storming canvas** ↔ **Swift DDD/ES project** in a way that:

- Generates compilable Swift project from bundle JSON (no manual yaml tweaking required)
- Installs Claude Code skills for downstream per-feature development
- Allows optional canvas reverse-sync via Claude Code MCP (not Genesis itself)
- Is portable: works for any Swift DDD project, not just OpportunityContext or IAMContext

## 2. Non-goals

- Genesis is **not** a runtime — it's a developer tool
- Genesis does **not** implement business logic generation — that's per-feature skills (`usecase`, `readmodel`, `/api`)
- Genesis does **not** implement an MCP client — it only writes MCP config that Claude Code uses
- Genesis does **not** orchestrate workflows — no `pipeline status`, no `_index.md`, no skill-name printing (D24)

## 3. Project structure Genesis produces

```
{project-root}/
├── Package.swift                            # SwiftPM, with required deps
├── README.md / CLAUDE.md                    # Boilerplate
├── .ai/
│   ├── conventions/api.md                   # Cross-aggregate API conventions
│   └── contexts/
│       └── {Aggregate}/
│           ├── config.md                    # Aggregate + path configuration
│           ├── commands.md                  # Guards + state transitions (master, D15)
│           ├── invariants.md                # Aggregate invariants (master, D15)
│           ├── errors.md                    # Domain error catalog (master, D17)
│           ├── api.md                       # Transport rules + error→HTTP (master, D17)
│           ├── test-scenarios.md            # Gherkin master (D16)
│           ├── notes/                       # §4/§8 per-UC notes
│           └── reference.md
├── docs/tasks/<UC>.md                       # Per-UC spec, machine-rendered (D15 Option D)
├── projections/
│   └── {Prefix}_Get{ReadModel}Projection.js # KurrentDB projections
├── scripts/
│   ├── start-kurrentdb.sh
│   └── projection.sh
├── Sources/
│   ├── {Shared}/                            # Context-level shared (Phase 1.f infra + Phase 1.b/1.c DTOs)
│   │   ├── ApplicationService.swift         # AS protocol (Phase 1.f)
│   │   ├── ContextError.swift               # generic error wrapper (Phase 1.f)
│   │   ├── Iso8601.swift                    # ISO8601 helpers + parsing error (Phase 1.f)
│   │   ├── InvalidDecimalStringError.swift  # marker error (Phase 1.f)
│   │   ├── ProjectionReadInconsistency.swift # read-side drift signal (Phase 1.f)
│   │   ├── String+IsBlank.swift             # convention helpers (Phase 1.f)
│   │   ├── String+PascalCase.swift
│   │   ├── String+StrippingPrefix.swift
│   │   ├── README.md                        # module charter (Phase 1.f)
│   │   └── <Dto>.swift                      # bundle-driven DTOs (Phase 1.b)
│   ├── {Aggregate}Aggregate/                # One SwiftPM target per aggregate
│   │   ├── event.yaml
│   │   ├── projection-model.yaml
│   │   ├── openapi.yaml + generator config
│   │   ├── {Aggregate}Error.swift
│   │   ├── Entity/
│   │   │   ├── {Aggregate}.swift            # Aggregate root
│   │   │   ├── {Aggregate}+Invariant.swift
│   │   │   └── Commands/{Aggregate}+{UC}.swift
│   │   ├── Usecase/
│   │   │   ├── Port/Out/{Aggregate}Repository.swift
│   │   │   ├── Port/In/{UC}/{Usecase,Input,Output}.swift
│   │   │   ├── Service/{UC}Service.swift
│   │   │   └── Projector/{ReadModel}/...
│   │   └── Adapter/
│   │       ├── ApiHandler.swift
│   │       └── {UC}/{UC}ApplicationService.swift
│   ├── {Context}/                           # Cross-aggregate listeners
│   │   └── Listener/{SourceAggregate}/When{Event}.swift
│   └── {Server}/                            # Optional executable target
└── Tests/
    └── {Context}Tests/...
```

## 4. SSOT discipline (D15–D17)

Single source of truth split by content type:

| Content | Master location | How consumed |
|---|---|---|
| Aggregate invariants | `.ai/contexts/{Ctx}/invariants.md` | `docs/tasks/<UC>.md` §3 transcludes; CI verifies via hash |
| Domain error catalog | `.ai/contexts/{Ctx}/errors.md` | `docs/tasks/<UC>.md` §5 transcludes; **no HTTP status** |
| Transport rules + error→HTTP map | `.ai/contexts/{Ctx}/api.md` | `/api` skill consumes |
| Command guards + state | `.ai/contexts/{Ctx}/commands.md` | `/usecase` skill consumes; `/event-storming` skill writes |
| Gherkin scenarios | `.ai/contexts/{Ctx}/test-scenarios.md` | `docs/tasks/<UC>.md` §6 transcludes |
| Per-UC notes (§4/§8) | `.ai/contexts/{Ctx}/notes/<UC>.md` | `docs/tasks/<UC>.md` transcludes |
| Per-UC spec view | `docs/tasks/<UC>.md` | **100% machine-rendered**, hash-locked, hand-edits forbidden by CI |

**No bidirectional sync**. `docs/tasks/<UC>.md` is a derived view; editing it triggers CI hash mismatch.

## 5. Command surface

### 5.1 Bootstrap commands

#### `genesis new <ContextName>`

Bootstraps a new DDD project. Required input: bundle JSON or `--interactive`.

**Inputs**:
- `--from-bundle <path>` — Cosmogony Event Storming export
- `--interactive` — Q&A wizard fallback
- `--config <sidecar.yaml>` — override defaults (prefix, etc.)
- `--with-mcp <mcp-config.json>` — opt-in: also run install-mcp
- `--no-git` — skip git pre-flight (for CI / sandbox)

**Output**:
- Full project structure as above
- `.scaffold-manifest.json` recording generation provenance
- Empty `.ai/contexts/<Aggregate>/` business document skeletons
- Optional `~/.claude/skills/` installation if not present
- Optional `~/.claude/mcp-config.json` if `--with-mcp`

#### `genesis install-skills [--scope user|project]`

Copies skill bundles to `~/.claude/skills/` (default user-global) or `<project>/.claude/skills/`.

**Skills installed**:
- `event-storming` (modified for auto-discovery, D21)
- `write-ddd-spec` (modified for --all/--resume + GENERATED blocks, D15)
- `usecase`
- `readmodel`
- `/api` (new, capped 200 LoC, D18)
- `strict-review`
- `test-review-commit`, `reset-projection` (when promoted, D20)

#### `genesis install-mcp [--config <path>]`

Writes `~/.claude/mcp-config.json` so Claude Code can reach Cosmogony's MCP server.

**Inputs**: MCP config JSON (Claude Code standard format) or interactive prompt for Cosmogony connection details.

### 5.2 In-project maintenance commands

#### `genesis diff`

Read-only drift detection between bundle.json, `.ai/contexts/`, and Sources/. Bidirectional.

**Output sections**:
- `[SAFE TO AUTO-APPLY]` — new use cases / aggregates → can `apply --only-new`
- `[NEEDS HUMAN]` — renames, deletions, ambiguous changes
- `[STALE]` — manifest hash mismatch, orphan files
- `[CODE-AHEAD]` — code has things bundle doesn't (reverse drift)

**Exit codes**: 0 = clean, 1 = drift, 2 = error. CI-friendly.

#### `genesis apply --only-new [--dry-run]`

Adds new files for use cases / aggregates that exist in bundle but not in code.

**Hard rules**:
- Never modifies existing files
- Pre-flight: `git rev-parse --is-inside-work-tree` + `git status --porcelain` clean
- Overlap check: aborts if files to write overlap with `git diff --name-only HEAD`
- On build failure: `git checkout` + `git clean -fd` rollback affected paths
- `--no-git` escape hatch for CI / sandbox

#### `genesis adapter`

Reads bundle.json + existing `swift-adapter.yaml`. Proposes additions for unmapped types.

**Output**: `.ai/contexts/{Ctx}/swift-adapter.proposed.yaml`. User merges via `git diff` (D9).

**LLM judgment**: 2-layer guard (D14)
1. Only emit types from limited categories (primitive/container/customType/identifier/enum)
2. Semantic sanity check (reject `EmployeeStatus → Set<Int>` type mismatches)

### 5.3 Canvas commands

#### `genesis plan-canvas-sync`

**Pure file diff, no MCP** (per Gemini Option D, R3).

Reads code structure (`Sources/`, `.ai/contexts/`) and `bundle.json`. Produces:

`.swift-ddd/canvas-ops/<timestamp>.proposed.json`

Contains:
- `base_board_hash` (from bundle.json, the last-known canvas state)
- Operations list with `entityId + expected_pre_image` (anti-ABA, D30)
- Each op categorized: 🟢 ADD / 🟡 UPDATE / 🟡 RENAME / 🔴 REMOVE
- `es_clear_board` **never** emitted (D26)

User reviews via `git diff`, commits the file. Apply phase is Claude Code skill, not Genesis.

#### `genesis verify-canvas`

Pure file diff variant of `plan-canvas-sync` — produces report only, no `.proposed.json`. CI-friendly with exit codes.

## 6. Manifest schemas

### 6.1 `.scaffold-manifest.json` (D5)

Lives in `.ai/contexts/{Context}/`. Git-committed. ~10 lines per generated file:

```json
{
  "manifestVersion": 1,
  "bundleId": "<from bundle.json>",
  "templateVersion": "<Genesis version>",
  "exportedAt": "<bundle export timestamp>",
  "generatedFiles": [
    { "path": "Sources/.../Foo.swift", "sha256": "abc...", "role": "aggregate" }
  ]
}
```

### 6.2 `swift-adapter.yaml` (D6)

Lives in `.ai/contexts/{Context}/`. Hand-authored or proposed by `genesis adapter`:

```yaml
adapterVersion: 1
schemaVersion: 1
contextName: IAMContext
bundleId: <matches bundle.manifestVersion>
templateVersion: ">=2.3.0"
swiftToolsVersion: "5.9"

typeMapping:
  PermissionSet: "Set<String>"
  "Array[String]": "[String]"
  "Set[String]": "Set<String>"

customTypes:
  - { name: EmailAddress, kind: valueObject, underlying: String }
  - { name: EmployeeStatus, kind: enum, cases: [active, suspended] }
  - { name: UserId, kind: identifier, underlying: UUID }

createdEventPolicy:
  required: true
  namingPattern: "{Aggregate}Created"
  payloadFromState: true

payloadConventions:
  inputSuffix: Input
  outputSuffix: Output
  eventPayloadSuffix: Payload

aggregateSplit:
  strategy: byBoundedContext
  rootMap:
    UserAccessProfile: Sources/IAMContext/UserAccessProfile

idStrategy:
  kind: typedStruct
  wrapper: "{Aggregate}ID"

testingConventions:
  framework: swiftTesting
  fixturesPath: Tests/{Context}Tests/Fixtures

imports:
  "**/Usecase.swift":
    - Foundation

skip:
  usecases: ["LegacyGrantPrivilege"]
```

### 6.3 Renames manifest (D8)

Lives in **Genesis repo's templates directory** (not in user's project). When Genesis ships a new template version that renames a generated file, the rename map ensures `apply` produces a migration patch rather than `removed + added`:

```yaml
# templates/<version>/renames.yaml
renames:
  - { from: "OldEventName.swift", to: "NewEventName.swift", since: "0.4.0" }
```

## 7. Transaction safety (D7, D27)

`new` and `apply` follow this protocol:

```
1. git rev-parse --is-inside-work-tree     → fail if not git repo (unless --no-git)
2. git status --porcelain <output-path>    → fail if uncommitted changes
3. git diff --name-only HEAD               → fail if overlap with files-to-write
4. git stash push -u -m "pre-genesis-<id>" → stash working tree
5. write files + update manifest atomically
6. swift build                              → validate compile
7. if fail: git checkout -- <written> && git clean -fd <new> → rollback
8. git stash pop
```

**No typed confirms** (D27). Safety budget invested in backup, not prevention rituals.

For canvas operations: `plan-canvas-sync` first captures `es_get_board` snapshot to `.swift-ddd/canvas-backups/<ts>.json` (when skill runs `apply-canvas-ops`). Mandatory because Cosmogony is pure hard delete with no history (D32).

## 8. MCP boundary (D29, D31 revised)

Genesis itself does **not** call MCP. The split:

| Component | Does it touch MCP? |
|---|---|
| `genesis install-mcp` | Writes `~/.claude/mcp-config.json`, no MCP traffic |
| `genesis plan-canvas-sync` | Reads files only, no MCP |
| `genesis verify-canvas` | Reads files only, no MCP |
| `genesis apply-canvas-ops` | **Does not exist as Genesis subcommand** |
| Claude Code skill `apply-canvas` | Reads `.proposed-canvas-ops.json` and executes via MCP through Claude Code's channel |

**Rationale**: an MCP server like Cosmogony's exposes tools to Claude Code agents via stdio/SSE. A standalone Swift CLI would need its own MCP client implementation to talk to it, which doubles surface area for marginal benefit. Letting Claude Code's skill do the actual MCP call keeps responsibilities clean.

> This revises the earlier D31 ("sync is CLI not skill") under the Genesis framing: `plan` stays in CLI (no MCP), `apply` moves to skill (uses MCP).

## 9. Skill installation model

### 9.1 Storage

Default: `~/.claude/skills/` (user-global).

Override: `--scope project` writes to `<project>/.claude/skills/` for per-project versions.

### 9.2 Source

Skills bundled with Genesis (in `Templates/skills/` directory of Genesis repo, under `Sources/GenesisCore/Resources/`). Versioned with Genesis itself — no separate skill repo. `genesis install-skills` enumerates the bundled skill directories dynamically (each valid skill is a non-symlink directory containing `SKILL.md`), so adding a new skill needs only a new directory, no code change.

### 9.2a Reporting (Phase 1.d ratification of D24)

`genesis install-skills` prints which skills were `installed` / `skipped` / `overwritten` (and `failed`, if any) to stdout, including their names. This does **not** violate D24 — D24's "CLI never prints skill names" applies to the `genesis new` bootstrap flow, not to the skill-management command itself, where the user needs to know what was installed.

### 9.3 Update

`genesis update-skills` re-copies the bundled versions, preserving any user customizations (TBD: detection mechanism). **Not implemented in Phase 1.d** — Phase 1.d ships `install-skills` only; `--force` is the blunt re-install path until `update-skills` lands.

## 10. Versioning

Single SemVer line:

```
Genesis 0.3.1
├── templates v0.3.1     (bundled)
├── skill bundles v0.3.1 (bundled)
├── adapter schema v1    (independent, advances slower)
└── manifest schema v1   (independent, advances slower)
```

Adapter schema and manifest schema versions are independent because they represent on-disk artifact contracts; Genesis can read older versions for backward compat.

### 10.1 DDDKit dependency anchor (Phase 0 Q1 revised, `dddkit-correction`)

Genesis-produced `Package.swift` pins the DDDKit kit to:

- **URL**: `https://github.com/gradyzhuo/swift-ddd-kit.git`
- **Version**: `from: "0.3.0"` (Genesis policy = OC `Package.resolved` current; OC manifest 下界 = `from: "0.1.0"`)
- **Package identity**: `swift-ddd-kit` (URL 末段；用於 `.product(name: "DDDKit", package: "swift-ddd-kit")` 與 `.plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit")`)
- **Platforms**: `[.macOS(.v15)]` only — kit 宣告 `.iOS(.v18)` 下界，SwiftPM 不允許消費端低於依賴；OC ground truth 為 macOS-only，且 transitive 依賴（`swift-kurrentdb` + gRPC + NIO）偏 server-side。日後若需 iOS target，須一併確認 transitive 依賴在 iOS 的可用性。

Repository 形狀（對齊 gradyzhuo `Repository: Sendable` + OC `AuditQuotingRepository` ground truth）：

- `package struct {Aggregate}Repository: EventSourcingRepository` — **`struct`** 而非 `final class`（gradyzhuo `Repository: Sendable`，非 `: AnyObject`）
- `package typealias StorageCoordinator = KurrentStorageCoordinator<{Aggregate}>` — **`KurrentStorageCoordinator`** 而非 `ESDBStorageCoordinator`；位於 `KurrentSupport` target，由 `DDDKit` re-export
- `package let coordinator: StorageCoordinator` — 不可變（struct + Repository 協議只要求 getter）
- **路徑**：`Sources/{Aggregate}Aggregate/Usecase/Port/Out/{Aggregate}Repository.swift`（Phase 1.e migration；Phase 1.b 原本放 `Adapter/`，與 OC `AuditQuotingRepository` ground truth 對齊後移到 `Usecase/Port/Out/`）

**歷史脈絡**：Phase 0 Q1 原鎖定 `Mendesky/DDDKit` 1.12.4 是讀錯 fork。`dddkit-correction` task（spec：`docs/tasks/dddkit-correction.md`）於 2026-05-14 修訂。Phase 1.a / Phase 1.b spec 視為歷史紀錄，保留 superseded banner + inline ⚠️ 修訂標記；正確值以本節為準。Aggregate 結構對齊 gradyzhuo `AggregateRoot`（含 `init(id:, ...payload) throws`、`init?(first:other:)` 委派、`{A}+Delete.swift` 等）由 `phase-1e-aggregate-alignment` 處理，見 §10.2。`{Ctx}Shared/` 基礎 infra 由 `phase-1f-context-shared-infra` 自動 bootstrap，見 §10.3。

### 10.2 ModelGeneratorPlugin + `{A}AggregateProtocol`（Phase 1.e）

`gradyzhuo/swift-ddd-kit` 0.3.0 的 build-tool plugin `ModelGeneratorPlugin` 會從 `projection-model.yaml` + `event.yaml` + `event-generator-config.yaml` 三個檔案產出 `generated-projection-model.swift`，其中關鍵產物是 **`{Aggregate}AggregateProtocol`**：

```swift
package protocol {Aggregate}AggregateProtocol: AggregateRoot
    where ID == String, DeletedEventType == {Aggregate}Deleted {
    init?(first createdEvent: {CreatedEventType}, other events: [any DomainEvent]) throws
    func when(event: {NonCreatedEvent_1}) throws
    // ...
    func when(event: {Aggregate}Deleted) throws
}
```

加上 default extension 提供 `init?(events:)` 與 `when(happened:)` — Genesis 產出的 aggregate **不可手寫**這兩個方法（會與 plugin default 衝突）。

**Genesis 對齊細節**：

- Aggregate target plugins list 含 `ModelGeneratorPlugin`（Phase 1.e 加入 `PackageTarget.swift.template`）
- `projection-model.yaml` 必存在（plugin 強制）；Genesis 從 `bundle.readModels[]` 萃取 entries 並 scope to 該 aggregate（per `aggregateSpecId` + event filter by `aggregateEventNames`）；空 readModels fallback `Get{A}Existence` entry 確保 plugin 有東西可吃
- Aggregate conform `{A}AggregateProtocol`（**非**直接 conform `AggregateRoot`）
- `Entity/Commands/{A}+Delete.swift` 自動生成，含 `func when(event: {A}Deleted) throws { self.metadata.delete() }`（plugin requires it on protocol）
- `category` static override：`"{Prefix}\(Self.self)"` where `Prefix = contextName.filter { $0.isUppercase }`（IAMContext → `IAMC`、OpportunityContext → `OC`、QuotationContext → `QC`）— 防多 context cluster KurrentDB stream 碰撞

**typedStruct ID deprecation**（Phase 1.e）：`Entity where ID == String` 強制 ID == String，使 Phase 1.c 的 `idStrategy.typedStruct` 結構性不相容。Phase 1.e 對 typedStruct adapter → emit stderr warning + fallback to direct（id 永遠 `String`）；Yaml schema 保留向後相容，但生成路徑廢棄。詳見 `docs/tasks/phase-1e-aggregate-alignment.md` 與 `docs/decisions.md` Phase 1.e ratification 條目。

### 10.3 ContextShared infra bootstrap（Phase 1.f）

Genesis Phase 1.f 在每個產出專案的 `Sources/{Ctx}Shared/` 自動 bootstrap 9 個基礎 infra 檔（不論 bundle 有無 DTO 或 customType — `needsShared` 改 always true）：

| File | Role |
|---|---|
| `ApplicationService.swift` | `package protocol ApplicationService { associatedtype Input; associatedtype Output; func execute(...) }` |
| `ContextError.swift` | `package struct ContextError<E: Error & Equatable>` generic wrapper + `Source` enum |
| `Iso8601.swift` | `Iso8601ParsingError` + `Date.parseIso8601(_:timeZone:)` helpers（timezone 預設 `.gmt`） |
| `InvalidDecimalStringError.swift` | Marker error for Decimal-from-String parsing |
| `ProjectionReadInconsistency.swift` | Read-side projection drift signal（ApiHandler maps to HTTP 503） |
| `String+IsBlank.swift` | `String.isBlank`（含 CJK 全形空格） |
| `String+PascalCase.swift` | `String.pascalCase` |
| `String+StrippingPrefix.swift` | `String.strippingPrefix(_:)` |
| `README.md` | Genesis-authored module charter（含 add-type 3 yes/no 判準） |

8 個 Swift 檔皆 `package` access modifier；template source 來自 OC `OCShared/` CORE/CONVENTION 分類（per Gemini facts report 2026-05-18）。**全部 verbatim** 除 `Iso8601.swift` 移除 OC 的 `TimeZoneConstants.taipei` + `Calendar.taipei`（Taiwan-conventional），改 `.gmt` 為預設 timezone。

**Skip list**（OC-SPECIFIC，Genesis 不 bootstrap）：`AggregateRootNames`、`OCEmbeddedImageMarkdownExtractor`、`OrganizationType`、`QuotingBundleType*`、`AccountingTypeDto`、`ConfigKeyDto/ConfigValueDto`、`ServiceItemConfigDto`、`ServiceItemTypeDto`、`WorkItemTypeDto`、`PricingDto*`、`DtoConversionError`、`FileType*`。

**用途**：per-feature skills（`/api` / `/usecase` / `/readmodel`）可依賴此 infra 存在，產 ApplicationService、ApiHandler、Projector 等 code 時不需重寫基礎 types。詳見 `docs/tasks/phase-1f-context-shared-infra.md` 與 `docs/decisions.md` Phase 1.f ratification 條目。

### 10.4 ReadModel skill flow（Phase 2 — /readmodel skill v1）

Genesis Phase 2 ship `/readmodel` 作為第一個 per-feature design-time skill。Skill 位於 `Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md`（259 lines），透過 Phase 1.d 的 `genesis install-skills` pipeline 安裝到 target project 的 `.claude/skills/readmodel/SKILL.md`。

**Lifecycle / Scope**：
- 跑在 Genesis-bootstrapped project 內（user 已先 `genesis new`）
- Design-phase tool：讀 bundle JSON + 互動式收集 + 寫 readModels[] 新 entry
- 不直接生 Swift / JS / YAML — 那是 Phase 1.g `ReadModelRenderer` 的工作（待開）

**6-step interactive flow**：
1. Locate bundle — `$ARGUMENTS[0]` 或 cwd 找 `*-bundle.json`
2. Choose aggregate — `AskUserQuestion` single-select（含字面值 `<context-level>`）
3. Choose events — `AskUserQuestion` multiSelect:true
4. Name — Get prefix + PascalCase noun；衝突走 overwrite/rename/abort
5. Key field selection — `intersection of payload field names across selected events`；single-select；含 keyType (String/UUID/Int/Int64) 與 local `keyField` rename
6. Stored fields — multiSelect from payload union (minus key)

**bundle.readModels[] schema (revised)**：
```json
{
  "name": "GetX",
  "aggregateRef": "AuditQuoting | <context-level>",
  "key": {"field": "auditQuotingId", "type": "String", "fromEventPayload": "quotingId"},
  "storedFields": [{"name": "...", "type": "...", "default": null}],
  "events": [{"name": "...", "sourceAggregate": "..."}],
  "comment": null
}
```

`readModelSpecId` 改 optional（auto-derived as `rm-{name}`）；舊 `eventNames` 仍由 BundleParser 從新 `events[].name` 派生以維持向後相容。

**Event payload resolver**（`ReadModelBundleAppender.resolvePayload`）：
- Pass-1: aggregate.events[].payload（未來 schema 擴充）
- Pass-2: useCases[].emittedEvent join → eventPayload[]
- Pass-3: empty fallback（skill 走 manual-entry path with warning）

**streamPrefix resolution precedence**：
1. `<bundle>.adapter.yaml` `streamPrefix` override
2. `bundle.context.streamPrefix`（若 context 為 object）
3. Deterministic fallback：strip "Context" 後 alias map（`Opportunity → OC`），else upper-snake `IAMContext → IAM_`

**Implementation**：
- `Sources/GenesisCore/FullBundle.swift`：新增 `ReadModelKey` / `ReadModelStoredField` / `ReadModelEventRef` types；extends `ReadModelSpec`
- `Sources/GenesisCore/BundleParser.swift`：`RawReadModel.events` 三種 schema 都支援
- `Sources/GenesisCore/ReadModelBundleAppender.swift`：transform fn + 9 個 validation paths + `resolvePayload`
- `Tests/GenesisCoreTests/ReadModelBundleAppenderTests.swift`：15 tests (happy + 9 validation + cross-aggregate + 3 resolvePayload)

詳見 `docs/tasks/2026-05-18-readmodel-skill.md` 與 `docs/decisions.md` /readmodel skill v1 ratification 條目。

**未來銜接**：
- Phase 1.g `ReadModelRenderer` — 從 bundle.readModels[] 產 ReadModel.swift / Presenter.swift / projection-model.yaml entry / OC_*Projection.js（Presenter `when()` 空 body with TODO）
- `/presenter` skill — design ApplicationService 轉換（sibling skill；依賴此 readmodel schema）
- `/readmodel-mutation` skill (v2 candidate) — 收集 per-event mutation 邏輯自動填 Presenter `when()`



### 10.5 ReadModel codegen flow（Phase 1.g — per-aggregate v1）

Phase 1.g 加 `ReadModelRenderer` 處理 `bundle.readModels[]` 的 codegen 路徑，補完 /readmodel skill 的 design-side 之後的機械翻譯。

**Per-aggregate v1 scope**（cross-aggregate defer Phase 1.g.2）：

對每個 `aggregateRef = "<aggregate name>"` 的 readmodel entry，產 3 個 OC-canonical files：

```
Sources/{Aggregate}Aggregate/Usecase/Projector/Get{Noun}/
├── {Noun}ReadModel.swift         # package class : ReadModel (backing key field 宣告 audit H1)
└── Get{Noun}Presenter.swift      # package struct : Get{Noun}ProjectorProtocol
                                  # empty when() body + TODO, scaffold-once (audit H6)

projections/
└── {ProjectionStreamPrefix}Get{Noun}Projection.js  # KurrentDB linkTo projection script
```

+ 既有 `Sources/{Aggregate}Aggregate/projection-model.yaml` 加入 `Get{Noun}:` entry（events 走 normalized UpperCamel — Phase 1.g 修了 lower-camel 在 yaml 內被 filter 掉的 bug）

**Two stream prefix concepts (audit M1)**：
- `ProjectionStreamPrefix`（with trailing `_`，e.g. `IAM_`, `OC_`）: KurrentDB linkTo target stream + Presenter categoryRule
- `SourceCategoryPrefix`（without `_`，e.g. `IAM`, `OC`）: JS `fromStreams(["$ce-..."])` source category

**Stream prefix resolution**：
1. strip `"Context"` suffix from contextName
2. alias map (`Opportunity → OC`, v1 hardcode)
3. fallback upper-snake via `CaseTransformer.upperSnake` (`IAMContext → IAM_`, `MyApp → MY_APP_`)
4. `Context` alone → throw

**Scaffold-once（audit H6）**：NewCommand 跑前掃 `outputDir` 找 existing `Sources/*/Usecase/Projector/*/Get*Presenter.swift`，pass 給 ReadModelRenderer 的 `existingPresenterPaths` set；renderer 跳過已存在的 Presenter 路徑（**保留 user 手填的 mutation logic**）。ReadModel.swift / JS file 仍每次重 generate（不該被 hand-edit）。

**Schema strict validation**：
- `entry.key` nil → throw
- `entry.eventRefs` empty 或缺 sourceAggregate → throw
- `aggregateRef == "<context-level>"` → throw with Phase 1.g.2 hint
- `aggregateRef` not in bundle.aggregates[] → throw

**storedFields default heuristic（audit M3）**：
- `T?` / `Optional<T>` → `nil`
- `[T]` / `Array<T>` → `[]`
- `[K: V]` / `Dictionary<K,V>` → `[:]`
- `Set<T>` → `Set()`
- explicit `default` → 直接 substitute
- non-optional non-collection 無 default → throw actionable error

**Plugin compile invariant**：
- 此 renderer 不檢查 plugin output
- 信任：projection-model.yaml events + Presenter when() methods + plugin protocol 都從同一 bundle entry 推導（normalized event names 三處共用 → consistent）
- 真 e2e build 驗證：`/tmp/phase1g-e2e` 2408 targets compile pass in 46.97s

詳見 `docs/tasks/phase-1g-readmodel-renderer.md` 與 `docs/decisions.md` Phase 1.g ratification 條目。

**未來銜接**：
- **Phase 1.g.2**: cross-aggregate codegen — 新 `{Context}` SwiftPM target + plugin + event.yaml + multi-aggregate imports（OC `OpportunityContext` target pattern）
- **Phase 1.h**: Adapter `streamPrefix` override + extensible alias map
- **`/readmodel-mutation` skill (v2)**: 自動收集 per-event mutation 邏輯填 Presenter when() body


### 10.6 Cross-aggregate ReadModel codegen（Phase 1.g.2）

Phase 1.g.2 解除 Phase 1.g 對 `aggregateRef = "<context-level>"` 的 reject，補完跨 aggregate codegen 路徑。

**Conditional `{Context}` SwiftPM target**: 當且僅當 bundle 有任何 context-level readmodel 時，`PackageRenderer` emit 新 `{Context}` target：

```swift
.target(name: "{ContextName}",
        dependencies: [
            .target(name: "<UniqueSourceAggregate1>Aggregate"),
            .target(name: "<UniqueSourceAggregate2>Aggregate"),
            ...,
            .target(name: "{ContextName}Shared"),
            .product(name: "DDDKit", package: "swift-ddd-kit"),
        ],
        resources: [
            .process("event.yaml"),
            .process("projection-model.yaml"),
            .process("event-generator-config.yaml"),
        ],
        plugins: [
            .plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit"),
        ]),
```

加 product `.library(name: "{ContextName}", targets: ["{ContextName}"])`。

**Deps = unique sourceAggregate set sorted alphabetically** (per audit M1+M2)，match OC pattern 不列全 aggregate。

**3 個 context-level resource files** (`ContextProjectionModelRenderer`)：

```
Sources/{ContextName}/
├── event.yaml                       # {} (context target 不發 events)
├── projection-model.yaml            # 所有 cross-agg entries (normalized UpperCamel)
└── event-generator-config.yaml      # dependencies list (sorted + unique + Shared)
```

`event-generator-config.yaml`:

```yaml
accessModifier: package
dependencies:
  - <Agg1>Aggregate
  - <Agg2>Aggregate
  - {ContextName}Shared
```

**Swift files dispatch**: ReadModelRenderer 根據 `aggregateRef` 走不同 path：

- per-aggregate → `Sources/{Agg}Aggregate/Usecase/Projector/Get{Noun}/`
- context-level → `Sources/{ContextName}/Projector/Get{Noun}/` 加 `import {Agg}Aggregate` per unique sourceAggregate

**Presenter template** 加 `{AggregateImports}` placeholder：per-aggregate 為空字串，context-level 為 sorted-alphabetical multi-line imports (audit M2+M3 determinism)。

**Scaffold-once 擴 context dir**: `NewCommand.scanExistingPresenterPaths` 同時掃 per-aggregate 跟 `Sources/{Context}/Projector/Get*/Get*Presenter.swift`，避免 regenerate 洗掉 user 手填 mutation (audit H1)。

**Real e2e 驗證**: 對含 2 aggregates + 1 cross-agg readmodel 的 IAM-like bundle，`swift build` 跑通 (`/tmp/phase1g2-e2e` 2444 targets, 50.78s)。

詳見 `docs/tasks/phase-1g2-cross-aggregate-codegen.md` 與 `docs/decisions.md` Phase 1.g.2 ratification 條目。

**未來銜接 (defer)**：
- Phase 1.h: adapter `streamPrefix` override + extensible alias map
- Context target OpenAPIGenerator + openapi.yaml + openapi-generator-config.yaml (context-level HTTP handlers)


### 10.7 ApplicationService scaffold + DTO mapper codegen（Phase 1.h，narrow v2）

Phase 1.h 加 `ApiRenderer` 作為 codegen 框架，對 bundle 內 write UC + bundle.dtos[] 產 Adapter 層 scaffold；body 由後續 `/api` skill (revise) 填。

**Scope narrow per Codex audit**: 只 emit `ApplicationService.swift` + DTO mapper；ApiHandler / ApiComponents / openapi.yaml / OpenAPIGenerator plugin 擴展 defer Phase 1.i（避免 user 環境缺 OpenAPIGenerator 時 build fail）。

**輸出**:

```
Sources/<A>Aggregate/Adapter/<UC>/
└── <UC>ApplicationService.swift                # Variant A simple, operatorId LAST per OC

Sources/<A>Aggregate/Adapter/Dto/
└── <X>Dto+Domain.swift                          # enum: full mapper; struct: scaffold + TODO

Sources/{Ctx}Shared/                              # 仅當 isContextShared=true 或 legacy default
└── <X>Dto.swift                                  # bare type, no mapper (per OCShared §5.5)
```

**Pure function of bundle** (audit H2 fix)：
- Service Input fields = `useCase.input` (filter operatorId + ID)
- AGG_ID_NAME = `aggregate.identityName` (not parsed from event.yaml)
- DTO enum cases = `dto.cases[]`
- Type resolution via `SwiftTypeResolver` (`Array[String]` → `[String]`)

**bundle.dtos[] schema extension**:

```json
{
  "dtoSpecId": "...",
  "name": "AccountingTypeDto",
  "dtoKind": "enum",                     // NEW: "enum" | "struct" | "union" (legacy nil → description-based)
  "cases": ["foo", "bar"],               // NEW: enum cases
  "domainTypeName": "AccountingType",    // NEW: default strip "Dto" suffix
  "isContextShared": false               // NEW: false → per-aggregate Adapter/Dto/; true → {Ctx}Shared
}
```

**Backwards-compat heuristic** (audit M3+M4 兼容): 純 legacy DTO (無 Phase 1.h fields) → BundleParser 設 `isContextShared=true` 維持既有 SharedTargetRenderer 行為。

**Scaffold-once**: NewCommand 掃 `Sources/<A>Aggregate/Adapter/*/` + `Adapter/Dto/*+Domain.swift` existing paths → skip emit。AI 填過的 execute() body 不被覆寫。

**TODO marker format**: 統一 `fatalError("TODO(/api skill): ...")` — type-erased Never 滿足任意 return type，build pass 但 runtime trap (forces /api skill 填)。

**未來 Phase 1.i 補完**:
- openapi.yaml stub + openapi-generator-config.yaml emission
- PackageRenderer OpenAPIGenerator plugin + swift-openapi-* runtime deps
- ApiHandler.swift scaffold (catch ladder framework + per-UC method)
- ApiComponents+Error.swift scaffold (exhaustive switch over <A>Error)

**v2 候選**:
- Variant B `init(from payload:)` (audit H1 deferred — 需 openapi schema parsing)
- Multipart upload, read UCs, union DTO, cross-agg mapToApiError multi-branch
- DTO per-aggregate explicit assignment (v1 假設第一 aggregate)
- Mapper name divergence (1:1 假設)

詳見 `docs/tasks/phase-1h-api-renderer.md` 與 `docs/decisions.md` Phase 1.h ratification 條目。


### 10.8 OpenAPI infrastructure + ApiHandler scaffold（Phase 1.i，Variant A v1）

Phase 1.i 補完 Phase 1.h 縮 scope 時 defer 的 OpenAPI 基建——對每含 write UC 的 aggregate 自動產：

```
Sources/<A>Aggregate/
├── openapi.yaml                                       # NEW (1.i)
├── openapi-generator-config.yaml                      # NEW (1.i)
└── Adapter/
    ├── ApiHandler.swift                               # NEW (1.i, per-aggregate)
    └── ApiComponents/
        └── ApiComponents+<A>ApiError.swift            # NEW (1.i, per-aggregate)
```

**`<A>ApiError` 命名修正 (Gemini facts §1)**: per-aggregate (e.g. `UserAccessProfileApiError`)，不是 `<Ctx>ApiError`。

**2 new renderers**:
- `OpenApiYamlRenderer.swift`: per write-UC aggregate emit openapi.yaml + config (pure function of bundle)
- `ApiHandlerRenderer.swift`: per write-UC aggregate emit ApiHandler + ApiComponents

**PackageRenderer 擴**:
- Top-level deps 條件式 +2 (`swift-openapi-generator`, `swift-openapi-runtime`) when any aggregate has write UCs
- Per-aggregate target 條件式 +1 dep (`OpenAPIRuntime`) + 2 resources (openapi.yaml + openapi-generator-config.yaml) + 1 plugin (`OpenAPIGenerator`)
- 純 read-only aggregate 不加 OpenAPI (避免 orphan resources)

**openapi.yaml v1 結構**:

```yaml
openapi: 3.1.0
info: {title, version}
paths:
  /<kebab-A>/{<aggIdName>}/<kebab-uc>:
    post:                                # v1 simplification, all POST
      operationId: <ucCamel>
      parameters: [$ref aggIdName, $ref operatorId]
      requestBody:
        application/json:
          schema: $ref <UC>Request
      responses:
        '200': $ref <A>Id
        '404': $ref NotFoundError
        '422': $ref UnprocessableEntityError
        '503': $ref ServiceUnavailableError
components:
  parameters: { <aggIdName>: in path, operatorId: in header }
  responses: { NotFoundError, UnprocessableEntityError, ServiceUnavailableError }
  schemas:
    <A>Id: { type: object, properties: { <aggIdName>: string } }
    <A>ApiError:
      type: string
      enum:
        - aggregateNotFound       # infra
        - invalidPayload          # infra
        - invalidDateFormat       # infra
        - undefinedDomainError    # infra
        - serviceUnavailable      # infra
        - <domain cases...>       # from bundle.invariants[].errorCode
    <UC>Request: { type: object, required: [...], properties: { ...inline... } }
```

**ApiHandler scaffold (Variant A v1)**:
- struct ApiHandler: APIProtocol（no `<Storage>` generic）
- kdbClient init + repository computed var + mapToApiError
- per write UC method: catch ladder framework + `// TODO(/api skill)` body for AS Input construction (用 fatalError closure 滿足 type)

**ApiComponents+<A>ApiError.swift scaffold**:
- `init(from: ContextError<<A>Error>)` non-failable wrapper, falls back to `.undefinedDomainError`
- `init?(from: <A>Error)` exhaustive switch, 1:1 case names from bundle.invariants[].errorCode
- Empty invariants → `default: return nil`（滿足 Swift exhaustive switch over non-empty enum）

**Scaffold-once extension**: NewCommand `scanExistingApiPaths` 擴 4 新 paths — existing scaffolds 不 overwrite（AI 填過的 body 保留）。

**Plugin invariant 驗證**: real e2e build mandatory acceptance gate（plugin 真生 `Operations.X.*` + ApiHandler conform compile 通過）。

**v2 候選**: Variant B (`init(from payload:)`)、multipart、read UCs、cross-agg mapToApiError、Server target Hummingbird、API↔domain ID rename、semantic HTTP method routing、DecimalAmount $ref。

詳見 `docs/tasks/phase-1i-api-handler.md` 與 `docs/decisions.md` Phase 1.i ratification 條目。


### 10.9 /presenter skill flow（read-side AS design）

Genesis ship `/presenter` 作為第二個 design-time skill (mirror /readmodel pattern)。Skill 在 Genesis-bootstrapped project 內 design read-side ApplicationService 形狀，append `bundle.presenters[]`，由未來 Phase 1.k renderer 消費。

**Skill 5-step flow**:
1. Locate bundle + validate readModels[] non-empty
2. Choose readmodel (`AskUserQuestion` single-select; from bundle.readModels[].name)
3. Name presenter (default = readmodel.name; regex `^Get[A-Z][A-Za-z0-9]+$`)
4. Choose output kind (`AskUserQuestion`: `array` / `single` / `scalar`)
5. Configure output details (elementType + elementSource + isOptional + inputFields)

**bundle.presenters[] schema**:

```json
{
  "presenterSpecId": "p-<name>",
  "name": "Get<Noun>",
  "readModelRef": "<readmodel name>",        // must exist in bundle.readModels[]
  "aggregateRef": "<inherited from readmodel>",
  "input": { "fields": [...] },
  "output": {
    "kind": "array | single | scalar",
    "elementType": "<DTO or Swift type>",
    "elementSource": "<readModel field name>",
    "isOptional": false
  },
  "endpoint": {
    "path": "/<kebab-A>/{<aggIdName>}/<kebab-stripGet>",  // default
    "method": "GET"
  },
  "comment": null
}
```

**Backwards-compat**: existing fixtures without `presenters: []` → BundleParser defaults to empty array. No migration needed.

**PresenterBundleAppender**: pure function of bundle with 6 validation paths (name regex / output kind / elementType / elementSource / input fields validation / readModelRef existence)。

**Defer Phase 1.k**: codegen renderer 消費 bundle.presenters[] → emit:
- `Sources/<A>Aggregate/Adapter/Get<X>/Get<X>ApplicationService.swift` (read-side variant — kdbClient injection)
- ApiHandler.swift GET method scaffold
- openapi.yaml GET endpoint entry

詳見 `docs/tasks/2026-05-19-presenter-skill.md` + `docs/decisions.md` /presenter skill v1 ratification 條目。


### 10.10 PresenterRenderer + read-side codegen（Phase 1.k）

Phase 1.k 補完 read-side codegen — 對 `bundle.presenters[]` (per-aggregate v1) 自動產：

```
Sources/<A>Aggregate/Adapter/<presenter.name>/<presenter.name>ApplicationService.swift   # NEW
                                                                                          # kdbClient injection, Output per kind
Sources/<A>Aggregate/Adapter/ApiHandler.swift                                             # extended (read method appended)
Sources/<A>Aggregate/openapi.yaml                                                         # extended (GET endpoints + dynamic parameters)
```

**3 output kinds**:

| kind | isOptional | Output Swift type |
|---|---|---|
| array | any | `[<elementType>]` |
| single | false | `<elementType>` |
| single | true | `<elementType>?` |
| scalar | false | `<elementType>` (e.g. `String`) |
| scalar | true | `<elementType>?` |

**Defer Phase 1.k.2**: cross-aggregate presenter (`aggregateRef == "<context-level>"`), `ContextError<<A>QueryError>` mapping, multi-readModel join, multi path param, operatorId for read endpoints, response schema $ref 對應 DTO auto-emit (v1 假設 user 手加 OR elementType=String scalar)。

**Pure function of bundle**: PresenterRenderer 不讀 FileManager — 同 Phase 1.h/1.i pattern。

**Read-side AS scaffold** (verbatim shape):

```swift
import Foundation
import KurrentDB
import {Ctx}Shared

package struct {Name}ApplicationServiceInput { ... }

package struct {Name}ApplicationService: ApplicationService {
    package typealias Input = {Name}ApplicationServiceInput
    package typealias Output = <outputType per kind>
    private let kdbClient: KurrentDBClient
    package init(kdbClient: KurrentDBClient) { ... }
    package func execute(input: Input) async throws -> Output {
        // TODO(/presenter-fill skill): fetch via {Name}Presenter + map readModel.{ElementSource} to Output
        fatalError("TODO(/presenter-fill skill): execute body for {Name}ApplicationService")
    }
}
```

**ApiHandler read method** (no JSON body unwrap, no operatorId, mapToApiError catch-all → 503):

```swift
package func {ucCamel}(_ input: Operations.{ucCamel}.Input) async throws -> Operations.{ucCamel}.Output {
    let {pathParamName} = input.path.{pathParamName}
    let service = {Name}ApplicationService(kdbClient: kdbClient)
    let asInput = {Name}ApplicationServiceInput({pathParamName}: {pathParamName})
    do {
        let output = try await service.execute(input: asInput)
        return .ok(.init(body: .json(output)))
    } catch { ... }
}
```

**openapi.yaml GET endpoint**:

```yaml
  <presenter.endpoint.path>:
    get:
      operationId: <camelCase(presenter.name)>
      parameters: [$ref ...]
      responses:
        '200':
          content:
            application/json:
              schema:
                # array → type: array, items: $ref schema
                # single → $ref schema
                # scalar → type: <yaml type>
```

**Dynamic parameters block** (Phase 1.k extension): OpenApiYamlRenderer collects unique path param names from useCases (always = aggregate.identityName) + presenters (from input.fields[0].name); operatorId emitted only when writeUCs 非空。

詳見 `docs/tasks/phase-1k-presenter-renderer.md` + `docs/decisions.md` Phase 1.k ratification 條目。

### 10.11 /api skill — write-side AI fill flow（v4）

`/api` skill 與 `/readmodel`、`/presenter` 不同 —— 那兩個是 **bundle-writing**（design-time，改 bundle JSON）；`/api` 是 **fill-in**（implementation-time，in-place edit Swift scaffold）。它消費 Phase 1.h+1.i renderer 留下的 `fatalError("TODO(/api skill)")` body。

```
bundle JSON
    ↓ genesis new (Phase 1.h + 1.i)
write-side scaffold（body 為 fatalError TODO）：
  Adapter/<UC>/<UC>ApplicationService.swift   # execute() fatalError
  Adapter/ApiHandler.swift                     # asInput closure fatalError
  Adapter/Dto/<X>Dto+Domain.swift              # init(from dto:) fatalError
  Adapter/ApiComponents/ApiComponents+<A>ApiError.swift  # case .x: self = .x（已 compile-pass）
    ↓ /api <useCaseName>（≤200 LoC SKILL.md，6 Phase）
fill categories 1-3（category 4 = NO-OP）：
  1 AS execute() → service.execute(...) + return（server-gen ID 用 UUID，只進 Service Input）
  2 ApiHandler asInput → 直接構造（Variant B 以 AS Input 欄位 Swift 型別決定 Decimal/Date 解析）
  3 DTO toDomain → field-by-field（依 domain type 決定轉換）
  4 ApiComponents → 不動（aggregate-wide mapper，per-UC 改會跨 UC 害 422→503）
    ↓ swift build
✓ write-side compile pass，可 serve HTTP
```

**關鍵設計（Codex audit v4 驅動）**：

- **Variant 偵測 truth source = AS Input 欄位 Swift 型別**，不看 openapi schema —— Phase 1.i 把 Decimal/Date 都 emit 成 plain `type: string`，schema 無法區分（audit H2）。
- **category 4 NO-OP** —— ApiComponents 是 aggregate-wide error mapper，被同 aggregate 所有 UC 共用，per-UC 改 `return nil` 會有跨 UC 副作用（audit H1）。
- **idempotent 用 structural invariant**（含 `service.execute` / 無 `_ = payload` 殘留 / domain field assignment 齊全），不靠「fatalError 消失」單一信號，半填 → exit 4（audit M7）。
- **exit codes**：0 success / 1 prerequisite missing（含 UC 0 match）/ 2 read-UC out-of-scope / 3 drift（AS Input non-path/non-header fields ≠ openapi requestBody）/ 4 corrupted-or-ambiguous（含多 aggregate 同名 UC、半填、duplicate handler）。

詳見 `docs/tasks/2026-05-18-api-skill.md` (v4) + `docs/decisions.md` /api skill v4 ratification 條目。

### 10.12 /presenter-fill skill — read-side AI fill flow（v1）

`/presenter-fill` 是 `/api` 的 read-side sibling。Phase 1.k 對 bundle.presenters[] codegen 出 read-side `{Name}ApplicationService.swift`（execute body 為 `fatalError("TODO(/presenter-fill skill)")`）+ **完整的** ApiHandler read method。本 skill 只填那一個 execute body。

```
bundle JSON（含 readModels[] + presenters[]）
    ↓ /readmodel + /presenter（design-time bundle-writing）
    ↓ genesis new（Phase 1.g projector codegen + Phase 1.k read-side AS + ApiHandler read method）
read-side scaffold：
  {A}Aggregate/Adapter/{Name}/{Name}ApplicationService.swift   # execute() fatalError TODO ← 唯一要填
  {A}Aggregate/Usecase/Projector/{Name}/{Name}Presenter.swift  # plugin projector（per-aggregate）
  {A}Aggregate/Adapter/ApiHandler.swift                        # read method 已完整 codegen（不碰）
    ↓ /presenter-fill <presenterName>（≤200 LoC，5 Phase）
fill execute() body：
  let presenter = {R}Presenter(coordinator: .init(client: kdbClient, eventMapper: {R}EventMapper()))
  非optional: guard let readModel = ...?.readModel else { throw ProjectionReadInconsistency(...) }; return readModel.{elementSource}
  optional:   let readModel = ...?.readModel; return readModel?.{elementSource}
    ↓ swift build
✓ read-side compile pass，可 serve HTTP GET
```

**關鍵設計（OC-aligned + Codex audit v1 驅動）**：

- **scope = per-aggregate only（D1）**：cross-aggregate（context-level readModel）的 read-side AS 在 `{A}Aggregate` 要 import context target → `Context → {A}Aggregate → Context` 循環依賴 → exit 3，defer Phase 1.k.2。
- **idempotent 先於 parse（audit H1）**：已填 body 的 TODO 註解已移除，Phase 2 先做 execute-block structural invariant，避免重跑誤判 exit 4。
- **單一 input field（audit H2）**：projector Input 只 wrap 單一 key；多欄（key+filter）的 filter 屬 domain 邏輯（OC GetContractNotes 手寫）無法自動填 → exit 3。
- **nil → ProjectionReadInconsistency → 503（D2）**：non-optional nil 用 Phase 1.f infra error（保證 compile）；read-side ApiHandler 無 404 path；404/422 精確語意需 designated domain notFound case（OC 有時用，Genesis bundle 不保證），defer v2。
- **scaffold self-describing**：skill 從 read-side AS 的 TODO 註解 parse `{R}Presenter` + `{elementSource}`；eventMapper = `{R}Presenter` 去 `Presenter` suffix + `EventMapper`。

詳見 `docs/tasks/2026-05-23-presenter-fill-skill.md` + `docs/decisions.md` /presenter-fill skill v1 ratification 條目。

### 10.13 Cross-aggregate read flow + QueryError 雙軌制（Phase 1.k.2，OC-aligned）

Phase 1.k.2 補完 Phase 1.k 留下的「per-aggregate presenter 引用 context-level readModel」架構錯位（read-side AS 在 `{A}Aggregate` 但 projector 在 `{Context}` target 造成循環依賴）+ 對齊 OC 的 query-side error 雙軌制。

```
bundle JSON (含 cross-agg readModel + presenter，BundleParser 強制 D1 co-location)
    ↓ genesis new (Phase 1.k.2)
    ├── per-agg: Sources/{A}Aggregate/{A}QueryError.swift (case .notFound)
    │            + Adapter/{Name}/{Name}ApplicationService.swift (kdbClient + Presenter projector 同 module)
    │            + Adapter/ApiHandler.swift (404 catch ContextError<{A}QueryError>)
    │            + Adapter/ApiComponents/ApiComponents+{A}ApiError.swift
    │            + openapi.yaml
    └── context-level (when bundle has cross-agg presenter):
                 Sources/{Context}/{Context}QueryError.swift (case .notFound)
                 + Adapter/{Name}/{Name}ApplicationService.swift (kdbClient + context-level projector 同 module)
                 + Adapter/ApiHandler.swift (multi-branch mapToApiError import 各 source aggregate, 404 catch ContextError<{Context}QueryError>)
                 + Adapter/ApiComponents/ApiComponents+{Context}ApiError.swift (per source aggregate overloads + QueryError overload)
                 + openapi.yaml (無 operatorId/aggIdName，per-agg domain errorCodes union 進 ApiError enum)
    ↓ /presenter-fill v2 (依路徑推導 module → 選 {QueryErrorType})
fill execute() body：
  non-optional nil → throw ContextError<{QueryErrorType}>(error: .notFound, ...) → 404
  optional       → return readModel?.{elementSource}
    ↓ swift build
✓ cross-agg read endpoint 真正 serve 404 + ApiHandler/projector/openapi 全 compile pass
```

**關鍵設計**：

- **D1 co-location（BundleParser 強制）**：`presenter.aggregateRef == resolved readModel.aggregateRef`。不一致 reject `bundleInvalid`。這隱含 OC 的「presenter/AS/readModel 同 target」規則。
- **`PresenterPlacementResolver` 共用 helper（audit M3）**：5 個 renderer（Presenter/QueryError/ApiHandler/OpenApiYaml/Package）皆透過此 helper 判 per-agg vs context-level，避免邏輯散落 drift。
- **QueryError 雙軌制（OC pattern F1）**：per-aggregate + context-level 各自的 `<X>QueryError.swift`（v1 預設 `case notFound`），讀取端 ApiHandler 加 `catch ContextError<{X}QueryError> where error.error == .notFound → .notFound(.init(error: .aggregateNotFound))` 404 catch。`aggregateNotFound` 已是 ApiError infra case（Phase 1.i），故 read 404 reuse 不需 openapi enum 改動。
- **context-level ApiHandler 獨立 template**（audit H3）：不沿用 per-agg template（後者帶 `repository` / `{A}AggregateEventMapper` 不存在符號），新 `ApiHandlerContext.swift.template` 僅 kdbClient + mapToApiError + read methods。mapToApiError multi-branch import 各 source aggregate（透過 readModel.events.sourceAggregate dedup），對齊 OC `OpportunityContext.Adapter.ApiHandler` 多 branch pattern。
- **needsOpenApi 擴展**（audit H4）：top-level swift-openapi-* package deps 條件由「有任一 write UC」改為「有任一 write UC 或任一 read presenter（per-agg/context）」，否則 presenter-only 場景 SwiftPM resolve fail。per-agg target conditional 同步擴展。
- **/presenter-fill v2 升級**：Phase 1 glob 加 `Sources/*/Adapter/` context 路徑；non-optional nil throw 從 v1 `ProjectionReadInconsistency → 503` 升級為 `ContextError<{QueryErrorType}> → 404`，**解除 v1 known limit #2**。v1 既有 fills 不自動升級（structural invariant 視為「已填」exit 0），user 想升級須手 unfill。
- **scalar+collection reject**（D4）：BundleParser 攔 `presenter.output.kind=.scalar` 配 collection elementType（Set</Array</[/Dictionary< prefix + strip optional + trim），避免 openapi `OpenAPIArrayContainer` 錯配（Phase 1.k 既有限制，現在 fail-fast at bundle level）。

詳見 `docs/tasks/phase-1k2-cross-aggregate-presenter.md` + `docs/decisions.md` Phase 1.k.2 ratification 條目。

### 10.14 /readmodel-mutation skill — projector when() body fill flow（v1）

`/readmodel-mutation` 是 `/api`（write-side）與 `/presenter-fill`（read-side AS）之後的第三個 in-place fill skill —— 填 Phase 1.g 留下的 projector `when()` mutation body stubs。完成 read-side codegen 鏈最後一塊：**read endpoint 真正能回正確 readModel 資料**（不只 compile-pass）。

```
bundle (含 readModels[] + events refs + presenters[])
    ↓ /readmodel + /presenter (design-time bundle-writing)
    ↓ genesis new (Phase 1.g + 1.k + 1.k.2 projector + AS scaffold)
projector scaffold:
  Sources/{A}Aggregate/Usecase/Projector/{Name}/{Name}Presenter.swift
  OR Sources/{Context}/Projector/{Name}/{Name}Presenter.swift (cross-agg, Phase 1.k.2)
  含 per event 的 stub: when(readModel: inout R, event: E) { _ = readModel; _ = event }
    ↓ /readmodel-mutation <presenterName>  ← 本 skill 填這
fill 5 patterns（依 event name + payload-vs-storedField）：
  Removed/Deleted → removeAll { $0.id == event.id }
  Edited/Updated/Renamed → guard firstIndex + readModel[i].field = event.field
  Added → readModel.col.append(.init(field: event.field, ...))
  Created → readModel.anchorField = event.anchorField (set anchor 多 field)
  Set/Edited 全 scalar → readModel.field = event.field
  [X] → Set<X> → readModel.setField = Set(event.arr)
    ↓ /presenter-fill <presenterName>
read AS body 填好 (Phase 1.k.2 已 ship)
    ↓ swift build
✓ read endpoint 真正運作：projector 累積 event → readModel 累積狀態 → AS 抓 readModel → 200/404
```

**關鍵設計**：

- **in-place fill（D1 = A）**：與 /api、/presenter-fill 同 mental model；不擴 bundle schema、不改 renderer。理由：mutation 是 code-level 邏輯（不是 design-time 結構決策），DSL 中間層增加 debug 成本且涵蓋不全。
- **5 patterns + pattern priority** 對應 OC ground truth：set scalar (GetFontSize) / set anchor (QuotationCreated 多 read) / append struct (GetContractNotes ContractNoteAddedByUser) / removeAll (GetContractNotes ContractNoteRemovedByUser) / updateAt (GetContractNotes ContractNoteEdited) / assignList (Set<roles> from `[String]`).
- **idempotent per-method（granular）**：每 `when()` body 獨立判定（同 file 可混合已填+未填）；placeholder tolerant matching（whitespace、trailing comment、line-based `^\s*_ = readModel/event`）。
- **out-of-scope（exit 3）**：v1 不涵蓋 reorder via Dictionary+compactMap、insert-at-position with fallback、cross-event 條件 update、custom type wrap、append struct 涉及 payload-missing-field（domain 決策，需 manual default）。
- **per-agg + context-level locate**：Phase 1.k.2 後 cross-agg projector 在 `Sources/{Context}/Projector/`，本 skill 同樣 cover。

詳見 `docs/tasks/2026-05-25-readmodel-mutation-skill.md` + `docs/decisions.md` /readmodel-mutation skill v1 ratification 條目。

### 10.15 Variant B `init(from payload:)` extension（Phase 1.j，pure quality improvement）

Phase 1.j 補完 Phase 1.h/1.i defer 的 OC pattern：當 UC 的 AS Input 含 `Date` / `Date?` field（Variant B-Date），ApiRenderer 在同 AS file emit `extension <UC>ApplicationServiceInput { init(from payload:, <aggIdName>:, operatorId:) throws { self.init(...) } }`；/api skill v5 用短形 `try <UC>...Input(from: payload, ...)` + `catch is Iso8601ParsingError → 422 .invalidDateFormat` 取代 v4 inline guard+throw。**行為不變**，handler method body 變短、與 OC AddAccountingApplicationService 1:1。

**Variant B-Date 自動 emit body rules**：plain field → `<f>: payload.<f>`；Date / Date? field → `<f>: try Date.parseIso8601(payload.<f>)`（Phase 1.f `parseIso8601` 雙 overload Swift 自動 resolve）。aggId / operatorId 從 init args 傳入（非 payload）。

**Trigger**: ApiRenderer.`hasVariantBDate(resolvedFields:)` — 任一 non-aggId non-operatorId field 型別 `Date` / `Date?` 即 emit；否則 placeholder 空字串、Variant A path 不變。

**/api v5 短形偵測**: grep AS file `extension <UC>ApplicationServiceInput { init(from payload:`，命中且純 Date（無 Decimal） → emit 短形；否則 v4 inline path（Decimal 路徑 + 無 extension fallback）。

**Defer v2**: Variant B-Decimal extension（需 guard+throw in init body）、nested DTO `.init(from:)` 與 array DTO `try .map { try ... }` 自動 emit、既有 v4 inline handler retro-upgrade 為短形。

詳見 `docs/tasks/phase-1j-variant-b-extension.md` + `docs/decisions.md` Phase 1.j ratification 條目。


## 11. Open questions

These are spec-level gaps not yet resolved:

1. **Hash algorithm for sourceHashes** — sha256 of body, frontmatter excluded? Or whole file?
2. **`_routing.md` format** — D21 mentions routing cache for `event-storming` ambiguity, schema undefined.
3. **`.ai/conventions/review.md` content** — D19 says shared between `test-review-commit` and `strict-review`, skeleton undefined.
4. **Per-project skill override conflict** — if user customizes a skill in `~/.claude/skills/` and Genesis ships a new version, how to detect and prompt?
5. ~~**`/api` skill 6 steps** — D18 caps at 200 LoC / 6 steps but the steps themselves are not enumerated.~~ **Resolved (/api skill v4, 2026-05-22)**：6 Phase（0 read-UC 偵測 / 1 locate aggregate / 2 prerequisite / 3 parse inputs / 4 drift+Variant 偵測 / 5 fill categories 1-3 / 6 report）enumerated in §10.11；SKILL.md 188 行 ≤200。
6. **Cosmogony MCP config schema** — exact shape `install-mcp` writes (depends on Cosmogony's MCP server invocation).

These should be resolved during implementation, not blocking design lock-in.

## 12. Reading order for new contributors

1. This document (`docs/architecture.md`)
2. `docs/discussions/2026-05-12-*.md` — Why CLI? Why these decisions?
3. `docs/discussions/2026-05-13-*.md` — Why this skill ecosystem? Why these boundaries?
4. (When implementation starts) `Templates/` directory for the actual scaffolding artifacts
