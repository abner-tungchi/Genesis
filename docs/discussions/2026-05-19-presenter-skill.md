# /presenter skill v1 — design discussion

**Date**: 2026-05-19
**Status**: decisions locked, ready for write-spec
**Facts source**: Phase 1.g Gemini investigation (`a835dbfeb3c99a33e`) §4 + Phase 1.h Gemini facts §1（Variant A/B AS shape）
**Related**:
- `2026-05-18-readmodel-skill.json` (done — sibling design-time skill；同 bundle-writing pattern)
- `phase-1g-readmodel-renderer.json` (done — pattern parallel)
- `phase-1h-api-renderer.json` (done — write-side AS scaffold；read-side AS 為 /presenter 對應)
- `phase-1i-api-handler.json` (done — ApiHandler scaffold；/presenter 涉及 read endpoint）

---

## 1. Position vs sibling skills

```
[Design-time skills]
  /readmodel  (DONE)  → bundle.readModels[]  (event → state structure)
  /presenter  (THIS)   → bundle.presenters[]  (state → API output structure)

  Both write bundle JSON only. No code emit. No file reads beyond bundle.

[Codegen renderers]
  Phase 1.g   (DONE)  → ReadModel.swift + Presenter.swift (projector) + JS + yaml
  Phase 1.h+1.i (DONE) → Adapter scaffold for WRITE UCs
  Phase 1.k   (FUTURE) → Adapter scaffold for READ UCs (Get<X>ApplicationService) ← /presenter 解鎖此 phase

[AI fill]
  /api skill v3 (READY) → fill TODO bodies in Phase 1.h+1.i scaffolds
  (future) /presenter-fill — fill Get<X>ApplicationService execute() body if needed
```

---

## 2. OC read-side AS pattern (from Phase 1.g+1.h facts)

對齊 OC `Sources/AuditQuotingAggregate/Adapter/<Get<X>>/<Get<X>>ApplicationService.swift`：

```swift
package struct GetQuotingProofsApplicationServiceInput {
    package let auditQuotingId: String
    // (optional) filter params, e.g. proofType?

    package init(auditQuotingId: String) {
        self.auditQuotingId = auditQuotingId
    }
}

package struct GetQuotingProofsApplicationService: ApplicationService {
    package typealias Input = GetQuotingProofsApplicationServiceInput
    package typealias Output = [QuotingProofDto]   // ← 關鍵差別：read-side output 是 DTO array/struct/scalar

    private let kdbClient: KurrentDBClient        // ← kdbClient 不是 repository（read-side）

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        let presenter = GetQuotingProofsPresenter(
            coordinator: .init(client: kdbClient, eventMapper: GetQuotingProofsEventMapper())
        )
        let result = try await presenter.execute(input: .init(auditQuotingId: input.auditQuotingId))
        return result?.readModel.proofs ?? []      // ← state-to-output 轉換 (AI-fillable in future)
    }
}
```

### Key differences from write-side AS

| Aspect | Write-side (Phase 1.h) | Read-side (`/presenter` 對應) |
|---|---|---|
| Injection | `repository: <A>Repository` | `kdbClient: KurrentDBClient` (no repository — Presenter 用 kdbClient) |
| Output | `<UC>ApplicationServiceOutput { aggregateId: String }` | `[<X>Dto]` / `<X>Dto?` / scalar (per use case) |
| execute() body | construct Service Input + call service.execute | construct Presenter Input + call presenter.execute + map readModel→output |
| API route | POST/PATCH/PUT | GET (read) |
| Path | `/<resource>/{id}/<action>` | `/<resource>/{id}/<view>` 或 collection |
| ApiHandler catch ladder | full (DDDError → 404, mapToApiError → 422, etc.) | similar but no domain Error (read uses `<A>QueryError`); 結構性 differs (see Phase 1.h Gemini facts §2.5 non-standard read handlers) |

### Read-side AS Output 3 種形狀

| Form | Example | Use case |
|---|---|---|
| Array | `[QuotingProofDto]` | list-of-children: 一 readmodel 含 collection |
| Single struct | `AccountingTypeDto` | single composite value |
| Single optional scalar | `String?` | one-of value (extracted from readModel) |

User 在 /presenter skill 中需明示選哪種 + 對應 readModel 取值 path。

---

## 3. Decisions

### D1 — Skill scope (mirror /readmodel)

**Decision**: /presenter skill is **bundle-writing only**：讀 bundle，問 user，append `bundle.presenters[]` 新 entry。**不**寫 Swift / yaml / 任何 codegen artifact。

**Rationale**：
- 跟 /readmodel skill v1 完全對稱
- Codegen 在 future Phase 1.k 處理（讀 bundle.presenters[] → emit Get<X>ApplicationService.swift scaffold + ApiHandler read method）
- 跟 user 早期 "codegen + AI fill 拆法" 一致

### D2 — Bundle `presenters[]` schema

```json
{
  "presenterSpecId": "p-rm-GetQuotingProofs",
  "name": "GetQuotingProofs",                    // 對齊既有 readmodel name (匹配 bundle.readModels[].name)
  "readModelRef": "GetQuotingProofs",            // explicit reference to bundle.readModels[].name
  "aggregateRef": "AuditQuoting",                // copied from readmodel (denormalized for renderer convenience)
  "input": {
    "fields": [
      { "name": "auditQuotingId", "type": "String", "fromPath": "auditQuotingId" }
    ]
  },
  "output": {
    "kind": "array",                              // "array" | "single" | "scalar"
    "elementType": "QuotingProofDto",             // for array/single: DTO type; for scalar: e.g. "String"
    "elementSource": "proofs",                    // readModel field path that produces the output
    "isOptional": false                           // for single/scalar: nullable from readModel
  },
  "endpoint": {
    "path": "/<kebab-A>/{<aggIdName>}/<kebab-presenter-suffix>",  // simplified default; user can override
    "method": "GET"
  },
  "comment": null
}
```

**Field meanings**：
- `name`: bundle-level identifier; convention `Get<Noun>` (match readmodel name)
- `readModelRef`: must exist in bundle.readModels[] (by name)
- `aggregateRef`: must exist in bundle.aggregates[] (denormalized from readmodel)
- `input.fields[]`: AS Input fields; each maps to HTTP path/header/query
- `output.kind`: 3 forms (array/single/scalar)
- `output.elementType`: Swift type name (assumes type exists in bundle.dtos[] or Swift stdlib)
- `output.elementSource`: readModel field path (e.g. `proofs` → `readModel.proofs`; or `accountingType` for single)
- `endpoint.path` / `endpoint.method`: HTTP routing hint (defer enforcement to Phase 1.k codegen)
- `comment`: optional human note

**Skipped (defer v2)**：
- Complex filter / query params (only basic ID path param in v1)
- Multi-readModel join
- Pagination cursor
- Conditional output shape (oneOf at API level)

### D3 — Skill interactive flow (5 steps)

1. **Locate bundle** (same as /readmodel)
2. **Choose readmodel** (`AskUserQuestion` single-select)
   - Options = `bundle.readModels[].name`
   - 若 readmodel 為 empty list → exit 1 with hint「先跑 /readmodel」
3. **Name the presenter**
   - Default = same as readmodel name (e.g. `GetQuotingProofs`)
   - Validate: matches `^Get[A-Z][A-Za-z0-9]+$`，unique within bundle.presenters[]
4. **Choose output shape** (`AskUserQuestion` single-select)
   - Options: `array`, `single`, `scalar`
5. **Configure output details**
   - For `array`: `elementType` (free-form text — typically existing DTO name) + `elementSource` (single-select from readModel.storedFields[] for source field name)
   - For `single`: `elementType` + `elementSource` + `isOptional` (boolean toggle)
   - For `scalar`: `elementType` (e.g. `String`) + `elementSource` + `isOptional`

After all 5 steps:
- Build entry per D2 schema
- Re-serialise bundle JSON
- Single Write call
- Print success + next-step hint「待 Phase 1.k renderer ship 後可 codegen Get<X>ApplicationService」

### D4 — Multi-select / AskUserQuestion

Same convention as /readmodel skill: `AskUserQuestion` for all choice points. Exit 1 if not available.

### D5 — Skill artifact location

`Sources/GenesisCore/Resources/Templates/skills/presenter/SKILL.md` — installed via `genesis install-skills` to project-local `.claude/skills/presenter/`.

### D6 — Bundle write strategy

Same as /readmodel: append-only with duplicate name → overwrite / rename / abort prompt。

### D7 — Cross-aggregate presenter

If `bundle.readModels[].aggregateRef == "<context-level>"`，corresponding /presenter inherits cross-aggregate context. Bundle.presenters[].aggregateRef 同樣可為 `"<context-level>"`。Phase 1.k codegen 將 emit to `Sources/{Context}/Adapter/<Get<X>>/<Get<X>>ApplicationService.swift`.

### D8 — Phase 1.k renderer (defer)

Phase 1.k = Genesis renderer 讀 bundle.presenters[] → 產：
- `Sources/<A>Aggregate/Adapter/<UC>/<UC>ApplicationService.swift` (read-side variant — kdbClient injection, output type per `output.kind`)
- ApiHandler.swift method scaffold for read endpoint (separate from Phase 1.i write methods)
- openapi.yaml read endpoint entry (GET method, response schema from `output.elementType`)

Not in /presenter skill v1 scope.

### D9 — Acceptance

跟 /readmodel skill 同 pattern：
- SKILL.md ≤ 250 lines
- 5-step interactive flow
- Unit test for `PresenterBundleAppender.append(bundle, answers) → FullBundle`
- 3 fixtures: input bundle / answers / expected output
- Manual E2E sign-off

### D10 — Defer to v2

1. Filter / query params (beyond basic ID)
2. Multi-readModel join
3. Pagination
4. Cross-aggregate explicit support (basic in v1 via aggregateRef)
5. Output shape conditional (oneOf)
6. AI-fill skill for execute() body (currently codegen 後 user 手填)

---

## 4. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | Skill writes bundle only | mirror /readmodel pattern |
| D2 | bundle.presenters[] schema with readModelRef + output.kind/elementType/elementSource | enough for codegen v1 |
| D3 | 5-step interactive flow | tighter than /readmodel's 6 (no key field selection) |
| D4 | AskUserQuestion | same as /readmodel |
| D5 | Templates/skills/presenter/SKILL.md | reuse install-skills |
| D6 | Append-only with overwrite confirm | same as /readmodel |
| D7 | Cross-aggregate inherit from readmodel | propagate |
| D8 | Phase 1.k renderer separate task | scope discipline |
| D9 | Acceptance gates same as /readmodel | consistency |
| D10 | 6 known limits | honest |

---

## Next step

→ `/write-spec` /presenter skill v1 using above decisions.
