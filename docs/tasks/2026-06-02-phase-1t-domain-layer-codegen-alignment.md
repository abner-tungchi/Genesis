# Phase 1.t — domain-layer codegen alignment（vs OC AuditQuotingAggregate）

## 來源

討論：`docs/discussions/2026-06-01-domain-layer-codegen-gap.md`（D1-D6 consensus，R2 lock）+ `docs/discussions/2026-06-01-full-pipeline-parity-audit.md`（PA-F1/F3/F4 + N1/N2）。

本 task 實作 D2/D4/D5/D6 + N2（低/中風險、清楚可機械導的 codegen 補強）。**D3（create-init split 對齊 input）defer 到 Phase 1.t.1** —— 它 entangle 一個新發現的 /usecase Create pattern misalignment（create UC 的 input 無 aggId、id 由 service UUID 生，但 /usecase Create pattern emit `input.<aggId>`），風險高且獨立，單獨處理（goal「同 bug 解三次未果即停」紀律：隔離高風險）。

## 目標

把 Genesis `genesis new` 生成的 write-side domain 層往 OC `AuditQuotingAggregate` 對齊，補上「機械可導但目前 UNDER-generate」的 scaffold，並對「不可機械導的 business rule」用 honest obligation（commented TODO / fatalError）而非 fake structure。解決 parity audit 的 PA-F3（ensureInvariant 未承載 bundle invariant）、PA-F4（無 ContextError factory）、N1（dead create command scaffold）、N2（shared import 綁 DTO 存在 → primitive-only aggregate 補 factory 會編譯失敗）、以及 when reducer 的 silent-corruption 風險（D5）。

核心哲學（與 test-gen Phase 1.s 一致）：**scaffold 可導、honest-mark 不可導**。受 DDDKit 約束（`apply(event:)` 在 `when` 前後各跑 `ensureInvariant()`）—— ensureInvariant **不可**預設 throw/fatalError，只能 runnable no-op + commented obligation。

## 介面合約（Interface Contract）

### D2 + N2 — ContextError factory extension（`AggregateRenderer.renderError` + `AggregateError.swift.template`）

生成的 `<A>Error.swift` 從「bare enum」變為「enum + ContextError factory extension」：

```swift
import Foundation
import {ContextName}Shared            // ← N2 fix：ContextError 住 Shared，無條件 import

package enum {Aggregate}Error: Error, Equatable {
{ErrorCases}
}

extension ContextError where ErrorType == {Aggregate}Error {
{ContextErrorFactories}              // 每個 errorCode 一個 static func
}
```

每個 errorCode factory（依生成的 `Shared/ContextError.swift` init 簽名；OC 形狀為 `.init(error:in:message:)` + `.class(_:function:)`）：

```swift
    static func {errorCode}(function: String = #function, message: String = "") -> Self {
        .init(error: .{errorCode}, in: .class({Aggregate}.self, function: function), message: message)
    }
```

- **N2**：error 檔的 `import {ContextName}Shared` **無條件** emit（ContextError 永遠在 Shared；`<Ctx>Shared` target 永遠存在 — Phase 1.f `needsShared=true`）。不沿用 `needsSharedForImport`（那條只判 aggregate 是否引用 DTO/customType）。`renderError` 須新增 `contextName` 參數。
- error enum 無 invariant（`placeholder` case）時：factory extension 對 `placeholder` 也生（保持 compile），或 skip extension（擇一，impl 時以 compile 為準）。
- factory 精確簽名（Codex audit 已驗）：`ContextError.init(error:in:message:timestamp:)`、source case 為巢狀 `ContextError.Source.class(AnyObject.Type, function:)` → factory body `.init(error: .<errorCode>, in: .class(<A>.self, function: function), message: message)` 正確、不 compile error。impl 仍以實際 Read `Shared/ContextError.swift.template` 為準。
- **無 invariant 的 `placeholder` case**：**skip 整個 factory extension**（不生 `ContextError<…>.placeholder()` —— 與 honest-obligation 哲學不一致；`placeholder` 只是讓 enum 可編譯的 shim）。SharedImport 仍 emit（無害）。

### D4 — ensureInvariant() commented obligation（`AggregateRenderer.renderAggregate` + `Aggregate.swift.template`）

`ensureInvariant()` body 從單一空 stub 改為「runnable no-op + bundle invariant 承載為註解」：

```swift
    package func ensureInvariant() throws {
        // GENESIS-TODO: implement aggregate invariants (called by DDDKit apply() before & after every event).
        // Bundle-declared invariants for this aggregate:
{InvariantObligations}
        // Throw ContextError<{Aggregate}Error>.<errorCode>(message:) on violation.
        // NOTE: body MUST stay runnable (no default throw/fatalError) — apply() runs this pre+post every event.
    }
```

`{InvariantObligations}` = 每個 bundle invariant 一行註解：`        //   - <title> (<errorCode>): <rules joined>`。無 invariant → `        //   (none declared in bundle)`。

- **不生 named `check*()` stubs**（Gemini：bundle N invariant ≠ 開發者 M check 分解，固定 stub 約束分解 = Domain Theater）。
- **不預設 throw/fatalError**（Codex/DDDKit：pre/post-apply 會炸全部 apply）。

### D5 — when(event:) strict-safe scalar reducer / 其餘 fatalError（`UseCaseRenderer.renderCommandExtension` + `CommandExtension.swift.template`）

`when(event:)` body 從空 no-op stub 改為：
- **若該 event payload 每個欄位都 strict-safe 對映 state**（payload field name == aggregate state field name **且** resolved type 相同 **且** 非 collection（Set/Array）**且** 非 `new*`/`old*` 語義 prefix）→ emit 全部 `self.<f> = event.<f>`。
- **否則**（任一欄位非 strict-safe）→ emit `fatalError("GENESIS-TODO: implement state transition for {EventTypeName}")`（honest obligation：replay crash 勝 silent state corruption）。

`renderCommandExtension` 須新增 aggregate state（`agg.state`）+ event payload（`useCase.eventPayload`）資訊以判定 strict-safe（目前只拿 `commandFields = useCase.input`）。

> **`{WhenBody}` 由 renderer（Swift code）算出後代入 template** —— 不是 generated Swift 內的 symbol。fatalError 分支由 renderer 組字串：`"fatalError(\"GENESIS-TODO: implement state transition for \(eventTypeName)\")"`，其中 `eventTypeName` 是 renderer 既有的 Swift 變數（已傳入 renderCommandExtension），所以 generated 檔得到**字面 event 名**（如 `...for UserPromoted`），無 `eventTypeName` 未定義問題（Codex audit HIGH#1）。
> **type-equality 比的是 model resolved type**（`agg.state` / `useCase.eventPayload` 各 `FieldSpec.rawType` 經 `SwiftTypeResolver.resolve`），**不是** generated stored property 的 `T?`（`?` 是 renderAggregate 最後才加）。所以 state `foo` 與 payload `foo` 都 resolve 成 `String` → 視為相等（Codex audit 確認，D5 不會永遠 fatalError）。`self.foo = event.foo`（`String` → `String?` property）compile-pass。

command method body（`{useCaseCamelCase}(...)`）維持現狀 `fatalError("not implemented")`（domain 驗證+event build 是 human rule，honest obligation 不變）。

### D6 — 移除 dead create command scaffold（`UseCaseRenderer` / `AggregateRenderer`）

create UC（`ucCamel` prefix `create`/`establish`）**不生** `Entity/Commands/<A>+<CreateUC>.swift`。理由：plugin-generated aggregate protocol 不 dispatch Created event 到 `when(event:)`（Created 由 rehydration init 處理）；OC 無 create command file；該檔的 command method + `when(Created)` 是 dead scaffold。

`UseCaseRenderer.render` 對 create UC skip `renderCommandExtension`（其餘 Input/Output/Usecase/Service 照生）。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/AggregateError.swift.template` | 加 `{SharedImport}`（無條件）+ `extension ContextError where ErrorType==<A>Error { {ContextErrorFactories} }` |
| `Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template` | ensureInvariant body 加 `{InvariantObligations}` 註解 + NOTE |
| `Sources/GenesisCore/Resources/Templates/v0.1/CommandExtension.swift.template` | when body 改 `{WhenBody}`（strict-safe assignments 或 fatalError）；command method body 不變 |
| `Sources/GenesisCore/AggregateRenderer.swift` | `renderError` 加 `contextName` 參數 + 生 factory + 無條件 SharedImport；`renderAggregate` 算 `{InvariantObligations}`；`render` 把 contextName 傳給 renderError |
| `Sources/GenesisCore/UseCaseRenderer.swift` | `renderCommandExtension` 加 state+payload 參數 + 算 `{WhenBody}` strict-safe 判定；`render` 對 create UC skip command extension（D6）|
| `Tests/GenesisCoreTests/UseCaseRendererTests.swift`（新檔）| D5 positive path 單元測試：餵 strict-safe synthetic（state `[foo:String]` + eventPayload `[foo:String]`）→ assert command extension 含 `self.foo = event.foo`；non-strict（type/集合/new-old）→ assert 含 `GENESIS-TODO: implement state transition`。create UC → assert 不生 command extension（D6）|

### 受影響 call site（不需改但列出）
- `AggregateRenderer.render` 已有 `contextName` in scope（傳給 renderError）。
- 既有 codegen 測試（`*RendererTests` / golden / integration）若 assert 生成內容會受影響 → 更新期望。

## 實作步驟

### Step 1（D2+N2，最低風險先做）：ContextError factory
1. Read `Sources/GenesisCore/Resources/Templates/v0.1/Shared/ContextError.swift.template` 取 `ContextError.init` + error source API 精確簽名。
2. `AggregateError.swift.template`：加 `{SharedImport}` 行 + factory extension 區塊 `{ContextErrorFactories}`。
3. `AggregateRenderer.renderError`：加 `contextName` 參數；SharedImport 無條件 `import \(contextName)Shared`；逐 errorCode 生 factory（dedupe 同 `seenCodes`）；`render` 呼叫處傳 `contextName`。
4. 處理無 invariant 的 `placeholder` case（factory 對它生或整個 extension skip）。

### Step 2（D6）：移 dead create command scaffold
1. `UseCaseRenderer.render`：把 `renderCommandExtension` 呼叫包在 `if !isCreateUseCase`（create UC skip）。
2. 確認 create UC 仍生 Input/Output/Usecase/Service（不受影響）。

### Step 3（D4）：ensureInvariant commented obligation
1. `Aggregate.swift.template`：ensureInvariant body 改成含 `{InvariantObligations}` + NOTE（見介面合約）。
2. `renderAggregate`：算 `{InvariantObligations}`（每 invariant 一行註解 title/errorCode/rules；無 → `(none declared in bundle)`），加進 template vars。

### Step 4（D5，中風險）：when strict-safe reducer
1. `renderCommandExtension`：加參數 `stateFields: [FieldSpec]`（agg.state）+ `payloadFields: [FieldSpec]`（useCase.eventPayload）。
2. 算 strict-safe：for 每 payload field，檢查 (a) name 在 state names；(b) resolved type 等於 state 同名 field 的 resolved type；(c) 非 Set/Array（resolved 不含 `Set<`/`[`）；(d) name 非 `new`/`old` prefix（lowercased）。全部 payload field 都 strict-safe → `{WhenBody}` = `self.<f> = event.<f>` 逐行（state field 是 Optional，assignment compile-pass）；任一不符 → `{WhenBody}` = `fatalError("GENESIS-TODO: implement state transition for \(eventTypeName)")`。
3. `CommandExtension.swift.template`：when body 用 `{WhenBody}` 取代原 GENESIS-STUB 註解。
4. `render` 把 `agg.state` + `useCase.eventPayload` 傳進 renderCommandExtension。
5. **新增 `UseCaseRendererTests.swift`**（補 D5 positive path —— IAM regen 無 strict-safe UC，必須單元測）：strict-safe synthetic → `self.foo = event.foo`；non-strict → fatalError TODO；create UC → 無 command extension。

### Step 5：regen + 對比 + 測試
見驗收標準。

## 失敗路徑

| 條件 | 行為 |
|---|---|
| `Shared/ContextError.swift` init 簽名與 spec 假設不符 | impl 以實際 Read 結果為準調整 factory（不硬套 OC 印象）|
| primitive-only aggregate（無 dtos/customTypes）補 factory | N2 fix（無條件 SharedImport）確保 compile |
| invariant rules 含特殊字元（換行/引號）破壞註解 | `{InvariantObligations}` 生成時 sanitize（單行化）|
| strict-safe 判定誤判（type resolve 差異）| 偏保守：判不準就 fatalError（honest obligation），不生可能錯的 assignment |

## 不改動的部分

- `Repository.swift.template` / `Usecase.swift.template` / `Service.swift.template` — 不動（orchestration 層已對齊）。
- read 側（Projector / ReadModel / Presenter / `/readmodel-mutation`）— 不動。
- `event.yaml` / event-generator-config / plugin 行為 — 不動。
- DDDKit / bundle schema — 不動。
- **command method body**（`{useCaseCamelCase}(...)` 的 `fatalError("not implemented")`）— 不動（domain rule，honest obligation）。

### Non-goals（行為層）
- 本 task **不**改 create-init 簽名（D3 → Phase 1.t.1）。
- 本 task **不**改 `/usecase` skill（Create pattern aggId/UUID 問題 → Phase 1.t.1）。
- 本 task **不**新增 domain-fill skill（D1：no big skill）。
- 本 task **不**生 named `check*()` invariant stubs（D4：避免 Domain Theater）。
- 本 task **不**自動填 command method body / invariant rule body（human）。
- 本 task **不**加 bundle payload provenance 標記（開放問題 #1，defer）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -3                          # 期望 Build complete!
swift test 2>&1 | tail -5                           # 期望全 pass（更新後 renderer 測試）

# regen IAM 專案（domain 層改動端到端）
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -2

# D2: ContextError factory + N2 SharedImport
grep -q 'extension ContextError where ErrorType == UserAccessProfileError' "$TMP"/Sources/UserAccessProfileAggregate/UserAccessProfileError.swift
grep -q 'import IAMContextShared' "$TMP"/Sources/UserAccessProfileAggregate/UserAccessProfileError.swift
grep -q 'static func userIdNotExist' "$TMP"/Sources/UserAccessProfileAggregate/UserAccessProfileError.swift

# D4: ensureInvariant 承載 bundle invariant 註解、無預設 throw
grep -q 'GENESIS-TODO: implement aggregate invariants' "$TMP"/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift
grep -q 'employeeMustActive' "$TMP"/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift

# D6: 無 create command scaffold；非 create 有
! test -f "$TMP"/Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+CreateUserAccessProfile.swift
test -f "$TMP"/Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+PromoteUser.swift

# D5: when reducer — promoteUser（newJobTitle/oldJobTitle 非同名 → 整個 when fatalError）
grep -q 'GENESIS-TODO: implement state transition' "$TMP"/Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+PromoteUser.swift
rm -rf "$TMP"

# N2（primitive-only aggregate）—— IAM fixture 有 DTO 抓不到 N2 bug，必須用 minimal-bundle（MinimalContext，無 DTO/customType）
# 若 agent 誤用 needsSharedForImport 決定 error 檔 import，IAM 會過、primitive-only 才炸 → 這條才是真 N2 驗收
TMP2=$(mktemp -d)
swift run genesis new MinimalContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/minimal-bundle.json --output "$TMP2" --skip-build --no-git 2>&1 | tail -2
ERRFILE=$(find "$TMP2"/Sources -name '*Error.swift' -path '*Aggregate*' | head -1)
grep -q 'import MinimalContextShared' "$ERRFILE"     # N2: 無條件 SharedImport（即使 primitive-only）
rm -rf "$TMP2"
```

> **D5 positive path（strict-safe assignment）無法靠 IAM regen 驗**：IAM 非 create UC 全非 strict-safe（grant/revoke/assign = Set collection；promote/transfer = new*/old* prefix；create 被 D6 skip）→ 沒有 UC 命中 `self.<f> = event.<f>` 分支。**改靠 renderer unit test**（見 Step 4 / 下方 Agent 必做 swift test 含新測）。
> generated `swift build` 需網路抓 DDDKit + plugin，放 Human 補做；Agent 必做以 grep 結構 + renderer unit test 為準。

### Human 補做
- [ ] 對照生成的 `UserAccessProfileError.swift` factory extension 與 OC `AuditQuotingError.swift` factory 形狀一致（function/message 帶法）。
- [ ] 確認生成專案 `swift build` 通過（含 plugin codegen + ContextError factory + ensureInvariant + when fatalError 編譯）。
- [ ] 體感：domain 層 stub 是「誠實 obligation」（TODO/fatalError）而非 fake structure（無假 check 分解、無 silent no-op when）。

## 已知限制

- **create UC domain 仍不可機械完整**：create-init split（D3）defer 到 1.t.1；本 task 後 create UC 的 command/init domain 邏輯仍 human。
- **when strict-safe 判定保守**：type resolve 邊界 case 偏向 fatalError（寧可 honest crash 不可 silent 錯 assignment）。可能對「其實安全」的 case 也 fatalError（人手填）。
- **ensureInvariant 永遠 runnable no-op**：受 DDDKit pre/post-apply 約束，不能 fatalError → 未填的 invariant 不會 fail-loud（只有註解 obligation）。未來可加 `genesis check`-style obligation report（範圍外）。
- **無 payload provenance**：derived payload 欄位（create）來源仍無機械標記（開放 #1 defer 1.t.1）。

### 依賴關係
- 軟相依（done）：parity audit + domain-gap discussion（本 task 來源）。
- 無 hard 阻塞。
- 後續：Phase 1.t.1（D3 create-init + /usecase Create pattern + UUID）。
