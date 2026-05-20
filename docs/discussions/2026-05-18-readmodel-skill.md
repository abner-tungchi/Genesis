# /readmodel skill v1 — design discussion

**Date**: 2026-05-18
**Status**: decisions locked, ready for write-spec
**Related**: `docs/tasks/registry/2026-05-18-api-skill.json` (sibling per-feature skill, paused)
**Facts source**: Gemini agent investigation of `~/JiaBao/Mendesky/OpportunityContext` (2026-05-18, agent `a835dbfeb3c99a33e`)
**Decision authority**: User confirmed split into separate `/readmodel` + `/presenter` skills (Option A), OC as ground truth, `AskUserQuestion multiSelect:true` for event selection (Option B).

---

## 1. Facts — OC readmodel pattern (from Gemini investigation)

> Full report cached in agent transcript; the bits that matter for skill design are summarised here.

### 1.1 Files per projection (OC convention)

| File | Author | Path |
|---|---|---|
| `<Noun>ReadModel.swift` | **human** | `Sources/<Target>/Usecase/Projector/Get<Noun>/` (or `Sources/<Target>/Projector/Get<Noun>/` for cross-aggregate) |
| `Get<Noun>Presenter.swift` (= the OC Projector) | **human** | same dir |
| `Get<Noun>ApplicationService.swift` (the API-shaped query) | **human** | `Sources/<Target>/Adapter/Get<Noun>/` |
| `OC_Get<Noun>Projection.js` | **human** (maintained by hand today) | `projections/` |
| `Get<Noun>ProjectorProtocol`, `Get<Noun>EventMapper`, `Get<Noun>EventFilter` | **generated** by `ModelGeneratorPlugin` | `.build/plugins/outputs/.../generated/` |

→ Genesis bundle → codegen must emit **the 4 human-written files**; the 3 generated files come for free from the SwiftPM plugin.

### 1.2 `projection-model.yaml` schema (OC's source of truth)

Verbatim from `AuditQuotingAggregate/projection-model.yaml`:

```yaml
GetQuotingProofs:
  model: readModel
  events:
    - QuotingProofUploadedToGcs
    - QuotingProofOnGcsRemoved
```

Trivial flat shape. `<ProjectionName>` becomes the symbol prefix; `events: [...]` drives the generated protocol's `when(...)` methods.

### 1.3 ReadModel struct shape

- `package class` conforming to `ReadModel` (Codable + `var id: Hashable`)
- `var id: String { <keyField> }` — computed property delegating to stored key
- Stored key field name = either aggregate root id (most common) or grouping id or inverse-lookup key
- Initialiser takes only the key; other fields default to `nil` / `[]` / `[:]`
- Nested row types: `package struct: Codable, Sendable, Equatable`

### 1.4 Presenter (= OC's Projector) shape

- `package struct: Get<Noun>ProjectorProtocol`
- Nested `Get<Noun>Input: CQRSProjectorInput` with `id: String` exposed via semantic init label
- Required typealiases: `Input`, `StorageCoordinator = KurrentStorageCoordinator<Self>`, `ReadModelType`
- `static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "OC_") }` — `OC_` is the **project-level stream prefix**
- One `when(readModel: inout ReadModelType, event: <EventName>) throws` per event — **missing one = compile error**

### 1.5 JS projection (the silent contract)

```js
fromStreams(["$ce-OCAuditQuoting"])
.when({
    $init: function(){ return {} },
    AuditQuotingCreated: handleEvent,
    AccountingTypeEdited: handleEvent
});
function handleEvent(state, event) {
    if (event.isJson) {
        linkTo("OC_GetAccountingType-" + event.body["quotingId"], event);
    }
}
```

**Critical**: the JS encodes info NOT in `projection-model.yaml`:
1. Source stream category (`$ce-OC<AggregateCategory>`)
2. **Key field name on the event payload** (`event.body["quotingId"]`)
3. Stream prefix (`OC_`)

→ The JS file and the Swift Presenter's `Input.id` semantics **must agree**, but nothing enforces it. **This is a footgun the skill should solve by hoisting the key field to a single declaration.**

### 1.6 Storage backend

KurrentDB (= EventStoreDB) only. **Replay-on-read** every query. No caching, no checkpoints, no Postgres/Redis. swift-ddd-kit has `ReadModelPersistence` but OC doesn't use it.

### 1.7 Naming conventions (rigid, derivable)

| Concern | Convention |
|---|---|
| Bundle entry name | `Get<Noun>` (verb-noun, camelCase) |
| ReadModel type | `<Noun>ReadModel` (strip `Get`) |
| Presenter type | `Get<Noun>Presenter` |
| ApplicationService type | `Get<Noun>ApplicationService` |
| Stream category (KurrentDB) | `<Prefix>Get<Noun>` |
| Stream name | `<category>-<id>` |
| JS file | `<Prefix>Get<Noun>Projection.js` |
| Access modifier | `package` uniform |

---

## 2. Decisions

### D1 — Skill scope: what does `/readmodel` produce?

**Decision**: `/readmodel` skill writes a **readmodel section into the bundle JSON**. It does NOT directly generate Swift / JS files. Code generation is Genesis's `genesis new` (or future regenerate command) job, driven by the bundle.

**Rationale**:
- User's stated direction this session: bundle = single source of truth; codegen happens at bundle ingestion time, not per-skill
- Separates design intent (skill collects user's design) from mechanical translation (renderer transforms bundle into code)
- Existing `~/.claude/skills/readmodel/SKILL.md` (config.md-centric, generates code directly) serves a different lifecycle (per-feature on existing project), not in conflict

**Scope of `/readmodel` skill v1 specifically**:
- Reads existing bundle to surface aggregates/events as choices
- Asks user to design a new readmodel (multi-select events, name, key field, stored fields, source aggregates)
- Writes a new entry into `bundle.readModels[]`
- Does **NOT**: invoke `genesis new`, generate any Swift/JS, deploy projections, run tests, commit

### D2 — Bundle `readModels[]` schema extension

**Decision**: Extend bundle schema. New shape:

```json
{
  "name": "GetAccountingType",
  "aggregateRef": "AuditQuoting",
  "key": { "field": "auditQuotingId", "type": "String" },
  "fields": [
    { "name": "auditQuotingId", "type": "String", "default": null },
    { "name": "accountingType", "type": "AccountingTypeDto?", "default": null }
  ],
  "events": [
    { "name": "AuditQuotingCreated", "payloadKeyField": "quotingId" },
    { "name": "AccountingTypeEdited", "payloadKeyField": "quotingId" }
  ],
  "sourceAggregates": ["AuditQuoting"],
  "comment": null
}
```

**Field meanings**:
- `name`: bundle-level identifier; conforms to OC's `Get<Noun>` verb-noun camelCase
- `aggregateRef`: which aggregate this readmodel is **filed under** (determines the output directory in codegen). Allowed value: any aggregate name in bundle, or context-level (see D7).
- `key.field`: ReadModel's id field name (e.g. `auditQuotingId`). Codegen wires `var id: <type> { <field> }`.
- `key.type`: usually `String`, allowed Hashable types only.
- `fields[]`: stored fields on the ReadModel. Codegen emits each as `package var <name>: <type>`. Default `null` → optional with `nil` init.
- `events[].payloadKeyField`: the JS projection's `event.body["<field>"]` argument. **Hoists the JS<>Swift footgun from §1.5 to a single bundle declaration.** Codegen uses it for both Swift Presenter's `when(...)` key extraction (if needed) and JS projection's `linkTo` argument.
- `sourceAggregates[]`: which `$ce-<Prefix><Aggregate>` streams the JS projection subscribes to. Usually = aggregates that emit the listed events.
- `comment`: optional human note, becomes YAML comment in `projection-model.yaml`.

**Rationale**:
- Captures everything Gemini facts §1.5 identifies as currently implicit (key field, source streams)
- Eliminates the JS↔Swift drift footgun by single-source-of-truthing the key field
- Preserves OC's flat YAML shape (which is just `events:` + `model:`) — the extra fields in JSON are bundle-only, not pushed back into YAML

**Skipped (out of scope v1)**:
- DTO type references — assume types exist in `OCShared` / context Shared module; do not validate
- `+Query.swift` extension methods — those are post-skill custom code, not in bundle
- ApplicationService section — that's `/presenter` skill's job (D8)

### D3 — Skill interactive flow (the user-facing dialogue)

**Decision**: 6-step flow using `AskUserQuestion` for all choice points.

1. **Read bundle**. If missing or no `aggregates`, error out with hint.
2. **Ask aggregate** (`AskUserQuestion`, single-select): "Which aggregate does this readmodel belong to?" Options = bundle's aggregate names + `<context-level>`. If only one aggregate, skip and announce.
3. **Ask events** (`AskUserQuestion`, multiSelect: true): "Which events affect this readmodel?" Options = events from the chosen aggregate + (if context-level) all aggregates' events. Show event payload preview where available.
4. **Ask name** (free-form text via subsequent prompt or `AskUserQuestion` "Other"): collect `Get<Noun>` name. Validate camelCase, starts with `Get`, uniqueness within bundle.
5. **Ask key field**: from the chosen events' payload, propose candidate key fields (frequency-based heuristic — fields that appear in all chosen events). Single-select via `AskUserQuestion`.
6. **Ask stored fields**: For each event's payload field, ask if it should be stored on the ReadModel (multi-select). User can also free-form additional fields.

After confirmation, write to bundle and report success.

**Rationale**:
- `AskUserQuestion multiSelect` is locked decision; matches user preference for structured UI
- 6 steps keeps the flow short; longer collection (validation, dependencies) deferred to audit-spec phase
- Skill stays read-only on bundle until final write — easy to abort partway

**Open question for audit-spec**:
- Should skill auto-detect candidate key field by scanning event payloads, or always ask? (Lean: auto-detect with explicit confirm.)
- How to handle event-payload preview when bundle doesn't include payload schema? (Lean: ask user to manually specify if missing.)

### D4 — Multi-select mechanism

**Decision**: `AskUserQuestion` tool with `multiSelect: true`. (Already locked by user.)

**Constraint**: Skill prompt must explicitly instruct the Claude session to use the tool. If running in a session that lacks `AskUserQuestion`, the skill falls back to numbered-list textual prompting (graceful degradation).

### D5 — Skill artifact location

**Decision**: Genesis ships skill at `Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md`. When `genesis install-skills` runs, it copies to target project's `.claude/skills/readmodel/SKILL.md`.

**Rationale**:
- Phase 1.d already established this pipeline; reuse infrastructure
- Skill is project-local (per Genesis-bootstrapped project), does not conflict with user's `~/.claude/skills/readmodel/` global skill (which has different config.md-centric scope)

### D6 — Bundle write strategy

**Decision**: Skill appends new entry to `bundle.readModels[]`. Idempotency check: if `name` already exists → ask user to overwrite / pick new name / abort.

**Format**: re-serialise the entire bundle JSON with 2-space indent, preserving existing entry order (new entry appended last).

**Rationale**:
- Bundle JSON is hand-readable, must remain diff-friendly
- Append-only avoids breaking unrelated entries
- Overwrite confirmation prevents silent destruction

### D7 — Cross-aggregate readmodels

**Decision**: Support `aggregateRef = "<context-level>"` to mark cross-aggregate readmodels. Codegen places them under `Sources/<Context>/Projector/` (no `Usecase/` layer), matching OC's `OpportunityContext/Projector/` pattern.

**Rationale**:
- OC has 4 cross-aggregate projections (e.g., `GetSelectedServiceItems` spans 2 aggregates)
- Skipping this would force users to artificially file them under one aggregate, fighting OC convention
- Allows `events[]` to mix events from multiple aggregates' `event.yaml`s, as OC does via `event-generator-config.yaml dependencies`

**Skill UX**: in step 2, if user picks `<context-level>`, step 3 shows events from ALL aggregates (clearly labelled which aggregate each event comes from).

### D8 — Relationship to `/presenter` skill (deferred but considered)

**Decision**: `/readmodel` skill v1 does NOT touch ApplicationService / `/presenter` concerns. Bundle field for ApplicationService output shape will be added by `/presenter` skill in its own design pass.

**Implication for `/readmodel` v1**:
- Only collects ReadModel + Projector shape (the storage + projection mechanics)
- ApplicationService skeleton in codegen output is a basic stub — `Get<Noun>Presenter(...).execute(...).readModel` passthrough. `/presenter` skill later fleshes out the DTO transformation.

**Open question for `/presenter` skill discussion**: in OC, the ApplicationService can contain non-trivial logic (cross-projection lookups, validation, DTO mapping). What's the precise `/readmodel` ↔ `/presenter` boundary? Defer to `/presenter` discussion.

### D9 — Codegen side (Genesis renderers) — out of scope for skill spec, but flagged

**Decision**: `/readmodel` skill v1 spec covers SKILL behaviour only. Genesis renderer side (ReadModelRenderer / ProjectionYamlRenderer / JSProjectionRenderer) is a separate task (call it Phase 1.g or 2.a).

**Rationale**:
- Skill writes bundle; bundle codegen is downstream concern with its own scope
- Avoids ballooning this spec into 3 features
- Allows /readmodel skill to ship and be usable for bundle authoring even before full codegen lands

**Tracking**: open a separate task entry post `/readmodel` skill landing. Include: extend `SharedTargetRenderer` or add `ReadModelRenderer`; emit ReadModel.swift / Presenter.swift / projection-model.yaml entry / OC_Get<X>Projection.js per bundle.readModels[] entry.

### D10 — Stream prefix configuration

**Decision**: Stream prefix (OC's `OC_`) lives at **bundle context-level**, NOT per-readmodel.

**Schema addition**: `bundle.context.streamPrefix: "OC_"` (already-existing field if Genesis adapter has it; else new field).

**Rationale**:
- Stream prefix is project-wide invariant — every projection in OC uses `OC_`
- Putting it on each readmodel would invite drift
- Default value if missing: derived from context name (e.g., `IAMContext` → `IAM_`)

### D11 — Acceptance for skill v1

Skill considered complete when:

1. Skill prompt file (`SKILL.md`) exists at `Sources/GenesisCore/Resources/Templates/skills/readmodel/SKILL.md`, conforming to `~/.claude/skills/<name>/SKILL.md` frontmatter format
2. Skill correctly reads a bundle and surfaces aggregates / events as choices
3. Skill writes a valid `readModels[]` entry conforming to D2 schema
4. Bundle JSON validates after write (schema validation passes if schemas added — else round-trip JSON parse passes)
5. Skill aborts cleanly on bundle errors / user cancellation (no partial writes)
6. Integration test: feed test bundle + scripted answers → assert resulting bundle equals expected JSON
7. `genesis install-skills` copies skill into target project's `.claude/skills/readmodel/`
8. (Stretch) Schema validation: bundle.readModels[] entries match a JSON Schema added to `Sources/GenesisCore/Resources/Schemas/` if such mechanism exists

---

## 3. Known limitations (carry into spec)

1. **No payload schema in bundle yet** — events in bundle currently lack payload field definitions in some fixtures (`readmodels-bundle.json` is minimal). Skill must gracefully prompt user when payload info missing. Track schema extension as follow-up.
2. **`/presenter` is sibling, undefined** — skill avoids claiming presenter territory but boundary may shift after `/presenter` discussion.
3. **No `+Query.swift` extension support** — out of scope; users hand-author those post-codegen.
4. **No `ReadModelPersistence` support** — bundle assumes Kurrent replay-on-read; if Genesis later supports stateful read-model stores, schema needs a `storage:` field.
5. **`AskUserQuestion` not universally available** — skill must degrade gracefully to text prompts. Document this limitation in spec.
6. **Existing `~/.claude/skills/readmodel/SKILL.md` (config.md-centric)** is a DIFFERENT tool with overlapping name; users running both inside a Genesis project may be confused. Resolution: Genesis-installed version takes precedence (project-local skills override global). Document this clearly in SKILL.md description.
7. **`genesis new` regeneration after `/readmodel` write** is not part of this skill; users must run regeneration manually. May need `/readmodel` to print a "next step: re-run `genesis new <bundle>`" hint.
8. **Cross-aggregate readmodel directory layout** (D7) requires `genesis new` codegen to support context-level Projector dir; verify Phase 1.b/1.c aggregate-extraction logic handles this. May need a Phase 1.g pre-req.

---

## 4. Decision log

| # | Decision | Rationale (short) |
|---|---|---|
| D1 | Skill writes bundle, not Swift | bundle = SSOT, codegen elsewhere |
| D2 | Bundle readModels[] schema with key/fields/events.payloadKeyField/sourceAggregates | hoist JS↔Swift footgun to single SSOT |
| D3 | 6-step interactive flow using AskUserQuestion | matches user preference |
| D4 | AskUserQuestion multiSelect:true | already locked |
| D5 | Skill at Templates/skills/readmodel/SKILL.md, installed via install-skills | reuse Phase 1.d infra |
| D6 | Append-only bundle write with overwrite confirm | diff-friendly + safe |
| D7 | Cross-aggregate readmodels supported via aggregateRef="<context-level>" | mirrors OC pattern |
| D8 | /presenter is separate skill; /readmodel v1 ignores ApplicationService logic | scope discipline |
| D9 | Renderer side is separate Phase 1.g task | skill is shippable on its own |
| D10 | streamPrefix at context-level, not per-readmodel | project-wide invariant |
| D11 | 8-point acceptance gates v1 | testable / objective |

---

## Next step

→ `/write-spec` for `/readmodel` skill v1 using decisions above. Output to `docs/tasks/2026-05-18-readmodel-skill.md` + registry entry.
