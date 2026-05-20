# Genesis

A Swift CLI that bootstraps Swift DDD/Event-Sourcing projects from [Cosmogony](https://github.com/Mendesky) Event Storming exports.

## Status

🟢 **Phase 1 implemented** — `genesis new` and `genesis install-skills` are working, with 97 passing tests. Phases 2–4 (MCP, drift detection, canvas sync) are designed but not yet built.

## What Genesis does

Genesis bridges the gap between a **business model** (Cosmogony Event Storming canvas, exported as a bundle JSON) and a **working Swift DDD/ES project**. It generates the mechanical scaffolding — aggregates, events, repositories, use-case ports, business-doc skeletons — and leaves the use-case bodies as `fatalError("not implemented")` stubs for you (or a Claude Code skill) to fill in.

It is a developer tool, independent of any specific DDD project.

## Install

Genesis is not yet distributed as a binary. For now, run from source:

```bash
git clone <genesis-repo-url> && cd Genesis
swift build -c release
# binary at .build/release/genesis
```

Requires Swift 5.10+ (macOS 13+).

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

`genesis new` runs a git pre-flight (the output dir must be a clean git work tree, unless `--no-git`), generates the project, then validates it with `swift package resolve`. On failure it rolls back everything it wrote.

### Install Claude Code skills

```bash
# User-global (default) — installs into ~/.claude/skills/
genesis install-skills

# Per-project
genesis install-skills --scope project --project-dir ./my-project

# Overwrite existing skills
genesis install-skills --force
```

Installs the bundled skill set (`event-storming`, `write-ddd-spec`, `usecase`, `readmodel`, `api`, `strict-review`) so Claude Code can pick up where Genesis leaves off — filling the use-case stubs with real business logic.

## What gets generated

From a bundle with one aggregate (`UserAccessProfile`) and seven use cases, `genesis new` produces ~60 files:

```
{project-root}/
├── Package.swift                                 # SwiftPM, depends on DDDKit 1.12.4
├── README.md / CLAUDE.md                         # Boilerplate + Claude Code guide
├── Sources/
│   ├── {Aggregate}Aggregate/                     # One SwiftPM target per aggregate
│   │   ├── event.yaml                            # SSOT for events; DDDKit plugin compiles it
│   │   ├── event-generator-config.yaml
│   │   ├── {Aggregate}.swift                     # AggregateRoot class skeleton
│   │   ├── {Aggregate}Error.swift                # Error enum from bundle invariants
│   │   ├── Entity/Commands/{Aggregate}+{UC}.swift # Command + when(event:) stubs
│   │   ├── Usecase/Port/In/{UC}/                 # Input / Output / Usecase protocol
│   │   ├── Usecase/Service/{UC}Service.swift     # Service struct (stub body)
│   │   └── Adapter/{Aggregate}Repository.swift   # EventSourcingRepository thin class
│   └── {Context}Shared/                          # Cross-aggregate DTOs / value objects / typed IDs
├── Tests/{Context}Tests/                         # Test target placeholder
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

The Swift code compiles; the use-case bodies are stubs. The `.ai/contexts/` markdown files are the single source of truth for business rules — downstream Claude Code skills read and edit these.

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
| 1.a | CLI skeleton + `Package.swift` rendering | ✅ Done |
| 1.b | Bundle extraction → `Sources/{Aggregate}/` tree | ✅ Done |
| 1.c | `swift-adapter.yaml` + manifest + business docs + Shared target | ✅ Done |
| 1.d | `genesis install-skills` | ✅ Done |
| 2 | `genesis install-mcp` — write Cosmogony MCP config | Designed |
| 3 | `genesis diff` / `apply` / `adapter` / `update-skills` — in-project maintenance | Designed |
| 4 | `genesis plan-canvas-sync` / `verify-canvas` — canvas reverse-sync | Designed |

## Development

```bash
swift build          # build CLI + core library
swift test           # run all 97 tests
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
