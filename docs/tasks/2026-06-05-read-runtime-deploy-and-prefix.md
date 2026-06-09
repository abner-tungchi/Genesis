# read-after-write 收尾：deploy 腳本 codegen + stream-prefix 對齊修復 + server template 誠實化

## 來源

討論：`docs/discussions/2026-06-05-projection-deploy-and-read-runtime.md`（consensus，3-lens adversarial + synthesis；**crux 已證**：GET 讀 read model **不需** Swift 訂閱迴圈，靠部署的 server-side JS projection + Presenter on-demand 重播）。user 已拍板 5 開放問題（2026-06-05）：

1. **contract** → eventual consistency，不加 wait/retry（= OC 實證行為）。
2. **deploy 腳本** → always-emit `projection.sh`+`start-kurrentdb.sh` 到 `scripts/`，localhost 預設 + env 覆寫。
3. **`key.fromEventPayload` 安全** → v1 加 guard（id 欄位須存在於該 event payload）。
4. **DDDKit 方向** → 維持 Genesis 自己的 `Projection.js.template` 當真相（不 track DDDKit generator）。
5. **stream-prefix** → spec 釘清楚 prefix 慣例 + 驗證三方對齊。

## 目標

讓一個 fresh Genesis 專案的 **read-after-write 真的能動**（外部 GET 拿到投影資料），補齊「codegen 已做好讀路徑、卻沒有部署管道 + prefix 對非-OC context 靜默錯位」這兩個缺口；並把 `Server.swift.template` 誤導 TODO 改誠實。**不**做 Swift 訂閱/EventBus 寫反應 lane（defer）。

---

## 關鍵發現（grounding，全 file:line 驗證）

### F-crux（已證，討論的核心）
GET → `ApiHandler` → read-side `ApplicationService(kdbClient:)` → `Presenter(coordinator:).execute()` → DDDKit `EventSourcingProjector.execute()` = `fetchEvents(byId:)` + `apply(when:)`（`swift-ddd-kit/.../EventSourcingProjector.swift:39-57`）。stream = `categoryRule .fromClass(withPrefix:"<prefix>_")` → `"<prefix>_Get<Noun>-<id>"`，由部署的 JS projection 灌（`fromStreams(["$ce-<srcCat><Agg>"]).linkTo("<prefix>_Get<Noun>-"+payload[idField])`）。**零** Swift 訂閱依賴。`OCServer` 訂閱迴圈 = 跨 aggregate 寫反應 lane（defer）。

### F-deploy（gating gap）
Genesis emit **0 個 `.sh`**（已驗）。codegen 的 `.js` 落在 repo 根 `projections/<prefix>Get<Noun>Projection.js`（`ReadModelRenderer.swift:125`），但**沒任何東西把它送進 KurrentDB** → `<prefix>_Get<Noun>-<id>` link stream 永遠空 → GET 靜默回 nil。OC 的 `scripts/projection.sh`（glob `projections/*Projection.js` → `POST /projections/continuous?type=js&enabled=true&emit=true&trackemittedstreams=true`）+ `scripts/start-kurrentdb.sh`（docker run KDB，`EVENTSTORE_RUN_PROJECTIONS=All`）**100% 通用、零 per-aggregate 內容**。

### F-prefix（真 bug，非 cosmetic）⚠️
**兩個 renderer 對 stream category prefix 用了不同推導 → 對 OpportunityContext 以外的 context 靜默錯位**：
- `AggregateRenderer.swift:160-161`：寫 category prefix = **`uppercaseLetters(contextName)`**（`Aggregate.swift.template:10-11` = `"{CategoryPrefix}\(Self.self)"`）。`IAMContext → "IAMC"` → 事件落 `$ce-IAMCUserAccessProfile`。
- `ReadModelRenderer.swift:148-163` `streamPrefix`：`sourceCategory` = **`Opportunity→OC` alias，else `upperSnake(stripped)`**。`IAMContext → "IAM"` → JS `fromStreams(["$ce-IAMUserAccessProfile"])`。
- **OpportunityContext 剛好對齊**（兩者皆 `OC`：uppercaseLetters("OpportunityContext")=="OC"，alias 也=="OC"）→ 所以 OC 能動、**非-OC 全壞**（IAM: 寫 `IAMC` vs 讀 `IAM`；AuditQuotingContext: 寫 `AQC` vs 讀 `AUDIT_QUOTING`）。
- 真相錨：OC `AuditQuoting.swift:49-51` `category = "OC\(Self.self)"` → `OCAuditQuoting`；JS `fromStreams(["$ce-OCAuditQuoting"])`（`projections/OC_GetTotalAssetsProjection.js:1`）。寫 category 是**事件物理落地處 = 唯一真相**，讀側必須對齊它。
- `Server.swift.template:33-35` 註解甚至自己寫著讀側用 `$ce-IAMUserAccessProfile`（`IAM`）—— 正是描述了壞掉的狀態。
- 既有 `ReadModelRendererTests.swift:72,96,244-246,250,256` **把壞行為當成期望寫死**（`IAM_`/`AUDIT_QUOTING_`/`MY_APP_`...），需一併更新。

### F-payload（guard 資料路徑）
event payload 在 **use case** 上（`BundleParser.swift:280,417,428` `eventPayload: [RawField]`），非獨立 events 集合。`readModel.eventRefs[].name` 是 event type 名 → 需對應到「emit 該 event 的 use case」的 `eventPayload` 欄位集，才能驗 `key.fromEventPayload`。

---

## 介面合約

### M1 — `DeployScriptRenderer`（新）

```
public enum DeployScriptRenderer {
    public static func render(contextName: String) throws -> [(path: String, content: String, role: String)]
}
```

- 回傳**恆 2 個** tuple（與 bundle 內容無關，純 context-name 參數化）：
  - `("scripts/projection.sh", <generic projection.sh>, "deploy-script")`
  - `("scripts/start-kurrentdb.sh", <generic start-kurrentdb.sh>, "deploy-script")`
- 內容 = OC 兩腳本的**結構性複本**（從 `Resources/Templates/v0.1/Scripts/projection.sh.template` + `start-kurrentdb.sh.template` 載入），但 **config 字面值刻意改寫成 `${VAR:-default}` 形（這是 audit MF4 確認的「OC 之外的 enhancement」、非逐字 parity）** —— OC 的腳本是 bare literal（`projection.sh:6-8`、`start-kurrentdb.sh:10-11`），且 `ESDB_URL` **不**被腳本讀（只 `Server.swift.template:23` 讀）→ 別沿用討論裡「ESDB_URL 已是 env」的（錯）理由：
  - `projection.sh`：glob `projections/*Projection.js` → `curl POST "$KDB_HOST"/projections/continuous?name=<name>&type=js&enabled=true&emit=true&trackemittedstreams=true`；disable+delete+recreate；需 `jq`。config 改 override 形：`KDB_HOST="${KDB_HOST:-http://localhost:2113}"`、`KDB_USER="${KDB_USER:-admin}"`、`KDB_PASS="${KDB_PASS:-changeit}"`。**零** per-aggregate 內容。
  - `start-kurrentdb.sh`：`docker run` image **`docker.eventstore.com/kurrent-latest/kurrentdb:latest`**（完整路徑，非 `kurrentdb:latest`），env flags **全帶 `EVENTSTORE_` 前綴**：`EVENTSTORE_RUN_PROJECTIONS=All` + `EVENTSTORE_START_STANDARD_PROJECTIONS=true` + `EVENTSTORE_INSECURE=true` + `EVENTSTORE_ENABLE_ATOM_PUB_OVER_HTTP=true`；container 名 `CONTAINER="${CONTAINER:-kurrentdb-<contextName-kebab>}"`（OC 寫死 `kurrentdb-opportunity-context`）、`HTTP_PORT="${HTTP_PORT:-2113}"`/`GRPC_PORT="${GRPC_PORT:-1113}"`；poll readiness。
- `role = "deploy-script"`（manifest 多一種 role）。
- **執行權限 caveat**：`SourceWriter` 用 `content.write(...)` 不設 +x（`SourceWriter.swift:57-58`）→ 腳本是 644。README/smoke 一律以 `bash scripts/<x>.sh` 跑（shebang 在、無 +x 也可）。`[inferred]` 是否在 commit() 後對 role==deploy-script 補 `chmod +x` 為實作可選；spec 硬不變量 = 「`bash scripts/x.sh` 跑得起來」。

### M2a — `Server.swift.template` 誠實化

改 `:21` + `:32-42`：
- 刪掉 `:40-41` 的假宣稱「Until subscription is wired, read endpoints return empty/notFound」。
- 改成（語意）：「read GET 在 (a) 跑過 `bash scripts/projection.sh` 部署 JS projection + (b) source aggregate stream 有事件 後即可運作（Presenter 於 GET 當下 on-demand 重播 `$ce-<prefix><Agg>` 投影出的 link stream）；**eventual consistency** —— write 後**立刻** GET 可能 nil/空/503 直到 server-side JS projection 追上（async）；不做同步 read-your-write。」
- `:32-42` 的 subscription TODO 改標明：**只**為**跨 aggregate 寫反應（Listener lane）**，與讀路徑無關，defer（見 OC `OCServer.swift` 的 startSubscription / `EventBusRegister`）。
- `:33-35` prefix 註解改成對齊後的真相（`$ce-<uppercaseLetters(contextName)><Agg>`，與 aggregate 寫 category 同源；見 M2b）。

### M2b — stream-prefix 三方對齊（真 bug 修復）⚠️ load-bearing

**單一真相**：新增 `StreamNaming`（GenesisCore），category prefix = `uppercaseLetters(contextName)`（= AggregateRenderer 既有寫 category 推導 = 事件物理落地的真相）：

```
public enum StreamNaming {
    /// 大寫字母 of contextName（OpportunityContext→"OC"、IAMContext→"IAMC"）。
    /// 唯一真相：aggregate 寫 category = "<prefix><Agg>"（→ $ce-<prefix><Agg>）；
    /// JS projection fromStreams 訂閱同一條；Presenter categoryRule = "<prefix>_"。三方 by construction 對齊。
    public static func categoryPrefix(contextName: String) throws -> String
    public static func projectionPrefix(contextName: String) throws -> String  // = categoryPrefix + "_"
    public static func sourceCategory(contextName: String) throws -> String    // = categoryPrefix
}
```
- `categoryPrefix` 邏輯（**MF2：須同時保留兩個既有 guard**）：
  1. `stripped = contextName` 去掉尾綴 `"Context"`；若 `stripped.isEmpty` → throw `GenesisError.bundleInvalid("contextName must not equal 'Context' alone; cannot derive stream prefix")`（**逐字沿用 `ReadModelRenderer.streamPrefix` 既有訊息**，使 `ReadModelRendererTests:261-266 testStreamPrefixContextOnlyThrows` 續綠；注意 `uppercaseLetters("Context")=="C"` 非空，光靠 no-uppercase guard 抓不到 `Context`-alone）。
  2. `letters = String(contextName.filter { $0.isUppercase })`（**對 FULL contextName**，與 `AggregateRenderer:161` 逐字等價；`IAMContext` 的尾 `C` 正來自 `Context` → `IAMC`）；若 `letters.isEmpty`（全小寫名如 `myapp`）→ throw `bundleInvalid("contextName '<x>' has no uppercase letters to derive a stream category prefix; rename e.g. FooContext")`。
  3. return `letters`。
  - ⚠️（audit F4 caveat）`categoryPrefix` 是**刻意有損的縮寫**：`AccountContext`/`AdminContext`/`AnalyticsContext` 都 → `AC`。v1 可接受（每個 Genesis 專案單一 context、prefix 只需在單一 event-store namespace 內自洽）；多 context 共用同一 KDB 才需強化，記 follow-up。
- **`AggregateRenderer.swift:160-161`** 的 inline `categoryPrefix` → 改呼叫 `StreamNaming.categoryPrefix(contextName:)`（行為對 OC/既有皆**不變**：uppercaseLetters 同式；只是抽共用 + 加空 guard）。
- **`ReadModelRenderer.streamPrefix`** → 改回傳 `(projection: try StreamNaming.projectionPrefix(...), sourceCategory: try StreamNaming.sourceCategory(...))`，**刪掉 `Opportunity→OC` alias + `upperSnake` fallback**。保留 public 簽名（呼叫端/測試沿用）。
- **結果**：OpportunityContext 仍 `OC`/`OC_`（不變）；IAMContext `IAM→IAMC`、AuditQuotingContext `AUDIT_QUOTING→AQC`、MyApp `MY_APP→MA`、BillingContext `BILLING→BC`（對齊各自 aggregate 寫 category）。
- **更新測試**：`ReadModelRendererTests.swift:72,96,244-246,250,256`（改 prefix 期望值）+ **新增三方對齊 golden**：對一個非-OC 測試 bundle，斷言 `AggregateRenderer` 產的 `category` 的 prefix == `StreamNaming.sourceCategory` == `projectionPrefix` 去底線；且 JS `fromStreams` 的 `$ce-<srcCat><Agg>` 與 aggregate `category` 字面一致。

### M2c — `key.fromEventPayload` guard（#3）

在 `ReadModelRenderer.render` 內，對每個 readModel entry 的每個 `eventRef`：
- 嘗試解析「emit 該 event type（`eventRef.name`）的 use case」於 `bundle.useCases`（match emitted event type 名），取其 `eventPayload` 欄位名集。
- 若**可解析**且 `key.fromEventPayload ∉ 欄位名集` → **hard fail** `GenesisError.bundleInvalid("readModel '<name>' key.fromEventPayload '<f>' 不在 event '<evt>' 的 payload 欄位 [...] 中；linkTo 會指向沒人寫的 stream → read model 永遠空。修 /readmodel 的 key.fromEventPayload")`。
- 若**無法解析**（event type 對不到 use case / payload 缺）→ emit **warning**（`stderr` 提示「無法驗證 key.fromEventPayload，請人工確認」），**不**阻擋生成（fail-safe，不誤殺合法但描述不全的 bundle）。
- `[inferred]` 解析路徑（event type → use case → eventPayload）的精確 API 由 impl 對照 `FullBundle`/`UseCaseSpec` 確定；spec 硬不變量 = 「可驗證時錯欄位必 fail、不可驗證時 warn 不擋」。aggregate id 欄位（最常見的 idField，如 `quotingId`）通常在所有相關 event payload 內 → 正常情況 guard 綠。

### M3 — smoke / 驗收（agent 可跑部分 + Human 完整鏈）

證明零 Swift 訂閱即可 read-after-write（同時驗整個 crux + prefix 對齊）。

---

## 改動檔案

| 檔案 | 改動 |
|------|------|
| `Sources/GenesisCore/StreamNaming.swift` | **新增**：`categoryPrefix`/`projectionPrefix`/`sourceCategory`（單一真相 = uppercaseLetters）。 |
| `Sources/GenesisCore/DeployScriptRenderer.swift` | **新增**：render 2 個通用腳本（載 template + context-name 參數化）。 |
| `Sources/GenesisCore/Resources/Templates/v0.1/Scripts/projection.sh.template` | **新增**：OC `scripts/projection.sh` 的參數化複本（localhost 預設 + env 覆寫）。 |
| `Sources/GenesisCore/Resources/Templates/v0.1/Scripts/start-kurrentdb.sh.template` | **新增**：OC `scripts/start-kurrentdb.sh` 複本（container 名 = `<contextName-kebab>`）。 |
| `Sources/Genesis/Commands/NewCommand.swift` | **編輯**：加 §2.3.8（或 §2.9）`for file in try DeployScriptRenderer.render(contextName:) { try plan(...) }`。 |
| `Sources/GenesisCore/AggregateRenderer.swift` | **編輯**：`:160-161` inline categoryPrefix → `StreamNaming.categoryPrefix(contextName:)`（行為不變 + 空 guard）。 |
| `Sources/GenesisCore/ReadModelRenderer.swift` | **編輯**：`streamPrefix` 改用 `StreamNaming`（刪 alias/upperSnake）；`render` 加 M2c guard。 |
| `Sources/GenesisCore/Resources/Templates/v0.1/Server/Server.swift.template` | **編輯**：`:21,:32-42` 誠實化（M2a）。 |
| `Tests/GenesisCoreTests/ReadModelRendererTests.swift` | **編輯（audit MF1/MF2，逐行）**：prefix 期望更新 —— `:72`(`AUDIT_QUOTING_…js`→`AQC_`)、`:91`(`AUDIT_QUOTING_`→`AQC_`)、`:94`(`$ce-AUDIT_QUOTINGAuditQuoting`→`$ce-AQCAuditQuoting`，**source-stream 對齊斷言、原本漏列**)、`:96`、`:244-246`(`IAMContext`→`IAM_`**改 `IAMC_`**/`IAMC`)、`:250`(`MyApp`→**`MA_`**)、`:256`(`BillingContext`→**`BC_`**)、`:257-258`、`:285`(`AUDIT_QUOTING_…js`→`AQC_`)。`:261-266` `testStreamPrefixContextOnlyThrows` 依 MF2 決議保留（StreamNaming 仍 reject `Context`-alone、訊息含 `must not equal Context`）。+ 新增三方對齊 golden + key-guard 正/負測。**closing check（impl 收尾必跑）**：`grep -rnE 'IAM_Get\|\$ce-IAM[^C]\|AUDIT_QUOTING\|MY_APP_\|BILLING_' Tests/` 應為空。 |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | **編輯（audit MF1，原本整檔漏列！）**：`:441`(`projections/IAM_GetUserAccessProfileRolesProjection.js`→`IAMC_…`)、`:457`(`$ce-IAMUserAccessProfile`→`$ce-IAMCUserAccessProfile`)、`:459`(`linkTo("IAM_GetUserAccessProfileRoles-`→`linkTo("IAMC_…`)。這些目前**綠**、改 prefix 後會紅 → 不更新則「全 suite 無回歸」gate 假紅。 |
| `Tests/GenesisCoreTests/DeployScriptRendererTests.swift` | **新增**：golden（恆 2 檔、role、glob+continuous POST 字串、**`${VAR:-default}` env-override 形（非 bare literal）**、`EVENTSTORE_RUN_PROJECTIONS=All`、image `docker.eventstore.com/kurrent-latest/kurrentdb:latest`、container 名 = context-kebab、零 per-aggregate）。 |
| `Tests/GenesisCoreTests/StreamNamingTests.swift` | **新增**：uppercaseLetters 推導（`OpportunityContext`→`OC`、`IAMContext`→`IAMC`、`AuditQuotingContext`→`AQC`、`MyApp`→`MA`、`BillingContext`→`BC`）+ no-uppercase guard + `Context`-alone reject（MF2）。 |
| （可能）`Tests/.../AggregateRendererTests` | `:69` 斷言 `"IAMC\(Self.self)"` —— 寫 category **不變**，續綠（確認 StreamNaming 抽取等價）。 |

---

## 失敗路徑

| 條件 | 行為 |
|------|------|
| contextName == `Context`（去尾綴後空）| `StreamNaming.categoryPrefix` throw bundleInvalid（訊息含 `must not equal Context`，沿用既有；MF2）|
| contextName 全小寫（無大寫字母，如 `myapp`）| `StreamNaming.categoryPrefix` throw bundleInvalid（no-uppercase guard；兩 renderer 一致）|
| `key.fromEventPayload` 對不上 event payload（可解析時）| `ReadModelRenderer.render` throw bundleInvalid（擋靜默空 read model）|
| event type 解析不到 use case（不可驗證）| warning，不擋生成 |
| 部署前 GET | eventual consistency：nil/空/404/503，直到 `projection.sh` 部署 + 事件追上（已文件化，非 bug）|
| 腳本無 +x | 以 `bash scripts/x.sh` 跑（shebang 在）|

---

## 不改動 / Non-goals

- **不**做 Swift persistent-subscription/EventBus 寫反應 lane（`OCServer` startSubscription / `EventBusRegister` 的 `When<Event>` listener）—— 獨立的跨 aggregate 寫反應階段，defer（D9）。
- **不**改寫 aggregate **寫** category 推導（保持 uppercaseLetters，避免 breaking 既生成專案的 event stream）；只把**讀側**對齊到它。
- **不** track DDDKit 的 `KurrentDBProjectionFileGenerator`（D4，維持 Genesis `Projection.js.template`）。
- **不**碰 `ProjectorProtocol`/`apply()`/`EventMapper`（DDDKit build-plugin 產，D5）。
- **不**加 retry/poll helper（D8/#1，OC 也沒有）；**不**做同步 read-your-write。
- **不**碰 auth/CORS/GCS/ensureInvariant（project-specific，TODO slot）。
- **不**做 `when()` mutation body（`/readmodel-mutation`）/ presenter business（`/presenter-fill`）。

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test --filter "StreamNamingTests|DeployScriptRendererTests|ReadModelRendererTests" 2>&1 | tail -5
swift test 2>&1 | tail -3   # 全 suite 無回歸

# regen IAM（--skip-build）→ 驗 deploy 腳本 + prefix 三方對齊
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1
test -f "$TMP/scripts/projection.sh" && test -f "$TMP/scripts/start-kurrentdb.sh"        # deploy 腳本存在
grep -q 'projections/continuous' "$TMP/scripts/projection.sh"
grep -q 'EVENTSTORE_RUN_PROJECTIONS=All' "$TMP/scripts/start-kurrentdb.sh"
grep -q 'kurrentdb:latest' "$TMP/scripts/start-kurrentdb.sh"          # image 路徑
grep -qE 'KDB_HOST="\$\{KDB_HOST:-' "$TMP/scripts/projection.sh"      # MF4: env-override 形（非 bare literal）
# ⭐ prefix 三方對齊（IAMContext → IAMC）。MF3：不用 `grep IAMC`（會誤中 "IAMContext" import/註解子字串）；
#   改精準比對 aggregate 寫 category 字面 + Presenter categoryRule：
grep -q '"IAMC\\(Self.self)"' "$TMP"/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift   # 寫 category = IAMC+Self
grep -rq 'withPrefix: "IAMC_"' "$TMP"/Sources                          # Presenter categoryRule（修前是 IAM_）
for js in "$TMP"/projections/*Projection.js; do grep -q '\$ce-IAMC' "$js" || echo "MISALIGN: $js"; done   # JS 訂閱 = $ce-IAMC<Agg>
ls "$TMP"/projections/IAMC_*Projection.js >/dev/null 2>&1 && echo "projection 檔前綴 IAMC_ ✓"
! ls "$TMP"/projections/IAM_*Projection.js >/dev/null 2>&1 && echo "舊 IAM_ 前綴已消失 ✓"   # 負向：舊壞前綴不存在
# server template 不再有假宣稱
! grep -rq 'read endpoints return empty/notFound' "$TMP"/Sources 2>/dev/null && echo "server template 假宣稱已移除 ✓"
rm -rf "$TMP"
```

### Human 補做（read-after-write 完整鏈，需 Docker + KurrentDB）

- [ ] **read-after-write smoke（M3，證 crux）—— 拆兩段斷言（audit F5）**：fresh `genesis new` 一個**有 read model 的 context**（⚠️ iam-cosmogony-bundle **有** read models〔`GetPermissions`/`GetUserAccessProfileRoles`〕→ 可用；若選的 context 無 read model 則此 smoke 無從跑）→ `bash scripts/start-kurrentdb.sh` → `bash scripts/projection.sh`（部署 codegen 的 `.js`）→ `swift run <Ctx>Server` → 外部 POST 寫事件 → **稍候**：
  - **(1) 核心 gating 證明（不需 `/readmodel-mutation`）**：GET 回**非-nil read model（欄位為 default）** → 證明 **prefix 對齊 + link-stream 真的被灌**（這就是本 task 修的兩件事 + crux「零 Swift 訂閱」）。
  - **(2) 投影值（需先 `/readmodel-mutation` 填 `when()` body）**：GET 回**非-default 欄位值**。此段依賴 deferred skill，非本 task gating。
- [ ] **prefix 對齊實證**：確認 KurrentDB UI 裡 JS projection 訂閱的 `$ce-<prefix><Agg>` 與實際事件 stream 同名（write 有進、projection 有 emit、link stream 有資料）。
- [ ] **eventual consistency**：write 後**立刻** GET 觀察到 nil/空（projection 還沒追上）→ 稍候再 GET 有值（驗證 contract，非 bug）。

---

## 依賴關係

- **來源**：`docs/discussions/2026-06-05-projection-deploy-and-read-runtime.md`（crux + D1-D9 + user 拍板 5 問）。
- **硬相依（done）**：ReadModelRenderer（已 codegen `.js`/Presenter/ReadModel）、ServerRenderer（已 codegen 可跑 server + read GET handler from kdbClient）、AggregateRenderer（categoryPrefix 既有）。
- **解鎖**：fresh 專案的 read-after-write 真的能動（非-OC context 不再靜默壞）；deploy 一鍵化。
- **後續（defer）**：Swift 訂閱/EventBus 寫反應 lane（codegen 機械骨架 + skill 填 listener 清單，D9，先解 `$ce-AuditQuoting` vs `$ce-OCAuditQuoting` 命名）；auth/CORS；ensureInvariant skill。

## 下一步
write-spec done；**audit-spec done**（adversarial workflow `wf_6de2e84a-31f`，2 lens + synthesis；對照 REAL AggregateRenderer/ReadModelRenderer/BundleParser/SourceWriter/OC scripts + **live IAM regen**）。verdict = **NEEDS_FIX, ready_after_fixes=true**（核心分析全驗證 sound：M2b bug live-regen 證實、StreamNaming 抽取對 OC 行為等價、crux、eventual contract、M2c guard 資料路徑可行）。**4 must-fix 已全 fold 進本 spec**：MF1（BLOCK，test-update 清單漏 6 處綠斷言：ReadModelRendererTests `:91,94,285` + 整檔漏列的 NewCommandTests `:441,457,459` → 已補 + closing grep）、MF2（HIGH，StreamNaming guard 須同時保 `Context`-alone reject〔`uppercaseLetters("Context")=="C"` 抓不到〕+ no-uppercase guard → 已釘雙 guard + 訊息）、MF3（MED，acceptance `grep IAMC` 誤中 `IAMContext` 子字串 → 改精準比對寫 category 字面 + `withPrefix:"IAMC_"`）、MF4（MED，「逐字複本」與「env 覆寫」矛盾 + 3 個 OC 字面誤述 → 改「結構性複本 + `${VAR:-default}` enhancement」+ 修 `EVENTSTORE_` 前綴/image 全路徑 + golden 驗 override 形）。residual（impl/Human-smoke 時驗）：uppercaseLetters 縮寫跨 context 可碰撞（v1 可接受，已加 caveat）、M3 smoke 拆「default 欄位=gating 證明」vs「投影值=需 /readmodel-mutation」。

~~NEXT → impl~~ → **impl DONE**（2026-06-05，ultracode；M1→M2 + adversarial review wf_86abdfdd-dfd）。全 gate 綠：swift build（0 warning）/ 全 suite **319 pass · 0 fail · 2 skip** / **live IAM regen 三方對齊證實**（aggregate `IAMC` = Presenter `IAMC_` = JS `$ce-IAMC<Agg>` = 檔 `IAMC_`，舊 `IAM_` 消失）/ 2 deploy 腳本 emit + `bash -n` 過 / server template 假宣稱移除。review verdict FIX_THEN_SHIP → 2 MED 已修（MF-A：M2c guard 加 `&& $0.aggregate == ref.sourceAggregate` 防跨 aggregate 同名 event resolve 錯 UC + 負向測；MF-B：`/readmodel` SKILL.md 改 uppercase-letters 單一規則、刪舊覆寫 precedence）+ 2 LOW shell（guarded cat、port-coupled KDB_HOST）。**尚未 commit**。M3 read-after-write 完整鏈 = Human smoke（Docker+KDB）。
