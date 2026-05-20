# Phase 1.k — Genesis PresenterRenderer + read-side codegen

## 來源

討論：`docs/discussions/2026-05-19-phase-1k-presenter-renderer.md`
Phase 1.g Gemini facts §4 (read-side AS) + Phase 1.h facts §1 (Variant A shape)

Ground truth refs：
- OC read-side AS: `OpportunityContext/Sources/AuditQuotingAggregate/Adapter/GetQuotingProofs/GetQuotingProofsApplicationService.swift`
- OC read-side ApiHandler method: `ApiHandler.swift:28-51` (`getQuotingProofs`)
- OC openapi.yaml GET pattern: `Sources/AuditQuotingAggregate/openapi.yaml` (multiple `get:` entries)

## 目標

擴 Genesis codegen 補完 read-side scaffold — 解 /presenter skill 寫的 `bundle.presenters[]` entry codegen 落地：

對每 per-aggregate presenter:
1. emit `Sources/<A>Aggregate/Adapter/<presenter.name>/<presenter.name>ApplicationService.swift` (read-side AS scaffold with `kdbClient` injection, Output per output.kind)
2. extend `Adapter/ApiHandler.swift` 加 read GET method
3. extend `openapi.yaml` 加 GET endpoint + response schema

**v1 scope**:
- Per-aggregate presenters (`aggregateRef == <aggName>`)
- 3 output kinds (array / single / scalar)
- Single path param assumption

**Defer Phase 1.k.2 / v2**:
- Cross-aggregate presenters (`aggregateRef == "<context-level>"`)
- `ContextError<<A>QueryError>` mapping
- Multi-readModel join
- Multi-path-param / filter params
- operatorId header for read endpoints
- Response schema $ref 對應 DTO auto-emit (assume user 手加 to openapi.yaml's components/schemas[] OR future Phase)

**Real e2e 驗收**：對含 presenter 的 bundle 跑 `genesis new` → output project `swift build` PASS (plugin 生 `Operations.<getX>.Output` 含 `.ok(.init(body: .json(<ElementType>)))` variant，ApiHandler conform 通過)。

---

## 介面合約

### 新 file

| File | 性質 |
|---|---|
| `Sources/GenesisCore/PresenterRenderer.swift` | NEW；read-side AS scaffold per presenter |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template` | NEW |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template` | NEW |

### 修改既有 file

| File | 修改 |
|---|---|
| `Sources/GenesisCore/ApiHandlerRenderer.swift` | extend `render()` 加 presenters loop → emit read methods alongside write methods |
| `Sources/GenesisCore/OpenApiYamlRenderer.swift` | extend `renderOpenApiYaml()` 加 GET path operations per presenter + response schemas |
| `Sources/Genesis/Commands/NewCommand.swift` | 加 PresenterRenderer step (在 ApiRenderer 後、OpenApiYamlRenderer + ApiHandlerRenderer 前)；擴 `scanExistingApiPaths` 含 read-side AS paths |
| `Sources/GenesisCore/Version.swift` | `0.1.0-phase1k` |

### PresenterRenderer 公開介面

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

行為:
1. 遍歷 `bundle.presenters[]`
2. Skip cross-aggregate (`aggregateRef == "<context-level>"`) + warn
3. 對每 per-aggregate presenter:
   - 計算 `outputType` from `presenter.output.kind/elementType/isOptional`
   - Render template + emit `Sources/<aggregateRef>Aggregate/Adapter/<presenter.name>/<presenter.name>ApplicationService.swift`
4. Scaffold-once: existing path → skip

### Output type derivation rule

| kind | isOptional | Output |
|---|---|---|
| `array` | any | `[<elementType>]` |
| `single` | false | `<elementType>` |
| `single` | true | `<elementType>?` |
| `scalar` | false | `<elementType>` |
| `scalar` | true | `<elementType>?` |

### Read-side AS template

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
        // Reference: Sources/<aggregateRef>Aggregate/Usecase/Projector/{Name}/{Name}Presenter.swift
        fatalError("TODO(/presenter-fill skill): execute body for {Name}ApplicationService")
    }
}
```

`{INPUT_FIELDS}` per `presenter.input.fields[]`: `    package let <name>: <type>`
`{INIT_PARAMS}` per field: `<name>: <type>` comma-separated
`{INIT_ASSIGNMENTS}` per field: `        self.<name> = <name>`

### ApiHandlerRenderer extension (read method)

After write methods loop, add presenters loop:

```swift
let presentersForAggregate = bundle.presenters.filter { $0.aggregateRef == aggregate.name }
for presenter in presentersForAggregate {
    let methodContent = renderApiHandlerReadMethod(presenter: presenter, contextName: contextName)
    methods.append(methodContent)
}
```

Read method template:

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

`{ucCamel}` = `camelCase(presenter.name)` (e.g. `GetQuotingProofs` → `getQuotingProofs`)
`{Name}` = `presenter.name` (PascalCase)
`{pathParamName}` = `presenter.input.fields[0].name` (assume single path param; v1)

### OpenApiYamlRenderer extension (GET endpoint)

After write UC path operations loop, add presenters loop emitting GET operations:

```yaml
  <presenter.endpoint.path>:
    get:
      operationId: <ucCamel(presenter.name)>
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

`{RESPONSE_SCHEMA}` per `presenter.output.kind`:

```yaml
# kind=array:
                type: array
                items:
                  $ref: '#/components/schemas/<elementType>'

# kind=single (any isOptional):
                $ref: '#/components/schemas/<elementType>'

# kind=scalar:
                type: <yaml-type from elementType>
```

`<yaml-type>` for scalar uses same mapping as Phase 1.i `yamlType()` function (`String → string`, `Int → integer`, etc.).

**Note**: response schema $ref 假設 `<elementType>` 已存在 components/schemas[] (user-authored OR future-emitted)。Phase 1.k 不自動加 elementType 到 components — defer。

### NewCommand step ordering

```
1-7: existing
8. ApiRenderer (Phase 1.h — write-side AS + DTO)
9. [NEW] PresenterRenderer (Phase 1.k — read-side AS scaffold)
10. OpenApiYamlRenderer (Phase 1.i + 1.k extension — write POST + read GET)
11. ApiHandlerRenderer (Phase 1.i + 1.k extension — write methods + read methods)
12. PackageRenderer / ManifestRenderer
13. SourceWriter plan / commit
14. swift package resolve + build
```

### scaffold-once paths to scan

NewCommand `scanExistingApiPaths` 擴：
- Phase 1.k addition: `Sources/<A>Aggregate/Adapter/<presenter.name>/<presenter.name>ApplicationService.swift`（per presenter）
- Phase 1.i existing scans 已 cover ApiHandler.swift / ApiComponents / openapi.yaml (但這些檔 Phase 1.k extension 透過 ApiHandlerRenderer + OpenApiYamlRenderer 重新 emit；scaffold-once 仍是 file-level)

**Trade-off**: 若 Phase 1.i 已 emit ApiHandler.swift (write-only)，後 user 加 presenter 再 regenerate → Phase 1.k ApiHandlerRenderer scaffold-once skip → read methods 不被加。User 需 `--force` OR 手刪。**v1 acceptable** (per Phase 1.h/1.i limit echo)。

### Cross-aggregate presenter (defer Phase 1.k.2)

```swift
if presenter.aggregateRef == "<context-level>" {
    // Skip emit + warn; defer Phase 1.k.2
    continue
}
```

不 throw — silent skip + console warn (per /presenter skill design)。

### Output file roles

| Role | File |
|---|---|
| `presenterApplicationService` | `Sources/<A>Aggregate/Adapter/<Name>/<Name>ApplicationService.swift` |

ApiHandlerRenderer + OpenApiYamlRenderer existing roles 不變 (single file per aggregate, 合 write + read content)。

---

## 驗收標準

### A1 — Renderer + 2 templates exist
```
test -f Sources/GenesisCore/PresenterRenderer.swift
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template
```

### A2 — Version bump
```
grep -F '0.1.0-phase1k' Sources/GenesisCore/Version.swift
! grep -F '0.1.0-phase1i' Sources/GenesisCore/Version.swift
```

### A3 — Template content sanity
```
# Read-side AS template:
grep -F 'package struct {Name}ApplicationService: ApplicationService' Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template
grep -F 'kdbClient: KurrentDBClient' Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template
grep -F 'TODO(/presenter-fill skill)' Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template
grep -F 'fatalError' Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template
! grep -F 'repository' Sources/GenesisCore/Resources/Templates/v0.1/Api/PresenterApplicationService.swift.template  # read-side: kdbClient not repository

# Read method template:
grep -F '_ = {pathParamName}' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template
grep -F '(kdbClient: kdbClient)' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template
! grep -F 'guard case let .json(payload)' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template  # read: no body unwrap
grep -F '.serviceUnavailable' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerReadMethod.swift.template
```

### A4 — Unit tests
```
swift test --filter PresenterRendererTests
swift test --filter ApiHandlerRendererTests
swift test --filter OpenApiYamlRendererTests
```

涵蓋 (PresenterRenderer):
- testHappyPathArrayOutput (Output = [QuotingProofDto])
- testHappyPathSingleOutputOptional (Output = AccountingTypeDto?)
- testHappyPathScalarOutput (Output = String?)
- testCrossAggregateSkipped (aggregateRef = <context-level> → not emitted)
- testScaffoldOnceSkipsExisting

涵蓋 (ApiHandlerRenderer 擴展):
- testHandlerIncludesBothWriteAndReadMethods (per aggregate)
- testReadMethodNoJsonGuard
- testReadMethodCatchLadder

涵蓋 (OpenApiYamlRenderer 擴展):
- testYamlIncludesGetEndpointsForPresenters
- testGetEndpointResponseSchemaArray
- testGetEndpointResponseSchemaSingle
- testGetEndpointResponseSchemaScalar

### A5 — Full suite green
```
swift test  # 既有 200 tests + 新增 ~12 tests
```

### A6 — Integration: NewCommand 產 read-side files

對 fixture iam-readmodel-cross-bundle.json (有 readmodels；需手加 1+ presenter for Phase 1.k test) OR 新 fixture `iam-presenter-bundle.json`：

```
swift test --filter NewCommandTests/testPresenterScaffoldGenerated
```

assertions：
- `Sources/<A>Aggregate/Adapter/<Name>/<Name>ApplicationService.swift` 存在
- 內含 `kdbClient: KurrentDBClient` (read-side)
- 內含 `fatalError("TODO(/presenter-fill skill)")`
- `ApiHandler.swift` 含 read method (per presenter)
- `openapi.yaml` 含 GET endpoint (per presenter)

### A7 — Real e2e swift build (MANDATORY)

```
GENESIS_RUN_E2E_BUILD=1 swift test --filter NewCommandTests/testPresenterE2EBuild
```
or manual via `genesis new` + `swift build`。

預期：
- OpenAPIGenerator plugin 生 `Operations.<getX>.Output` 含 `.ok` variant with `.json(<ElementType>)` body
- ApiHandler read method conform `APIProtocol`
- Read-side AS scaffold compile (fatalError body 滿足 type)

### A8 — docs ratification
```
grep -F 'Phase 1.k' docs/decisions.md
grep -F 'PresenterRenderer' docs/architecture.md
```

### A9 — Scaffold-once skip

Unit test confirm: existing PresenterApplicationService path in existingPaths → skip emit。

### A10 — Cross-aggregate silent skip

Unit test: presenter with `aggregateRef == "<context-level>"` → renderer 不 emit (warn but no throw)。

---

## 失敗路徑

| 場景 | 行為 |
|---|---|
| bundle.presenters[] 為空 | renderer 回 [] outputs |
| presenter.readModelRef 不存在 in bundle.readModels[] | already enforced by /presenter skill bundle write; defensive check in renderer → skip + warn |
| presenter.aggregateRef 不存在 in bundle.aggregates[] | defensive check → skip + warn (per /presenter skill validate已 enforce) |
| presenter.aggregateRef == "<context-level>" | skip + warn (defer Phase 1.k.2) |
| existing path in existingPaths | scaffold-once skip emit |
| openapi.yaml elementType $ref 對應 schema 不存在 | swift build fail at user end with explicit message (user 手加 to openapi.yaml components or wait future Phase) |

---

## 已知限制 (per discussion D11)

1. **Cross-aggregate presenter defer Phase 1.k.2** — silently skip
2. **Read-side `ContextError<<A>QueryError>` defer Phase 1.k.2** — v1 catch-all 落到 .serviceUnavailable
3. **Multi-readModel join defer v2**
4. **Multi-path-param defer v2** — v1 假設 single path param = `presenter.input.fields[0].name`
5. **Filter/query params defer v2**
6. **operatorId header for read defer v2**
7. **Response schema elementType $ref 假設存在** — user 手加 OR future Phase emit
8. **Scaffold-once limit** — re-emit on existing files 不 append (need `--force` OR delete)
9. **AS execute() body fatalError TODO** — defer `/presenter-fill` skill v2
10. **Plugin invariant 信任** — OpenAPIGenerator GET endpoint 必須生對應 `Operations.<X>.Output.Ok.Body = .json(<ElementType>)` variant

---

## 實作步驟（for /pickup）

1. 2 templates in `Templates/v0.1/Api/`
2. `Sources/GenesisCore/PresenterRenderer.swift` (~150 lines)
3. Extend `Sources/GenesisCore/ApiHandlerRenderer.swift` — 加 renderApiHandlerReadMethod + presenters loop
4. Extend `Sources/GenesisCore/OpenApiYamlRenderer.swift` — 加 GET path operations + response schema per presenter
5. Wire `NewCommand.swift` — 加 PresenterRenderer step + extend scan
6. Bump `Version.swift`
7. New fixture (or extend existing) for integration tests — must have at least 1 presenter
8. `PresenterRendererTests.swift` (~10 tests)
9. Extend `ApiHandlerRendererTests` + `OpenApiYamlRendererTests` 加 presenter assertions
10. NewCommandTests integration + real e2e build
11. Bump existing version-pinned tests
12. docs/decisions.md + docs/architecture.md §10.10

---

## Sign-off requirements

- [ ] write-spec reviewed (this v1)
- [ ] audit-spec pass 1 (internal)
- [ ] audit-spec pass 2 (Codex external — defer if empty output again)
- [ ] decisions.md ratification
- [ ] registry: draft → ready → done

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals (read-side AS scaffold + ApiHandler read + openapi GET) ↔ Non-goals (cross-agg / query-error / multi-readmodel / filter params) 互斥
- [x] depends_on: 2026-05-19-presenter-skill (DONE) + phase-1h (DONE) + phase-1i (DONE)
- [x] A1-A10 全 Agent runnable；A7 = env-gated real build
- [x] 10 known limits 不與 acceptance 衝突
