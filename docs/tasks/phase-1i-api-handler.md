# Phase 1.i — Genesis OpenAPI infrastructure + ApiHandler/ApiComponents scaffold (Variant A v1)

## 來源

討論：`docs/discussions/2026-05-19-phase-1i-api-handler.md`
Gemini facts (2026-05-19, agent `ab441e44c75c617e9`)：OC openapi.yaml + Package.swift + Operations types 完整 10-section report.

Ground truth refs：
- OC openapi.yaml：`/Users/abnertsai/JiaBao/Mendesky/OpportunityContext/Sources/AuditQuotingAggregate/openapi.yaml` (3100+ lines)
- OC openapi-generator-config.yaml：4 lines verbatim
- OC ApiHandler editEstimatedRevenue：`Sources/AuditQuotingAggregate/Adapter/ApiHandler.swift:464-491` (Variant A canonical)
- OC ApiComponents+AuditQuotingApiError.swift：full file
- OC Package.swift OpenAPI sections：lines 24-35 (deps), 60-77 (aggregate target)
- OC Operations types (plugin-generated)：`Types.swift:7742-7970` (editEstimatedRevenue)

## 目標

擴 Genesis codegen 補完 Phase 1.h 縮 scope 時 defer 的 OpenAPI 基建 + ApiHandler scaffold：

對每 aggregate（含至少 1 write UC）emit 4 個新檔 + 修改 Package.swift：

1. `Sources/<A>Aggregate/openapi.yaml`（per aggregate，含所有 write UC paths + components/schemas + components/responses + components/parameters）
2. `Sources/<A>Aggregate/openapi-generator-config.yaml`（per aggregate）
3. `Sources/<A>Aggregate/Adapter/ApiHandler.swift`（per aggregate，含所有 write UC method scaffold + mapToApiError）
4. `Sources/<A>Aggregate/Adapter/ApiComponents/ApiComponents+<A>ApiError.swift`（per aggregate）

PackageRenderer 擴展：
- Top-level dependencies +2: `swift-openapi-generator`, `swift-openapi-runtime`
- Per aggregate target: +1 dep (`OpenAPIRuntime`)、+2 resources（openapi.yaml + openapi-generator-config.yaml）、+1 plugin (`OpenAPIGenerator`)

**v1 scope**: Variant A simple write UCs only。Variant B / multipart / read / cross-agg / Hummingbird / ID rename / DecimalAmount $ref → defer。

**Real e2e 驗收**：對含 simple write UC bundle 跑 `genesis new` → output project `swift build` PASS（plugin 生 `Operations.X.*` + `Components.Schemas.<A>ApiError`，ApiHandler/ApiComponents 對齊 compile 通過）。

---

## 介面合約

### 新 file

| File | 性質 |
|---|---|
| `Sources/GenesisCore/OpenApiYamlRenderer.swift` | NEW；emit openapi.yaml + openapi-generator-config.yaml per aggregate |
| `Sources/GenesisCore/ApiHandlerRenderer.swift` | NEW；emit ApiHandler.swift + ApiComponents+<A>ApiError.swift per aggregate |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/openapi.yaml.template` | NEW |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/openapi-generator-config.yaml.template` | NEW |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandler.swift.template` | NEW (skeleton w/ mapToApiError) |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerMethod.swift.template` | NEW (per-UC block) |
| `Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiComponentsError.swift.template` | NEW |

### 修改既有 file

| File | 修改 |
|---|---|
| `Sources/GenesisCore/PackageRenderer.swift` | 加 OpenAPI deps + per-aggregate target plugin/resources/dep (擴 Package template + PackageTarget template) |
| `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template` | 加 OpenAPI dependencies block placeholder |
| `Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template` | 加 OpenAPIRuntime dep + openapi resources + OpenAPIGenerator plugin |
| `Sources/Genesis/Commands/NewCommand.swift` | 加 OpenApiYamlRenderer + ApiHandlerRenderer steps；擴 `scanExistingApiPaths` 含新 4 file paths |
| `Sources/GenesisCore/Version.swift` | `0.1.0-phase1i` |

### OpenApiYamlRenderer 公開介面

```swift
public enum OpenApiYamlRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)]
}
```

行為 per aggregate (含至少 1 write UC)：
- emit `Sources/<A>Aggregate/openapi.yaml`（聚合所有 write UC paths）
- emit `Sources/<A>Aggregate/openapi-generator-config.yaml`
- 兩檔 existing → skip (scaffold-once)

純 function of bundle（pattern 同 Phase 1.h ApiRenderer，audit H2 alignment）。

### ApiHandlerRenderer 公開介面

```swift
public enum ApiHandlerRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        adapter: Adapter,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)]
}
```

行為 per aggregate (含至少 1 write UC)：
- emit `Sources/<A>Aggregate/Adapter/ApiHandler.swift`（聚合所有 write UC method）
- emit `Sources/<A>Aggregate/Adapter/ApiComponents/ApiComponents+<A>ApiError.swift`
- 兩檔 existing → skip

### openapi.yaml 結構 (v1 simplified)

```yaml
openapi: 3.1.0
info:
  title: {ContextName} {AggregateName} API
  version: 0.1.0
paths:
{PATH_OPERATIONS}
components:
  parameters:
    {aggIdName}:
      name: {aggIdName}
      in: path
      required: true
      schema:
        type: string
    operatorId:
      name: operatorId
      in: header
      required: true
      schema:
        type: string
  responses:
    NotFoundError:
      description: '404'
      content:
        application/json:
          schema:
            type: object
            required: [error]
            properties:
              error:
                $ref: '#/components/schemas/{A}ApiError'
    UnprocessableEntityError:
      description: '422'
      content:
        application/json:
          schema:
            type: object
            required: [error]
            properties:
              error:
                $ref: '#/components/schemas/{A}ApiError'
    ServiceUnavailableError:
      description: '503'
      content:
        application/json:
          schema:
            type: object
            required: [error]
            properties:
              error:
                $ref: '#/components/schemas/{A}ApiError'
  schemas:
    {A}Id:
      type: object
      required: [{aggIdName}]
      properties:
        {aggIdName}:
          type: string
    {A}ApiError:
      type: string
      enum:
{API_ERROR_CASES}
{REQUEST_SCHEMAS}
```

`{PATH_OPERATIONS}` per write UC：

```yaml
  /{kebab-A}/{<aggIdName>}/{kebab-uc}:
    post:
      operationId: {ucCamel}
      description: 'TODO: describe'
      parameters:
        - $ref: '#/components/parameters/{aggIdName}'
        - $ref: '#/components/parameters/operatorId'
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/{UC}Request'
      responses:
        '200':
          description: 'success'
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/{A}Id'
        '404':
          $ref: '#/components/responses/NotFoundError'
        '422':
          $ref: '#/components/responses/UnprocessableEntityError'
        '503':
          $ref: '#/components/responses/ServiceUnavailableError'
```

`{REQUEST_SCHEMAS}` per write UC：

```yaml
    {UC}Request:
      type: object
      required:
{REQUIRED_FIELDS}
      properties:
{PROPERTY_LINES}
```

`{REQUIRED_FIELDS}`：每 Service Input field (filter `operatorId` + `{aggIdName}`)，`        - <name>` per line.
`{PROPERTY_LINES}`：每 field 一塊：

```yaml
        <name>:
          type: <yaml-type>
```

`<yaml-type>` mapping (v1 simplified per audit D3):
| Swift type | YAML type |
|---|---|
| `String` | `string` |
| `Int` / `Int64` / `UInt` | `integer` |
| `Bool` | `boolean` |
| `Decimal` | `string`  (plain, DecimalAmount $ref defer) |
| `Date` | `string`  (no `format: date-time`, plugin 1.x limit) |
| `[String]` / `Set<String>` | `array` with `items: type: string` |
| 其他 | `string`  (fallback，AI skill 後續 promote) |

`{API_ERROR_CASES}` (per D2)：

```yaml
        - aggregateNotFound
        - invalidPayload
        - invalidDateFormat
        - undefinedDomainError
        - serviceUnavailable
{DOMAIN_ERROR_CASES}      # per bundle.aggregates[].invariants[].errorCode
```

### openapi-generator-config.yaml template

```yaml
generate:
  - types
  - server
accessModifier: package
```

### ApiHandler.swift template (skeleton)

```swift
import DDDCore
import Foundation
import KurrentDB
{SharedImport}


package struct ApiHandler: APIProtocol {

    private let kdbClient: KurrentDBClient
    private var repository: {A}Repository {
        return .init(coordinator: .init(client: kdbClient, eventMapper: {A}AggregateEventMapper()))
    }

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    private func mapToApiError(_ error: Error) -> Components.Schemas.{A}ApiError? {
        if let contextError = error as? ContextError<{A}Error> {
            return .init(from: contextError)
        }
        return nil
    }

{UC_HANDLER_METHODS}
}
```

`{UC_HANDLER_METHODS}` per write UC：

```swift
    package func {ucCamel}(_ input: Operations.{ucCamel}.Input) async throws -> Operations.{ucCamel}.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let {aggIdName} = input.path.{aggIdName}
        let operatorId = input.headers.operatorId

        // TODO(/api skill): unpack `payload` into AS Input fields below
        let asInput = {UC}ApplicationServiceInput(
            {aggIdName}: {aggIdName},
            operatorId: operatorId
            // TODO(/api skill): pass payload fields as additional init args matching AS Input
        )

        let service = {UC}ApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init({aggIdName}: output.{aggIdName}))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }
```

### ApiComponents+<A>ApiError.swift template

```swift
{SharedImport}


extension Components.Schemas.{A}ApiError {
    // TODO: log unmapped domain error when project-wide logging is introduced.
    package init(from error: ContextError<{A}Error>) {
        self = .init(from: error.error) ?? .undefinedDomainError
    }

    package init?(from error: {A}Error) {
        switch error {
{ERROR_CASES_EXHAUSTIVE}
        }
    }
}
```

`{ERROR_CASES_EXHAUSTIVE}` per bundle.aggregates[].invariants[].errorCode (dedup'd)：

```swift
        case .{name}: self = .{name}
```

### PackageRenderer extensions

**Top-level deps (新 placeholder `{OpenApiDependencies}` in Package.swift.template)**：

```swift
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
```

**Per-aggregate target (修改 PackageTarget.swift.template)**：

Dependencies block 加：
```swift
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
```

Resources block (新 placeholder)：
```swift
                .process("openapi.yaml"),
                .process("openapi-generator-config.yaml"),
```

Plugins block 加（既有 plugins 之後）：
```swift
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
```

**Condition**: 只在 aggregate 含至少 1 write UC 時加 OpenAPI 相關 entries。pure write UC == bundle.useCases[].aggregateSpecId matches aggregate AND !isReadUC.

### NewCommand step ordering

```
1. parse bundle
2. AdapterApplier
3. AggregateRenderer loop
4. ContextLevelRenderer
5. SharedTargetRenderer
6. ReadModelRenderer
7. ContextProjectionModelRenderer
8. ApiRenderer (Phase 1.h — AS + DTO)
9. [NEW] OpenApiYamlRenderer (openapi.yaml + openapi-generator-config.yaml)
10. [NEW] ApiHandlerRenderer (ApiHandler.swift + ApiComponents)
11. PackageRenderer (含 Phase 1.i 擴展)
12. SourceWriter plan / commit
13. swift package resolve + build
```

### Output file roles

| Role | File |
|---|---|
| `openapiYaml` | `Sources/<A>Aggregate/openapi.yaml` |
| `openapiGeneratorConfig` | `Sources/<A>Aggregate/openapi-generator-config.yaml` |
| `apiHandler` | `Sources/<A>Aggregate/Adapter/ApiHandler.swift` |
| `apiComponentsError` | `Sources/<A>Aggregate/Adapter/ApiComponents/ApiComponents+<A>ApiError.swift` |

### Scaffold-once paths to scan

NewCommand `scanExistingApiPaths` 擴 (per audit H6 pattern, 同 Phase 1.h scan)：
- `Sources/<A>Aggregate/openapi.yaml`
- `Sources/<A>Aggregate/openapi-generator-config.yaml`
- `Sources/<A>Aggregate/Adapter/ApiHandler.swift`
- `Sources/<A>Aggregate/Adapter/ApiComponents/ApiComponents+<A>ApiError.swift`

---

## 驗收標準

### A1 — 2 renderers + 5 templates exist
```
test -f Sources/GenesisCore/OpenApiYamlRenderer.swift
test -f Sources/GenesisCore/ApiHandlerRenderer.swift
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/openapi.yaml.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/openapi-generator-config.yaml.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandler.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerMethod.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiComponentsError.swift.template
```

### A2 — Version bump
```
grep -F '0.1.0-phase1i' Sources/GenesisCore/Version.swift
! grep -F '0.1.0-phase1h' Sources/GenesisCore/Version.swift
```

### A3 — PackageRenderer 擴展 verifiable
```
grep -F 'swift-openapi-generator' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F 'swift-openapi-runtime' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F 'OpenAPIRuntime' Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template
grep -F 'OpenAPIGenerator' Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template
grep -F 'openapi.yaml' Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template
```

### A4 — Template content sanity
```
grep -F 'openapi: 3.1.0' Sources/GenesisCore/Resources/Templates/v0.1/Api/openapi.yaml.template
grep -F 'aggregateNotFound' Sources/GenesisCore/Resources/Templates/v0.1/Api/openapi.yaml.template
grep -F 'undefinedDomainError' Sources/GenesisCore/Resources/Templates/v0.1/Api/openapi.yaml.template
grep -F 'package struct ApiHandler: APIProtocol' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandler.swift.template
grep -F 'mapToApiError' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandler.swift.template
! grep -F '<Storage' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandler.swift.template
grep -F 'guard case let .json(payload)' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerMethod.swift.template
grep -F 'TODO(/api skill)' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerMethod.swift.template
grep -F 'aggregateNotFound' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiHandlerMethod.swift.template
grep -F 'undefinedDomainError' Sources/GenesisCore/Resources/Templates/v0.1/Api/ApiComponentsError.swift.template
```

### A5 — Unit tests
```
swift test --filter OpenApiYamlRendererTests
swift test --filter ApiHandlerRendererTests
swift test --filter PackageRendererTests
```

涵蓋（OpenApiYamlRenderer）：
- testOpenApiYamlContainsAllWriteUCs
- testOpenApiYamlOmitsReadUCs
- testApiErrorEnumContainsInfraCases (5 個 hardcoded)
- testApiErrorEnumContainsDomainCases (from invariants[].errorCode)
- testRequestSchemaShape (per UC)
- testGeneratorConfigVerbatim
- testScaffoldOnceSkipsExisting

涵蓋（ApiHandlerRenderer）：
- testApiHandlerHasAllWriteUCMethods
- testApiHandlerSkipsReadUCs
- testApiHandlerSkeletonNoStorageGeneric
- testApiHandlerCatchLadderShape (per UC)
- testApiComponentsErrorExhaustiveSwitch
- testScaffoldOnceSkipsExisting

涵蓋（PackageRendererTests）：
- testEmitsOpenAPIGeneratorPluginPerWriteAggregate
- testSkipsOpenAPIPluginForReadOnlyAggregate (defer? — or always emit since aggregate base is assumed to grow write UCs)

### A6 — Full suite green
```
swift test  # 既有 187+ + 新增 ~15 Phase 1.i tests
```

### A7 — Integration: NewCommand 產 4 個新 files
```
swift test --filter NewCommandTests/testApiHandlerScaffoldGenerated
```

assertions：
- `Sources/UserAccessProfileAggregate/openapi.yaml` 存在 + 含 operationId per UC
- `Sources/UserAccessProfileAggregate/openapi-generator-config.yaml` 存在
- `Sources/UserAccessProfileAggregate/Adapter/ApiHandler.swift` 存在含 ApiHandler struct
- `Sources/UserAccessProfileAggregate/Adapter/ApiComponents/ApiComponents+UserAccessProfileApiError.swift` 存在

### A8 — Real e2e swift build (mandatory)
```
GENESIS_RUN_E2E_BUILD=1 swift test --filter NewCommandTests/testApiHandlerE2EBuild
```
or manual via `genesis new` + `swift build`.

預期：
- OpenAPIGenerator plugin 生 `Operations.*` + `Components.Schemas.<A>ApiError` + `APIProtocol`
- ApiHandler conform APIProtocol 通過
- ApiComponents switch 1:1 對齊（domain enum case = openapi enum case 同名）
- AS scaffold (Phase 1.h) 用 fatalError 滿足 type

### A9 — Plugin output verifiable
```
# After genesis new + swift build, check plugin emitted Operations type for at least one UC
test -d /tmp/phase1i-e2e/.build/plugins/outputs/*/UserAccessProfileAggregate/destination/OpenAPIGenerator/GeneratedSources/
grep -F 'package enum Operations' /tmp/phase1i-e2e/.build/plugins/outputs/*/UserAccessProfileAggregate/destination/OpenAPIGenerator/GeneratedSources/Types.swift
```

### A10 — docs ratification
```
grep -F 'Phase 1.i' docs/decisions.md
grep -F 'OpenApiYamlRenderer\|ApiHandlerRenderer' docs/architecture.md
```

### A11 — Scaffold-once (per Phase 1.h H6 pattern)
Unit test 確認：existing `openapi.yaml` / `ApiHandler.swift` / `ApiComponents+*.swift` / `openapi-generator-config.yaml` in `existingPaths` → skip emit。

---

## 失敗路徑

| 場景 | 行為 |
|---|---|
| bundle.useCases[] 為空 | renderer 回 [] outputs |
| Aggregate 無 write UC | per-aggregate skip emit (openapi/handler/components all skipped；no orphan files) |
| bundle.aggregates[].invariants[] 為空 | ApiComponents switch empty (零 case；compile pass for empty enum case path — Swift's exhaustive over empty enum is `default` only or no body needed) |
| existing path collision | scaffold-once skip emit |
| OpenAPIGenerator plugin 缺 (user 改 Package.swift 移除) | swift build fail with explicit message; v1 不偵測 |

---

## 已知限制（v1 narrow scope）

1. **Variant B (`init(from payload:)`) defer Phase 1.i.2**
2. **Multipart upload defer Phase 1.i.2**
3. **Read UCs defer Phase 1.i.2**
4. **Cross-aggregate `mapToApiError` defer Phase 1.i.2**
5. **HTTP method = POST for all v1** — semantics-aware routing defer v2
6. **Path templating simple v1** (`/<kebab-A>/{id}/<kebab-uc>`) — defer v2
7. **Decimal as plain `type: string` v1** — DecimalAmount $ref defer (AI skill promote)
8. **Server target setup defer Phase 2.x** (Hummingbird wire-up)
9. **API↔domain ID rename defer v2**
10. **Bridge extensions defer v2**
11. **Plugin invariant 黑箱信任** — 跟 Phase 1.g/1.h 同 risk profile
12. **`{A}ApiError` enum case 超集 of `<A>Error` cases** — 含 5 infra cases；user 可手動 prune
13. **Empty switch in ApiComponents** — 若 aggregate 無 invariants → switch empty。Swift 規則：`switch error {}` 對 empty enum 是 valid (vacuously exhaustive)；對 non-empty enum compile fail。實作上限制：若 enum 非空但 switch 空 → 需 `default: return nil` fallback。Spec 暫不處理 (v1 假設 aggregate 有 invariants)

---

## 實作步驟

1. 5 templates in `Sources/GenesisCore/Resources/Templates/v0.1/Api/` (4 new + 1 already exists from Phase 1.h reuse？ — 全 new since Phase 1.h 只有 ApplicationService + DtoEnumMapper + DtoStructMapper)
2. `Sources/GenesisCore/OpenApiYamlRenderer.swift` (~250 lines: per-aggregate yaml gen, schema/parameters/responses)
3. `Sources/GenesisCore/ApiHandlerRenderer.swift` (~200 lines: skeleton + per-UC method + ApiComponents)
4. `Sources/GenesisCore/PackageRenderer.swift` — 加 OpenAPI deps + per-aggregate target plugin/resources (conditional on write UCs presence per aggregate)
5. `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template` — 加 `{OpenApiDependencies}` placeholder
6. `Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template` — 加 OpenAPI dep/resource/plugin
7. `Sources/Genesis/Commands/NewCommand.swift` — 加 2 new steps + 擴 scanExistingApiPaths
8. `Sources/GenesisCore/Version.swift` bump
9. New fixture (or reuse iam-readmodel-cross-bundle.json — already has 2 aggregates + Permission UCs)
10. Unit tests: `OpenApiYamlRendererTests.swift` + `ApiHandlerRendererTests.swift` + extend `PackageRendererTests.swift` (~15 tests)
11. `NewCommandTests` 新 case (testApiHandlerScaffoldGenerated + testApiHandlerE2EBuild)
12. Bump existing version-pinned tests `0.1.0-phase1h` → `0.1.0-phase1i`
13. docs/decisions.md + docs/architecture.md §10.8

---

## Sign-off requirements

- [ ] write-spec reviewed
- [ ] audit-spec pass 1 (internal)
- [ ] audit-spec pass 2 (Codex external)
- [ ] decisions.md ratification
- [ ] registry: draft → ready → done

---

## Spec self-check

- [x] 無 line 錨點
- [x] Goals (OpenAPI infra + ApiHandler scaffold) ↔ Non-goals (Variant B/multipart/read/cross-agg/Server) 互斥
- [x] Agent / Human 分段（A1-A11 = Agent runnable；A8 env-gated real build mandatory）
- [x] depends_on: phase-1f (DONE — Shared infra), phase-1h (DONE — AS scaffold)
- [x] 無 ≥N counts (5 templates / 2 renderers / 5 infra cases 為設計常數)
