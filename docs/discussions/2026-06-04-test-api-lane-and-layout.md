---
topic: "test 生成擴充：Api-test lane（test-gen 加 layer 維度）+ test 檔案 layout 收斂成 codegen-owned deriver（flat vs OC-foldered）"
status: consensus
created: "2026-06-04"
updated: "2026-06-04"
participants:
  - Claude (Opus 4.8)
  - adversarial workflow test-api-lane-and-layout-discuss（3 lens：feasibility/codegen〔swiftc〕、skill-boundary+layout、fidelity+scope+value + synthesis）
facilitator: Claude
rounds_completed: 1
mode: default
premises:
  fixed:
    - "Phase 1.z test-gen = enabled-red 2-lane（usecase 層）；FixtureRenderer codegen bare UsecaseCall fixtures；genesis verify gate。"
    - "codegen-vs-retrofit D1：deterministic → codegen；stochastic judgment → skill。canonicalInputFields / FixtureRenderer 是「deterministic→單一 codegen 來源」先例。"
    - "Genesis-generated ApiHandler = `package struct ApiHandler: APIProtocol { init(kdbClient:) }`（無 MockStorage generic；MockStorage/FileStorageCore 是 OC-specific，Genesis 不生）。response/status mapping（.ok/.notFound/.unprocessableContent + mapToApiError）已 codegen。"
  proposed:
    - "（被推翻）openapi types 是 build-time 產、test-gen 讀不到 → 無法 emit 編得過的 request envelope。"
---

# Api-test lane + test 檔案 layout deriver

## 議題定義
test-gen v1 只攻 usecase 層；OC 的 `<UC>ApiTests`（HTTP/transport）沒被產。要決定：**(A)** Api-test lane 放哪（擴 test-gen 的 layer 維度 / 獨立 skill / codegen），以及 **(B)** test 檔路徑慣例要不要收斂成 codegen-owned 單一 deriver、且 flat vs OC-deep。

## 關鍵發現：那個「make-or-break openapi 字串 wrinkle」其實是假的
我原本框成「Api request envelope 用的 swift-openapi-generator 型別是 build-time 才生、test-gen 讀不到 source → 編不出 envelope」。**3 lens + 實測推翻**：**Genesis 自己用 `OpenApiYamlRenderer`（bundle 的純函數）寫出 openapi.yaml**，所以 envelope 命名是從 **test-gen 已經在讀的同一份 bundle facts** 確定性可預測的：
- operationId = `uc.useCase` 逐字（OpenApiYamlRenderer:176；config **無** `namingStrategy: idiomatic` → 零 casing 轉換）→ `Operations.<ucCamel>`。
- path param = `aggregate.identityName`（:179）；header = 字面 `operatorId`（:180）；body fields = `uc.input` 去掉 operatorId/aggId（:203）。
- **每個 wire field 都收斂成 `String`**（yamlType：Decimal→string :344、Date→string :345；path/header 硬寫 type:string）→ Api envelope **型別單一（全 String）、比 usecase Input lane 還簡單**。
- **scratch-compile 證明**（swiftc 6.2.3，真 OC package，build complete exit 0）：只用 bundle facts 合成的 Api test，**只 `import <A>Aggregate`** 就 typecheck（Operations/Components/APIProtocol 由 build plugin emit `package` 進 aggregate module；build 本來就是 `swift test` 的前置）。
→ wrinkle 是 **build-order 事實**（型別 build 後才在），不是 **unpredictability**。test-gen 仍不 build，predicted envelope 在 `swift build` 後可編。

## 決策紀錄

| # | 決定 | 理由 |
|---|------|------|
| **D-C1** | **擴 test-gen 加 `layer: usecase\|api` 維度**，重用 harness/fixture-Given/enabled-red/verify。**不**獨立 `/api-test` skill、**不**全 codegen。 | ~75% shell 共用；差的 ~25%（SUT call / status-assert / envelope split）是 bundle-deterministic。`ApiHandlerMethod.swift.template` 已 commit 到每個 build-generated 名 → 證明可預測。獨立 skill 會把 verify 合約/firewall/two-file/fixture-consume 慣例 fork 成第二份 prose 要手 sync（就是 path 慣例已經 split 的那種 drift）。|
| **D-wrinkle** | **predict envelope from bundle**（operationId 逐字、wire 全 String）：wire-primitive body field → literal envelope；non-primitive field → typed compiling thunk。 | Genesis 兩端都自己擁有（寫 yaml + 寫 test），predict = 讀自己的 OpenApiYamlRenderer 非外部 generator。non-primitive thunk fallback 保證 misprediction 不會弄壞整個 Api target（test-gen 不 build）。|
| **D-C2-deriver** | **加 `TestLayout.testPath(aggregate:useCase:layer:)` 到 GenesisCore**，FixtureRenderer + test-gen + api-lane 全 migrate 到它。 | 已驗 split bug：FixtureRenderer:71（deep `SharedUtility/UsecaseCall/<A>.swift`）vs test-gen SKILL.md:59-62（flat `<UC>Tests.generated.swift`）**現在就不一致**；SKILL prose 讓 LLM 每跑重推 path（drift）。加 api 層不收斂 = 第三份 copy。canonicalInputFields 先例。|
| **D-C2-layout** | **v1 = flat-with-layer-suffix**（`<ucPascal>UsecaseTests` / `<ucPascal>ApiTests`，經 deriver）；deep-folder mode 留 flag defer。 | flat-無-suffix 一加 api 就撞（`<UC>Tests` vs `<UC>ApiTests`，再被 .generated/.authored 加倍）；suffix 解掉。載重需求是「**一個 deriver 擁有慣例**」非資料夾深度 → 有了 deriver，flat→deep 是 one-function change 零 call-site churn。deep 在 OC scale（~40 UC/agg → 80+ 檔）有導航價值但加 SourceWriter mkdir/orphan-cleanup 風險 → defer。fixture 檔仍在 `SharedUtility/UsecaseCall/<A>.swift`（跨 UC 共用、非 per-UC leaf）。 |
| **D-C3-thunks** | codegen：SUT standup / envelope structure / wire-String types / happy-200 + not-found-404 status。thunk-hole：bad-input VALUE、parse-boundary CODE+VALUE、non-primitive envelope field。 | 那三個是真 judgment：觸發值是人意圖、parse-boundary code 是 /api-author 的 branch 選擇（firewall-opaque、不在 bundle §5）、non-primitive envelope test-gen build 不出來。皆走 test-gen 既有的 typed-genesisTODO JUDGMENT lane。 |
| **D-C4** | **v1 跳過 `<UC>ApplicationServiceTests`**；usecase（domain seam）+ api（transport seam）為兩條 canonical lane。 | 真 diff 證明它 = usecase test 改 SUT 型別 + output 欄位名 + inline-vs-named-Input；usecase test 嚴格更強（多 2 個 re-hydration 斷言）。零新 failure mode；AS delegation 透過 Api lane 傳遞性覆蓋。生它 = per-UC 測數 3x、verify matrix 膨脹、~零邊際覆蓋（OC 那 ~117 個近重複是 imported bloat）。**非永久**：若 AS 之後有自己的 failure mode 再給它 seam。 |
| **D-verify-gap** | **擴 genesis verify**，讓它不會在 /api 的 `fatalError` stub 未填時 false-green Api lane。 | NEW finding：VerifyChecker 只掃 `GenesisTODO.notImplemented`（:59,63）；但 /api 的兩個 stub 是 `fatalError("TODO(/api skill):")`（ApiHandlerMethod:14 + ApplicationService:36）→ verify **目前會 false-green** handler 還是 fatalError 的 Api lane。要嘛掃 fatalError sentinel、要嘛 /api scaffold 改 emit GenesisTODO marker（後者順便修 run 時 SIGABRT 風險）。 |
| **D-sequence** | **M1 先出 TestLayout deriver（純 refactor）→ M2 才做 api layer 維度。** | M1 便宜、全 deterministic、修掉現有 split-path bug、在任何 Api code 前 de-risk placement。耦合會讓 deriver 卡在 envelope-prediction 的高風險部分。 |

## 改動面 / LEAN v1 scope
- **M1（先，低風險純 refactor）**：`TestLayout.testPath(aggregate:useCase:layer:)` 進 GenesisCore；FixtureRenderer:71 + test-gen SKILL.md:59-62 migrate；usecase 測改出 `<ucPascal>UsecaseTests.generated.swift`/`.authored.swift`（flat-with-suffix）。確認 SourceWriter 處理 renamed leaf path。**不**加新 lane。
- **M2（M1 後）**：test-gen 加 `layer:.api`。
  - **codegen 完整 body** 兩條 mechanical lane：happy-200（`ApiHandler(kdbClient:)` + bundle-derived envelope〔String wire fields〕+ createX fixture 當 Given + `response.ok.body.json.<aggId>` re-hydrate 斷言）；aggregate-not-found-404（`response.notFound.body.json.error == .aggregateNotFound`）。重用 @Suite/.serialized/.tags、repo init、withTestBundle、two-file、reconcile。
  - **thunk-hole**：bad-input-value 422 + parse-boundary 422（live `#expect` on `response.unprocessableContent.body.json.error` + typed genesisTODO envelope/value thunk；parse-boundary 的 CODE 留人）。
  - **non-wire-primitive** body field 的 envelope → typed compiling thunk（misprediction 不弄壞整 target）。
  - **擴 genesis verify**：不 false-green /api fatalError stub 未填的 Api lane。
  - **文件化 sequencing**：Api test enabled-red-但-compiling 只在 `swift build` 後；GREEN 需 **/api（填 handler+AS）+ /domain-fill** 都跑 → 比 usecase lane 紅更久。

## 開放問題（user 已拍板 2026-06-04）
1. **layout** → **DEEP NOW（OC-style nested folders）**。⚠️ user 選了 minority-lens / 較高風險選項（非 rec 的 flat-v1）。**後果**：M1 的 `TestLayout` deriver 直接出 nested path，且 **SourceWriter 必須在 M1 就支援 create intermediate dirs + UC 改名時 orphan-dir cleanup**（討論原本想 defer 的風險被拉進 M1）。
2. **verify false-green fix** → **(b)**：/api scaffold 改 emit `GenesisTODO.notImplemented`（同時把 Phase 1.z deferred 的 adapter/presenter `fatalError`→`GenesisTODO` 遷移拉進 M2；順便修 run-time SIGABRT）。
3. **Api lane** → **always emit** 兩條 lane（無 opt-in flag）。
4. **clean-room compile gate** → **require**（Claude 無論如何都做）：lock v1 前 fresh `genesis new` + emit Genesis-form Api test（`ApiHandler(kdbClient:)`，非 OC `<MockStorage>`）+ `swift build --build-tests` 確認 predicted envelope 真編得過。
5. **Decimal-as-String 門檻** → **codegen 成 String literal**，pin 到 shipped openapi-generator-config；config/naming 變動視為 breaking。其餘非 wire-primitive（含未來 $ref/non-primitive envelope field）走 typed thunk。

## 下次討論指引
spec_ready = true，**5 開放問題已拍板**。NEXT → write-spec（**兩個 milestone**：M1 TestLayout deriver〔含 SourceWriter deep-dir 支援 + orphan cleanup〕；M2 api layer 維度 + verify-gap fix〔/api fatalError→GenesisTODO〕）→ audit-spec → impl。載重點：D-wrinkle（predict-not-build；non-primitive→thunk）、D-C2-deriver（單一來源）、**layout=DEEP（SourceWriter dir-handling 進 M1）**、D-verify-gap（否則 Api lane false-green）、D-sequence（M1 先）。
