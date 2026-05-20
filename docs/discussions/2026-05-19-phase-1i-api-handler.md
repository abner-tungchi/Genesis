# Phase 1.i — Genesis OpenAPI infrastructure + ApiHandler/ApiComponents scaffold

**Date**: 2026-05-19
**Status**: decisions locked, ready for write-spec
**Facts source**: Gemini 2026-05-19 agent `ab441e44c75c617e9`
**Related**:
- `phase-1h-api-renderer.json` (done — AS scaffold + DTO mapper已 ship；Phase 1.i 補完 deferred 部分)
- `2026-05-18-api-skill.json` (status: ready；Phase 1.i 完後 revise → AI fill TODOs)
- `phase-1f-context-shared-infra.json` (done — `{Ctx}Shared/ApplicationService.swift`)

---

## 1. 範圍：補完 Phase 1.h 縮 scope 時 defer 的所有項目

Phase 1.h 已 ship：
- ✅ `<UC>ApplicationService.swift` scaffold (Variant A simple)
- ✅ DTO mapper (enum full / struct scaffold)
- ✅ DTO schema extension (dtoKind, cases, etc.)
- ✅ Conditional Shared emit
- ✅ Pure function of bundle

Phase 1.i 補：
- 🆕 `Sources/<A>Aggregate/openapi.yaml` stub emission (from bundle)
- 🆕 `Sources/<A>Aggregate/openapi-generator-config.yaml`
- 🆕 PackageRenderer 加 swift-openapi-* deps + OpenAPIGenerator plugin + resources
- 🆕 `Sources/<A>Aggregate/Adapter/ApiHandler.swift` scaffold (per aggregate)
- 🆕 `Sources/<A>Aggregate/Adapter/ApiComponents/ApiComponents+<A>ApiError.swift` scaffold

---

## 2. OC facts highlights (per Gemini investigation)

### 2.1 openapi.yaml 命名修正

**OC 用 per-aggregate `<A>ApiError` 不是 `<Ctx>ApiError`**：
- `AuditQuotingApiError` (file `ApiComponents+AuditQuotingApiError.swift`)
- `CompanyRegistrationQuotingApiError`
- 不是 `OpportunityContextApiError`

→ Phase 1.i 用 `<A>ApiError` (e.g. `UserAccessProfileApiError`)。修正 Phase 1.h 既有 spec 的 `{Ctx}ApiError` 命名錯誤（順帶在 Phase 1.h impl 內處理過 `<Ctx>ApiError` 但實際 IAM 範例只有 1 aggregate，沒踩雷）。

### 2.2 openapi.yaml 結構模式

每 aggregate 一個 openapi.yaml：

```yaml
openapi: 3.1.0
info: {title, version}
paths:
  /<resource>/{<aggId>}/<uc-path>:
    <method>:
      operationId: {ucCamel}
      parameters:
        - $ref: '#/components/parameters/<aggId>'    # in: path, shared
        - $ref: '#/components/parameters/operatorId' # in: header, shared
      requestBody:
        required: true
        content:
          application/json:
            schema: { type: object, properties: {...inline...} }
      responses:
        '200': inline JSON
        '404': $ref shared NotFoundError
        '422': $ref shared UnprocessableEntityError
        '503': $ref shared ServiceUnavailableError
components:
  parameters:
    <aggId>: { in: path, ... }     # shared
    operatorId: { in: header, ... } # shared
  responses:
    NotFoundError: { content: { application/json: { schema: { error: <A>ApiError } } } }
    UnprocessableEntityError: ...
    ServiceUnavailableError: ...
  schemas:
    DecimalAmount: { type: string, pattern: ... }  # Decimal-as-String 避 plugin 1.x 限制
    <A>Id: { type: object, required: [<aggId>], properties: { <aggId>: { type: string } } }
    <A>ApiError: { type: string, enum: [...] }
    # ...per-UC Request schemas
```

### 2.3 `<A>ApiError` enum cases 不從 `<A>Error` 直接 derive

OC `AuditQuotingApiError` 含：
- Curated subset of `<A>Error` cases（user-actionable，不含結構性 cases）
- Query error cases (`<A>QueryError`) 若有 read side
- **Infra cases**：`aggregateNotFound`, `invalidPayload`, `invalidDateFormat`, `undefinedDomainError`, `serviceUnavailable`

但 ApiComponents+ApiError.swift 的 `init?(from: <A>Error)` switch 必須 **exhaustive over ALL `<A>Error` cases** — 不對應的 enum case 走 `return nil // TODO`.

### 2.4 Variant A handler 6 blocks (verbatim)

per Gemini §6：
1. JSON-body unwrap (`guard case let .json(payload)`)
2. Extract path + header params
3. (optional inline) Decimal parse with fallback to `.invalid<Field>`
4. Construct ApplicationService + execute
5. `DDDError.aggregateNotFound → .notFound`
6. Catch-all → `mapToApiError` or `.serviceUnavailable`

每 block 內某些行 byte-identical（catch ladder），某些 placeholder（response constructor, AS Input field list）。Codegen 可填全部 framework, leave AI 填 payload→AS 轉換 + response field 注入.

### 2.5 Package.swift OpenAPI sections

每 aggregate target 加：
- Dependency: `.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")`
- Resources: `.process("openapi.yaml")` + `.process("openapi-generator-config.yaml")`
- Plugin: `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")`

Top-level package 加 4 dependencies：
- `swift-openapi-generator` (>=1.0.0)
- `swift-openapi-runtime` (>=1.0.0)
- `swift-openapi-hummingbird` (>=2.0.1) — **for Server target**
- `hummingbird` (>=2.14.0) — **for Server target**

Phase 1.i v1 不需 Server target setup（user 後續 wire）。`swift-openapi-hummingbird` + `hummingbird` 加進 dependencies 但不 link to aggregate target — 留給 future Server scaffold。

---

## 3. Decisions

### D1 — Phase 1.i scope (Variant A simple write UC only)

emit 5 categories per write UC + per aggregate：
1. `openapi.yaml` (per aggregate，含所有 write UC + components/schemas + components/responses)
2. `openapi-generator-config.yaml` (per aggregate)
3. PackageRenderer 擴 deps + per-aggregate target plugin/resources
4. `ApiHandler.swift` scaffold (per aggregate，含所有 write UC method)
5. `ApiComponents+<A>ApiError.swift` (per aggregate)

**Defer Phase 1.i.2 / v2**：
- Variant B `init(from payload:)` extension
- Multipart upload (`<Storage>` generic, `multipartForm` switch)
- Read UCs (`ContextError<<A>QueryError>` mapping)
- Cross-aggregate `mapToApiError` 多 branch (Quotation pattern)
- API↔domain ID rename (`customizedReportingId` ↔ `reportId`)
- Server target scaffold (Hummingbird wire-up)
- DecimalAmount-based Decimal parsing inline in handler (v1 emit String → AI skill 添加 `Decimal(string:)` guard)

### D2 — `<A>ApiError` enum cases derivation

**v1 strategy**: Emit ALL `<A>Error.swift` cases + 5 infra cases。

來源：bundle.aggregates[].invariants[].errorCode (與 Phase 1.e `<A>Error.swift` 生成 SSOT 對齊)。

5 個 infra cases hardcoded：
```yaml
- aggregateNotFound
- invalidPayload
- invalidDateFormat
- undefinedDomainError
- serviceUnavailable
```

**Rationale**：
- ApiComponents switch 1:1 codegen 不會 build fail（每 domain case 都有對應 openapi case）
- User 可以後續手動 prune unreachable cases (從 openapi enum 移除，然後手改 switch 為 `return nil // TODO`)
- 比 OC 的 hand-curated 更 conservative，但 OK for v1 starting point
- AI fill skill 後續可協助 curation

### D3 — openapi.yaml 結構 v1 simplifications

**v1 emit**:
- HTTP method = `post` for all (簡化；OC 用 `patch`/`put`/`post`/`delete`/`patch` 取決於 semantics)
- Path = `/<lower-kebab-aggName>/{<aggId>}/<lower-kebab-ucName>` (simple template)
- Request body schema: inline `type: object` from `useCase.input` (excluding operatorId + aggId)
- Response 200: $ref `#/components/schemas/<A>Id` (echo aggregate id back，simplification)
- Response 404/422/503: $ref shared

**Defer v2**:
- HTTP method routing based on UC semantics (POST for `add*`/`create*`/`upload*`, PATCH for `edit*`, DELETE for `delete*`, etc.)
- Path templating per UC (現在簡單 `/<resource>/{id}/<uc>`)
- Response schemas per-UC variation
- DecimalAmount schema $ref（v1 用 plain `type: string` for Decimal — AI skill 後續 promote）

### D4 — ApiHandler.swift scaffold shape (v1 simple Variant A)

```swift
import DDDCore
import Foundation
import KurrentDB
import {Ctx}Shared


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

`{UC_HANDLER_METHODS}` 每 write UC 一 block:

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

⚠️ **No `<Storage>` generic in v1**（per Phase 1.h audit M5 + 1.i scope; multipart defer v2）

### D5 — ApiComponents+<A>ApiError.swift scaffold

```swift
import {Ctx}Shared


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

`{ERROR_CASES_EXHAUSTIVE}`：每 bundle.invariants[].errorCode 一行 `        case .{name}: self = .{name}`。

### D6 — PackageRenderer extensions

加 dependencies 區（top-level + 3 new packages）：
```swift
.package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
.package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
```
（不加 hummingbird / openapi-hummingbird — defer Server target）

每 aggregate target：
- Dependencies +1: `.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")`
- Resources +2: `openapi.yaml` + `openapi-generator-config.yaml`
- Plugins +1: `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")`

### D7 — Scaffold-once

ApiHandler.swift + ApiComponents+<A>ApiError.swift + openapi.yaml + openapi-generator-config.yaml：existing 不 overwrite (per audit H6 pattern)。

NewCommand `scanExistingApiPaths` 擴：原來只掃 Adapter/<UC>/* 跟 Adapter/Dto/*；新加 Adapter/ApiHandler.swift + Adapter/ApiComponents/ApiComponents+*.swift + openapi.yaml + openapi-generator-config.yaml.

### D8 — Output file paths

```
Sources/<A>Aggregate/openapi.yaml                                # NEW
Sources/<A>Aggregate/openapi-generator-config.yaml               # NEW
Sources/<A>Aggregate/Adapter/ApiHandler.swift                    # NEW (per aggregate)
Sources/<A>Aggregate/Adapter/ApiComponents/ApiComponents+<A>ApiError.swift   # NEW (per aggregate)
```

### D9 — Version bump

`0.1.0-phase1h` → `0.1.0-phase1i`

### D10 — Real e2e build expectation

跟 Phase 1.g/1.g.2 同 pattern — 真 `swift build` 必須 PASS：
- OpenAPIGenerator plugin 生 `Components.Schemas.*`、`Operations.*`、`APIProtocol`
- ApiHandler scaffold conform APIProtocol
- ApiComponents switch 1:1 對齊（每 `<A>Error` case 都有對應 `<A>ApiError` case，因為 codegen 同步 emit 兩邊）
- AS scaffold 用 fatalError 滿足 type

### D11 — Plugin invariant 風險

跟 Phase 1.g `ModelGeneratorPlugin` 同等級風險：spec 寫對 ≠ build pass。Mitigation：
- 寫 OC ground truth verbatim shape (openapi.yaml schema、generator-config）
- Real e2e build 是強制 acceptance gate
- 失敗 → 用 OC `Types.swift` plugin output 比對 debug

### D12 — Known limitations

1. **Variant B defer v2**：Phase 1.h+1.i 都不 support `init(from payload:)` extension；v1 ApiHandler payload conversion inline TODO，AI fill
2. **Multipart defer v2**
3. **Read UC defer v2** (no `<A>QueryError` handling)
4. **Cross-agg mapToApiError defer v2**
5. **HTTP method = POST for all v1** — semantics-aware routing defer v2
6. **Decimal `type: string` plain v1** — DecimalAmount $ref defer (AI skill 提案 promote)
7. **Server target setup defer Phase 2.x** — user 自串 Hummingbird router
8. **API↔domain ID rename defer v2**
9. **Bridge extensions defer v2**
10. **`<A>AggregateEventMapper`** is plugin-generated (Phase 1.e ModelGeneratorPlugin)
11. **Phase 1.h fixture iam-readmodel-cross-bundle.json 跟 1.i 衝突**：iam-readmodel-cross-bundle 有 Permission aggregate 但 invariants 空 → `<A>Error.swift` 是空 enum → ApiComponents switch 0-case → 還是 compile pass (empty switch over empty enum)

---

## 4. Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | scope = 5 categories Variant A simple | continue Phase 1.h pattern |
| D2 | `<A>ApiError` cases = all `<A>Error` + 5 infra (conservative) | guarantee switch compile pass |
| D3 | openapi.yaml v1 simplifications (POST/path/Decimal as string) | minimum viable; AI skill promote |
| D4 | ApiHandler Variant A only, no `<Storage>` generic | scope discipline |
| D5 | ApiComponents switch exhaustive 1:1 from bundle | match OC + compile pass |
| D6 | PackageRenderer +2 deps (no Hummingbird in 1.i) | Server target defer |
| D7 | Scaffold-once for 4 new files | Phase 1.g H6 pattern |
| D8 | 4 file paths canonical | mirror OC |
| D9 | Version 0.1.0-phase1i | manifest convention |
| D10 | Real e2e build mandatory | plugin invariant |
| D11 | Plugin risk acknowledged + mitigated via OC verbatim alignment | honest |
| D12 | 11 known limits | scope discipline |

---

## Next step

→ `/write-spec` Phase 1.i using above decisions.
