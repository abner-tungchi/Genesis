---
topic: "read-after-write 的『projection runtime』缺口 —— 釐清真正缺什麼，codegen/skill/deploy 切分（綁定 OC AuditQuotingAggregate）"
status: consensus
created: "2026-06-05"
updated: "2026-06-05"
participants:
  - Claude (Opus 4.8)
  - adversarial workflow projection-runtime-codegen-discuss（3 lens：read-model-population-truth / server-runtime-feasibility / scope-value + synthesis）
facilitator: Claude
rounds_completed: 1
mode: default
grounding: OC AuditQuotingAggregate（user 指定的參考 aggregate）+ OCServer/EventBusRegister/projection.sh + DDDKit checkout，全程 file:line 驗證
premises:
  fixed:
    - "Genesis = bundle → DDD/ES 專案 codegen，留 GenesisTODO 洞由 skill 填。codegen-vs-skill D1：deterministic→codegen、judgment→skill。"
    - "coverage audit（前一輪）判定『projection subscription runtime 缺失 = read 永遠不會動』是最大缺口、要從 OCServer port。"
  overturned:
    - "（被推翻）read 需要 Swift 的 OCServer persistent-subscription loop + EventBus 才會有資料。"
---

# read-after-write：真正缺的不是 runtime，是 deploy

## 議題定義
coverage audit 說「projection subscription runtime 缺失 → GET 永遠回空」是最大缺口，要把 `OCServer.swift` 的訂閱迴圈 port 進 Genesis。本討論綁定 **AuditQuotingAggregate** 把讀路徑 **end-to-end 追到底**，確認到底缺什麼、該 codegen / skill / deploy-script / defer 如何切。

## 關鍵發現：audit 的前提錯了 —— read **不需要** Swift 訂閱迴圈

3 lens 一致、高信心、逐檔追證（AuditQuoting `GetTotalAssets` 為參考鏈）：

> 一個 GET 把 read model 填出來，**完全不依賴** `OCServer` 的 persistent-subscription loop / EventBus。read model 是在 **GET 當下 lazy on-demand** 重建的。

追證鏈（全部 file:line）：
1. `ApiHandler` → `GetOperationInfoApplicationService.init(kdbClient:)`（**無** EventBus / storage，`GetOperationInfoApplicationService.swift:21`）。
2. `fetchTotalAssets` 建 `GetTotalAssetsPresenter(coordinator: .init(client: kdbClient, eventMapper:)).execute()`（`:82-83`）。
3. DDDKit `EventSourcingProjector.execute()` = `coordinator.fetchEvents(byId:)` 後 `buildReadModel` + `apply`（`swift-ddd-kit/.../EventSourcingProjector.swift:39-57`）。
4. category 由 `GetTotalAssetsPresenter.swift:18` 的 `categoryRule = .fromClass(withPrefix:"OC_")` → stream `"OC_GetTotalAssets-<id>"`。
5. 那條 link stream 由**部署到 KurrentDB 的 server-side JS projection** 填：`projections/OC_GetTotalAssetsProjection.js` 做 `fromStreams(["$ce-OCAuditQuoting"]).when({TotalAssetsEdited: …}).linkTo("OC_GetTotalAssets-"+event.body["quotingId"])`，KurrentDB 因 `start-kurrentdb.sh:22` 的 `EVENTSTORE_RUN_PROJECTIONS=All` 持續執行它。

**所以 read-after-write 只需要三件事**：(1) command append 到 aggregate（寫 `$ce-OCAuditQuoting`）；(2) 部署的 JS projection（server-side link）；(3) Presenter 在 GET 當下重播。`OCServer` 的訂閱迴圈 + `EventBusRegister` 的 `When<Event>` listener 是 **跨 aggregate 寫反應（Listener lane）**，與讀路徑正交。

→ **`Server.swift.template:40-42` 的 TODO「Until subscription is wired, read endpoints return empty/notFound」是事實錯誤**，把兩條 lane 混為一談，會誤導 skill-filler 去蓋根本不需要的訂閱線路。

### Genesis 其實「幾乎已經做完讀路徑」
逐檔確認 Genesis 今天就 codegen：`<Noun>ReadModel.swift`、scaffold-once `Get<Noun>Presenter.swift`（空 `when()` + TODO）、`projections/<Prefix>Get<Noun>Projection.js`（`ReadModelRenderer.swift:90-141` + `Projection.js.template`，與 OC 的 `.js` 格式結構一致）、`projection-model.yaml`/`event-generator-config.yaml`、以及一個會註冊 read GET handler（純 `kdbClient`）的可跑 server。**唯一真正缺的成品 = 部署腳本**：Genesis emit **0 個 `.sh`**（已驗證），所以 codegen 出來的 `.js` 從沒被送進 KurrentDB → `OC_<Name>` link stream 永遠空 → 每個 read GET 靜默回 nil。

## 決策紀錄

| # | 決定 | 理由 |
|---|------|------|
| **D1** | LEAN v1 read-after-write = JS projection（已 codegen）+ **新增** projection 部署腳本 + KurrentDB bootstrap 腳本 + Presenter on-demand 重播（已 codegen scaffold + skill 填）。**排除** Swift 訂閱/EventBus 迴圈。 | 讀路徑零訂閱依賴（全鏈追證）。訂閱迴圈是跨 aggregate 寫反應 lane（`OCServer.swift:84-104` + `EventBusRegister`），另一階段。納入 v1 = 多扛 ~200 行純 domain judgment。 |
| **D2** | 新增 `DeployScriptRenderer` emit 兩個**通用**腳本到 scaffold `scripts/`：`projection.sh`（glob `projections/*Projection.js` → POST 每個到 `/projections/continuous?type=js&enabled=true&emit=true&trackemittedstreams=true`）+ `start-kurrentdb.sh`（`EVENTSTORE_RUN_PROJECTIONS=All` 起 KDB）。OC 腳本的逐字/參數化複本，**零** per-aggregate 內容。 | 這是真正的 gating gap。OC 的 `projection.sh:108-121,161` 完全通用（只 glob+POST、無 aggregate 知識）。`/reset-projection` skill 已經就是驅動這兩個腳本 → 一 emit 出來 fresh scaffold 即可部署。deterministic → renderer 非 skill。 |
| **D3** | 修 `Server.swift.template:40-42`：刪掉「reads empty until subscription wired」假宣稱；改寫成「跑 `scripts/projection.sh` 部署 JS projection + source stream 有事件後 read 就會動；subscription TODO 只負責跨 aggregate **寫**反應」。 | 現文字把 on-demand 讀重播 lane 與寫反應訂閱 lane 混淆，會誤導人/skill 去蓋多餘訂閱線路。對 `GetTotalAssets` 讀路徑已驗證為錯。 |
| **D4** | `.js` 生成維持 **Genesis-side codegen**（`Projection.js.template` via `ReadModelRenderer`），**不**委派給 DDDKit 的 `KurrentDBProjectionFileGenerator` command plugin。 | DDDKit 那個是 manual CommandPlugin（drift 風險、非 prebuild），且要 `category`/`idField` yaml 欄位 —— Genesis 的 bare yaml（與 OC 既有 `projection-model.yaml`）都沒有。Genesis 已能 deterministic 產 OC-格式 `.js`。單一真相、無第二 generator 衝突。 |
| **D5** | `ProjectorProtocol`/`apply()`/`EventMapper` **不**進 Genesis codegen —— 它們是 DDDKit build-tool-plugin（`ModelGeneratorPlugin`）compile 時從 yaml 產。Genesis 只 emit yaml 輸入（已做）。 | 再 codegen 會與 plugin 輸出重複/衝突。 |
| **D6** | `when()` mutation body 維持 skill（`/readmodel-mutation`）；Presenter scaffold（空 `when()`+TODO 滿足 protocol）維持 codegen scaffold-once；`key.fromEventPayload`（read-model id 取哪個 event payload 欄位）維持 `/readmodel` skill 輸出存 bundle。 | body + id-欄位選擇是 business judgment；protocol-殼 + id 周圍的 JS 渲染是 deterministic。Genesis 已是此切分（`ReadModelRenderer.swift:208-221` TODO body；`key.fromEventPayload` 串進 `Projection.js.template:11`）。 |
| **D7** | v1 server = ship 現有 `Server.swift.template`（router + per-aggregate `ApiHandler.registerHandlers` + ESDB client + PORT bind）。**不** codegen 訂閱/ack-nack 迴圈或 EventBus。**永不**硬寫 OC-isms：GCS Storage + `GCS_*` env、BearerToken/CORS、明確 streamNames、port 24101、serverUrl `/opportunity-context`、具體 eventMappers —— 留 TODO slot / bundle 參數。 | `registerHandlers` 是 swift-openapi-hummingbird 生成方法（純 ApiHandler init signature 的函數）。部署 projection 後 server 就能 read-after-write。現 template 已正確避開那些 OC-isms。 |
| **D8** | read-after-write 在 API contract 上視為 **eventually consistent**。保留產 `ProjectionReadInconsistency`（Shared）+ drift→503 慣例。文件化：write 後立刻 GET 可能 503/空直到 server-side JS projection 追上。**不**做同步 read-your-write。 | JS projection 在 KurrentDB 內非同步跑；link stream 空時 Presenter 丟 `eventsNotFoundInProjector`（`EventSourcingProjector.swift:44-46`）。訂閱迴圈也不會讓讀變同步（不同 lane）。Genesis 已編 drift→503。 |
| **D9** | 未來真要做訂閱/EventBus runtime（**獨立的寫反應階段**，非 read v1）：codegen **機械骨架**（`persistentSubscriptions.create` + `startSubscription` ack/nack retry loop + `publishRecordedEvent` + `eventMappers[]`，參數化 {aggregates, `$ce` 寫 categories, mappers}）；`register()` 的 listener 註冊清單留 GenesisTODO 洞由 skill 填。並先解決 `$ce-AuditQuoting`（`OCServer.swift:86`）vs 實體寫 category `OCAuditQuoting`（→ `$ce-OCAuditQuoting`）的命名不一致。 | 訂閱機械 = aggregate/category 集合的函數；`When<Event>` 線路（哪個 listener、哪些 repo/projector、順序）= 跨 aggregate business intent = stochastic。未加前綴的訂閱 stream 看似 legacy/不一致，須裁決非盲抄。純未來 scope note。 |

## codegen / skill / deploy / defer 切分

- **codegen（多數已存在）**：`.js` projection、`ReadModel.swift`、Presenter scaffold（空 `when()`+TODO）、`projection-model.yaml`/`event-generator-config.yaml`、可跑 server（router+registerHandlers+ESDB+PORT）、`ProjectionReadInconsistency`。
- **skill**：`when()` body（`/readmodel-mutation`）、Presenter business 填（`/presenter-fill`）、`key.fromEventPayload`（`/readmodel`）、跑部署（`/reset-projection` 已驅動那兩腳本）。
- **deploy-script（v1 新增，gating gap）**：`scripts/projection.sh`、`scripts/start-kurrentdb.sh`。
- **defer**：DDDKit `ProjectorProtocol`/`apply()`/`EventMapper`（plugin）；Swift 訂閱/EventBus 寫反應 lane；`register()` listener 清單；auth/CORS/GCS/ensureInvariant/具體 streamNames/port；`StatefulEventSourcingProjector` 持久化 read-store 策略。

## 重要 caveat / dissent（須在 spec 載明）
- **僅對 on-demand CQRS-replay 策略成立**（AuditQuoting `GetTotalAssets` 用的）。DDDKit 另有 `StatefulEventSourcingProjector`/persisted-read-store 路徑；若未來某 read model 用它，可能就需要訂閱餵食 → v1 明文限定「on-demand 策略」。
- **eventual consistency**：write 後立刻 GET 可能撞空 link stream → 503/空直到追上。非同步 by design。
- **`key.fromEventPayload` 是最高 blast-radius 的潛在 bug**：選錯欄位 → linkTo 到沒人寫的 stream → read model 靜默全空、無錯誤。

## LEAN v1 scope（M0→M3）
- **M0**：批准本 synthesis 的 crux + 切分（= 本文件）。
- **M1（gating fix）**：`DeployScriptRenderer` → emit `scripts/projection.sh` + `scripts/start-kurrentdb.sh`（通用），接進 scaffold pipeline。
- **M2（correctness）**：修 `Server.swift.template:40-42` 誤導 TODO + 加 eventual-consistency 註記。
- **M3（smoke / 證明）**：fresh scaffold → `start-kurrentdb.sh` → `projection.sh` 部署 codegen 的 `.js` → append 事件到 source stream → GET 把 read model on-demand 填出來（證明零 Swift 訂閱即可）。M3 同時是整個 crux 的驗證閘。

## 開放問題（user 已拍板 2026-06-05）
1. **read-after-write contract** → **eventual consistency，不加 wait/retry helper**（= OC 行為，已驗證：OC read lane 零 retry/poll/sleep；`GetOperationInfoApplicationService` 的 `fetch*` 直接 `Presenter.execute()`，未投影欄位回 `nil`，`ApiHandler` 對 `ContextError<QueryError>.<x>NotFound` 回 404，其餘 503）。scaffold 文件化 eventual + 保留 drift→503，不做同步 read-your-write、不附 retry helper。
2. **deploy 腳本** → **always emit**（每次 `genesis new` 都寫 `scripts/projection.sh`+`start-kurrentdb.sh`）；KDB 連線用 **localhost 預設 + env 覆寫**（`ESDB_URL` 等已是 env；零新設定維度）。
3. **`key.fromEventPayload` 安全** → **v1 加 guard**：codegen-time / skill-time 檢查「所選 id 欄位真的存在於該 event 的 payload」，擋掉「linkTo 到沒人寫的 stream → read model 靜默全空」這個最高-blast-radius latent bug。
4. **DDDKit 方向** → **維持 Genesis 自己的 `Projection.js.template` 當真相**（D4；不 track DDDKit 的 manual command-plugin generator —— 它 drift-prone 且要 OC 沒有的 `category`/`idField` 欄位）。
5. **stream-prefix 通用性** → **spec 釘清楚 prefix 慣例 + 驗證三方對齊**：明確定義 `context → prefix`（如 `IAMContext → IAM_`），並驗證「JS `fromStreams`/`linkTo` 的 prefix」=「Presenter `categoryRule` 的 `withPrefix`」=「entity 寫 category」三者對齊；否則非-OC context 的讀會靜默壞。

## 下次討論指引
spec_ready = true，**5 開放問題已拍板**。NEXT → write-spec：**M1 DeployScriptRenderer（always-emit `projection.sh`+`start-kurrentdb.sh`，localhost+env）+ M2 修 `Server.swift.template:40-42` 誤導 TODO + eventual-consistency 註記 + key.fromEventPayload guard + stream-prefix 慣例釘死/驗證**；M3 smoke（fresh scaffold → start-kurrentdb → projection.sh → append 事件 → GET on-demand 填出 read model）當驗收。→ audit-spec → impl。載重點：crux（read 不需 Swift 訂閱）、D2（deploy 是唯一 gating gap）、D4（.js 留 Genesis）、D7（server 不硬寫 OC-isms）、caveat（on-demand-only + eventual + key.fromEventPayload guard）。
