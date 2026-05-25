# Phase 1.j — Variant B `init(from payload:)` extension emission（facts + 決策）

## 任務定位

Phase 1.h/1.i defer 的 OC pattern：對含 Decimal/Date AS Input field 的 UC，codegen emit `extension {UC}ApplicationServiceInput { init(from payload:, ...) throws { ... } }` 到同 AS file，handler 用短形 `try <UC>...Input(from: payload, ...)` 取代 inline guard+throw。**純品質改善** —— 行為不變，handler 變短，與 OC 一致。

## Facts gathered

### F1. OC 真實 pattern（AddAccountingApplicationService.swift）

extension **在同個 AS file** 內（不是 separate `+Init.swift`）：

```swift
extension AddAccountingApplicationServiceInput {
    package init(
        from payload: Components.Schemas.AddAccountingRequest,
        quotingId: String,
        operatorId: String
    ) throws {
        self.init(
            quotingId: quotingId,
            quotingBundleId: payload.quotingBundleId,           // plain pass
            quotingBundleType: .init(from: payload.quotingBundleType),  // enum DTO (non-throws init)
            startDate: try Date.parseIso8601(payload.startDate),        // Date throws
            endDate: try Date.parseIso8601(payload.endDate),
            workItems: try payload.workItems.map { try AccountingWorkItemDto(from: $0) },  // array DTO
            operatorId: operatorId
        )
    }
}
```

對應 handler 短形：
```swift
let applicationServiceInput: AddAccountingApplicationServiceInput
do {
    applicationServiceInput = try AddAccountingApplicationServiceInput(
        from: payload,
        quotingId: input.path.quotingId,
        operatorId: input.headers.operatorId
    )
} catch is Iso8601ParsingError {
    return .unprocessableContent(.init(body: .json(.init(error: .invalidDateFormat))))
}
```

### F2. Phase 1.h 現有 template (ApplicationService.swift.template)

emit struct + plain init + execute() stub。**無** `init(from payload:)` extension。`{INPUT_FIELDS}`/`{INIT_PARAMS_MID}`/`{INIT_ASSIGNMENTS}` 已有，只需加 `{PAYLOAD_INIT_EXTENSION}` placeholder。

### F3. /api v4 SKILL.md category 2 現狀

handler asInput 構造為 inline，含 Variant B 的 Decimal/Date guard+throw + error case 解析（audit H4）。未感知 extension 存在。

## 決策（直接定，無需問）

- **scope**: v1 cover Variant B-Date + plain pass-through。Variant B-Decimal 留 v2（Decimal 需 guard+throw in init body，比 Date 的 try parseIso8601 複雜，且 v1 沒有對應 fixture）。nested DTO `.init(from:)` 與 array DTO `try .map { try ... }` 也 defer v2（依賴 DTO scaffold 結構，目前 /api v4 也只 cover plain）。
- **extension placement**: 與 OC 一致，**在同個 AS file**（非 separate `+Init.swift`）。Phase 1.h template 加 `{PAYLOAD_INIT_EXTENSION}` placeholder。
- **trigger**: ApiRenderer 偵測 AS Input field 型別含 `Date` / `Date?` → emit extension。否則 placeholder 為空字串（Variant A 無 extension）。
- **/api skill v5 升級**：
  - 偵測 AS file 是否含 `extension <UC>ApplicationServiceInput { init(from payload:` → 若有 → category 2 emit 短形 `try <UC>...Input(from: payload, ...)` + 加 `catch is Iso8601ParsingError → .invalidDateFormat`。若無 → v4 inline 邏輯。
  - 不破壞既有 v4 fills（structural invariant 仍 idempotent）。
- **bundle schema**: 無變更（UC.input field type 已是 truth source）。
- **不 bump 版本**：codegen+skill 升級，與其他 phase fill skill 一致不 bump version。

## v1 scope（locked）

1. ApplicationService.swift.template 加 `{PAYLOAD_INIT_EXTENSION}` placeholder（template 尾部，struct 後 / Output 前）。
2. ApiRenderer 加 `hasVariantBDate(uc:)` 偵測 + `renderPayloadInitExtension(uc:)` emit extension block；無 Date field → 空字串。
3. extension body 規則：
   - 每 plain field（含 String, Int, Bool, Optional plain）：`<f>: payload.<f>`
   - 每 Date field：`<f>: try Date.parseIso8601(payload.<f>)`
   - 每 Date? field：`<f>: try payload.<f>.flatMap { try Date.parseIso8601($0) }`
   - aggIdName / operatorId 從 init args 傳入（非 payload）
4. /api skill v5 SKILL.md 升級：category 2 detect extension + short-form emit + handler catch ladder for Iso8601ParsingError。
5. 新 fixture（或派生現有）含 Date field UC，real e2e build pass。
6. 既有 iam-bundle fixture（無 Date）e2e 仍 pass（Variant A path 不變）。
7. docs decisions.md Phase 1.j ratification + architecture.md §10.15。
