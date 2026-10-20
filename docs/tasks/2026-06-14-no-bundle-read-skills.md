# No-bundle read-side skills：`/read-projector` + `/read-view`（reproduce AuditQuoting read 架構，不經 bundle）

## 來源

- 討論：`docs/discussions/2026-06-14-no-bundle-read-skill-design.md`（understanding inventory `wf_d9e76c6c-c92` + design discuss `wf_b34faef0-447`，3-lens + synthesis，全程 file-traced 對照 OC AuditQuotingAggregate + Genesis 模板）。spec_ready=true、無 user-blocking 問題。
- user goal：建立**不使用 bundle** 但能建 readmodel / projection / presenter / read-api / test 的 skill；以 **OC `AuditQuotingAggregate`** 的讀側架構為**目標 + 驗證條件**；可分多個 skill；同一問題修 3 次以上停下求助。

## 目標

讓使用者在一個 **Genesis-generated 專案內**、**不碰 bundle**、用互動 skill 把一條讀路徑（read model → projection → presenter → read API → tests）scaffold 出來，結構等同 OC `AuditQuotingAggregate`。北極星三條：
1. **目標架構** = AuditQuoting 讀側的 layering / 檔案結構 / pattern（projector→read-AS→api-handler→openapi→tests、wire↔domain id-rename 邊界、aggregating-view 能力）。
2. **整合約束** = 產出必須在 Genesis-generated 專案**編得過**（Genesis-form：`ApiHandler(kdbClient:)` 非 `ApiHandler<MockStorage>`、`StreamNaming.categoryPrefix=uppercaseLetters(contextName)` 絕不硬寫 `OC`、`package` access、沿用既有模板慣例）。
3. **無 bundle** → 互動 elicitation + 從既有專案 infer（`event.yaml`、`Sources/*Aggregate/`、`openapi.yaml`、`projection-model.yaml`）。

---

## 設計決策（discuss 已鎖；對照 OC + Genesis 模板）

| # | 決定 | 理由 |
|---|------|------|
| **D-SPLIT** | **2 個 net-new skill**：`/read-projector`（一條 passthrough read-model unit）+ `/read-view`（一條 aggregating read API）。**復用**既有 `/readmodel-mutation`（填 projector when() body）+ `/presenter-fill`（只填 trivial single-presenter passthrough AS）。**不**做單一 `/read-scaffold`、**不**做獨立 `/read-test`（test 折進各自 skill、依 shape 條件產）。 | OC 磁碟上兩種**物理不同**讀 shape：`Usecase/Projector/Get<Noun>/`（16 dirs：ReadModel+Presenter[+element DTO]）vs `Adapter/Get<View>/`（4 aggregators：AS+output DTO）。檔案集/測試 tier/fill seam 皆不同。`/presenter-fill` SKILL line 70 對 >1-field 直接 exit 3 且不碰 ApiHandler → 9-presenter aggregating AS 不能交給它，必須 `/read-view` 自己生 AS body。每個 skill 1:1 對映一個 OC 目錄 → 結構性重現非 heuristic。 |
| **D-Q1a** | **ApiHandler 整合走 Genesis-form**：`/read-view` **永不**宣告/編輯 ApiHandler struct header / generic / init，**只 append** 一個 read method 進既有 handler body，內用 `Get<View>ApplicationService(kdbClient: kdbClient)`。 | OC 的 `ApiHandler<Storage>` generic 只因 write command 用 storage；4 個 read method 全只碰 `kdbClient`（ApiHandler.swift:31,94,132）。Genesis 模板非 generic。read method body 兩種 handler 皆可移植；重宣告 header 會 fork 專案 handler。 |
| **D-Q1b**〔audit S1 修正：兩個錯誤決策**解耦**〕 | **notFound 一律 NAMED per-aggregate**（`.<agg>NotFound` 如 `.auditQuotingNotFound`），**不**條件於 not-applicable rule。`/read-view` 永遠走 **atomic 3-file lockstep**：`{A}QueryError.swift` 加 `case <agg>NotFound` + ContextError factory；openapi `{A}ApiError` enum 加 `- <agg>NotFound`（append-if-absent）；handler catch `where error.error == .<agg>NotFound` → `.notFound(.init(body:.json(.init(error:.<agg>NotFound))))`。**不**用 Genesis-generic `.aggregateNotFound`（那只出現在 write-side DDDError catch）。 | **磁碟反證 audit 原假設**：GetOperationInfoApplicationService.swift:29 + GetEvidenceInfoApplicationService.swift:28 **皆無** not-applicable rule 卻 throw 具名 `.auditQuotingNotFound`，handler（ApiHandler.swift:122,150）catch `.auditQuotingNotFound`→`.notFound(.init(error:.auditQuotingNotFound))`。故「named auto-on-when-not-applicable」會對 2/4 view 產生 generic 偏離 → 違反 golden gate 3(g)。OC 讀側 notFound **一律具名**。三檔皆 skill write scope，不 fork renderer。 |
| **D-Q1c**〔與 D-Q1b 正交的**獨立** axis〕 | openapi GET op 的 **422 + not-applicable case 條件式**：**只有 view 有 not-applicable rule** 才 emit `UnprocessableEntityError` response + `.unprocessableContent` handler catch + `{A}QueryError` 的 `.<x>NotApplicable` case（同樣 3-file lockstep 進 QueryError + ApiError enum）。否則只 404+503。**handler catch set 與 openapi response set 每 op 必一致**。**注意：notFound 具名（D-Q1b）與 not-applicable 422（本條）是兩條獨立 axis** —— 一個 view 可以「具名 notFound + 無 422」（GetOperationInfo/GetEvidenceInfo）或「具名 notFound + 有 422」（GetQuotingProofs/GetPredecessorServiceInfo）。 | 磁碟確認：getQuotingProofs/getPredecessorServiceInfo emit 404+422+503 且有 422 catch；getOperationInfo/getEvidenceInfo 只 404+503 無 422 catch。always-422 會記錄 handler 產不出的 response。no-bundle 直接寫 GET op、不呼叫 always-422 的 OpenApiYamlRenderer，故 conditional 零成本。 |
| **D-Q2** | **無 QueryError→ApiError mapper**：`mapToApiError` 維持只處理 `ContextError<{A}Error>`（write）。read handler 以 inline `where error.error == .<case>` raw-case catch。`/read-view` 的 handler method 須含 **DTO→Components.Schemas 的 response-mapping switch**（discriminated output；OC 在 handler 內做，非單行 return）。 | OC 無 QueryError mapper（mapToApiError 只 ContextError<AuditQuotingError>）；read handler inline raw-case。加 mapper 是 OC 沒有的 net-new 抽象、無 fan-in 效益。in-handler response switch 是 OC 對 stock ApiHandlerReadMethod 模板的確認 divergence，由 `/read-view` 擁有。 |
| **D-Q3**〔audit S3 修正：per-variant，非 3→2〕 | `/read-view` 消費 **persisted YAML mini-spec**：`discriminator{sourcePresenter,sourceField,cases[]}`；**`variants[]{ enumCase → { outputCase \| notApplicable: <naCase> }, fields[]{name←sourcePresenter.field,type} }`**（每個 discriminator enum case 各自映到「一個具名 output case」**或**「notApplicable throw」—— **不**假設 3→2 收斂）；`fields` per outputCase。首跑 AskUserQuestion 產出 → 寫在 AS 旁 → regen AS。on-disk Sources tree 仍唯一 SSOT；mini-spec 是 per-view replay artifact，**非** shadow bundle。 | variant→fieldset 矩陣多維、跨 aggregator 形狀**不同**：GetOperationInfo `.established→.established(8)`、`(.establishing\|.unestablished)→.nonEstablished(5)`；**GetPredecessorServiceInfo 是真 3-way**：`.established→.established`、`.establishing→.establishing`（**獨立** output case，非 nonEstablished）、`.unestablished→throw .predecessorServiceInfoNotApplicable`。硬編 3→2 會讓 LLM 對 GetPredecessorServiceInfo 產錯 switch + 錯 output enum。AskUserQuestion 純互動會碎成數十序列 prompt → declarative mini-spec 可審查 + idempotent。 |
| **D-Q4** | Input 命名 **layer-determined**：presenter 層 `Get<Noun>Input: CQRSProjectorInput`（init param=domain key 如 `auditQuotingId`，存進 local `id`）；aggregating AS 層 `Get<View>ApplicationServiceInput`（長後綴，**非** OC 短 `GetOperationInfoInput`）。 | OC 16 presenters 100% 一致用 `Get<Noun>Input:CQRSProjectorInput`（=Presenter.swift.template:7）。drift 只在 AS 層；兩個 Genesis 模板（PresenterApplicationService.swift.template:5、ApiHandlerReadMethod.swift.template:6）已標準化長後綴。長後綴也避免 view 名與 projector 名同 module 撞名。純機械規則。 |
| **D-Q5**〔audit S4/S6/S7 修正〕 | test tier **依 shape 條件產**。`/read-projector` 產 **Projector tier**（`Get<Noun>PresenterTests` + **每個 read-model 引用的 nested DTO 一個 `<Dto>Tests`，不論該 DTO source 在 co-located dir 或 module 他處**〔S7：OC `FileTypeDtoTests` 在 GetQuotingProofs test dir 但 `FileTypeDto` source 在 OCShared〕）。**例外（S6）：inverted-index / lookup projector（read-model `id` 欄位 ≠ aggregate-id，如 `GetAuditQuotingIdByQuotingCaseId` id=quotingCaseId）不產 Projector test** → Projector-tier test **opt-out/conditional**；golden compare 容忍 16-dir/15-test 不對稱。`/read-view` 產 **AS tier**（`Get<View>ApplicationServiceTests`：**notFound + not-applicable〔有則〕 + 每個 output shape ≥1 happy-path** —— discriminated view 每 output case 一個、passthrough-collection 一個）**且** **Api tier**（`Get<View>ApiTests`）。passthrough 無 AS tier；aggregating 無 Projector tier。 | 磁碟確認：Projectors/ 16 dir / 15 test（GetAuditQuotingIdByQuotingCaseId 無 test、是 inverted-index）；ApplicationServices/ 與 Api/ 只含 4 aggregator。test-gen D-C4「skip AS」是 write-side 專屬；read aggregating AS 帶 discriminator 分支邏輯 api lane 無法 per-output 便宜涵蓋 → OC 保留 AS test。nested DTO test co-located 在 owning read-model test dir（即使 type source 不在該 dir）。 |
| **D-Q6** | element/output DTO 由**擁有其檔案的 skill** 產、co-located 在同 `Get<X>/` dir。collection-element struct DTO（`QuotingProofDto`）+ enum-wrap-domain DTO（`ProofTypeDto`：type decl + `init(from:)` skeleton）→ `/read-projector`；output discriminated-enum DTO（`OperationInfoDto`）→ `/read-view`。**無**獨立 `/dto` skill。when()-body 的 Dto-convert wiring 仍歸 `/readmodel-mutation`。**caveat**：referenced enum-wrap DTO 已存在 module 他處（如 OC `FileTypeDto` 不在 GetQuotingProofs/）→ glob-check 先、存在則**不**重 emit（idempotency Class A）。 | OC 從不用 shared `Dto/` dir；element DTO 與 owning read model co-located。`[QuotingProofDto]` 欄位無 element DTO 編不過 → emission 必與 read model atomic。填 Genesis ReadModelRenderer 不產 element DTO 的 gap。FileTypeDto 缺席證明須 glob-existence-check、不可盲目 co-locate。 |
| **D-Q7** | **no-bundle idempotency = 2 write-class**，on-disk tree 為唯一 SSOT（無 shadow JSON）。**Class A（own-file**：ReadModel/Presenter/element DTO/AS/output DTO/test）：glob exact path，**存在則 SKIP**（永不覆寫手填 body）—— 鏡像 `NewCommand.scanExistingPresenterPaths` + `ReadModelRenderer.swift:138` scaffold-once。**Class B（shared-file**：projection-model.yaml、openapi.yaml、ApiHandler read method、`{A}QueryError`、`{A}ApiError` enum）：read → **exact-key-anchored** match（`Get<Noun>:` / `paths.<path>:` / `func get<View>(` / `case <name>`）→ 存在則 **replace-in-place**，否則 **append**；**fail-closed**（拒絕+問）on **ambiguous near-name**（如 `GetEvidenceCount` vs `GetEvidenceInfo`），絕不盲 append（重複 YAML key → projection deploy 爆）。named-error 為 atomic 3-file lockstep、各檔 append-if-absent、絕不 partial。 | 拿掉 bundle = 拿掉 full-file re-render 保證；盲 append 會雙寫。2-class 還原收斂性：glob-skip 是 owned-file 既有 precedent；name-keyed upsert 是 shared-file 的最小替代。shadow state file = bundle by another name、會與手編 drift、違反 no-bundle + convention-over-config。 |
| **D-Q8** | test wait seam emit `Task.sleep(for: .seconds(0.5))`（OC-canonical，golden-equivalence 必須）。每個 read-test 檔加 **prerequisite header 註解**：需 localhost KurrentDB + deployed projection、先跑 `/reset-projection`。poll-until-consistent helper **defer** follow-up，不卡 v1。 | Task.sleep 是唯一同步機制、遍佈 OC projector/AS/api test。withTestBundle 無 KDB 存活 guard → 死 KDB 變 silent hang → 必須文件化 prerequisite。改 seam 會破 golden 結構等價。 |
| **D-placement** | **GOLDEN PLACEMENT INVARIANT**（skill 必守、validation 必查）：passthrough view → `Usecase/Projector/Get<Noun>/` **且** 進 `projection-model.yaml`（它 project 一條 stream）；aggregating composite view → `Adapter/Get<View>/` **且不**進 `projection-model.yaml`（它 compose 既有 presenter，不 project 新 stream）。discriminator presenter（`GetCustomerEstablishmentStatus`）本身是 passthrough projector（有 projection-model entry），由 `/read-projector` 產、被 `/read-view` 依賴。 | 磁碟確認：projection-model.yaml 有 16 個 `Get<Noun>` key（含 GetCustomerEstablishmentStatus），但**無** GetOperationInfo/GetEvidenceInfo/GetPredecessorServiceInfo aggregator。aggregator 落 Adapter/、fan out 既有 presenter。誤放 aggregator 進 Projector/ 或 projection-model 是結構性 regression。 |

---

## M1 — `/read-projector`（一條 passthrough read-model unit）

### 輸入（AskUserQuestion，對照 on-disk `event.yaml`，零 bundle）
- read-model 名 `Get<Noun>`（驗 `^Get[A-Z][A-Za-z0-9]+$`）。
- aggregate（從 glob `Sources/*Aggregate/` 推單選；或 `<context-level>`）。
- key field domain 名（如 `auditQuotingId`）+ **`key.fromEventPayload`**（wire 名，如 `quotingId`）+ key type。
- source events（multiSelect，從該 aggregate `event.yaml` 列）。
- stored fields（name+type；scalar-optional vs collection-of-DTO）。collection：element DTO 名 + 欄位集 + nested enum DTO。

### 輸出檔案（Genesis-form，pin 見下）
- `Sources/<A>Aggregate/Usecase/Projector/Get<Noun>/<Noun>ReadModel.swift`（`ReadModel.swift.template` 形）。
- `.../Get<Noun>Presenter.swift`（`Presenter.swift.template` 形：`Get<Noun>Input:CQRSProjectorInput` + 4 typealias + `categoryRule .fromClass(withPrefix:"<StreamNaming prefix>")` + buildReadModel `.init(<keyField>: input.id)` + 每 event 一個 **empty `when()` stub**〔`_ = readModel; _ = event;`〕scaffold-once）。
- `.../{element}Dto.swift`（collection-element struct DTO：`Equatable, Codable` + memberwise init + `init(from domainModel:)` skeleton）+ `.../{enum}Dto.swift`（enum-wrap：`String` enum + `init(from:)` skeleton）—— **glob-skip 若型別已存在 module 他處**。
- **APPEND** `Get<Noun>:` block 到 `Sources/<A>Aggregate/projection-model.yaml`（`model: readModel` + events）。
- `projections/<prefix>Get<Noun>Projection.js`（`fromStreams(["$ce-<prefix><Agg>"])` + 每 event 一行 `<Event>: handleEvent` + `linkTo("<prefix>Get<Noun>-" + event.body["<key.fromEventPayload>"], event)`）。
- `Tests/<Ctx>Tests/<A>Aggregate/Projectors/Get<Noun>/Get<Noun>PresenterTests.swift` + 每 co-located element DTO 一個 `<Dto>Tests.swift`（純 DTO test，無 @Suite/KDB）。

### 洞（留給既有 skill 填）
- Presenter `when()` body → `/readmodel-mutation`（含 Dto-convert wiring）。
- 若此 noun 也被當 trivial single-presenter view 暴露 → 其 read-AS body → `/presenter-fill`。

### key.fromEventPayload silent-empty guard（carry-over，載重；audit S2 修正）
no-bundle 失去 `ReadModelRenderer.swift:67-96` 的 compile-time guard → `/read-projector` 必須在 elicitation 時**讀 `event.yaml`** 驗 `key.fromEventPayload` 存在。⚠️ **payload set 必須是 `properties[].name ∪ {aggregateRootId.alias}`**（含 createdEvent 的 aggregateRootId.alias），**非**只 `properties[]`：OC 全 16 個 read model 的 wire key（`quotingId`）**就是 `aggregateRootId.alias`、不在 `properties[]`**（如 `TotalAssetsEdited` 的 properties = quotingCaseGroupingId/quotingCaseId/totalAssets，quotingId 只在 `aggregateRootId.alias`，event.yaml:53）。只查 properties[] 會**誤擋 100% 合法 run**（bundle 版 guard 透過 `bundle.useCases[].eventPayload` 已 fold 進 aggregateRootId，no-bundle 須顯式 union）。常態：`key.fromEventPayload` **==** `aggregateRootId.alias`。不在此 union → 擋下並提示。**錯 linkTo id = read model 永遠靜默空**（最高 blast-radius）。

### 驗證目標（OC parity）
file-set == OC `Usecase/Projector/Get<Noun>/` + projection-model.yaml entry；`linkTo` id key == `key.fromEventPayload`（wire）非 readmodel local key（domain）。scalar 例 `GetTotalAssets`（`var totalAssets: Decimal?`、無 init default）、collection 例 `GetQuotingProofs`（`var proofs:[QuotingProofDto]`、init `self.proofs=[]`、append+removeAll when）。

---

## M2 — `/read-view`（一條 aggregating read API）

### 輸入
- view 名 `Get<View>`。
- **persisted YAML mini-spec**（D-Q3 schema），首跑 AskUserQuestion 互動產出、replay 時讀檔。
- **prerequisite（audit S5）**：discriminator presenter + 每個 source presenter 須**已存在 on-disk 且其 `projection-model.yaml` entry 也在**（glob-verify Presenter 檔 **AND** grep projection-model key；缺任一 → exit + prerequisite hint「先 `/read-projector` 產 `GetCustomerEstablishmentStatus` 等」）。理由：fan-out 用的 `Get<Source>EventMapper()` 是 **ModelGeneratorPlugin 從 source presenter 的 projection-model entry 生成**（驗：12 個 generated `Get*EventMapper`、Sources/ 內 0 個手寫），projection-model entry 缺 = EventMapper 不存在 = AS 編不過。`/read-view` **絕不**自己 emit EventMapper。

### 輸出檔案
- `Sources/<A>Aggregate/Adapter/Get<View>/Get<View>ApplicationService.swift` —— **FULL body**（async-let fan-out + enumCase→outputCase switch + not-applicable throw；用 `Get<View>ApplicationServiceInput`；**非** fatalError TODO）。body 形（pin）：
  ```
  let id = input.<keyField>
  guard let <disc> = try await fetch<Disc>(id: id) else {
      throw ContextError<<A>QueryError>.<notFoundCase>(in: .struct(Self.self, function: #function), message: ...)
  }
  // optional: if <disc> != .<x> { throw ContextError<<A>QueryError>.<naCase>(...) }
  async let <fieldA> = fetch<SourceA>(id: id)
  ...
  switch <disc> {
  // audit S3: PER-VARIANT mapping — each discriminator enum case maps to EITHER (i) a named output case
  // OR (ii) a notApplicable throw. NOT a hardcoded 3→2 collapse. The mini-spec drives this per view:
  //   GetOperationInfo:  .established→.established(8 fields); (.establishing|.unestablished)→.nonEstablished(5)
  //   GetPredecessorServiceInfo (genuine 3-way): .established→.established; .establishing→.establishing (DISTINCT case); .unestablished→throw .predecessorServiceInfoNotApplicable
  case <enumCaseA>: return .<outputCaseA>(.init(<f>: try await <f>, ...))
  case <enumCaseB>: throw ContextError<<A>QueryError>.<naCase>(in: .struct(Self.self, function: #function), message: ...)
  // ... one arm per discriminator case, exhaustive
  }
  ```
  fetch helper：`try await <Source>Presenter(coordinator: .init(client: kdbClient, eventMapper: <Source>EventMapper())).execute(input: .init(<keyField>: id))?.readModel.<field>`。
- `.../{View}Dto.swift` **（僅 discriminated view）**：output discriminated-enum DTO（`enum OperationInfoDto { case established(EstablishedOperationInfoDto); case <case2>(...) }` + 各 variant struct，欄位全 optional、domain-typed）。⚠️ **audit S4：passthrough-collection view（如 GetQuotingProofs，mini-spec 無 discriminator）不產 `{View}Dto.swift`** —— Output 直接是 `[<Element>Dto]`（複用 `/read-projector` 已產的 element DTO），AS 也無 discriminator switch（驗：Adapter/GetQuotingProofs/ 只有 AS 一檔）。
- **APPEND** read method 進既有 `Sources/<A>Aggregate/Adapter/ApiHandler.swift`（`func get<View>(_ input:)`；用 `Get<View>ApplicationService(kdbClient: kdbClient)`；named notFound catch〔D-Q1b〕+ conditional 422 catch〔D-Q1c〕；**不**動 handler header/generic/init/mapToApiError）。response mapping **依 shape**：discriminated → **DTO→Components.Schemas 的 switch**（`switch output { case let .established(info): … }`，OC ApiHandler.swift:98-120）；passthrough-collection → **`.map`** over element DTO + 單 `.ok`（OC ApiHandler.swift:34-43），**無** switch。
- **APPEND/UPSERT** GET op 進 `Sources/<A>Aggregate/openapi.yaml`（operationId `lowerCamel(view)`、200 oneOf+discriminator〔discriminated〕或 array/items-$ref〔collection〕、404+503 always、**422 conditional**〔D-Q1c〕、notFound case 具名〔D-Q1b〕）。**path kebab（audit S8）**：`/<agg-kebab>/{<wireId>}/<kebab-view>`，但 (a) collection GET 須 disambiguate 與既有 POST 同名 path —— OC 慣例 **append `-list`**（`GetQuotingProofs` → `/audit-quotings/{quotingId}/quoting-proof-list`，因 `uploadQuotingProof` POST 已佔 `/quoting-proofs`）；(b) Class-B `paths.<path>:` upsert **fail-closed** 當目標 path 已有**不同 HTTP verb** 的 method（不可把 GET 併進別人的 POST path-item）。
- named-error 時：3-file lockstep `{A}QueryError.swift`（加 case + ContextError factory）+ openapi `{A}ApiError` enum（append-if-absent）+ handler catch。
- `Tests/.../ApplicationServices/Get<View>/Get<View>ApplicationServiceTests.swift`（每 variant + notFound + not-applicable〔有則〕）+ `Tests/.../Api/Get<View>/Get<View>ApiTests.swift`（full HTTP seam、`withTestBundle` + `Task.sleep(.seconds(0.5))` + wire-String 斷言、prerequisite header）。

### 洞
**AS body 無洞**（從 mini-spec 全生成）—— 這是與 `/presenter-fill`（留 fatalError）的關鍵差異。

### 驗證目標
落 `Adapter/Get<View>/`（**非** Projector/、**非** projection-model.yaml）；AS output enum + per-field source mapping 對齊 OC；openapi 422-conditionality 與 handler catch set 一致；build clean。例：`GetOperationInfo`（discriminator establishment-status、established{8}/nonEstablished{5}、9-presenter fan-out、無 422）、`GetQuotingProofs`-as-view（passthrough collection、有 quotingProofsNotApplicable → 422）。

---

## 復用既有 skill + sequencing
- `/readmodel-mutation <Get<Noun>>` 填 projector when() body（既有；無改）。
- `/presenter-fill <Get<Noun>>` 只填 trivial single-presenter passthrough AS（既有；對 multi-field exit 3 → aggregating 不歸它）。
- **sequence（單一 read feature）**：(1) `/read-projector` 對 view fan-out 的**每個** source presenter（**含** discriminator presenter）—— 必須先存在否則 `/read-view` 生的 AS 編不過。(2) `/readmodel-mutation`（+ trivial 的 `/presenter-fill`）填 when/passthrough body。(3) `/read-view` 從 mini-spec scaffold aggregating AS + DTO + handler method + openapi + QueryError（之後無 fill）。每 phase 後 build。discriminator-presenter 前置是唯一硬 ordering edge → `/read-view` 顯著文件化。

---

## 改動檔案

| 檔案 | 改動 |
|------|------|
| `Sources/GenesisCore/Resources/Templates/skills/read-projector/SKILL.md` | **新增** skill prose（M1 contract；對照 `/readmodel` + `/readmodel-mutation` 格式；emit Genesis-form pins；2-class idempotency；key.fromEventPayload guard 讀 event.yaml；Projector test tier）。 |
| `Sources/GenesisCore/Resources/Templates/skills/read-view/SKILL.md` | **新增** skill prose（M2 contract；mini-spec schema + 首跑互動產出/replay；aggregating AS body 生成；ApiHandler method append；openapi conditional-422 upsert；named-error 3-file lockstep；AS+Api test tiers；discriminator 前置）。 |
| `Tests/GenesisIntegrationTests/ReadSkillGoldenTests.swift`（或等價）| **新增**：clean-room golden-structure compare + build gate + idempotency gate（見驗收）。`[inferred]` 確切 harness 形（XCTest 驅動 install-skills + 模擬 skill 輸出 vs OC）由 impl 決定；硬不變量 = 「對 AuditQuoting 輸入產出 AuditQuoting-equivalent 結構且 build clean」。 |
| （無）| skill 由 `install-skills` 自動 glob `Templates/skills/` 安裝 → **不需**改 SkillInstaller/registry 程式。 |

> **不改 core renderer**：不動 ReadModelRenderer / OpenApiYamlRenderer / QueryErrorRenderer / ApiHandlerReadMethod 模板（skill 寫更豐富內容而非 fork 它們）。

---

## Genesis-form pins（skill 必照；非抄 OC）
- ApiHandler 非 generic、別處構造；`/read-view` 只 append `func get<View>` 用 `Get<View>ApplicationService(kdbClient: kdbClient)`，永不宣告 header/Storage generic。
- read-AS Input 永遠 `Get<View>ApplicationServiceInput`（長後綴）；presenter 層 `Get<Noun>Input: CQRSProjectorInput`（`package let id`，`init(<keyField>:){ self.id = <keyField> }`）。
- **notFound 一律 NAMED（audit S1，非條件式）**：`/read-view` 永遠 3-file lockstep —— `{A}QueryError` 加 `case <agg>NotFound` + ContextError factory；openapi `{A}ApiError` enum 加 `- <agg>NotFound`（append-if-absent）；handler catch `where error.error == .<agg>NotFound` → `.notFound(.init(body:.json(.init(error:.<agg>NotFound))))`。**不**用 stock generic `.aggregateNotFound`（那只在 write-side DDDError catch）。
- **not-applicable 422（獨立 axis，條件式）**：僅當 view 有 not-applicable rule 才 lockstep 加 `.<x>NotApplicable`（QueryError + ApiError enum）+ openapi `UnprocessableEntityError` 422 response + handler `.unprocessableContent` catch。
- openapi GET：404+503 always；422 僅當有 not-applicable rule；catch set 與 response set 一致。
- 無 QueryError→ApiError mapper；`mapToApiError` 維持 `ContextError<{A}Error>`-only；read handler inline raw-case `where` catch。
- Projection.js `linkTo` 以 `event.body["<key.fromEventPayload>"]`（wire 名）+ stream `"<prefix>Get<Noun>-"`，**非** readmodel domain key。stream prefix = `StreamNaming.categoryPrefix(contextName)` 衍生，絕不硬寫 OC。
- ReadModel：`package class <Noun>ReadModel: ReadModel { var id:{KeyType}{ <keyField> }; var <keyField>:{KeyType}; <stored>; init(<keyField>:) }`（stored default：Optional→nil、Array/Set/Dict→[]/Set()/[:]、explicit override、未知型別 hard-fail）。
- element DTO co-located；enum-wrap DTO 給 type decl + `init(from:)`；glob-skip if 型別已存在 module。

---

## 失敗路徑

| 條件 | 行為 |
|------|------|
| read-model 名不合 `^Get...` | exit 1 |
| `key.fromEventPayload` 不在所選 event 的 `event.yaml` payload | 擋下 + 提示（避免 silent-empty read）|
| `/read-view` 的 discriminator/source presenter 未存在 on-disk | exit + prerequisite hint（先跑 `/read-projector`）|
| Class A 檔已存在 | SKIP（不覆寫手填 body）|
| Class B key 已存在（unambiguous）| replace-in-place（無 per-block prompt）|
| Class B near-name ambiguous（GetEvidenceCount vs GetEvidenceInfo）| **fail-closed**：拒絕 + 問 user，絕不盲 append |
| named-error lockstep 任一檔失敗 | 不 partial（原子）；報哪檔失敗 |
| 手動改名 dir（orphan）| glob-skip 偵測不到 → 文件化為人工清理，skill 不 GC |
| read test 跑無 KDB / 未部署 projection | silent hang（withTestBundle 無 guard）→ test 檔 header 文件化 prerequisite + 指向 `/reset-projection` |

---

## Non-goals
- **不**碰 bundle（不讀不寫 `bundle.readModels[]`）。
- **不** fork core renderer（ReadModelRenderer/OpenApiYamlRenderer/QueryErrorRenderer/ApiHandlerReadMethod 模板）。
- **不**做獨立 `/dto`、`/read-test`、`/read-scaffold` skill。
- **不**自動填 when()/passthrough-AS body（歸 `/readmodel-mutation`/`/presenter-fill`）。
- **不** GC 手改名 orphan dir。
- **不**做 poll-until-consistent test helper（defer；v1 用 `Task.sleep(0.5)` + prerequisite 註解）。
- **不**做 cross-aggregate（context-level）read view 的 AS（`/presenter-fill` v1 已 exit 3；同循環依賴限制）—— v1 限 per-aggregate。
- **不**改 ApiHandler header / generic / `mapToApiError`。

---

## 驗收標準

> **audit S10 範圍界定**：automated gate 只驗 **結構 + `swift build`**，對象是 skill emit 的 scaffold（Class-A body 為 TODO/empty stub，**非** behaviorally-complete OC）。per-variant AS-tier 的**行為斷言 body 不可由 mini-spec 推導** → 以**可編譯 stub**（notFound + not-applicable shape）出貨，行為正確性走 Human gate。

### Agent 必做（clean-room golden-structure + build + idempotency；可機器執行）
1. **fresh Genesis 專案（AuditQuoting write-side 形）**：`genesis new` 一個 OpportunityContext（prefix OC_）+ AuditQuoting aggregate，`event.yaml` 含讀模型消費的 events（如 `TotalAssetsEdited`、`QuotingProofUploadedToGcs/OnGcsRemoved` 等）。⚠️ S10：**establishment status 是 `AuditQuotingCreated` 上的欄位 `customerStatus: CustomerEstablishmentStatus`、不是獨立 events**，由 `GetCustomerEstablishmentStatus` 消費。`install-skills` 裝 read-projector + read-view。
2. **驅動 skill**：`/read-projector` ×16（OC 的 Get<Noun> 定義：events + key.fromEventPayload + stored fields；含 inverted-index `GetAuditQuotingIdByQuotingCaseId`）、`/read-view` ×4（GetOperationInfo/GetEvidenceInfo/GetPredecessorServiceInfo/GetQuotingProofs mini-spec）。
3. **golden-compare（結構，忽略 TODO-body/註解/AS-Input-型別名 byte 差）**：(a) `Usecase/Projector/Get*/` file-set 等同 OC（ReadModel+Presenter+collection 的 element DTO）；(b) 4 aggregator 落 `Adapter/Get<View>/` 且**不在** projection-model.yaml（discriminated 有 `{View}Dto`；passthrough-collection 如 GetQuotingProofs **無** `{View}Dto`）；(c) projection-model.yaml 16 entry + event lists 對；(d) openapi GET op 的 **422-conditionality 對**（quotingProofs/predecessorServiceInfo→404+422+503；operationInfo/evidenceInfo→404+503）+ path kebab 對（GetQuotingProofs→`quoting-proof-list`）；(e) test tree = Projectors/（passthrough only，**容忍 16-dir/15-test**：inverted-index 無 Projector test；nested DTO test 含 OCShared-source 的如 `FileTypeDtoTests`）+ ApplicationServices/+Api/（aggregator only）對齊 OC；(f) wire↔domain id-rename 邊界在（linkTo `quotingId`；readmodel key `auditQuotingId`）；(g) **notFound 一律具名**（S1）：`.<agg>NotFound` 同時在 `{A}QueryError` **且** `{A}ApiError` enum lockstep（4 view 皆然，**非**只有 not-applicable 的）。**(carve-out, S9)** AS Input 型別名（Genesis 統一長後綴 `Get<View>ApplicationServiceInput`）是**刻意 Genesis-form 偏離**、golden 不比此名。
4. **build gate**：generated 專案 `swift build` clean（唯一全自動行為證明；含 named-error lockstep + aggregating AS fan-out 真的編得過）。
5. **idempotency gate**：兩個 skill 對該 tree **跑第二次** → 零 diff（無重複 YAML key、無 clobber body、無重複 handler method/enum case）。projection-model.yaml upsert 後 skill 須 **re-read 自檢**（block parse-able + events list == Presenter when() set）。

### Human 補做（read-test 行為腿；需 Docker + localhost KDB）
- [ ] read-test gate：`/reset-projection` 部署 projection 後跑 emitted 整合 test（projector/AS/api），驗 fill（when()/execute）行為正確。eventual-consistency（Task.sleep 0.5）。

---

## 依賴關係
- **來源**：understanding inventory `wf_d9e76c6c-c92` + design discuss `wf_b34faef0-447`（全 file-traced 對照 OC AuditQuotingAggregate）。
- **硬相依（done）**：ReadModelRenderer（read-model codegen 先例 + scaffold-once）、PresenterRenderer/`/presenter-fill`、`/readmodel-mutation`、StreamNaming（prefix 真相）、`/reset-projection`、deploy 腳本（read-after-write 部署）。
- **解鎖**：在 Genesis-generated 專案內**不經 bundle** 增建完整讀路徑（含 aggregating view —— Genesis 既有 renderer 做不到的 net-new value）。
- **後續（defer）**：poll-until-consistent test helper；cross-aggregate（context-level）read view；orphan-dir GC；mini-spec 的獨立 lint/驗證命令。

## 下一步
write-spec done；**audit-spec done**（adversarial workflow `wf_405ba9b8-b9f`，2 lens feasibility/compile + fidelity/OC-parity + synthesis；對照 REAL OC AuditQuoting tree + .build plugin outputs + DDDKit checkout + 3× swiftc -typecheck）。verdict = **NEEDS_FIX, ready_after_fixes=true**（無架構缺陷；compile 主張全 scratch-verified EXIT 0：EventMapper plugin-generated for reads、named-error lockstep、aggregating AS fan-out、generic+named QueryError 共存）。**10 must-fix（S1-S10）已全 fold 進本 spec**：S1（HIGH，notFound 一律具名、與 not-applicable 解耦 —— 原假設對 2/4 view 偏離）、S2（HIGH，key.fromEventPayload guard payload set = `properties[] ∪ {aggregateRootId.alias}` 否則誤擋 100%）、S3（HIGH，discriminator per-variant 映射、非 3→2，GetPredecessorServiceInfo 真 3-way）、S4（passthrough-collection view 無 {View}Dto/無 switch、用 .map）、S5（EventMapper plugin-provenance pin + prerequisite 綁 projection-model entry）、S6（inverted-index projector 無 Projector test、golden 容忍 16/15）、S7（non-co-located nested DTO test 如 FileTypeDtoTests）、S8（openapi path kebab collision → `-list` + verb fail-closed）、S9（AS Input 長後綴 carve-out of golden）、S10（acceptance：establishment status 是 AuditQuotingCreated 欄位非 events；automated gate 限 structure+build，行為斷言 → Human gate）。residual（impl/clean-room 驗）：Class-B projection-model upsert 是 compile-load-bearing（impl 加 post-write re-read 自檢 + 精確 near-name ambiguity 門檻）；automated gate 跑 skill-emitted scaffold（Class-A TODO body）非 OC behavioral。

NEXT → **impl**（M1 `/read-projector` → M2 `/read-view`，依 sequence；ultracode）→ impl-review → clean-room validation。3-strikes：同一修復 loop 3 次以上停下求助。
