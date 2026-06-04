# Genesis

A Swift CLI that bootstraps Swift DDD/Event-Sourcing projects from [Cosmogony](https://github.com/Mendesky) Event Storming exports.

## Status

🟢 **Phase 1 implemented** — `genesis new`, `install-skills`, `uninstall-skills`, `check-skills`, `bundle-parse`, and `verify` are working, with 299 passing tests. Generated projects are **TDD-first**: they compile, with runtime `GenesisTODO` holes that keep each unfilled feature's test red until you fill it (`genesis verify` gates release). The per-feature fill pipeline ships as 12 Claude Code skills (model → plan → test → fill). Phases 2–4 (MCP, drift detection, canvas sync) are designed but not yet built.

## What Genesis does

Genesis bridges the gap between a **business model** (Cosmogony Event Storming canvas, exported as a bundle JSON) and a **working Swift DDD/ES project**. It generates the mechanical scaffolding — aggregates, events, repositories, use-case ports, adapters, test fixtures, business-doc skeletons — as a **scaffold-emitter**: everything mechanically derivable from the bundle is generated, and everything that needs human domain judgment (invariant predicates, command business rules, non-trivial state transitions) is left as a runtime **`throw GenesisTODO.notImplemented(...)`** hole.

Genesis is **TDD-first**: a freshly generated project **compiles** (the holes are runtime throw-markers, not compile-time `#error`), but the test for each unfilled feature is **RED** until you fill it — write the test, watch it go red, implement, watch it go green, one feature at a time. `grep GenesisTODO.notImplemented` is the honest, greppable to-do list; **`genesis verify`** is the release/CI gate (no unfilled holes; every declared invariant has an enabled test). Deterministic fill skills (`/usecase`, `/api`, `/readmodel-mutation`) fill the mechanical bodies; **`/domain-fill`** transcribes human-dictated domain logic into the remaining holes; **`/test-gen`** emits enabled-red Swift Testing tests, and `genesis new` already ships the `createX(…)` fixtures their Given setup calls.

It is a developer tool, independent of any specific DDD project.

## Install

Genesis is not yet distributed as a binary. For now, run from source:

```bash
git clone <genesis-repo-url> && cd Genesis
swift build -c release
# binary at .build/release/genesis
```

Requires Swift 6.0+ (macOS 13+) — generated projects use Swift Testing + SwiftPM tools 6.0.

## Usage

### Bootstrap a project

```bash
# Minimal — uses built-in defaults
genesis new IAMContext --from-bundle ./bundle.json

# With an adapter to override type mapping / ID strategy / etc.
genesis new IAMContext --from-bundle ./bundle.json --adapter ./swift-adapter.yaml

# Into a specific directory
genesis new IAMContext --from-bundle ./bundle.json --output ./my-project
```

| Flag | Purpose |
|------|---------|
| `--from-bundle <path>` | Cosmogony Event Storming bundle JSON (required) |
| `--adapter <path>` | `swift-adapter.yaml` to override defaults (optional) |
| `--output <dir>` | Output directory (default: current directory) |
| `--no-git` | Skip the git pre-flight check (for CI / sandboxes) |
| `--skip-build` | Skip the post-generation `swift build` (resolve still runs) |

`genesis new` runs a git pre-flight (the output dir must be a clean git work tree, unless `--no-git`), generates the project, runs `swift package resolve`, and then (unless `--skip-build`) `swift build`. On failure it rolls back everything it wrote.

> **Note:** a freshly generated project **compiles** — domain holes are runtime `throw GenesisTODO.notImplemented(...)` markers, not compile-time `#error`. `swift build` passes; the *test* for each unfilled feature is **red** until you fill it (TDD-first). `--skip-build` just skips the network-heavy post-generation build. Fill the holes with the deterministic skills + `/domain-fill`; run `genesis verify` (in the project) as the release gate.

### Install Claude Code skills

```bash
# User-global (default) — installs into ~/.claude/skills/
genesis install-skills

# Per-project
genesis install-skills --scope project --project-dir ./my-project

# Overwrite existing skills
genesis install-skills --force

# Remove the bundled skills again — keeps any skill you've hand-edited (unless --force)
genesis uninstall-skills
genesis uninstall-skills --scope project --project-dir ./my-project --force
```

Installs the bundled skill set so Claude Code can pick up where Genesis leaves off (`uninstall-skills` is the inverse; by default it only removes skills whose contents still match the bundled version, so your edits are never silently deleted):

| Skill | Role |
|-------|------|
| `event-storming` | Model a domain on the Cosmogony canvas |
| `write-ddd-spec` / `bundle-plan` | Turn a bundle into per-use-case contract-first task specs (`/bundle-plan` is the batch, method-X path) |
| `usecase` | Fill the domain `Usecase.execute()` orchestration body (Create / Update / Delete patterns) |
| `api` | Fill the write-side `ApplicationService` + `ApiHandler` bodies |
| `readmodel` / `presenter` | Scaffold read models + presenters |
| `readmodel-mutation` / `presenter-fill` | Fill read-side projector `when()` + read AS bodies (type-closure patterns incl. Dto-convert) |
| `test-gen` | Emit **enabled-red** Swift Testing tests (2-lane: mechanical full body / judgment envelope + a typed `genesisTODO` Given-thunk); two-file split (machine `.generated` + human `.authored`). Consumes the codegen'd fixtures |
| `domain-fill` | Transcription-only: dictate domain logic, the skill writes it into the entity-layer `GenesisTODO.notImplemented` holes (never drafts logic itself) |
| `strict-review` | Review pass |

### Other commands

```bash
genesis --version                  # print the Genesis version
genesis bundle-parse ./bundle.json # authoritative bundle parse → canonical FullBundle JSON on stdout
genesis check-skills               # report whether installed skills are in sync with this binary
genesis verify                     # run inside a generated project: release/CI gate — fails (exit 2) on any unfilled GenesisTODO hole (Sources or Tests) or any invariant with no enabled test
```

## What gets generated

From a bundle with one aggregate (`UserAccessProfile`), seven use cases, and a read model, `genesis new` produces ~91 files:

```
{project-root}/
├── Package.swift                                 # SwiftPM (tools 6.0), depends on gradyzhuo/swift-ddd-kit 0.3.0
├── README.md / CLAUDE.md                         # Boilerplate + Claude Code guide
├── Sources/
│   ├── {Aggregate}Aggregate/                     # One SwiftPM target per aggregate
│   │   ├── event.yaml                            # SSOT for events; DDDKit plugin compiles it
│   │   ├── event-generator-config.yaml / openapi.yaml
│   │   ├── {Aggregate}.swift / {Aggregate}GenesisTODO.swift # AggregateRoot + ensureInvariant() (no-op until /domain-fill) + the GenesisTODO marker enum
│   │   ├── {Aggregate}Error.swift                # Error enum + ContextError factories, from bundle invariants
│   │   ├── Entity/Commands/{Aggregate}+{UC}.swift # Command body (precondition scaffold + GenesisTODO throw) + when(event:) reducer
│   │   ├── Usecase/Port/In/{UC}/                 # Input / Output / Usecase protocol (execute body filled by /usecase)
│   │   ├── Usecase/Port/Out/{Aggregate}Repository.swift # EventSourcingRepository (KurrentDB-backed)
│   │   ├── Usecase/Service/{UC}Service.swift     # Service conformance struct
│   │   ├── Usecase/Projector/{RM}/               # ReadModel + Presenter (read side)
│   │   └── Adapter/                              # ApplicationService + ApiHandler + DTOs
│   └── {Context}Shared/                          # Cross-aggregate DTOs / value objects / ContextError / typed IDs
├── Tests/{Context}Tests/                         # placeholder + SharedUtility/UsecaseCall/{Aggregate}.swift (codegen'd bare test fixtures); /test-gen adds enabled-red tests
└── .ai/
    ├── conventions/api.md                        # Cross-aggregate API conventions
    └── contexts/{Context}/
        ├── .scaffold-manifest.json               # sha256 of every generated file
        ├── swift-adapter.yaml                    # Starter adapter (if --adapter not given)
        └── {Aggregate}/                          # Per-aggregate business docs (SSOT)
            ├── config.md / commands.md / invariants.md
            ├── errors.md / api.md / test-scenarios.md
            ├── reference.md
            └── notes/{UC}.md                     # Per-use-case working notes
```

The mechanical scaffolding is complete; the domain-judgment bodies are `throw GenesisTODO.notImplemented(...)` holes, so a fresh project **compiles** but its feature tests are red until the fill skills + `/domain-fill` resolve them (`genesis verify` gates release). The `.ai/contexts/` markdown files are the single source of truth for business rules — downstream Claude Code skills read and edit these.

## The swift-adapter.yaml

The adapter file overrides Genesis's built-in heuristics. All fields are optional:

```yaml
adapterVersion: 1
schemaVersion: 1
contextName: IAMContext
bundleId: <must match the bundle if present>

typeMapping:                       # bundle type string → Swift type
  "Array[String]": "[String]"

customTypes:                       # extra value types emitted into {Context}Shared
  - { name: EmployeeStatus, kind: enum, cases: [active, suspended] }
  - { name: EmailAddress, kind: valueObject, underlying: String }
  - { name: UserAccessProfileID, kind: identifier, underlying: UUID }

createdEventOverrides:             # which use case is the "created" event
  UserAccessProfile: createUserAccessProfile

aggregateSplit:
  strategy: byBoundedContext

idStrategy:
  kind: typedStruct                # or `direct` (String IDs)
  wrapper: "{Aggregate}ID"
```

Run `genesis new` without `--adapter` once, and a starter `swift-adapter.yaml` is written into `.ai/contexts/{Context}/` for you to edit and pass back on the next run.

## Design philosophy

Three-layer separation of concerns:

| Layer | Concern | Tooling |
|------|---------|---------|
| **CLI (Genesis)** | Mechanical work — scaffolding, file generation, drift detection | Swift executable |
| **Claude Code skills** | LLM judgment — business-rule clarification, code generation with context | Markdown skills in `~/.claude/skills/` |
| **Filesystem** | SSOT — `.ai/contexts/` (business), `bundle.json` (canvas snapshot), `Sources/` (code) | Git as transaction layer |

Core principles:

- **Add-only writes** — never destructive without explicit confirmation; `genesis new` rolls back fully on any failure
- **Git as transaction** — pre-flight check + rollback, no separate transaction infrastructure
- **Templates bundled with CLI** — versioning aligns naturally with the CLI version
- **Stateless where possible** — `.scaffold-manifest.json` records generation provenance, not workflow state

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| 1.a–1.d | CLI skeleton + `Package.swift` + bundle extraction + adapter/manifest/docs + `install-skills` | ✅ Done |
| 1.e–1.m | Aggregate/usecase/api/readmodel/presenter renderers + server wire-up (OC-aligned) | ✅ Done |
| 1.n–1.s | Type-ownership routing, codegen injection, write DTOs, `bundle-parse` CLI, `/bundle-plan` + `/test-gen` skills | ✅ Done |
| 1.t–1.w | Domain scaffold-emitter: ContextError factories, create-init alignment, OpenAPI collection types, domain holes (`#error`, later migrated to a throw-marker in 1.y), Dto-convert pattern, `/domain-fill` (transcription-only) | ✅ Done |
| 1.x–1.z + fixtures | TDD honest-hole migration (`#error` → `GenesisTODO` throw-marker — fresh gen now compiles), execute-orchestration codegen, `genesis verify` gate, `/test-gen` enabled-red 2-lane, codegen test fixtures (`FixtureRenderer`), `uninstall-skills` | ✅ Done |
| 2 | `genesis install-mcp` — write Cosmogony MCP config | Designed |
| 3 | `genesis diff` / `apply` / `adapter` / `update-skills` — in-project maintenance | Designed |
| 4 | `genesis plan-canvas-sync` / `verify-canvas` — canvas reverse-sync | Designed |

Per-phase specs live in `docs/tasks/` (status in `docs/tasks/registry/`); the multi-agent design discussions that drive them are in `docs/discussions/`.

## Development

```bash
swift build          # build CLI + core library
swift test           # run all 299 tests
swift run genesis new IAMContext --from-bundle <path>   # run from source
```

Specs for each phase live in `docs/tasks/`, with status tracked in `docs/tasks/registry/`.

## Source material

Genesis's architecture is distilled from multi-agent design discussions:

- [`docs/discussions/2026-05-12-swift-ddd-scaffold-restructure.md`](docs/discussions/2026-05-12-swift-ddd-scaffold-restructure.md) — Decisions D1–D14
- [`docs/discussions/2026-05-13-skill-pipeline-boundaries.md`](docs/discussions/2026-05-13-skill-pipeline-boundaries.md) — Decisions D15–D33

See [`docs/architecture.md`](docs/architecture.md) for the distilled architecture spec and [`docs/decisions.md`](docs/decisions.md) for the decision index.

## License

TBD
