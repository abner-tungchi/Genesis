---
topic: Phase 1.p — Write-side per-UC DTO support (F7 from dogfood)
status: ready
date: 2026-05-27
origin: workflow discuss-to-impl (3 rounds, consensus reached)
references:
  - Sources/GenesisCore/SwiftTypeResolver.swift:4-8
  - Sources/GenesisCore/TypeOwnershipResolver.swift:3-6
  - Sources/GenesisCore/ApiRenderer.swift:40
  - Sources/GenesisCore/ApiRenderer.swift:53
  - Sources/GenesisCore/ApiRenderer.swift:63
  - Sources/GenesisCore/ApiRenderer.swift:127-130
  - Sources/GenesisCore/DtoRenderer.swift:44
  - Sources/GenesisCore/SharedTargetRenderer.swift:55
  - Sources/GenesisCore/ApiHandlerRenderer.swift:37
  - Sources/GenesisCore/OpenApiYamlRenderer.swift:260
  - Sources/GenesisCore/SourceWriter.swift:25
  - Sources/GenesisCore/Resources/Templates/skills/api/SKILL.md
  - docs/tasks/2026-05-27-phase-1o-hygiene.md (prior phase)
  - OC `Adapter/EditBusinessTaxFilingMethod/BusinessTaxFilingMethodDto.swift` (ground truth)
  - OC `OCShared/AccountingTypeDto.swift` (contextShared example)
  - tests/fixtures/iam-bundle.json:474 (EmployeeStatus enum verification)
  - tests/fixtures/iam-cross-agg-presenter-bundle.json (EmployeeStatus enum verification)
---

# Phase 1.p — Write-side per-UC DTO support (F7 from dogfood)

## 議題定義

### 背景

Layer 2 dogfood re-verify of IAM bundle (2026-05-27, post Phase 1.o.1) confirmed Genesis does NOT codegen write-side per-UC DTOs that OC ground truth has. Concrete example: OC `EditBusinessTaxFilingMethod` UC contains `Adapter/EditBusinessTaxFilingMethod/BusinessTaxFilingMethodDto.swift` with a DTO definition plus 2 `init(from:)` mappers (Domain→DTO and Schema→DTO). Genesis currently only emits `<UC>ApplicationService.swift` with primitive-typed Input fields and no DTO indirection. IAM bundle did not expose this because all UC inputs were String/Int/[String] primitives.

OC ground truth has THREE storage levels for DTOs:
- **per-UC** (1 UC only): `Adapter/<UC>/<X>Dto.swift` — def + both mappers in same file
- **aggregate-shared** (cross UC within aggregate): `Adapter/Dto/<X>Dto.swift` + `Adapter/Dto/<X>Dto+Domain.swift`
- **context-shared** (cross aggregate): `<Context>Shared/<X>Dto.swift` def + ONE gateway-level `<X>Dto+Schema.swift` + per-aggregate `<X>Dto+Domain.swift`

User pre-locked: 2-axis bundle marker (`scope` × `usage`), naming `requestDto/responseDto/both`, Option β (Genesis emits def + Domain mapper, wire/schema mapper deferred to `/api` skill), Cosmogony Event Storming Tool will emit `scope`/`usage`/`useCaseRef` separately.

### 目標

Add write-side per-UC DTO codegen to Genesis so that write UCs with non-primitive Input field types emit (1) a per-UC DTO file containing at minimum the domain `init(from: dto)` mapper, (2) an ApplicationService Input with DTO-typed fields, (3) a structured TODO marker for `/api` skill to wire `init(from:)` calls in execute body. This closes F7 from the 2026-05-27 dogfood findings and unblocks write-side OC alignment for any future UC that takes a custom-type Input.

### 範圍

#### 討論內

- BundleParser: parse new `scope`/`usage`/`useCaseRef` fields; infer for legacy bundles missing them; emit `bundleSchemaVersion:2` sentinel; reserved-name filter (`*ApiError`, `ApiComponents+*`, `*+Schema`, `*+Domain`) rejecting accidental DTO names.
- New `DtoRouter` returning `DtoRoute { scope, definitionLocation, usage, useCaseRef?, aggregateRef? }`. Runs AFTER `TypeOwnershipResolver` and respects its output. Mirrors `TypeOwnershipResolver.warnings` tuple pattern. Default usage = `both` when missing.
- ApiRenderer: emit per-UC DTO files (mapper-only by default; def conditional on `definitionLocation=perUseCase`); change AS Input field type to `<X>Dto` when `DtoRouter` resolves `usage ∈ {request, both}`; emit structured TODO `// genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=<f>, dto=<X>Dto)` in execute body.
- Identity-mapper collision fix at `ApiRenderer.swift:63` — change skip key from `dto.name` to `(useCase?, dto.name)` tuple.
- DTO discovery rule (Q3): `rawType ∈ bundle.dtos[].name ∪ adapter.customTypes[].name AND ∉ SwiftTypeResolver.primitives → DTO-ify`. No `useDto` marker. Allow-list is the existing symbol at `SwiftTypeResolver.swift:4-8`, not duplicated.
- DtoRouter warnings: default one-line stderr summary; `--verbose` opt-in for per-DTO detail.
- Tests: `DtoRouter` unit tests; `ApiRenderer` per-UC mapper-only emission tests; legacy-bundle inference tests; hand-crafted fixture introducing `EmployeeStatus` as write-side input DTO for Gherkin §6.

#### 討論外（Non-goals）

- `/api` skill update for execute-body `init(from:)` call insertion → **Phase 1.p.1** (queued immediately after 1.p).
- Schema mapper emission (wire mapping `<X>Dto ↔ Components.Schemas.<X>`) — deferred until `openapi.yaml` schema is filled by `/api` skill (Phase 1.p.1+).
- `aggregate × *` write-DTO combinations — forbidden via `bundleInvalid` in Phase 1.p; lifted in Phase 1.q.
- `contextShared × request` write-side mapper extension — stubbed-with-`bundleInvalid` in Phase 1.p; lifted in Phase 1.q.
- `perUseCase × response` — forbidden via `bundleInvalid` (no OC counterexample exists).
- Cosmogony Event Storming Tool bundle schema v2 update — parallel separate task under user control, Phase 1.p must NOT block on it.
- Sweeping existing bundles to add `scope`/`usage` — Cosmogony's job.

### 約束

- Single-user, single-project context: dogfood velocity prioritized over deprecation theater.
- Cannot block on Cosmogony bandwidth → BundleParser inference path is the only tested path initially; spec ships hand-crafted fixture.
- Convention over configuration (user prior feedback): no `useDto:true` marker per Input field.
- `TypeOwnership` enum at `TypeOwnershipResolver.swift:3-6` is binary (`.ownedBy` / `.contextShared`); `guard case .ownedBy` at `ApiRenderer.swift:53` would silently drop new cases if enum extended → forbids extending it; mandates separate `DtoRouter`.
- Phase 1.p.1 must follow 1.p promptly — structured TODO is renderer output, not user-facing artifact, but execute body remains semantically empty until 1.p.1 ships.

## 決策紀錄

### D1. Q1 — Backwards compatibility strategy

**Decision**: Option B (infer) + mandatory DtoRouter warnings + `bundleSchemaVersion:2` sentinel + default `usage=both` when missing. BundleParser infers scope from existing fields (`isContextShared=true → contextShared`, `aggregateRef != null → aggregate`, else `perUseCase`). Sentinel makes future hard-fail flip mechanical.

**Rationale**: Unanimous final round. R1 confirms (single-user/single-project makes deprecation overhead). R2 explicitly aligns with majority. R3 locks with note that `/api` skill being schema-mapper emitter mitigates R2's original drift concern.

### D2. Q3 — DTO discovery / which Input fields trigger DTO indirection

**Decision**: Option A type-shape inference. Allow-list imported from `SwiftTypeResolver.primitives` at `Sources/GenesisCore/SwiftTypeResolver.swift:4-8`. Spec MUST reference that symbol, not duplicate the set. Rule: `rawType ∈ bundle.dtos[].name ∪ adapter.customTypes[].name AND ∉ SwiftTypeResolver.primitives → DTO-ify`.

**Rationale**: Unanimous final round. R1 reaffirms convention-over-configuration. R2 explicitly aligns with majority. R3 specifies symbol-level reuse to prevent duplication drift.

### D3. Q4 — perUseCase × request emission contents

**Decision**: Mapper-only by default. DTO definition emitted at per-UC file ONLY if DtoRouter resolves `definitionLocation=perUseCase`. DtoRouter computes `definitionLocation` separately from `scope`. Per-UC file ALWAYS contains `init(from: dto)` extension; def section is conditional. Phase 1.p §6 Gherkin MUST include explicit scenario: "Given UC `createUserAccessProfile` input has field `status: EmployeeStatus` AND `EmployeeStatus` already emitted at `contextShared` scope, When `genesis new` runs, Then `Adapter/CreateUserAccessProfile/EmployeeStatusDto.swift` contains ONLY `extension EmployeeStatus { init(from dto:) }` — no `enum EmployeeStatusDto` redeclaration."

**Rationale**: Unanimous final round. R1 confirms `EmployeeStatus` IS an enum (`iam-cross-agg-presenter-bundle.json`: "This is a Enum") — validates Q4 mapper-only path fires Day 1 of dogfood. R2 explicitly aligns. R3 locks as "the load-bearing decision — EmployeeStatus dogfood breaks otherwise."

### D4. Q6 — /api skill update scope + structured TODO format

**Decision**: Clean phase split. Phase 1.p emits AS execute body with structured TODO comment per DTO-typed field. Exact format: `// genesis-todo(phase=1.p.1, kind=dto-init-from-input, field=<f>, dto=<X>Dto)` — machine-greppable, single-line. Phase 1.p.1 = `/api` skill update for actual `init(from:)` call insertion + future schema mapper. Phase 1.p.1 must be queued immediately after 1.p, not weeks later.

**Rationale**: Unanimous final round. R3 specifies exact greppable format. R1 accepts split with caveat that 1.p.1 must follow promptly to avoid dogfood cost. R2 implicit alignment (no objection).

### D5. Q7 — apiError DTO handling + reserved-name filter

**Decision**: `apiError` stays NOT a bundle DTO. BundleParser adds reserved-name filter rejecting any `dto.name` matching `*ApiError`, `ApiComponents+*`, `*+Schema`, `*+Domain` patterns with `bundleInvalid` error. R3 clarifies: this is GREENFIELD infra at BundleParser, NOT an extension of `SourceWriter` (SourceWriter detects path collisions, not name patterns). Spec author must create the filter at BundleParser.

**Rationale**: Unanimous Round 1 + Round 2 + Round 3. R3's correction on infra location (BundleParser greenfield, not SourceWriter extension) accepted by all.

### D6. Q8 — Schema mapper file naming convention

**Decision**: Per-UC scope: same-file mappers, no suffix (`Adapter/<UC>/<X>Dto.swift`). Cross-cutting scope (`aggregate`/`contextShared`): `+Domain.swift` and `+Schema.swift` suffix files at gateway level. Locks OC convention verbatim.

**Rationale**: Unanimous across all three rounds; no objection final round.

### D7. Q2 — Routing implementation

**Decision**: Option B: new `DtoRouter` returning `DtoRoute { scope, definitionLocation, usage, useCaseRef?, aggregateRef? }` as separate stored fields (NO computed collapse). Do NOT extend `TypeOwnership` enum. Mirror `TypeOwnershipResolver.warnings` tuple pattern. DtoRouter MUST run AFTER TypeOwnershipResolver and respect its output — if router decides `perUseCase` while resolver marked `contextShared`, the def lives at higher scope.

**Rationale**: Unanimous. R3 cites `TypeOwnership` binary enum at `TypeOwnershipResolver.swift:3-6` and `guard case .ownedBy` silent-drop risk at `ApiRenderer.swift:53`. R2 explicitly endorses stored fields. R1 endorses separate fields for spec-audit readability.

### D8. Identity-mapper collision fix

**Decision**: Change skip rule at `ApiRenderer.swift:63` from keying on `dto.name` alone to `(useCase?, dto.name)` tuple where `useCase=nil` for `aggregate`/`contextShared` scope. One-line fix. Apply in Phase 1.p before `perUseCase` ships. R1 spec verification step: `! grep -rn 'skip.*dto\.name' Sources/GenesisCore/` should return zero non-tuple-keyed sites. DtoRenderer audit: R3 found no DtoRenderer in current codebase (ApiRenderer only); R2 verified `DtoRenderer.swift` exists at `Sources/GenesisCore/DtoRenderer.swift` but only renders definitions not mappers — treat as ApiRenderer-only unless spec author finds otherwise during write.

**Rationale**: Unanimous final round. R3 raised originally; R1 endorses with exhaustive grep verification; R2 implicit alignment.

### D9. perUseCase × response handling

**Decision**: Forbid in Phase 1.p. BundleParser emits `bundleInvalid` error with message: "perUseCase × response is unusual; use contextShared or aggregate response scope, or file an OC counterexample to lift this restriction."

**Rationale**: Unanimous across all rounds. No OC counterexample exists; failing loud now is reversible cheaply if one appears.

### D10. Phase 1.p scope boundary — implementation order

**Decision**: Phase 1.p implements `perUseCase × request` first (the dogfood-verifiable scope). `contextShared × request` stubbed-with-`bundleInvalid` (per R1's preference: "Keeps Phase 1.p focused on perUseCase × request which is the verifiable scope"). Other combinations forbidden via `bundleInvalid` with clear error messages naming the restriction. Phase 1.q lifts `contextShared × request` and `aggregate × *` later.

**Rationale**: Unanimous final round. R1 explicit preference for stubbed-with-`bundleInvalid` over silent-stub; R2 and R3 no objection.

### D11. Bundle schema version sentinel

**Decision**: Emit `bundleSchemaVersion:2` in new Cosmogony bundles. BundleParser sets `v1` post-inference for legacy bundles. Phase 1.p+N can flip to hard-fail on missing-or-`v1` mechanically when ready.

**Rationale**: Unanimous; low cost, future-proofs hard-fail migration.

### D12. Cosmogony sequencing

**Decision**: Genesis Phase 1.p ships independent of Cosmogony schema update. BundleParser inference path is the ONLY path tested initially. Spec ships a hand-crafted fixture (R1: "Cannot rely on Cosmogony; spec must ship hand-crafted fixture") introducing `EmployeeStatus` as write-side input DTO for Phase 1.p Gherkin verification. Cosmogony bundle-schema-v2 update is parallel separate task.

**Rationale**: Unanimous. R1's hand-crafted fixture point is critical addition — Phase 1.p cannot block on Cosmogony bandwidth.

### D13. AS Input field type adjustment (Q5)

**Decision**: Domain UseCase Input keeps domain types. AS Input fields swap to DTO type only when DtoRouter resolves `usage ∈ {request, both}` for that field's type. Lookup keyed by explicit DtoRouter result, not heuristic.

**Rationale**: Unanimous across all rounds; matches OC ground truth (`EditBusinessTaxFilingMethodService` domain uses domain type; AS uses Dto type).

### D14. DtoRouter warnings emission — volume management

**Decision**: Default = one-line summary on stderr: "DtoRouter: inferred N DTO routes from legacy bundle (run with `--verbose` for per-DTO detail). Migrate by adding `bundleSchemaVersion:2` + explicit `scope`/`usage`." Per-DTO lines emitted only with `--verbose` flag. Mandatory warning semantics preserved. Spec §3 verification step grep tests both summary and verbose output on legacy-bundle test fixtures.

**Rationale**: Unanimous final round. R1, R2, R3 converge on summary-default + `--verbose` opt-in to prevent alert-fatigue → silent inference drift.

### D15. EmployeeStatus shape — verification target shape

**Decision**: `EmployeeStatus` IS an enum (R1 confirmed via `iam-cross-agg-presenter-bundle.json`: "This is a Enum", fields `activate`/`resigned`). R2 confirms via `iam-bundle.json:474`. This validates Q4 mapper-only path fires Day 1 of dogfood. Phase 1.p §6 Gherkin MANDATORY scenario covers mapper-only emission with `contextShared`-already-emitted def.

**Rationale**: R1 + R2 verified independently in fixtures. R3 risk-side default aligned.

### D16. DtoRoute field naming detail

**Decision**: Keep `scope` and `definitionLocation` as separate stored fields on `DtoRoute` struct. NO computed collapse. R3: "Computed property hides the divergence case that matters for debugging." R1: "Reviewing the route inline must show both at a glance during spec audit."

**Rationale**: Unanimous final round. R2 also explicitly endorses stored fields with optional computed convenience.

### D17. DtoRenderer.swift ripple from identity-mapper fix

**Decision**: `DtoRenderer.swift` exists (R2 verified at `Sources/GenesisCore/DtoRenderer.swift:44`) but only renders DTO definitions, not mappers — so identity-mapper tuple fix is ApiRenderer-only. Spec author must add audit step: grep `DtoRenderer` for any `dto.name` keyed skip logic; if any found, apply same tuple fix.

**Rationale**: R2 file inspection resolves. R3 risk-side: "treat as ApiRenderer-only unless spec author finds otherwise during write." R1 exhaustive-grep verification step covers residual risk.

### D18. SharedTargetRenderer write-DTO coverage today

**Decision**: `SharedTargetRenderer` today emits generic bundle DTO definitions (routing `.contextShared` to `<Ctx>Shared` and `.ownedBy` to `<Agg>Aggregate`) but is NOT write-side/per-UC aware (R2 verified at `SharedTargetRenderer.swift:55`). Phase 1.p scope: keep `SharedTargetRenderer` as-is for `contextShared` definitions. Per-UC mapper emission happens at `ApiRenderer` (with new `DtoRouter` consultation). Aggregate-shared and `contextShared` write-DTO mapper extension is Phase 1.q+ work, stubbed-with-`bundleInvalid` in 1.p per implementation-order decision.

**Rationale**: R2 file inspection: "emits generic bundle DTO definitions today, including owned DTOs, but not write-side per-UC DTO definitions. Phase 1.p needs route-aware definition placement." R1 preference for stubbed-with-`bundleInvalid` keeps phase scope focused. R3 risk-conservative default aligned.

---

## 補丁區 — Post-Cosmogony-v20 amendments (2026-05-29)

Cosmogony v20 ship 後（cross-tool discussion `docs/discussions/2026-05-28-cosmogony-bundle-schema-mismatch.md` line 1101+），Phase 1.p 兩個原 lock 需要更新。

### D19. perReadModel scope 加入 lock + emission strategy（補 D3 + D10）

**Decision**: Phase 1.p D3 原 lock 隱含 3 個 scope value（perUseCase / aggregate / contextShared），現補 lock 第 4 個 **`perReadModel`**（Cosmogony v19 已 emit 此值）。完整 4 scope value set:
- `perUseCase` — 該 DTO 只 1 個 UC 用
- `aggregate` — 跨 UC 但同 aggregate 共用
- `perReadModel` — 該 DTO 只 1 個 read model（projection / query view）用 ← **新加**
- `contextShared` — 跨 aggregate 共用

D4 emission strategy 補 perReadModel cell：

| scope × usage | emission |
|---|---|
| `perReadModel × response` | emit DTO at `<A>Aggregate/Usecase/Projector/<RM>/<DtoName>.swift` + `<A>Aggregate/Usecase/Projector/<RM>/<RM>Presenter.swift` 內加 `init(from domain:)` mapper（response = projection → wire） |
| `perReadModel × request` | **forbid** via `bundleInvalid` — read-side 不應有 request DTO（query 沒 body） |
| `perReadModel × both` | **forbid** via `bundleInvalid` — 同上理由 |

對應 aggregate 從 readModel.aggregateRef 取（Cosmogony v20 derive；v19 + Genesis Phase 1.l.1.1 Option A derive 過渡）。

**Rationale**: Cosmogony team 在 cross-tool discussion 2026-05-28 提出 `perReadModel` 為 v19 schema 第 4 個 scope value（理由：write 側對稱 — write 有 perUseCase / aggregate / contextShared 三層，read 側也該有 perReadModel / contextShared 對齊）。Phase 1.p D3 原 spec 假設只 3 個 scope，沒涵蓋此 case，導致 Genesis Phase 1.l.1.1 Q1 dogfood 撞牆（permissionDto 找不到正確路由）。D19 補 lock 後 Phase 1.p impl 可完整覆蓋 4 scope × 3 usage = 12 cells 的 emission matrix（含 forbid case）。

### D20. D11 supersession — 用既存 `manifestVersion` 取代 `bundleSchemaVersion`

**Decision**: D11 原 lock 「emit `bundleSchemaVersion:2` 為 sentinel」**superseded** — 改用 Cosmogony envelope 既存的 `manifestVersion` 欄位作為 wire-format version gate：
- `manifestVersion: 1`（current）— Phase 1.p 新 fields（scope/usage/aggregateRef/readModelRef/perReadModel）optional，BundleParser 走 inference path
- `manifestVersion: 2`（Cosmogony v22 ship 後）— scope/usage required、ReadModel `aggregateRef` required、ReadModel `key` required，BundleParser strict reject 缺欄位

Genesis BundleParser 邏輯：
```swift
if envelope.manifestVersion >= 2 {
    // strict path: missing fields throw bundleInvalid
} else {
    // optional path: missing fields go through inference / derive (Phase 1.l.1.1 logic)
}
```

**Rationale**: Cosmogony team 在 cross-tool discussion 2026-05-28 line 437-454 指出，Cosmogony envelope 已有 `manifestVersion: 1` 欄位，跟 Genesis 原 D11 提的 `bundleSchemaVersion: 2` 是同一概念。雙處 alias 維護成本不必要。Genesis 改讀 `manifestVersion` 是更乾淨的方案（Cosmogony team line 1118-1119: "Genesis BundleParser 還是看 manifestVersion === 1"，confirmed contract）。

對 Phase 1.p impl 影響：BundleParser 的 strict-vs-optional gate 改用 `envelope.manifestVersion` 比對。其他 spec content（DtoRouter / ApiRenderer / mapper emit）不變。

### D21. Phase 1.p impl 啟動條件 unblocked（補 D12 sequencing）

**Decision**: 原 D12 假設「Phase 1.p ships independent of Cosmogony schema update」。Post-v20 sign-off 後**啟動條件已滿足**：
- Cosmogony v20 ship（aggregateRef derived from outbound Aggregate link）✅ 2026-05-29 main
- Genesis P0 Phase 1.l.1 ship（BundleParser adapter + codegen 注入）✅
- Genesis Phase 1.l.1.1 ship（DTO scope routing + readModel aggregateRef derive）✅

Phase 1.p impl 不必再等 Cosmogony v22 才能開動 — v20 bundle 已可直接 prototype + dogfood。v22 ship 後再加 manifestVersion=2 strict path validation gate（小改動，跟 D20 一致）。

**Rationale**: Cosmogony team 在 cross-tool MD line 1167 "Cosmogony v20 已完成，球在 Genesis 場上" 結論。Phase 1.p impl 啟動 unblock，預估 3-5 天工時（DtoRouter + ApiRenderer scope-aware mapper emit + ContextLevelRenderer extension + 對應 tests）。

## 開放問題

無（全部 locked，含 D19 / D20 / D21 補丁）

## 分歧紀錄（minority opinions）

### Div1. Q1 — Backwards compatibility (Round 1 R2 minority, now reconciled)

- **Final unanimous (R1 + R2 + R3)**: Option B inference + mandatory warnings + `bundleSchemaVersion:2` sentinel + default `usage=both`. R2 explicitly aligned with majority in final round. R3's note: `/api` skill being schema-mapper emitter mitigates R2's original drift concern.
- **Reviewer 2 (Round 1 original, now superseded)**: Option C deprecation period with strict shape inference. Avoid silent shape inference drift between AS Input and OpenAPI request schema. R2 themselves reversed in final round.

### Div2. Q3 — DTO discovery (Round 1 R2 minority, now reconciled)

- **Final unanimous (R1 + R2 + R3)**: Option A type-shape inference with primitive allow-list imported from `SwiftTypeResolver.primitives`. R2 explicitly aligned with majority. R3 specifies symbol-level reuse to prevent duplication drift.
- **Reviewer 2 (Round 1 original, now superseded)**: Hybrid explicit `useDto` marker. Avoid field-shape inference drift. R2 themselves reversed in final round.

### Div3. Q4 — perUseCase × request emission (Round 1 R2 minority + original prompt assumption, now reconciled)

- **Final unanimous (R1 + R2 + R3)**: Mapper-only by default; DTO def conditional on `DtoRouter.definitionLocation=perUseCase`. R1 confirms `EmployeeStatus` IS enum (Day-1 dogfood would break with redeclaration). R2 explicitly aligned with majority. R3: "the load-bearing decision."
- **Original prompt + R2 Round 1 (now superseded)**: DTO def + mapper in same per-UC file. Matched OC file path pattern literally. R2 themselves reversed; original prompt was a strawman.
