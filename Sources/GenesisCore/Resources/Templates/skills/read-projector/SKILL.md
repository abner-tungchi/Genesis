---
name: read-projector
description: Genesis no-bundle read-side scaffolding skill. Inside a Genesis-bootstrapped project, /read-projector scaffolds ONE passthrough read-model unit DIRECTLY into Sources/ (no bundle.readModels[] write, no genesis new) — reproducing OC AuditQuotingAggregate's Usecase/Projector/Get<Noun>/ shape: <Noun>ReadModel.swift, Get<Noun>Presenter.swift (empty when() stubs), co-located element/enum DTOs (collection read models), projections/<prefix>Get<Noun>Projection.js, and an appended Get<Noun> entry in projection-model.yaml; plus a Projector-tier test. Emits Genesis-form that compiles. Fills nothing — when() bodies are left for /readmodel-mutation.
argument-hint: [Get<Noun>]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# /read-projector — scaffold one passthrough read-model unit (no bundle)

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

在 Genesis-bootstrapped project 內，**不碰 bundle**、不跑 `genesis new`，直接把一條 **passthrough read model**（一個 `Get<Noun>`）scaffold 進 `Sources/`，結構等同 OC `AuditQuotingAggregate` 的 `Usecase/Projector/Get<Noun>/`。互動 elicit 設計事實（events、key、stored fields），從既有專案的 `event.yaml` / `Sources/` infer，產出 **Genesis-form**（編得過）的：

1. `Sources/<A>Aggregate/Usecase/Projector/Get<Noun>/<Noun>ReadModel.swift`
2. `.../Get<Noun>Presenter.swift`（`buildReadModel` + 每 event 一個 **empty `when()` stub**）
3. `.../{Element}Dto.swift`（collection read model）+ `.../{Enum}Dto.swift`（enum-wrap），**glob-skip 若型別已存在 module 他處**
4. `projections/<prefix>Get<Noun>Projection.js`
5. **APPEND** `Get<Noun>:` block 進 `Sources/<A>Aggregate/projection-model.yaml`
6. `Tests/<Ctx>Tests/<A>Aggregate/Projectors/Get<Noun>/Get<Noun>PresenterTests.swift` + 每個引用 nested DTO 一個 `<Dto>Tests.swift`

> **讀模型在 GET 當下 on-demand 重播**：read model 由部署的 server-side JS projection（步驟 4，跑 `bash scripts/projection.sh` 部署）灌進 `<prefix>Get<Noun>-<id>` link stream，Presenter coordinator 在讀時重播。**零 Swift 訂閱**。

### 絕對約束（不可違反）
- **不碰 bundle**（不讀不寫 `bundle.readModels[]`）、**不跑** `genesis new`。
- **不 fill** `when()` body —— emit `_ = readModel; _ = event;` stub，交給 `/readmodel-mutation`。
- **不**碰 `ProjectorProtocol` / `apply()` / `EventMapper` —— 它們由 DDDKit `ModelGeneratorPlugin` **從 projection-model.yaml 生成**（你 append entry，plugin 生 protocol+mapper）。**絕不**自己 emit 它們。
- **不**碰 aggregating read API（`Adapter/Get<View>/`）—— 那是 `/read-view`。
- 一次一 `Get<Noun>`。**Genesis-form**：`package` access、`StreamNaming` 衍生 prefix（**絕不硬寫 `OC`**）。

## 輸入解析
`$ARGUMENTS` = read-model 名 `Get<Noun>`（驗 `^Get[A-Z][A-Za-z0-9]+$`，否則 **exit 1**）。空 → exit 1 印 usage。

## Phase 0 — 定位專案 + 衍生 contextName / prefix
- 確認 cwd 是 generated project root（存在 `.ai/contexts/` 或 `Package.swift`），否則 **exit 1**。
- `contextName` = `.ai/contexts/` 目錄名 或 `Package.swift` product 名。
- **stream prefix = `StreamNaming.categoryPrefix(contextName)` = contextName 的大寫字母**（`OpportunityContext`→`OC`、`IAMContext`→`IAMC`）。projection prefix = `<prefix>_`。`<A>` 寫 stream category = `<prefix><A>` → JS 訂閱 `$ce-<prefix><A>`。**絕不硬寫 OC**。

## Phase 1 — 互動 elicit（AskUserQuestion，對照 on-disk，零 bundle）
1. **aggregate `<A>`**：glob `Sources/*Aggregate/` 列出單選（或 `<context-level>`）。
2. **source events**（multiSelect）：讀該 aggregate 的 `Sources/<A>Aggregate/event.yaml`，列其 event 名供選。
3. **key field**（domain 名，如 `auditQuotingId`）+ **type**（String/UUID/…）+ **`key.fromEventPayload`**（wire 名，如 `quotingId`）。
4. **stored fields**：name+type。scalar-optional（`Decimal?`）vs collection（`[<Element>Dto]`）。collection 再問 element DTO 名 + 欄位集 + 任何 nested enum DTO（mirror domain enum）。

### ⚠️ key.fromEventPayload silent-empty guard（載重，不可省）
verify `key.fromEventPayload` 存在於**所選每個 event 的 payload union**：

> **payload set = `event.yaml` 該 event 的 `properties[].name` ∪ `{aggregateRootId.alias}`**（含 createdEvent 的 `aggregateRootId.alias`）。

⚠️ **必須 union `aggregateRootId.alias`**：wire key（如 `quotingId`）**通常就是 `aggregateRootId.alias`、不在 `properties[]`**（OC 全 16 read model 皆如此：`TotalAssetsEdited` 的 properties 是 quotingCaseGroupingId/quotingCaseId/totalAssets，`quotingId` 只在 `aggregateRootId.alias`）。只查 `properties[]` 會誤擋所有合法 run。常態：`key.fromEventPayload == aggregateRootId.alias`。
若 `key.fromEventPayload` 不在 union → **擋下並提示**（錯 linkTo id = read model 永遠靜默空，最高 blast-radius）。

## Phase 2 — 名稱衍生（務必一致）
- read-model 名 `Get<Noun>`（如 `GetTotalAssets`、`GetQuotingProofs`）。
- ReadModel 型別 = 去 `Get` + `ReadModel` = `<Noun>ReadModel`（`GetTotalAssets`→`TotalAssetsReadModel`）。
- Presenter 型別 = `Get<Noun>Presenter`；Input struct = `Get<Noun>Input`（`CQRSProjectorInput`）。
- projector dir = `Sources/<A>Aggregate/Usecase/Projector/Get<Noun>/`。
- projection-model key = `Get<Noun>` 逐字。JS 檔 = `projections/<prefix>_Get<Noun>Projection.js`。
- ProjectorProtocol（plugin）= `Get<Noun>ProjectorProtocol`；EventMapper（plugin）= `Get<Noun>EventMapper`。

## Phase 3 — emit 檔案（Genesis-form；Class A own-file glob-skip）

> **idempotency Class A**：每個 own-file 先 `Glob` exact path，**存在則 SKIP**（不覆寫手填 body）。

### 3.1 `<Noun>ReadModel.swift`
```swift
import EventSourcing
{import Foundation if any field needs Decimal/Date}{import <Ctx>Shared if any field type is a shared DTO/custom type}

package class <Noun>ReadModel: ReadModel {
    package var id: <KeyType> { <keyField> }
    package var <keyField>: <KeyType>
    <one `package var <name>: <type>` per stored field>

    package init(<keyField>: <KeyType>) {
        self.<keyField> = <keyField>
        <one default-assign per stored field: Optional→ (skip, nil); Array/[X]→ self.x = []; Set<X>→ Set(); Dictionary/[K:V]→ [:]; explicit default→ that>
    }
}
```
- scalar 例（GetTotalAssets）：`package var totalAssets: Decimal?`、init 無 default 行（nil）、`import Foundation`。
- collection 例（GetQuotingProofs）：`package var proofs: [QuotingProofDto]`、init `self.proofs = []`。
- 未知型別無可推 default 且無 explicit → **擋下並提示**（補 default）。

### 3.2 `Get<Noun>Presenter.swift`（empty when() stubs）
```swift
import DDDCore
import EventSourcing
import KurrentSupport
{import <Ctx>Shared if DTOs}{import <X>Aggregate per cross-aggregate source}

package struct Get<Noun>Input: CQRSProjectorInput {
    package let id: <KeyType>
    package init(<keyField>: <KeyType>) { self.id = <keyField> }
}

package struct Get<Noun>Presenter: Get<Noun>ProjectorProtocol {
    package typealias Input = Get<Noun>Input
    package typealias StorageCoordinator = KurrentStorageCoordinator<Self>
    package typealias ReadModelType = <Noun>ReadModel
    package static var categoryRule: StreamCategoryRule { .fromClass(withPrefix: "<prefix>_") }

    package var coordinator: KurrentStorageCoordinator<Get<Noun>Presenter>
    package init(coordinator: KurrentStorageCoordinator<Get<Noun>Presenter>) { self.coordinator = coordinator }

    package func buildReadModel(input: Input) throws -> <Noun>ReadModel? {
        return .init(<keyField>: input.id)
    }
    <one EMPTY stub per source event:>
    package func when(readModel: inout ReadModelType, event: <Event>) throws {
        // TODO(/readmodel-mutation): mutation body. Plugin requires this method; body intentionally no-op.
        _ = readModel
        _ = event
    }
}
```

### 3.3 element / enum DTOs（collection only；glob-skip if exists）
**先 `Glob Sources/**/<Dto>.swift`**：若型別已存在 module 他處（如 OC `FileTypeDto` 在 OCShared）→ **不**重 emit（idempotency Class A）。否則 co-located 在 projector dir。**imports（audit MF5）**：emit `import <Ctx>Shared`（及/或宣告該 domain `<Element>`/`<Enum>` 型別的 aggregate domain module）—— `init(from domainModel: <Element>)` 引用 domain 型別需在 scope（鏡像 OC `QuotingProofDto.swift` 的 `import OCShared`）。
```swift
// element struct DTO
package struct <Element>Dto: Equatable, Codable {
    package let <fields...>
    package init(<memberwise>) { ... }
    package init(from domainModel: <Element>) {  // mapper skeleton; nested enum via <Enum>Dto(from:)
        self.init(<map each field; nested enum → <Enum>Dto(from: domainModel.<f>)>)
    }
}
// enum-wrap DTO (mirror a domain enum)
package enum <Enum>Dto: String, Codable {
    case <cases...>
    package init(from domainModel: <Enum>) { switch domainModel { case .<x>: self = .<x>; ... } }
}
```

### 3.4 `projections/<prefix>_Get<Noun>Projection.js`
```js
fromStreams([<unique "$ce-<prefix><sourceAgg>" per source aggregate>])
.when({
    $init: function () { return {} },
    <one `<Event>: handleEvent,` per source event>
});

function handleEvent(state, event) {
    if (event.isJson) {
        linkTo("<prefix>_Get<Noun>-" + event.body["<key.fromEventPayload>"], event);
    }
}
```
⚠️ `linkTo` id key = **`key.fromEventPayload`（wire 名，如 quotingId）**，**非** readmodel 的 domain key（`auditQuotingId`）。stream prefix `<prefix>`（衍生）。

### 3.5 APPEND projection-model.yaml（Class B — key-anchored upsert）
`Sources/<A>Aggregate/projection-model.yaml`：
```yaml
Get<Noun>:
  model: readModel
  events:
    <one `- <Event>` per source event>
```
- **Class B upsert**：Read 檔 → 找 top-level key `Get<Noun>:`（行首、冒號結尾）→ **存在則 replace 該 block in-place、否則 append**。**絕不盲 append**（重複 YAML key 會讓 projection deploy 爆）。
- **fail-closed on ambiguous near-name**（如 `GetEvidenceCount` vs `GetEvidenceInfo`：候選 key 為 target 的嚴格前綴 / 差 ≤2 字元）→ 停下問 user，不猜。
- **post-write 自檢**：re-read → 該 block 可 parse + `events` list == Presenter 的 when() event 集；不符 → 報錯回滾。

### 3.6 Projector-tier test
> **test 檔骨架（audit MF3，務必照 `/test-gen` @Suite 骨架 recipe，否則 test target 編不過）**：(a) import header `import Testing` / `import DDDKit` / `import KurrentDB` / `import TestUtility` / `import <A>Aggregate`（+ `import Foundation` if Decimal/Date）；(b) `withTestBundle(client: kdbClient) { bundle in … bundle.generateAggregateRootId(for: <A>.self) … }` arrange seam；(c) **CRITICAL — `.tags(.<aggLowerCamel>)` 需 `extension Tag { @Tag static var <agg>: Self }` 存在於共用支援檔（`Tests/<Ctx>Tests/SharedUtility/TestTag.swift` 或 GenesisTestSupport）→ idempotent append-if-absent**，否則整 test target 編不過。⚠️ `swift build` **不** build test target，此漏會逃過 build gate、在 Human read-test gate 才炸。
- `Get<Noun>PresenterTests.swift`（`@Suite(.serialized, .tags(.<aggLowerCamel>))` + kdbClient/repository + `Task.sleep(for: .seconds(0.5))` projection-await + presenter.execute 斷言 + nil-when-unset；header 註解寫 prerequisite：需 localhost KurrentDB + 部署 projection、先跑 `/reset-projection`）。
- 每個**引用的 nested DTO** 一個 `<Dto>Tests.swift`（純 DTO test，無 @Suite/KDB；測 `init(from:)`）—— **不論該 DTO source 在 co-located dir 或 module 他處**（OC `FileTypeDtoTests` 在此但 source 在 OCShared）。
- **例外（inverted-index）**：若 read model 的 `id` 欄位 ≠ aggregate-id（lookup/inverted-index，如 `GetAuditQuotingIdByQuotingCaseId` id=quotingCaseId）→ **不產 Projector test**（OC 該類無 test）。

## Phase 4 — 報告
印產出檔清單 + skipped（已存在）+ 下一步：(1) `/readmodel-mutation Get<Noun>` 填 when() body；(2) 若此 noun 也要當 trivial single-presenter view 暴露 → `/presenter-fill`；(3) `bash scripts/start-kurrentdb.sh` + `bash scripts/projection.sh` 部署 projection；(4) `swift build` 驗編譯。提醒 read 是 eventual-consistent（write 後稍候 projection 追上才有值）。

## 與其他 skill 的關係
- 上游：無 bundle。設計事實互動 elicit + 從 `event.yaml`/`Sources/` infer。
- sibling：`/read-view`（aggregating read API，fan-out 多個本 skill 產的 presenter）。
- 下游：`/readmodel-mutation`（填 when() body）；`/presenter-fill`（trivial passthrough AS body）；`/reset-projection`（部署 JS projection）；`genesis verify`（gate 殘留 marker）。
- **不**呼叫它們；只產檔 + 留 stub。
