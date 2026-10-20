---
name: read-view
description: Genesis no-bundle read-API scaffolding skill. Inside a Genesis-bootstrapped project, /read-view scaffolds ONE aggregating read API DIRECTLY into Sources/ (no bundle, no genesis new) — reproducing OC AuditQuotingAggregate's Adapter/Get<View>/ shape: an aggregating ApplicationService that fans out across several existing presenters with a discriminator switch + not-applicable rules (generated FULL from a persisted YAML mini-spec, no fatalError TODO), the output discriminated-enum DTO, an APPENDED read method in the existing ApiHandler (Genesis-form, kdbClient-only), an UPSERTED openapi GET op (conditional 404/422/503), named <A>QueryError cases (3-file lockstep), and AS + Api test tiers. Emits Genesis-form that compiles.
argument-hint: [Get<View>]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# /read-view — scaffold one aggregating read API (no bundle)

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

在 Genesis-bootstrapped project 內，**不碰 bundle**、不跑 `genesis new`，把一條 **aggregating read view**（一個 `Get<View>`）scaffold 進 `Sources/`，結構等同 OC `AuditQuotingAggregate` 的 `Adapter/Get<View>/`。這條 view fan-out **既有的多個 presenter**（由 `/read-projector` 先產）、依 discriminator 分支、依 not-applicable rule throw，產出 **Genesis-form**（編得過）的：

1. `Sources/<A>Aggregate/Adapter/Get<View>/Get<View>ApplicationService.swift`（**FULL body**，從 mini-spec 生成，**非** fatalError TODO）
2. `.../{View}Dto.swift`（**僅 discriminated view**：output discriminated-enum DTO）
3. **APPEND** read method 進既有 `Sources/<A>Aggregate/Adapter/ApiHandler.swift`
4. **UPSERT** GET op 進 `Sources/<A>Aggregate/openapi.yaml`
5. **named-error 3-file lockstep**：`{A}QueryError.swift` + openapi `{A}ApiError` enum + handler catch
6. `Tests/<Ctx>Tests/<A>Aggregate/ApplicationServices/Get<View>/Get<View>ApplicationServiceTests.swift` + `.../Api/Get<View>/Get<View>ApiTests.swift`

> 這是 Genesis 既有 renderer **做不到** 的 net-new value：aggregating fan-out + discriminator + 不可由 `/presenter-fill` 處理（它對 >1-field input 直接 exit 3）。

### 絕對約束（不可違反）
- **不碰 bundle**、**不跑** `genesis new`。
- **不**宣告/編輯 ApiHandler 的 struct header / generic / init / `mapToApiError` —— **只 append 一個 read method 進 body**（Genesis-form：handler 非 generic，用 `Get<View>ApplicationService(kdbClient: kdbClient)`）。
- **不** emit `Get<Source>EventMapper` / `ProjectorProtocol` —— 它們由 `ModelGeneratorPlugin` 從 source presenter 的 projection-model.yaml entry 生成（見 prerequisite）。**絕不**自己寫。
- **不**碰 source presenter / read model（屬 `/read-projector`）。
- **不**加 `QueryError→ApiError` mapper —— handler 以 inline `where error.error == .<case>` raw-case catch；`mapToApiError` 維持只處理 `ContextError<{A}Error>`（write）。
- 一次一 `Get<View>`。**Genesis-form**、`package` access。

## 輸入解析
`$ARGUMENTS` = view 名 `Get<View>`（驗 `^Get[A-Z][A-Za-z0-9]+$`）。空 → exit 1。

## Phase 0 — 定位專案 + prerequisite（載重）
- 確認 generated project root；衍生 `contextName`、`<A>`（從 mini-spec / 互動）。
- **prerequisite（必查）**：mini-spec 引用的 discriminator presenter + **每個** source presenter 須**已存在 on-disk** （`Glob Sources/<A>Aggregate/Usecase/Projector/Get<Source>/Get<Source>Presenter.swift`）**且其 `projection-model.yaml` entry 也在**（`grep "^Get<Source>:" projection-model.yaml`）。缺任一 → **exit 3** + hint「先 `/read-projector Get<Source>`（含 discriminator presenter 如 `GetCustomerEstablishmentStatus`）」。
  - 理由：fan-out 用的 `Get<Source>EventMapper()` 由 plugin **從 source presenter 的 projection-model entry 生成**（Sources/ 內 0 個手寫 EventMapper）。entry 缺 = EventMapper 不存在 = AS 編不過。

## Phase 1 — mini-spec（persisted YAML；首跑互動產出、replay 讀檔）
mini-spec 寫在 AS 旁（`Sources/<A>Aggregate/Adapter/Get<View>/Get<View>.readview.yaml`）。**它是 per-view replay artifact、非 shadow bundle**（on-disk Sources tree 仍唯一 SSOT）。schema：
```yaml
view: Get<View>
keyField: <auditQuotingId>          # AS Input 的 domain key 欄位
wireId: <quotingId>                 # path/openapi 的 wire param（= aggregate identityName）
shape: discriminated | collection   # discriminated=有 discriminator；collection=passthrough [<Element>Dto]
discriminator:                      # 僅 discriminated
  sourcePresenter: GetCustomerEstablishmentStatus
  sourceField: establishmentStatus
  cases: [established, establishing, unestablished]
variants:                           # 每個 discriminator enum case 一條（per-variant，非 3→2 收斂）
  - enumCase: established
    outputCase: established          # 映到一個具名 output case …
    fields:                          # … 該 output case 的欄位（各 ← 某 source presenter 的某 field）
      - { name: totalAssets, from: GetTotalAssets.totalAssets, type: "Decimal?" }
      - { name: lastYearRevenue, from: GetLastYearRevenue.lastYearRevenue, type: "Decimal?" }
  - enumCase: establishing
    outputCase: establishing         # 可以是「獨立」output case（GetPredecessorServiceInfo），非必然 nonEstablished
    fields: [ ... ]
  - enumCase: unestablished
    notApplicable: <predecessorServiceInfoNotApplicable>   # … 或 throw not-applicable（取代 outputCase）
notApplicableGuard: null | { whenPredicate: "<disc> != .established", queryErrorCase: <quotingProofsNotApplicable> }
# collection-shape view 改用：
# collection: { elementDto: QuotingProofDto, fromPresenter: GetQuotingProofs, fromField: proofs }
```
首跑：AskUserQuestion 逐項問（discriminator 來源、每 variant→outputCase 或 notApplicable、每 output case 的欄位+來源 presenter+型別、notFound 永遠具名、是否有 not-applicable guard）。產出後寫檔。replay：直接讀檔 regen，**不**再問。

## Phase 2 — 名稱衍生
- AS 型別 `Get<View>ApplicationService`；**Input struct 永遠 `Get<View>ApplicationServiceInput`（長後綴，Genesis-form；非 OC 短 `Get<View>Input`）**。
- output DTO（discriminated）`<View>Dto` = enum，case = mini-spec 各 outputCase（如 `OperationInfoDto { case established(EstablishedOperationInfoDto); case nonEstablished(...) }` 或 `PredecessorServiceInfoDto { case established(...); case establishing(...) }`）。
- ApiHandler method 名 = `lowerCamel(View)` = operationId。
- QueryError 型別 `<A>QueryError`；notFound case = **`<aggLowerCamel>NotFound`**（具名，一律）。

## Phase 3 — emit（Genesis-form；Class A own-file glob-skip / Class B shared-file key-upsert）

### 3.1 `Get<View>ApplicationService.swift`（FULL body，Class A glob-skip）
**imports（audit MF2，務必）**：`import DDDCore`（coordinator generic constraint `EventStreamNaming` + `any EventTypeMapper` 在此、非 re-export）+ `import KurrentDB` + `import <Ctx>Shared`（`ApplicationService` / `ContextError` / `ContextError.Source` 在此，**mandatory**）皆**無條件**；`import Foundation` **僅當** fan-out 有 `Decimal`/`Date`。鏡像 OC per-file import set。
```swift
import DDDCore
import KurrentDB
import <Ctx>Shared
{import Foundation if any Decimal/Date}

package struct Get<View>ApplicationServiceInput {
    package let <keyField>: <KeyType>
    package init(<keyField>: <KeyType>) { self.<keyField> = <keyField> }
}

package struct Get<View>ApplicationService: ApplicationService {
    package typealias Input = Get<View>ApplicationServiceInput
    package typealias Output = <ViewDto | [<Element>Dto]>
    private let kdbClient: KurrentDBClient
    package init(kdbClient: KurrentDBClient) { self.kdbClient = kdbClient }

    package func execute(input: Input) async throws -> Output {
        let id = input.<keyField>
        // DISCRIMINATED:
        guard let <disc> = try await fetch<Disc>(id: id) else {
            throw ContextError<<A>QueryError>.<aggLowerCamel>NotFound(in: .struct(Self.self, function: #function), message: "...")
        }
        // optional not-applicable guard (mini-spec notApplicableGuard):
        // if <disc> <pred> { throw ContextError<<A>QueryError>.<naCase>(in: .struct(Self.self, function: #function), message: "...") }
        async let <field> = fetch<Source>(id: id)   // one per output field across all variants
        ...
        switch <disc> {
        // PER-VARIANT (audit S3): each enum case → a named output case OR a notApplicable throw. NOT a 3→2 collapse.
        case .<enumCaseA>: return .<outputCaseA>(.init(<f>: try await <f>, ...))
        case .<enumCaseB>: return .<outputCaseB>(.init(<f>: try await <f>, ...))
        case .<enumCaseC>: throw ContextError<<A>QueryError>.<naCase>(in: .struct(Self.self, function: #function), message: "...")
        }
    }

    // fetch helper — TWO forms (audit MF6):
    // (a) single-field independent fetch (use with `async let`): returns the field directly.
    private func fetch<Source>(id: <KeyType>) async throws -> <FieldType> {
        try await Get<Source>Presenter(coordinator: .init(client: kdbClient, eventMapper: Get<Source>EventMapper()))
            .execute(input: .init(<keyField>: id))?.readModel.<field>
    }
    // (b) whole-readModel fetch (use with serial `let x = try await fetch<Source>(id:)`) when MULTIPLE output
    //     fields come from ONE source presenter, reused across variant arms (GetPredecessorServiceInfo:
    //     `let auditorInfo = try await fetchPredecessorAuditorInfo(id: id)` → then `auditorInfo?.hasPredecessorAuditor`,
    //     `auditorInfo?.predecessorAuditorChangingReasons ?? []` in both arms):
    private func fetch<Source>(id: <KeyType>) async throws -> <Source>ReadModel? {
        try await Get<Source>Presenter(coordinator: .init(client: kdbClient, eventMapper: Get<Source>EventMapper()))
            .execute(input: .init(<keyField>: id))?.readModel
    }
}
```
- **COLLECTION shape（passthrough，mini-spec `collection:`）**：Output = `[<Element>Dto]`；**無 discriminator switch、無 `{View}Dto`**。**audit MF4：用 form-(a) helper 回 `[<Element>Dto]`、`?? []` 在 helper 內**（`return try await Get<Source>Presenter(...).execute(input:.init(<keyField>:id))?.readModel.<field> ?? []`），execute body 則 `return try await fetch<Source>(id: id)`（**不**再 `?.readModel.<field>` —— helper 已 unwrap，OC GetQuotingProofs 形）。guard 同上 notFound（仍具名）+ optional not-applicable guard 在 return 前。
- worked examples：GetOperationInfo（`.established→.established(8)`、`(.establishing|.unestablished)→.nonEstablished(5)`）；**GetPredecessorServiceInfo 真 3-way**（`.established→.established`、`.establishing→.establishing` 獨立 case、`.unestablished→throw .predecessorServiceInfoNotApplicable`）。

### 3.2 `{View}Dto.swift`（僅 discriminated；Class A glob-skip）
```swift
{import <Ctx>Shared / Foundation as needed}
package enum <View>Dto: Equatable, Codable {
    case <outputCaseA>(<OutputCaseA>Dto)
    case <outputCaseB>(<OutputCaseB>Dto)
}
package struct <OutputCaseX>Dto: Equatable, Codable {
    package let <field>: <type>   // 各欄位通常 optional、domain-typed (Decimal? / UInt? / nested <X>Dto? ...)
    package init(<memberwise>) { ... }
}
```
collection shape **不產** 此檔（複用 `/read-projector` 已產的 element DTO）。

### 3.3 APPEND ApiHandler read method（Class B key-upsert，anchor `func <opId>(`）
> 方法**不可**宣告 `package`：參數／回傳是 generated internal 的 `Operations.*` 型別（openapi-generator `accessModifier: internal`），`package` 會編譯失敗（method cannot be declared package because its parameter uses an internal type）。與 codegen 的 `ApiHandlerReadMethod` 模板一致。
進 `Sources/<A>Aggregate/Adapter/ApiHandler.swift` body（**不**動 header/generic/init/mapToApiError）：
```swift
    func <opId>(_ input: Operations.<opId>.Input) async throws -> Operations.<opId>.Output {
        let <wireId> = input.path.<wireId>
        let service = Get<View>ApplicationService(kdbClient: kdbClient)
        do {
            let output = try await service.execute(input: .init(<keyField>: <wireId>))
            // DISCRIMINATED → map domain DTO to Components.Schemas via switch:
            let response: Components.Schemas.<View>
            switch output {
            case let .<outputCaseA>(info): response = .<outputCaseA>(.init(<wire-field>: info.<f>.map { ... } ...))
            case let .<outputCaseB>(info): response = .<outputCaseB>(.init(...))
            }
            return .ok(.init(body: .json(response)))
            // COLLECTION → `.map` element DTO to Components.Schemas, no switch:
            // return .ok(.init(body: .json(output.map { Components.Schemas.<Element>(<wire-field>: $0.<f>, ...) })))
        } catch let error as ContextError<<A>QueryError> where error.error == .<aggLowerCamel>NotFound {
            return .notFound(.init(body: .json(.init(error: .<aggLowerCamel>NotFound))))
        // CONDITIONAL 422 (only when not-applicable rule):
        } catch let error as ContextError<<A>QueryError> where error.error == .<naCase> {
            return .unprocessableContent(.init(body: .json(.init(error: .<naCase>))))
        } catch {
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }
```
- **id-rename 邊界**：path/wire param = `<wireId>`（= aggregate identityName，如 `quotingId`）；AS Input field = `<keyField>`（domain，如 `auditQuotingId`）。handler 橋接 `input.path.<wireId>` → `.init(<keyField>: <wireId>)`。
- DTO→wire 機械轉換：`Decimal`→`$0.description`(String)、`UInt`→`Int($0)`、`ClosedRange<UInt>`→`.init(lowerBound:upperBound:)`、domain enum→`.rawValue` 或 `.init(from:)`、array via `.map`。
- **Class B**：找 `func <opId>(` anchor → 存在則 replace method、否則 append 進 struct body 尾（`}` 前）。fail-closed on ambiguous。

### 3.4 UPSERT openapi GET op（Class B key-upsert，anchor `paths.<path>:`）
進 `Sources/<A>Aggregate/openapi.yaml`：operationId `<opId>`、200 response body schema **`$ref: '#/components/schemas/<View>'`**（discriminated）或 **`type: array, items: $ref '#/components/schemas/<Element>'`**（collection）、**404+503 always**、**422 conditional**（有 not-applicable rule 才 emit `UnprocessableEntityError` response，與 handler catch set 一致）。
- **path kebab**：`/<agg-kebab>/{<wireId>}/<kebab-view>`；**collection GET 須與既有 POST disambiguate** —— OC 慣例 append `-list`（`GetQuotingProofs`→`/audit-quotings/{quotingId}/quoting-proof-list`，因 `uploadQuotingProof` POST 佔 `/quoting-proofs`）。
- **Class B fail-closed**：若目標 `paths.<path>:` 已有**不同 HTTP verb**（如該 path 已有 POST）→ 停下問，**不**把 GET 併進別人的 path-item。

### 3.4b UPSERT openapi `components/schemas`（audit MF1，**載重 — 漏了 handler 編不過**）
§3.3 的 handler 引用 `Components.Schemas.<View>` / `Components.Schemas.<Element>` —— 這些 Swift 型別由 swift-openapi-generator **從 `components/schemas` 生成**。GET op（§3.4）只寫 `paths:` 不夠；**必須同時 UPSERT** 對應 schema objects（否則 `Components.Schemas.<View>` 不存在 → handler 編不過 → build gate 失敗）。Class B key-anchored upsert under `components.schemas.<Name>:`，fail-closed on near-name，glob/grep 已存在則 skip（如既有 `QuotingProof`）：
- **discriminated view** → emit `components/schemas/<View>`（`oneOf: [$ref 各 variant schema]` + `discriminator: { propertyName: <discriminatorWireField 如 customerEstablishmentType>, mapping: {...} }`）+ **每 output case 一個 object schema** `<OutputCase><View>`（如 `EstablishedOperationInfo`/`NonEstablishedOperationInfo`/`EstablishingPredecessorServiceInfo`），各帶 `<discriminatorWireField>` string-enum property + 每個 wire field（`Decimal`→`$ref DecimalAmount` 或 `type: string`、`UInt`→`type: integer`、`ClosedRange<UInt>`→既有 range schema $ref、domain enum→`$ref <Enum>` wire enum schema）。所引用的 wire enum schema 若不存在亦 emit。
- **collection view** → emit `components/schemas/<Element>`（GET 200 `items: $ref` 的目標；all-string object，欄位 = element DTO 的 wire 投影），**除非** glob/grep 證明它已存在（如 `QuotingProof` 已被 write op 定義過 → skip）。
- 與 named-error lockstep（§3.5）對稱：**success-path 也是 lockstep**（handler 型別引用 ⟷ openapi schema），兩者缺一不可。

### 3.5 named-error 3-file lockstep（atomic；S1 一律具名）
**永遠**（不論有無 not-applicable）：
- `Sources/<A>Aggregate/<A>QueryError.swift`：加 `case <aggLowerCamel>NotFound` + 對應 `ContextError` static factory（append-if-absent）。
- openapi `{A}ApiError` enum（`Components.Schemas.<A>ApiError`）：加 `- <aggLowerCamel>NotFound`（append-if-absent；它被 404 response $ref）。
- handler catch 引用該 case（3.3 已含）。
**有 not-applicable rule 時**：同樣 lockstep 加 `.<naCase>`（QueryError + ApiError enum + 422 catch + openapi 422 response）。
- **atomic**：任一檔失敗 → 不 partial、報哪檔。`.init(error: .<named>)` 需 named case 在**同一個** ApiError enum（404 body 所 $ref 的）→ 三檔一致才編得過。

### 3.6 test tiers（AS + Api）
> **test 檔骨架（audit MF3，照 `/test-gen` @Suite 骨架 recipe）**：import header（`import Testing`/`import KurrentDB`/`@testable import <A>Aggregate`（Api tier 需 internal 的 `Operations`／ApiHandler 方法）〔+ DDDKit/TestUtility/Foundation 視需要〕）；`.tags(.<aggLowerCamel>)` 需 `extension Tag { @Tag static var <agg>: Self }` 在共用支援檔、**idempotent append-if-absent**（否則 test target 編不過；`swift build` 不 build test target → Human gate 才炸）。
- `Get<View>ApplicationServiceTests.swift`：`@Suite(.serialized, .tags(.<aggLowerCamel>))` + kdbClient + `Task.sleep(for: .seconds(0.5))`；@Test：**notFound（不存在 id）+ not-applicable（有則）+ 每個 output shape ≥1 happy-path**（discriminated 每 output case 一個、collection 一個）。⚠️ **行為斷言 body 非 mini-spec 可推導 → 出 compilable stub**：**notFound stub 須 setup-free**（用 fresh/random id 呼 `execute`、斷言 thrown `ContextError<<A>QueryError>.error == .<aggLowerCamel>NotFound`，**不**依賴 `withTestBundle`/`createX` write helper）；happy-path / not-applicable body（需 write helper + 部署 projection）留 Human gate。header 註解寫 prerequisite（localhost KDB + 部署 projection + `/reset-projection`）。
- `Get<View>ApiTests.swift`：full HTTP seam，`ApiHandler(kdbClient: kdbClient)`（**非** OC `<MockStorage>`）、`withTestBundle` + `Task.sleep(0.5)`、wire-String 斷言、error case 斷言（`response.notFound.body.json.error == .<aggLowerCamel>NotFound`）。

## Phase 4 — 報告
印產出 + skipped（已存在）+ lockstep 結果 + 下一步：`swift build` 驗（含 named-error lockstep + fan-out 真編得過）；`bash scripts/projection.sh` 確保 source presenter 的 projection 已部署；read eventual-consistent。提醒：AS body **無洞**（已全生成，無需 fill）。

## 與其他 skill 的關係
- 上游：`/read-projector`（先產每個 source presenter + discriminator presenter，含其 projection-model entry）。
- sibling：`/presenter-fill`（只填 trivial single-presenter passthrough AS 的 fatalError；對本 skill 的 multi-presenter aggregating AS 不適用、它 exit 3）。
- 下游：`swift build`；`/reset-projection`（部署 source presenter 的 JS projection）；`genesis verify`。
- **不**呼叫它們。
