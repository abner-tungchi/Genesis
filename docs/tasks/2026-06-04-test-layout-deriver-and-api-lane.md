# TestLayout deriver（M1）+ test-gen api lane + /api fatalError→GenesisTODO（M2）

## 來源

討論：`docs/discussions/2026-06-04-test-api-lane-and-layout.md`（consensus，3-lens adversarial + synthesis）。user 已拍板 5 開放問題（2026-06-04）：

1. **layout = DEEP NOW**（OC-style nested folders；非 rec 的 flat-v1 — 較高風險選項，後果：deriver 直接出 nested path、SourceWriter dir-handling 進 M1）。
2. **verify false-green fix = (b)**：/api scaffold 的 `fatalError` 改 emit `GenesisTODO.notImplemented`（順帶把 Phase 1.z deferred 的 adapter/presenter `fatalError`→`GenesisTODO` 遷移拉進 M2；修 run-time SIGABRT）。
3. **Api lane = always emit**（無 opt-in flag）。
4. **clean-room compile gate = require**（lock v1 前 fresh `genesis new` + emit Genesis-form Api test + `swift build --build-tests`）。
5. **Decimal/Date = codegen 成 String literal**，pin 到 shipped openapi-generator-config；config/naming 變動視為 breaking；其餘非 wire-primitive 走 typed thunk。

## 目標

把 test 檔路徑慣例從「散在 FixtureRenderer 字串 + test-gen SKILL prose（兩者**現在就不一致**：FixtureRenderer 是 deep `SharedUtility/UsecaseCall/<A>.swift`、test-gen 是 flat `<ucPascal>Tests.generated.swift`）」收斂成**單一 codegen-owned `TestLayout` deriver**（M1），並在其上**擴 test-gen 加 `layer: usecase|api` 維度**，讓 OC 的 `<UC>ApiTests`（transport seam）也被產（M2）。順帶把 /api 的 3 個**寫側** `fatalError` stub 遷成 `GenesisTODO.notImplemented` —— 使 `genesis verify` 既有的 Sources/ marker scan **自動**抓到未填的（寫側）Api lane（修掉 D-verify-gap 的 false-green），且寫側 run 時不再 SIGABRT。**範圍限定寫側**：讀側 presenter 的 `fatalError`（`PresenterApplicationService.swift.template:26`，confirmed）仍是 SIGABRT + verify false-green，**不**在本 task（記為 follow-up，見 Non-goals S4）。

依 codegen-vs-retrofit D1：path 慣例是 bundle/名稱的純函數 → deriver（codegen）；但 test bodies 的 SUT/envelope shape 由 **test-gen skill（LLM）** emit（D-C1：擴維度、非獨立 skill、非全 Swift codegen）。

---

## 設計張力與決策（load-bearing）

### T1 — deriver 是 Swift，test-gen 是 LLM skill：「single source」怎麼成立？

`TestLayout` 在 GenesisCore（Swift），但 **test-gen + bundle-plan 都是 prose skill**（從 SKILL.md 文字推導路徑），LLM 在 skill-runtime **無法呼叫 Swift 函數**。故「single source of truth」需具體機制。

**決策（Option A，lean）**：`TestLayout` 以**文檔化的 path-template 常數**為唯一真相；Swift caller（FixtureRenderer）內插它得具體路徑（編譯期鎖）；test-gen SKILL.md prose **逐字 mirror** 同一組 template 字串；新增 `TestLayoutTests` **drift-guard**：讀 repo 內的 `Resources/Templates/skills/test-gen/SKILL.md`，assert 它**逐字包含** `TestLayout` 的 template 常數。任何一方改路徑、另一方沒改 → Genesis 自己的 CI 紅。
> 被否的 Option B（`genesis new` 寫 `.genesis/test-layout.json` 給 skill 讀）= 真 single source 但加 runtime 檔相依 + bundle-plan/test-gen 都要改讀檔，超出 lean v1。記為 follow-up。

### T2 — DEEP layout 的 SourceWriter 風險其實小於討論預期

`SourceWriter.commit()` **已**用 `createDirectory(withIntermediateDirectories: true)`（`SourceWriter.swift:49`）→ nested path 在 `genesis new` 時**本就會建中間目錄**；`rollback()` 已移除空的 created dirs（:74-79）。故 **`genesis new` 端的 deep-folder「mkdir 風險」實質為零**。剩下的 orphan-dir cleanup 只在 **regen 時 UC 改名**（舊 `<ucPascal>/` 變孤兒）才發生 —— 那是 **test-gen（LLM, regen）** 的職責，不在 `genesis new`。
**決策**：M1 **不需**改 SourceWriter 的 new-time 行為（驗證即可）；orphan-on-rename 記為 test-gen SKILL 的 regen 守則（prose），不寫 Swift 自動清理（保守，避免誤刪人檔）。

### T3 — verify-gap fix 因 #2(b) 幾乎免費

3 個 stub 改成 `throw GenesisTODO.notImplemented("...")` 後，`VerifyChecker` 既有的 Sources/ scan（找 `GenesisTODO.notImplemented` 字面，`VerifyChecker.swift:59`）**自動**抓到 → **verify 不需新增掃描邏輯**。唯一 verify-side 工作 = 一條 regression 測（assert 帶 GenesisTODO 的 api stub 被 flag）。
**前提（clean-room gate 驗）**：3 site 皆在 **aggregate module**（`Sources/<A>Aggregate/Adapter/...`，見 `ApiHandlerRenderer.swift:26`、`ApiRenderer.swift:39,69`），各自有唯一 `package enum GenesisTODO`（`AggregateRenderer.swift:262-272`）→ `GenesisTODO.notImplemented` 在該 module 可見且不歧義。context-level handler（`Sources/<Ctx>/Adapter/`）與 read methods **無 fatalError**（已驗：ApiHandlerContext/ApiHandlerReadMethod fatalError count = 0）→ 不在遷移範圍。

### T4 — ApiHandlerMethod 的 `fatalError` 在**非 throwing 的 IIFE** 內

`ApiHandlerMethod.swift.template:13-15` 是 `let asInput: X = { () -> X in fatalError(...) }()`（IIFE 非 throws）。直接換 `throw` 需把 IIFE 改 throwing + call site 加 `try`。**保留 IIFE**（而非把 `throw` 提到方法頂端）以保住下游 `.ok/.notFound/.unprocessableContent` mapping ladder 這個有價值的 codegen。形如：
```swift
let asInput: {UC}ApplicationServiceInput = try { () throws -> {UC}ApplicationServiceInput in
    throw GenesisTODO.notImplemented("TODO(/api skill): construct {UC}ApplicationServiceInput from payload")
}()
```
- 用**直接 `GenesisTODO.notImplemented`**（非 `genesisTODO<T>` helper）→ 該行含字面 token → verify 既有 scan 直接抓（T3）。
- **保留 message 內的 `TODO(/api skill):` 字串** → /api SKILL.md 既有以**訊息**為錨的 locator 大多存活（見 T5）。

### T5 — /api SKILL.md 與 fatalError 深度耦合，必須同步改（M2 範圍）

`skills/api/SKILL.md` grep `fatalError("TODO(/api skill): ...")`、有 exit-code gate 斷言「fatalError 消失」、Edit-replace 它（`:16,25,62,101-103,111,132,154` 等）。遷移後：
- locator 若以 `TODO(/api skill):` **訊息** grep → 存活（保留訊息策略）。
- exit-gate「`fatalError` 消失」→ 改為「`GenesisTODO.notImplemented` / `genesisTODO` 消失」。
- `let asInput = { fatalError(...) }()` 的 replace 範例 → 更新為 `{ throw GenesisTODO.notImplemented(...) }()` 形。
**決策**：M2 把 api/SKILL.md 的 fatalError 錨點逐條改為 GenesisTODO 錨點（保訊息、改 shape gate）。

### T6 — envelope 型別映射（#5）—— 三類，**非**一律 String

> ⚠️ 修正（audit S1）：「wire body field 全 String」**錯**。OpenApiYamlRenderer 對 **collection 欄位**今天就 emit `type: array` + `items:`（`:219-225`，偵測經 `collectionElementType` `:352-363` 認 `Array[X]`/`Set[X]`/`[X]`）→ swift-openapi-generator 產出 Swift **`[String]`**，**非** String。spec 的金標 IAM bundle **7 個寫 UC 有 4 個帶 `Array[String]` body**（`grantPrivilege`/`revokePrivilege`.permissions、`assignRoles`/`revokeRoles`.roles）→ 若 recipe 預設「wire-primitive→String literal」、把 array 丟給「未來 non-primitive thunk」，LLM 會 emit `permissions: "..."` 撞 `[String]` → **clean-room compile gate 在多數 reference UC 失敗**。

envelope 欄位**三類映射**（recipe + thunk lane 須照此分）：

1. **scalar wire-primitive**（`String`/`Int`/`Bool`，含被降為 string 的 `Decimal`/`Date`，見 yamlType `:332-348`）→ codegen **typed literal**（如 `totalAssets: "100.5"`、`count: 3`）。
2. **collection 欄位**（`Array[X]`/`Set[X]`/`[X]`，`collectionElementType != nil`）→ codegen **Swift 陣列字面**（element 為 scalar wire-type 時，如 `permissions: ["a", "b"]` for `[String]`）—— **不是 String literal、不是 thunk**。
3. **genuinely non-primitive ELEMENT type**（`$ref` / nested object / 非 scalar 的 element）→ typed compiling **thunk**（misprediction 不弄壞整個 Api target，因 test-gen 不 build）。

operationId **逐字**（`OpenApiYamlRenderer.swift:170,176`，`ucCamel = uc.useCase`）；**零 casing 轉換**的保證來自 **shipped `openapi-generator-config.yaml.template` 無 `namingStrategy: idiomatic`**（只有 `accessModifier: package`，line 4）—— **breaking-change trigger 是那個 config template 檔，不是 renderer:176**（audit S5）。

---

## M1 — `TestLayout` deriver（先；純 refactor，零行為新增）

### 介面合約

```swift
public enum TestLayout {
    // === 單一真相：path templates（占位符與 test-gen SKILL.md prose 同款：<contextName>/<A>/<ucPascal>）。
    //     TestLayoutTests 斷言 SKILL.md 逐字包含這些 → drift-guard（T1）。===
    public static let usecaseGeneratedTemplate = "Tests/<contextName>Tests/<A>Aggregate/Usecases/<ucPascal>/<ucPascal>UsecaseTests.generated.swift"
    public static let usecaseAuthoredTemplate  = "Tests/<contextName>Tests/<A>Aggregate/Usecases/<ucPascal>/<ucPascal>UsecaseTests.authored.swift"
    public static let apiGeneratedTemplate     = "Tests/<contextName>Tests/<A>Aggregate/Api/<ucPascal>/<ucPascal>ApiTests.generated.swift"
    public static let apiAuthoredTemplate      = "Tests/<contextName>Tests/<A>Aggregate/Api/<ucPascal>/<ucPascal>ApiTests.authored.swift"
    public static let fixtureTemplate          = "Tests/<contextName>Tests/SharedUtility/UsecaseCall/<A>.swift"
    public static let supportTemplate          = "Tests/<contextName>Tests/GenesisTestSupport.swift"

    public enum Layer { case usecase, api }
    public enum FileKind { case generated, authored }

    // === Swift caller 用（內插 template；編譯期鎖）===
    public static func testPath(contextName: String, aggregateName: String, ucPascal: String, layer: Layer, file: FileKind) -> String
    public static func fixturePath(contextName: String, aggregateName: String) -> String
    public static func supportPath(contextName: String) -> String
}
```

- `testPath`：以 `layer`/`file` 選對應 template，`.replacingOccurrences` 把 `<contextName>`→contextName、`<A>`→aggregateName、`<ucPascal>`→ucPascal。**呼叫者傳已轉好的 `ucPascal`**（`CaseTransformer.upperCamel(useCase)`）—— deriver 不做 case 轉換（與 test-gen prose 的推導一致；deriver 只負責 path 組裝）。
- 占位符 token（`<contextName>`/`<A>`/`<ucPascal>`）**故意與 SKILL.md prose 同款**，使 drift-guard 可逐字比對。
- DEEP 慣例釘 OC 金標 = **AuditQuotingAggregate parity 特指**：usecase 在 `<A>Aggregate/Usecases/<ucPascal>/`、api 在 `<A>Aggregate/Api/<ucPascal>/`；檔名帶 layer 後綴 `UsecaseTests`/`ApiTests`（現行 SKILL 的 `<ucPascal>Tests` 無 layer 後綴 → M1 一併改）。
  - ⚠️（audit S6）OC **內部不一致**、deriver 故意只出**正規化子集**：QuotationAggregate 省略 `Usecases/` 層、context-level presenter 落 `<Ctx>/Api/`、AuditQuoting 另有 `ServiceItem/` 中間層與「檔名 ≠ UC」的手寫檔。Genesis 對**所有** aggregate 統一採 AuditQuoting 形（每 UC 一個 `<ucPascal>/` + layer-suffixed 檔名），**非** byte-for-byte 全樹鏡像。Human DEEP round-trip gate 別期待重現 OC 的 ServiceItem/ 或分歧檔名。
- fixture / support 維持現狀路徑（已 OC-aligned；只是改由 deriver 提供）。

### 改動檔案（M1）

| 檔案 | 改動 |
|------|------|
| `Sources/GenesisCore/TestLayout.swift` | **新增** deriver（上述合約）。 |
| `Sources/GenesisCore/FixtureRenderer.swift` | **編輯**：`:71` 的字面路徑改呼叫 `TestLayout.fixturePath(contextName:aggregateName:)`（行為不變，只是換來源；golden 測續綠）。 |
| `Sources/GenesisCore/Resources/Templates/skills/test-gen/SKILL.md` | **編輯**：(a) 輸出路徑（`:17-18,60-62` + 輸入正規化區）從 flat `<ucPascal>Tests.generated.swift` 改 DEEP `<A>Aggregate/Usecases/<ucPascal>/<ucPascal>UsecaseTests.generated.swift`（**逐字採用 `TestLayout.usecaseGeneratedTemplate`/`usecaseAuthoredTemplate`/`supportTemplate`，每條獨佔一行 fenced／bare、不夾 prose、不 line-wrap**，否則 drift-guard 的 `contains` 撈不到、green-by-vacuum，audit S3）；(b) glob 區（`:86`）同步改 deep glob；(c) **@Suite struct 改名（audit S2，compile-blocker）**：`:104` `struct <ucPascal>Tests` → `struct <ucPascal>UsecaseTests`、`:265` `struct <ucPascal>AuthoredTests` → `struct <ucPascal>UsecaseAuthoredTests`（DEEP 把 Usecase+Api 兩 lane 併進同一 test target，struct 名若不帶 layer 後綴 → 與 M2 的 ApiTests 撞 `invalid redeclaration`；drift-guard 只比 path 字串、抓不到此撞名 → 改名指示為**強制**；OC parity 證 struct 名本就帶 layer 後綴如 `EditTotalAssetsApiTests`）；(d) 加 regen 改名孤兒目錄守則（prose，T2）。 |
| `Tests/GenesisCoreTests/TestLayoutTests.swift` | **新增**：(1) golden — `testPath`/`fixturePath`/`supportPath` 對已知輸入產正確 deep path；(2) **drift-guard（硬化，audit S3）** — 讀 `Resources/Templates/skills/test-gen/SKILL.md`，assert 它**逐字含** `usecaseGeneratedTemplate`/`usecaseAuthoredTemplate`/`supportTemplate`（M2 後再加 api 兩條）+ assert 每個 template 常數**非空** + assert **舊 flat token `<ucPascal>Tests.generated.swift`（無 `<A>Aggregate/Usecases/` 前綴）已不存在**（抓半套 migration）。 |
| `Tests/GenesisCoreTests/FixtureRendererTests.swift` | **不改邏輯**（路徑來源換了但結果同；確認 golden 仍綠；若有硬編路徑字串改引用 `TestLayout.fixturePath`）。 |

### M1 不改動

- `SourceWriter.swift`（new-time 已支援 nested mkdir + rollback；T2）。
- `NewCommand.swift` 的 §2.4 PlaceholderTests（`Tests/<Ctx>Tests/PlaceholderTests.swift`，flat、非 per-UC，續留）與 §2.4.1 FixtureRenderer 接線（FixtureRenderer 內部換來源，呼叫不變）。
- `PackageRenderer`（**audit 已確認**：`PackageTestTarget.swift.template` 只宣告 name+dependencies、無 `path:`/`sources:`/`exclude:` → SwiftPM 遞迴納入 `Tests/<Ctx>Tests/` 下所有 .swift，nested DEEP dir 自動涵蓋、不漏測）。
- test bodies / 2-lane emit 邏輯（M1 只動路徑，不動內容）。

---

## M2 — test-gen api lane + /api fatalError→GenesisTODO（M1 後）

### M2.a — /api 3 site fatalError → GenesisTODO（template + skill）

| 檔案 | 改動 |
|------|------|
| `Resources/Templates/v0.1/Api/ApiHandlerMethod.swift.template` | `:13-15` IIFE 改 throwing + `try`（T4 形）；保 `TODO(/api skill):` 訊息。 |
| `Resources/Templates/v0.1/Api/ApplicationService.swift.template` | `:36` `fatalError(...)` → `throw GenesisTODO.notImplemented("TODO(/api skill): execute body for {UC}ApplicationService")`（該 func 已 `async throws`、回 Output；throw 即滿足所有路徑）。 |
| `Resources/Templates/v0.1/Api/DtoStructMapper.swift.template` | `:12` `fatalError(...)` → `throw GenesisTODO.notImplemented("TODO(/api skill): struct DTO toDomain for {DomainTypeName}")`（`init(from:) throws`）。**前提**：mapper 落在 aggregate module（`ApiRenderer.swift:69` = `Sources/<A>Aggregate/Adapter/Dto/...`）→ GenesisTODO 可見；clean-room gate 驗。 |
| `Resources/Templates/skills/api/SKILL.md` | **逐條改錨點**（T5）：locator 保 `TODO(/api skill):` 訊息 grep；exit-gate「fatalError 消失」→「`GenesisTODO.notImplemented`/`genesisTODO` 消失」；`{ fatalError(...) }()` replace 範例 → `{ throw GenesisTODO.notImplemented(...) }()`；description 行的「fatalError TODO bodies」措辭更新。 |

### M2.b — test-gen 加 `layer: api`（SKILL.md prose；LLM emit）

test-gen SKILL.md **always emit 兩條 lane**（#3）：對每個 write UC，除既有 usecase lane 外，再產 api lane 兩檔（`<ucPascal>ApiTests.generated.swift` / `.authored.swift`，路徑經 `TestLayout` api template；**@Suite struct 名 = `<ucPascal>ApiTests` / `<ucPascal>ApiAuthoredTests`** —— layer-suffixed，與 usecase lane 的 `<ucPascal>UsecaseTests` 不撞名，audit S2）。重用既有 harness：`@Suite(.serialized, .tags(.<agg>))`、real localhost KurrentDB、`withTestBundle`、two-file ownership、reconcile 報告、enabled-red ladder。

**codegen 完整 body（MECHANICAL，從 bundle 確定性可生）**：
- **happy-200**：`ApiHandler(kdbClient:)`（非 OC `ApiHandler<MockStorage>`，#4 clean-room 驗的正是這形）→ 呼 `Operations.<ucCamel>` → request envelope 由 bundle 預測（operationId 逐字、path param=`identityName`、header 字面 `operatorId`、body=`uc.input` 去 operatorId/aggId）→ 用 createX fixture 當 Given → 斷言 `response.ok.body.json.<aggId>` re-hydrate。
  - **envelope 欄位三類映射（T6，audit S1，compile-blocker）**：scalar wire-primitive（含 Decimal/Date 降 String）→ typed literal（`totalAssets: "100.5"`）；**collection（`Array[X]`/`Set[X]`/`[X]`）→ Swift 陣列字面（`permissions: ["a","b"]` for `[String]`）—— 不是 String、不是 thunk**；genuinely non-primitive element（`$ref`/nested）→ thunk。IAM 金標 7 寫 UC 有 4 個帶 `Array[String]`（permissions/roles）→ 漏掉 collection 規則 = clean-room gate 多數 UC 紅。
- **aggregate-not-found-404**：斷言 `response.notFound.body.json.error == .aggregateNotFound`。
- imports：**只 `import <A>Aggregate`**（Operations/Components/APIProtocol 由 build plugin emit `package` 進 aggregate module；scratch-compile 已證）。

**thunk-hole（JUDGMENT，走既有 typed-genesisTODO lane）**：
- **bad-input-value 422** + **parse-boundary 422**：live `#expect` on `response.unprocessableContent.body.json.error` + typed `genesisTODO("GENESIS-ARRANGE: ...")` 包 envelope/觸發值；parse-boundary 的 CODE 留人。
- **non-primitive ELEMENT type 的 envelope 欄位**（`$ref`/nested object/非 scalar element；**注意：scalar 的 collection 走上面的陣列字面 codegen、不在此**）→ typed compiling thunk（misprediction 不弄壞整 target）。

**skip**（D-C4）：**不**產 `<UC>ApplicationServiceTests`（usecase lane 嚴格更強；AS delegation 由 api lane 傳遞覆蓋）。

| 檔案 | 改動 |
|------|------|
| `Resources/Templates/skills/test-gen/SKILL.md` | **編輯**：加 api lane recipe（上述）；輸出路徑加 api 兩條（採 `TestLayout.apiGeneratedTemplate`/`apiAuthoredTemplate`）；文件化「Api test enabled-red-但-compiling 只在 `swift build` 後；GREEN 需 /api（填 handler+AS）+ /domain-fill 都跑 → 比 usecase lane 紅更久」。 |
| `Tests/GenesisCoreTests/TestLayoutTests.swift` | drift-guard **補** assert SKILL.md 含 `apiGeneratedTemplate`/`apiAuthoredTemplate`。 |
| `Tests/GenesisCoreTests/VerifyCheckerTests.swift` | **加** regression：帶 `GenesisTODO.notImplemented`（含 IIFE-throw 形）的 Sources/ api stub → `remainingMarkers` 非空（verify 不 false-green）；填好（無 marker）→ 綠。 |

### M2 不改動

- `VerifyChecker.swift` 掃描邏輯（既有 Sources/ scan 已抓 `GenesisTODO.notImplemented`；T3）。
- `ApiHandler.swift.template`（struct 殼 + mapToApiError + init 不變）、`ApiHandlerReadMethod`/`ApiHandlerContext`（無 fatalError）。
- response mapping ladder（`.ok/.notFound/.unprocessableContent`）—— 保留為 codegen 價值。

---

## 失敗路徑

| 條件 | 行為 |
|------|------|
| TestLayout 與 SKILL.md prose 路徑漂移 | `TestLayoutTests` drift-guard 紅（Genesis CI）。|
| /api 未填、Api test 跑 | handler/AS 的 `GenesisTODO.notImplemented` 丟出 → Api test R-SUT 紅（乾淨、可診斷；**非** SIGABRT）。|
| /api 未填、`genesis verify` | Sources/ scan 抓到 `GenesisTODO.notImplemented` → verify 紅（不再 false-green）。|
| GenesisTODO 在某 site 不可見/歧義 | **clean-room compile gate** `swift build --build-tests` 失敗 → lock 前發現（預期：3 site 皆 aggregate module，可見不歧義）。|
| non-wire-primitive envelope field | test-gen emit typed thunk（人填）；compile-ok，misprediction 不弄壞 Api target。|
| regen 改 UC 名 → 舊 `<ucPascal>/` 孤兒 | test-gen regen 守則（prose）提示；不自動刪（T2，保守）。|

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test --filter TestLayoutTests 2>&1 | tail -5         # M1 golden + drift-guard 綠
swift test --filter FixtureRendererTests 2>&1 | tail -5    # 路徑換來源後續綠
swift test --filter VerifyCheckerTests 2>&1 | tail -5      # M2 verify regression 綠
swift test 2>&1 | tail -3                                  # 全 suite 無回歸

# regen IAM（--skip-build）→ 驗 DEEP 路徑 + api lane（注意：test-gen 是 skill，per-UC 檔由 /test-gen 產，
# 故此處驗 deriver/ fixture deep 路徑 + /api stub 已 GenesisTODO；per-UC test 檔的 emit 走 Human 補做）
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1
test -f "$TMP/Tests/IAMContextTests/SharedUtility/UsecaseCall/UserAccessProfile.swift"   # fixture（deriver 來源）
# /api stub 已遷 GenesisTODO（無 fatalError 殘留於 write-side adapter）
! grep -rq 'fatalError("TODO(/api skill)' "$TMP/Sources"
grep -rq 'GenesisTODO.notImplemented' "$TMP/Sources"        # ApplicationService / ApiHandler / DtoMapper stub
# clean-room compile gate（#4）：未填的 GenesisTODO-stub Api 形編得過
( cd "$TMP" && swift build --build-tests 2>&1 | tail -3 )
# verify 抓到未填 stub（不 false-green）
( cd "$TMP" && swift run --package-path /Users/abnertsai/JiaBao/Mendesky/Genesis genesis verify 2>&1 | tail -5 ) || echo "verify exit nonzero = 預期（未填 stub）"
rm -rf "$TMP"
```

### Human 補做（需人介入；含 #4 clean-room 完整鏈）

- [ ] **clean-room Api-test compile gate（#4，lock v1 前必過）**：fresh `genesis new` 一個含 write UC 的 context → 手動跑 `/test-gen <task-spec> `（產 usecase + api lane 兩檔）→ 確認 api 檔在 **Genesis-form**（`ApiHandler(kdbClient:)`，非 OC `<MockStorage>`）+ 只 `import <A>Aggregate` → `swift build --build-tests` **編得過**（predicted envelope 真編）。這是 lock v1 的硬門。**必含一個帶 `Array[String]` body field 的 write UC**（如 IAMContext 的 `grantPrivilege`.permissions）→ 確認 api lane emit `permissions: ["…"]` Swift 陣列字面（**非** `"…"` String）、`swift build --build-tests` 過（audit S1：IAM 7 寫 UC 有 4 帶 array，是多數情況、非邊緣）。同時也覆蓋 usecase+api 兩 struct 共存同 target 不撞名（audit S2）。
- [ ] **DEEP 路徑 round-trip**：`/test-gen` 對一個 UC → 確認檔落在 `Tests/<Ctx>Tests/<A>Aggregate/Usecases/<ucPascal>/<ucPascal>UsecaseTests.{generated,authored}.swift` 與 `.../Api/<ucPascal>/<ucPascal>ApiTests.{generated,authored}.swift`（與 OC 金標 AuditQuotingAggregate 同形）。
- [ ] **enabled-red ladder（api）**：未填時 api happy-test 跑 → R-SUT 紅（GenesisTODO，非 SIGABRT）；`/api` 填 handler+AS + `/domain-fill` 填 domain → 轉綠（需 localhost KurrentDB）。
- [ ] **verify 兩閘**：`genesis verify` 在 /api 未填時紅（抓 GenesisTODO）；填好後 `genesis verify` 綠、`swift test` 視 KDB。
- [ ] **/api skill 對遷移後 marker 仍可運作**：`/api <uc>` 能定位並填 `GenesisTODO.notImplemented` stub（locator 以 `TODO(/api skill):` 訊息錨；exit-gate 改 GenesisTODO 形）。

---

## 不改動的部分（總）

- `SourceWriter`（new-time deep mkdir 已支援）、`VerifyChecker` 掃描邏輯（已抓 GenesisTODO）、response mapping ladder、context-handler/read-method（無 fatalError）。
- bundle / openapi.yaml 生成（OpenApiYamlRenderer 已是純函數，envelope bundle-predictable）。
- usecase lane 的既有 enabled-red 2-lane emit 邏輯（只改路徑，不改內容）。

### Non-goals

- **不**做 flat↔deep 的 runtime flag（user 選 DEEP；flat 退役）。
- **不**做 Option B（`.genesis/test-layout.json` runtime 檔）—— follow-up。
- **不**自動清理 regen 改名的孤兒目錄（prose 守則，保守）。
- **不**產 `<UC>ApplicationServiceTests`（D-C4）；**不**做 Projectors/Invariants-unit/Entity/Listener lane（defer）。
- **不**動 presenter 的 fatalError —— 本 task 只遷 /api 的 3 個 **write-side** site。**audit 已確認（S4，CONFIRMED 非臆測）**：`PresenterApplicationService.swift.template:26` 在 `async throws -> Output`（:23）內 emit live `fatalError("TODO(/presenter-fill skill): …")` → presenter/read execute 跑到時**會 SIGABRT**，且 `VerifyChecker:59` 只掃 `GenesisTODO.notImplemented` → 對此 presenter fatalError **false-green**（正是寫側修掉的 D-verify-gap，讀側仍在）。本寫側 task 的 M2.b api lane **不**呼叫 presenter execute → 不在範圍。**Follow-up（已記）：presenter-fill fatalError → GenesisTODO（讀側 SIGABRT + verify-false-green parity）。⚠️ 該 follow-up 不能直接套用 aggregate-module 解**：presenter 可落 **context level**（`Sources/<Ctx>/Adapter`，`PresenterRenderer.swift:38`），而 context module **沒有** per-aggregate `GenesisTODO`（只在 `<A>Aggregate` 內，`AggregateRenderer.swift:262-272`）→ 需先 emit context-scoped `GenesisTODO`（或 module-qualified throw）才編得過。

---

## 依賴關係

- **來源共識**：`docs/discussions/2026-06-04-test-api-lane-and-layout.md`（D-C1…D-sequence + user 拍板 5 問）。
- **硬相依（done）**：Phase 1.z（test-gen enabled-red 2-lane；VerifyChecker sanitizeSwift + Sources/ marker scan）、FixtureRenderer（deep `SharedUtility/UsecaseCall/<A>.swift` 先例 + 路徑來源待收斂）。
- **軟相依（done）**：Phase 1.h/1.i（ApiRenderer/ApiHandlerRenderer scaffold + 3 fatalError stub）、Phase 1.x/1.y（GenesisTODO throw-marker + genesis verify）。
- **解鎖**：OC `<UC>ApiTests`（transport seam）可被 test-gen 產；test 路徑單一真相（消除 FixtureRenderer↔test-gen drift）；/api 未填的誠實 red + verify-catch。
- **後續**：Option B（runtime layout manifest）；orphan-dir 自動清理；**presenter-fill fatalError→GenesisTODO（CONFIRMED 讀側 SIGABRT + verify-false-green；需 context-scoped GenesisTODO，見 Non-goals S4）**；其餘 test lanes；`/fill-given`。

## 下一步（spec → audit → impl）

write-spec done；**audit-spec done**（adversarial workflow `wf_278fd3b5-edc`，2 lens feasibility/compile + fidelity/scope + synthesis；對照 REAL SourceWriter/ApiRenderer/ApiHandlerRenderer/VerifyChecker/OpenApiYamlRenderer/PackageRenderer/DtoRenderer + OC 金標樹 + swiftc 6.2.3 scratch-compile）。verdict = **NEEDS_FIX, ready_after_fixes=true**（無 fundamental flaw）。**6 findings 已全數 fold 進本 spec**：S1（HIGH，collection→Swift 陣列字面，非 String，T6+M2.b）、S2（HIGH，@Suite struct layer-suffix 改名防撞名）、S3（MED，drift-guard 硬化）、S4（MED，presenter SIGABRT confirmed + context-level GenesisTODO gap）、S5（LOW，config citation 拆引用）、S6（LOW，OC normalized-subset）。confirmed-sound：IIFE-throw `swiftc -typecheck EXIT=0`（且為必需形）、3 site GenesisTODO module-visible（context-shared DTO 不洩）、verify 自動 catch、SourceWriter/SwiftPM 無需改、always-emit api lane 每 write UC 都有 endpoint。residual（只能 impl/clean-room 時驗）：LLM 是否可靠 emit byte-identical path 常數 + 正確分辨 scalar-literal/array-literal/thunk → 靠 clean-room compile gate（#4）守。

~~NEXT → impl~~ → **impl DONE**（2026-06-05，ultracode；M1→M2 + adversarial review wf_baa9a62f-c5d）。全 gate 綠：swift build / TestLayoutTests 5 / VerifyCheckerTests 18 / ApiRendererTests 14 / 全 suite **306 pass · 0 fail · 2 skip** / clean-room `genesis new`+`swift build --build-tests` EXIT=0 / `genesis verify` 抓 /api markers。review 找到 1 HIGH（drift-guard whole-file `contains` = green-by-vacuum，mutation 證明）→ **已修**（改為 split fence、要求 exactly-one fenced block 含全 5 template；mutation-proof 確認現在會 FAIL）+ lens-2 LOW prose tighten（happy-200 fixture 收同一 `<aggId>`）。residual 全落 Human clean-room #4 gate。**尚未 commit**（待 user）。follow-up：presenter fatalError→GenesisTODO（讀側 SIGABRT，需 context-scoped GenesisTODO）。
