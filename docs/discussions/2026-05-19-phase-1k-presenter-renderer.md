# Phase 1.k — Genesis PresenterRenderer + read-side codegen

**Date**: 2026-05-19
**Status**: decisions locked, ready for write-spec
**Facts source**: Phase 1.g Gemini §4（read-side AS pattern）+ Phase 1.h facts §1（Variant A shape）
**Related**:
- `2026-05-19-presenter-skill.json` (done — bundle.presenters[] writer)
- `phase-1h-api-renderer.json` (done — write-side AS + DTO)
- `phase-1i-api-handler.json` (done — openapi.yaml + ApiHandler write + ApiComponents)

---

## 1. 範圍

Genesis Phase 1.k 補完 read-side codegen — 解 /presenter skill 寫 bundle.presenters[] entry 後的 codegen 落地：

對每 presenter (per write-aggregate)：
- 🆕 `Sources/<A>Aggregate/Adapter/<presenter.name>/<presenter.name>ApplicationService.swift` (read-side AS scaffold)
- 🆕 Extend `Adapter/ApiHandler.swift` 加 read GET method per presenter (在 Phase 1.i write methods 之後)
- 🆕 Extend `Sources/<A>Aggregate/openapi.yaml` 加 GET endpoint per presenter

對 cross-aggregate (`presenter.aggregateRef == "<context-level>"`) defer v2（與 Phase 1.g.2 對應，但目前 cross-agg AS pattern 較複雜）。

**v1 scope**：
- ✅ Per-aggregate read-side presenters
- ✅ 3 output kinds (array / single / scalar)
- ❌ Cross-aggregate presenters (defer Phase 1.k.2)
- ❌ Read-side `ContextError<<A>QueryError>` mapping (defer Phase 1.k.2 — v1 catch-all fall through `.serviceUnavailable`)
- ❌ Multi-readModel join (defer v2)

---

## 2. OC ground truth (recap)

```swift
// OC: Sources/AuditQuotingAggregate/Adapter/GetQuotingProofs/GetQuotingProofsApplicationService.swift
package struct GetQuotingProofsApplicationServiceInput {
    package let auditQuotingId: String
    package init(auditQuotingId: String) {
        self.auditQuotingId = auditQuotingId
    }
}

package struct GetQuotingProofsApplicationService: ApplicationService {
    package typealias Input = GetQuotingProofsApplicationServiceInput
    package typealias Output = [QuotingProofDto]   // ← per output.kind/elementType

    private let kdbClient: KurrentDBClient        // ← read-side: kdbClient injection

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        let presenter = GetQuotingProofsPresenter(
            coordinator: .init(client: kdbClient, eventMapper: GetQuotingProofsEventMapper())
        )
        let result = try await presenter.execute(input: .init(auditQuotingId: input.auditQuotingId))
        return result?.readModel.proofs ?? []      // ← state-to-output 轉換 (AI/手 fill)
    }
}
```

Read-side ApiHandler method (OC `getQuotingProofs`):
```swift
package func getQuotingProofs(_ input: Operations.getQuotingProofs.Input) async throws -> Operations.getQuotingProofs.Output {
    let auditQuotingId = input.path.auditQuotingId
    let service = GetQuotingProofsApplicationService(kdbClient: kdbClient)
    do {
        let output = try await service.execute(input: .init(auditQuotingId: auditQuotingId))
        return .ok(.init(body: .json(output)))     // ← 直接回 array/single/scalar 為 response body
    } catch {
        if let apiError = mapToApiError(error) {
            return .unprocessableContent(.init(body: .json(.init(error: apiError))))
        }
        return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
    }
}
```

差別 from write-side handler:
- 沒 `guard case let .json(payload)` — read 無 request body
- 沒 `operatorId` extraction (read 不需 operator metadata — actually OC 也是 header；但 v1 skip)
- ApplicationService 用 `kdbClient` 不是 `repository`
- 沒 `.aggregateNotFound` 特殊 catch (read 通常用 `<A>QueryError` 區分，v1 略過)

openapi.yaml GET endpoint:
```yaml
  /audit-quotings/{quotingId}/quoting-proofs:
    get:
      operationId: getQuotingProofs
      parameters:
        - $ref: '#/components/parameters/quotingId'
      responses:
        '200':
          description: 'success'
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/QuotingProofDto'
        '404': ...
        '422': ...
        '503': ...
```

---

## 3. Decisions

### D1 — Phase 1.k 3 個 changes

1. **NEW** `Sources/GenesisCore/PresenterRenderer.swift` — emit read-side AS scaffold per presenter
2. **EXTEND** `Sources/GenesisCore/ApiHandlerRenderer.swift` — emit read GET methods alongside write methods (single ApiHandler.swift per aggregate)
3. **EXTEND** `Sources/GenesisCore/OpenApiYamlRenderer.swift` — emit GET endpoints + response schemas per presenter

### D2 — Read-side AS scaffold shape (per OC)

Template `Templates/v0.1/Api/PresenterApplicationService.swift.template`：

```swift
import Foundation
{SharedImport}

package struct {Name}ApplicationServiceInput {
{INPUT_FIELDS}

    package init({INIT_PARAMS}) {
{INIT_ASSIGNMENTS}
    }
}

package struct {Name}ApplicationService: ApplicationService {
    package typealias Input = {Name}ApplicationServiceInput
    package typealias Output = {OUTPUT_TYPE}

    private let kdbClient: KurrentDBClient

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        // TODO(/presenter-fill skill): fetch via {Name}Presenter (projector) and map readModel.{elementSource} to Output
        // Reference: Sources/<A>Aggregate/Usecase/Projector/{Name}/{Name}Presenter.swift
        fatalError("TODO(/presenter-fill skill): execute body for {Name}ApplicationService")
    }
}
```

**Placeholders**:
- `{Name}`: presenter.name (e.g. `GetQuotingProofs`)
- `{SharedImport}`: `import {Ctx}Shared`
- `{INPUT_FIELDS}` / `{INIT_PARAMS}` / `{INIT_ASSIGNMENTS}`: from presenter.input.fields[]
- `{OUTPUT_TYPE}`: derived from presenter.output:
  - kind=array: `[{elementType}]`
  - kind=single + isOptional=false: `{elementType}`
  - kind=single + isOptional=true: `{elementType}?`
  - kind=scalar + isOptional=false: `{elementType}` (e.g. `String`)
  - kind=scalar + isOptional=true: `{elementType}?`

### D3 — Read-side ApiHandler method shape

ApiHandlerRenderer 新增 helper `renderApiHandlerReadMethod`：

Template `Templates/v0.1/Api/ApiHandlerReadMethod.swift.template`：

```swift
    package func {ucCamel}(_ input: Operations.{ucCamel}.Input) async throws -> Operations.{ucCamel}.Output {
        let {pathParamName} = input.path.{pathParamName}
        _ = {pathParamName}

        let service = {Name}ApplicationService(kdbClient: kdbClient)
        let asInput = {Name}ApplicationServiceInput(
            {pathParamName}: {pathParamName}
        )
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(output)))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }
```

**v1 simplifications**：
- 假設 single path param = `presenter.input.fields[0].name` (對齊 readModel.key.field)
- 沒 `.aggregateNotFound` 特殊 catch (read 無 write-side semantics)
- 沒 query-error catch (defer Phase 1.k.2)

### D4 — openapi.yaml GET endpoint extension

OpenApiYamlRenderer 對每 presenter 新增 path operation：

```yaml
  /<presenter.endpoint.path-stripped>:
    get:
      operationId: <presenter.name (camelCase)>
      description: 'TODO: describe <presenter.name>'
      parameters:
        - $ref: '#/components/parameters/<pathParamName>'
      responses:
        '200':
          description: 'success'
          content:
            application/json:
              schema:
                {RESPONSE_SCHEMA}
        '404':
          $ref: '#/components/responses/NotFoundError'
        '422':
          $ref: '#/components/responses/UnprocessableEntityError'
        '503':
          $ref: '#/components/responses/ServiceUnavailableError'
```

`{RESPONSE_SCHEMA}` per output.kind:

```yaml
# array:
                type: array
                items:
                  $ref: '#/components/schemas/<elementType>'

# single (non-optional):
                $ref: '#/components/schemas/<elementType>'

# single (optional) — same as non-optional in openapi (nullability via 404 response)

# scalar (e.g. String):
                type: string
```

**Note**: response schema 引用 `<elementType>` 假設此 schema 已存在於 openapi.yaml `components/schemas` 中（user 手加 OR future Phase emit from bundle.dtos[]）。

### D5 — operationId mapping

`operationId = ucCamel(presenter.name)` — 對齊既有 Phase 1.i write convention (UC name = lower-camel)。`GetQuotingProofs` → `getQuotingProofs`。

OpenAPIGenerator plugin 依此生成 `Operations.getQuotingProofs.Input/Output`。

### D6 — endpoint path

預設用 `presenter.endpoint.path`（/presenter skill 已在 D7 設定預設 `/<kebab-A>/{<pathParam>}/<kebab-stripGet>`）。

Renderer 不 mutate；directly use `presenter.endpoint.path`。

### D7 — Scaffold-once + scan extension

Phase 1.k 加新 paths to NewCommand `scanExistingApiPaths`：
- `Sources/<A>Aggregate/Adapter/<presenter.name>/<presenter.name>ApplicationService.swift`

`Adapter/ApiHandler.swift` + `openapi.yaml` 既有 path 已被 Phase 1.i scan 覆蓋 — 但 Phase 1.k extension 必須**避免** scaffold-once skip 阻擋 read method append。

**Resolution**: Phase 1.i scaffold-once = entire file skip-if-exists。Phase 1.k 在 existing scaffold + read methods 並存場景 → 整檔 skip 是錯的（會 lose read methods）。

**Decision D7.1**: Phase 1.k 偵測 ApiHandler.swift / openapi.yaml existing 時，**read content, append read sections in-place via marker-based insertion**。

Marker pattern：
- ApiHandler.swift: search `// <-- READ METHODS BELOW -->` marker（若無 → fail-fast with hint「manual repair」）
- OR alternative: if marker missing AND file already has presenters' methods (grep `func <ucCamel>` matches) → skip (idempotent)
- OR cleaner: Phase 1.k v1 走 full-file emit + scaffold-once skip-if-exists; if user wants to add read methods to existing handler → re-run after deleting ApiHandler.swift OR use `--force`

**Simpler v1**: ApiHandlerRenderer extension — when called, 偵測 existing handler containing all expected methods (grep for each useCase + each presenter method) → if present, skip; otherwise emit full new ApiHandler.swift overwriting.

Actually cleanest: **Phase 1.k 不修 Phase 1.i 的 scaffold-once semantics**。Phase 1.i scaffold-once treats ApiHandler.swift as immutable once created. Phase 1.k v1 simply WAIT for user to delete + regenerate, OR Phase 1.k extends Phase 1.i's ApiHandlerRenderer to also consider presenters[] from the start (single first-emit pass covers both write + read).

**Final decision D7**: Phase 1.k = Phase 1.i renderers EXTEND to consume bundle.presenters[]:
- `ApiHandlerRenderer.render` 多 loop bundle.presenters → emit read methods alongside write
- `OpenApiYamlRenderer.render` 多 loop bundle.presenters → emit GET endpoints + response schemas
- Both renderers' scaffold-once unchanged (re-emit when file missing)

**Trade-off**: 若 user 先 ship 只有 useCases 的 project，後加 presenters → Phase 1.k 重新 emit will SKIP（scaffold-once）→ read methods 不會被加。User 需 `--force` regenerate OR delete files。

**v1 acceptable**: 跟 Phase 1.h/1.i 同 H6 limit (scaffold-once is one-shot; subsequent additions need manual)。

### D8 — PresenterRenderer 公開介面

```swift
public enum PresenterRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)]
}
```

Pure function of bundle (no FileManager reads)。對每 `bundle.presenters[]` non-context-level entry：emit AS scaffold。

Cross-aggregate (`aggregateRef == "<context-level>"`) → skip + warn (defer Phase 1.k.2)。

### D9 — NewCommand step ordering

```
1-8: existing (parse → AggregateRenderer → ... → ApiRenderer (1.h) → OpenApiYamlRenderer (1.i) → ApiHandlerRenderer (1.i))
9: [NEW Phase 1.k] PresenterRenderer
   But ApiHandlerRenderer 跟 OpenApiYamlRenderer 都需要 presenters 才能 emit read methods/GET endpoints — 必須把 presenters 信息 push 進去這兩個 renderer。

Actually re-think: Phase 1.k modifies ApiHandlerRenderer + OpenApiYamlRenderer in-place to take bundle.presenters[] into account. PresenterRenderer 是 NEW (read-side AS scaffold)，per presenter emit 1 file。

Final ordering:
8. ApiRenderer (Phase 1.h — write-side AS + DTO)
9. PresenterRenderer (Phase 1.k NEW — read-side AS)
10. OpenApiYamlRenderer (Phase 1.i + extension — write POST + read GET)
11. ApiHandlerRenderer (Phase 1.i + extension — write methods + read methods)
```

### D10 — Version bump

`0.1.0-phase1h` (current) → `0.1.0-phase1k`（jump 1.i→1.k 對齊既有 phase naming）

Wait — current Version is `0.1.0-phase1i` (from Phase 1.i ship). Phase 1.k bumps to `0.1.0-phase1k`. 對 — 沒 Phase 1.j 因 v1 scope 不含 Variant B 等。

### D11 — Known limitations

1. **Cross-aggregate presenter defer Phase 1.k.2** (`aggregateRef == "<context-level>"`)
2. **Read-side query-error mapping defer Phase 1.k.2** (`ContextError<<A>QueryError>`)
3. **Multi-readModel join defer v2**
4. **Multi path param defer v2** (v1 假設 single path param = presenter.input.fields[0])
5. **Filter / query params defer v2**
6. **operatorId header defer v2** (OC read endpoints 多數無 operatorId)
7. **Response schema $ref 假設 elementType 存在 openapi.yaml components/schemas[]** — user 手加 OR future Phase emit from bundle.dtos[]
8. **Scaffold-once limit** — existing ApiHandler.swift / openapi.yaml 不被 append；user 手刪 OR `--force` regenerate
9. **AS execute() body 為 fatalError TODO** — Phase 1.k 不填，留 `/presenter-fill` skill v2 或 user 手填
10. **Plugin invariant 信任** — Phase 1.k 假設 OpenAPIGenerator plugin 對 GET endpoint + response schema 正確 emit `Operations.X.Output.Ok.Body = .json(<ElementType>)`

### D12 — Acceptance gate

Real e2e build mandatory（同 Phase 1.g/1.h/1.i pattern）— 對含 presenter 的 bundle 跑 `genesis new` → `swift build` PASS。

---

## 4. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | 1 new renderer + 2 modifications | scope discipline |
| D2 | Read-side AS = kdbClient injection + Output per kind | mirror OC verbatim |
| D3 | ApiHandler read method = simplified write (no JSON guard, no operatorId) | match OC GET pattern |
| D4 | openapi.yaml GET endpoint per kind output schema | OpenAPI 3.1 compliant |
| D5 | operationId = camelCase(presenter.name) | plugin convention |
| D6 | endpoint path from presenter.endpoint.path | /presenter skill 已預設 |
| D7 | ApiHandlerRenderer + OpenApiYamlRenderer extend with presenters loop | one-shot emit (no append) |
| D8 | PresenterRenderer 公開介面同 pattern (pure function) | consistency |
| D9 | NewCommand step order 9 PresenterRenderer | scaffold-once 內 |
| D10 | Version → 0.1.0-phase1k | manifest convention |
| D11 | 10 known limits | scope discipline |
| D12 | Real e2e build mandatory | plugin invariant |

---

## Next step

→ `/write-spec` Phase 1.k using above decisions.
