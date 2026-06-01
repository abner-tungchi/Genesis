---
topic: "Genesis 全 pipeline 架構對齊驗證（vs OC AuditQuotingAggregate）"
status: in-progress
created: "2026-06-01"
updated: "2026-06-01"
validation_target: "OC Sources/AuditQuotingAggregate（gold standard）"
test_project: "/tmp/genesis-testgen-dogfood（從 Cosmogony IAMContext.json 生成）"
pipeline_skills: [code-gen (genesis new), bundle-plan, usecase, api, readmodel-mutation, presenter-fill, test-gen]
---

# Genesis 全 pipeline 架構對齊驗證

/ goal：把 Genesis 全鏈路跑過，逐層對比 OC `AuditQuotingAggregate`，不對齊處 → /discuss → write-spec → audit-spec → impl。每次修改存檔；同一 bug 解超過三次未果則求助。

**儲存策略（goal 約束 #1）**：本檔 = 持久化的 findings + 進度 log。code 修改 = Genesis repo git commit。生成的驗證 artifact 在 `/tmp/genesis-testgen-dogfood/`。

---

## OC gold-standard 架構地圖（gemini 測繪，condensed）

| 層 | 路徑 | 型別 | 關鍵 pattern |
|---|---|---|---|
| Entity root | `Entity/<A>.swift` | `package class : <A>AggregateProtocol`(plugin-gen protocol) | `metadata: AggregateRootMetadata`；business `init(id:…) throws`→build Created→`apply`；rehydration `required convenience init?(first:other:)`；`ensureInvariant()` 在 extension，**順序呼叫一串 `check*()`**，由 DDDKit `apply` 前後各呼一次 |
| Commands | `Entity/Commands/<A>+<Cmd>.swift` | `extension` | **每檔一對**：command method `func <cmd>(…) throws`（驗證→build event→`try self.apply(event:)`）+ `when(event:) throws`（純 state mutation）|
| Usecase In | `Usecase/Port/In/<UC>/` | Input(`UseCaseInput`)+Output(`UseCaseOutput`)+Usecase(`protocol: Usecase where Input/Output`) | **execute() body 在 Usecase protocol extension**，shape：`find→guard else aggregateNotFound→aggregate.<cmd>(…)→save(userId:)→return`+catch ladder(DDDError/ContextError/executeUsecaseFailed)|
| Usecase Service | `Usecase/Service/<UC>Service.swift` | `package struct : <UC>Usecase` | **僅 `let repository` + init，無 execute**（type-erased entry）|
| Port Out | `Usecase/Port/Out/<A>Repository.swift` | `package struct : EventSourcingRepository` | `KurrentStorageCoordinator<<A>>` |
| Adapter AS | `Adapter/<UC>/<UC>ApplicationService.swift` | 3 types(Input+Output+AS struct) | Input `init(from: <OpenAPI payload>) throws`；AS.execute→instantiate `<UC>Service`→delegate |
| ApiHandler | `Adapter/ApiHandler.swift` | `struct: APIProtocol` | computed `repository`(注入 plugin EventMapper)；per-endpoint guard/dispatch/error-ladder |
| Dto | `Adapter/Dto/*.swift` | reciprocal `extension` | 雙向 `init(from:)`(domain↔DTO)；DTO enum 本身 plugin-gen |
| Projector | `Usecase/Projector/<RM>/` | ReadModel(`class: ReadModel`)+Presenter(`struct: <RM>ProjectorProtocol` plugin-gen) | Presenter 提供 `when(readModel: inout, event:)` reducers |
| Error | `<A>Error.swift` | `enum: Error & Equatable`(payload-free) | + `extension ContextError where ErrorType==<A>Error` 每 case 一 static factory(帶 function/message)|
| Events/Mapper | `event.yaml`（770 行） | **plugin-gen** | events / `<A>AggregateProtocol` / `<A>AggregateEventMapper` / per-projector mapper 全由 plugin 從 event.yaml 生 |
| Tests | `Tests/.../AuditQuotingAggregate/{Usecases,ApplicationServices,Api,Projectors,Invariants,Entity}/` | swift-testing | `@Suite(.serialized,.tags)`+`KurrentDBClient.localhost()`+`withTestBundle`+`#expect/#require`；fixture lib `SharedUtility/UsecaseCall/<A>.swift` |

完整 map：見本 session gemini 測繪（agentId ab1d68aacfcd3eef1）。

---

## 逐層對比（Genesis 生成 IAM vs OC gold-standard）

| 層 | 對齊? | 證據 / 備註 |
|---|---|---|
| Entity root: `class` + plugin protocol + metadata + 雙 init | ✅ | `UserAccessProfile.swift` = `package class: UserAccessProfileAggregateProtocol`，metadata、business init + rehydration init 全對 |
| Commands: command method + `when(event:)` 一對 | ✅ 結構 / ❌ body | 檔案結構對（`UserAccessProfile+<Cmd>.swift` extension，pair）；**但 command body = `fatalError("not implemented")`、`when` = 空 GENESIS-STUB** |
| Usecase In triple + execute 在 protocol extension | ✅ 結構 | `CreateUserAccessProfileUsecase.swift` = protocol + extension（execute 為 `fatalError` 待 /usecase fill）|
| Usecase Service: struct 僅 repository、無 execute | ✅ | `CreateUserAccessProfileService` 完全對齊 |
| Port Out: struct EventSourcingRepository | ✅ | `UserAccessProfileRepository` = struct + `KurrentStorageCoordinator<UserAccessProfile>` |
| Adapter AS / ApiHandler / Dto | ✅ 結構（待 fill 驗）| 檔案佈局對；body 待 /api fill |
| Projector: ReadModel + Presenter | ✅ 結構（待 fill 驗）| `Usecase/Projector/GetPermissions/` 有 ReadModel + Presenter + Dto |
| Error enum + ContextError factory | ✅ enum / ⚠️ factory 待查 | `UserAccessProfileError` enum 對；ContextError factory extension 是否生成待查 |
| Events/Mapper plugin-gen + event.yaml | ✅ | 生成 `event.yaml`（對齊 plugin input 名）+ `event-generator-config.yaml`；build 過 = plugin 接受 |
| `save(aggregateRoot:userId:)` | ✅ | overload 在 DDDKit `KurrentSupport/Adapter/EventSourcingRepository.swift`；OC 與生成專案同 0.3.0 revision → /usecase emit 的 `userId:` 可 compile（虛驚，非 misalignment）|
| Tests（two-file split, swift-testing, withTestBundle）| ✅ | test-gen Phase 1.s 驗過（編譯 + disabled skip）|

---

## Findings（misalignments）

### PA-F1 — 【MAJOR】domain 邏輯層無 fill skill（command body / when reducer / ensureInvariant 全 stub）

**現況**：`genesis new` 生成的 domain 層全是 stub：
- `Entity/<A>.swift` 的 `ensureInvariant()` = 空 GENESIS-STUB（OC 是順序呼叫一串 `check*()`）。
- `Entity/Commands/<A>+<Cmd>.swift` 的 command method = `fatalError("not implemented")`；`when(event:)` = 空 GENESIS-STUB。

**fill skill 覆蓋盤點**：`/usecase`(execute orchestration)、`/api`(AS/handler)、`/presenter-fill` + `/readmodel-mutation`(read 側)、`/test-gen`(test)。**沒有任何 skill 填 domain 層**（command body / when / ensureInvariant）。`/usecase` SKILL.md 明文「不動 Aggregate Entity / Command extension」。

**OC 對照**：OC 這三者全是**手寫的真實業務邏輯**（`ensureInvariant` 17 個 check、command 驗證 + apply、when 純 mutation）。

**含意**：跑完**所有**現有 fill skill 後，Genesis 專案仍 compile-pass 但 runtime fatalError（command 未填）、replay 不還原 state（when 空）、invariant 不檢查（ensureInvariant 空）。test-gen 的 create-happy-path 會在 runtime 失敗。

**待決（→ /discuss）**：Genesis 該 (a) 新增 domain-fill skill（從 bundle §3 invariants + command/payload 生 ensureInvariant check 骨架 + when reducer + command apply）？還是 (b) 明確界定「domain 層手寫」（如 OC），但把 stub 從 bundle 補成更完整的可編譯骨架（至少 when reducer 的 `self.x = event.x` + ensureInvariant 的 check 清單）？

### PA-F2 — 【MAJOR】create init 參數 ⊋ use-case Input（payload 衍生欄位無來源）

**現況**：`UserAccessProfile.init(id:userId:department:jobTitle:permissions:roles:status:)` 有 7 參數（除 id 外 6 個），但 `CreateUserAccessProfileInput` business fields 只有 `userId/department/jobTitle`（3 個）。`permissions/roles/status` 來自 **event payload**（codegen 把 payload 全欄位塞進 init），但**不是 use-case input** —— 它們是衍生/外部查詢的資料（員工檔）。

**含意**：`/usecase` 的 Create pattern（Phase 4：逐 non-id init param 驗在 input business fields）對 `createUserAccessProfile` 會 **exit 3：`Create init expects field 'permissions' not in input; manual hand-fill required`** → create UC 無法機械 fill。

**OC 對照**：OC create init 參數對齊 use-case input（衍生欄位在 domain 內計算，不入 init 簽名）。

**待決（→ /discuss）**：codegen 的 create init 簽名來源該是 **use-case input fields**（payload 衍生欄位在 domain 計算）還是 **event payload 全欄位**？目前用 payload 全欄位 → 與 input 脫節。這也是 test-gen dogfood TG-F1 的根因（create happy-path 的 domain payload 無來源）。

### PA-F3 — ensureInvariant() 連 check 清單骨架都沒生（bundle §3 有 invariants）

**現況**：bundle 明確帶 3 個 invariants（checkUserId/userIdNotExist、checkPermissions/permissionNotMatch、employeeMustActive/employeeNotActive，各有 rules）。但生成的 `ensureInvariant()` 是單一空 stub，**沒有**把這些 invariant 展開成 `checkUserId()` / `checkPermissions()` / `employeeMustActive()` 方法骨架 + 在 ensureInvariant 內順序呼叫（OC pattern）。errorCode 也沒接到 `ContextError<<A>Error>.<errorCode>` throw。

**含意**：即使「domain 手寫」是 intended boundary，bundle 已有的結構資訊（invariant 名 + errorCode）沒被 codegen 利用 → 人要從零寫 check 結構。

**關聯**：與 PA-F1 (b) 選項同源。

### PA-F4 — 無 ContextError factory extension（OC 有 per-case static factory）

**現況**：生成的 `UserAccessProfileError.swift` 只有 bare enum（3 case），**無** `extension ContextError where ErrorType == UserAccessProfileError { static func ... }`。OC 的 `<A>Error.swift` 為每個 case 附 static factory（帶 `function`/`message`），domain code 靠它 throw（`ContextError<…>.userIdNotExist(function:#function, message:)`）。

**含意**：`ContextError<E>` generic 本身存在（`IAMContextShared/ContextError.swift`），catch ladder compile-pass；但 domain 要 throw 時無便捷 factory → 與 PA-F1/F3（domain 層）同源。當 domain 手寫/fill 時會缺這層 ergonomics。

### read 側 asymmetry（佐證 PA-F1）
`GetPermissionsPresenter.when(readModel:inout, event:)` 是 no-op stub，但**有** `/readmodel-mutation` skill 負責填（read 側 mutation 有 skill）。對比之下 **write 側 entity `when(event:)`（`Entity/Commands/`）+ command body + ensureInvariant 完全沒 fill skill** —— 這是 read/write 不對稱的 gap，強化 PA-F1。

### 測繪待補
- ApplicationService body 跑 /api fill 後是否對齊 OC（3 types + init(from:) + delegate）。

---

## 實證結果（pipeline 跑一遍）

| skill | 結果 |
|---|---|
| `genesis new`（code-gen）| ✅ 91 檔，結構對齊；domain body stub |
| bundle-plan | ✅ 產 task spec（CreateUserAccessProfile / PromoteUser）|
| `/usecase`（Update, promoteUser）| ✅ 套 Update pattern fill → **swift build EXIT 0**（orchestration 層 find→command→save(userId:)→return+catch ladder 與 OC 對齊且編譯）|
| `/usecase`（Create, createUserAccessProfile）| ❌ **exit 3**（PA-F2：init 要 permissions/roles/status 非 input）|
| `/api` | （待跑；結構對齊）|
| `/readmodel-mutation` / `/presenter-fill` | read 側有 skill（projector when reducer 待填）|
| `/test-gen` | ✅ Phase 1.s 驗過（編譯 + disabled skip）|

---

## 進度 log

- 2026-06-01：建立基準。gemini 測繪 OC AuditQuotingAggregate 完整架構。生成 IAM 專案（7 write UC + GetPermissions read）。逐層結構比對：佈局/型別大致對齊；**domain body 層全 stub 且無 fill skill（PA-F1）**、create init/input 脫節（PA-F2）、ensureInvariant 未骨架化（PA-F3）、無 ContextError factory（PA-F4）。save(userId:) 虛驚排除（overload 在 DDDKit KurrentSupport）。
- 2026-06-01：/discuss domain-layer gap（`2026-06-01-domain-layer-codegen-gap.md`，三方 R2 consensus）。仲裁關鍵：DDDKit `apply()` pre/post 跑 ensureInvariant → KO 預設 throw/fatalError。決定 D1-D6（全 codegen 補強，無大 skill）。
- 2026-06-02：**Phase 1.t 實作 + 驗證完成**（write-spec → audit-spec〔Codex 2 HIGH 全修〕→ impl）。解 **PA-F3/PA-F4/N1/N2 + when silent-corruption**：
  - **D2/N2**：ContextError factory 機械生（per errorCode static func）+ error 檔無條件 `import <Ctx>Shared`。IAM regen ✓ + primitive-only minimal-bundle regen ✓（N2 真驗：FooAggregate 無 DTO 仍 import MinimalContextShared）。
  - **D4**：ensureInvariant 承載 bundle invariant（title/errorCode/rules 註解）+ runnable no-op（不破 DDDKit pre/post-apply）。IAM regen 3 invariant 全入註解 ✓。
  - **D5**：when reducer strict-safe scalar → `self.<f>=event.<f>`、否則 fatalError obligation。IAM UserPromoted（new/old）→ fatalError ✓；4 個 UseCaseRendererTests（strict-safe assign / collection / new-old / create-skip）全綠。
  - **D6**：移除 dead create command scaffold。IAM 無 `+CreateUserAccessProfile.swift`、有 `+PromoteUser.swift` ✓。
  - swift build ✓ / swift test 256 pass（252 + 4 新）/ 0 fail。
- **剩餘（deferred）**：
  - **PA-F2 / D3 → Phase 1.t.1**：create-init split 對齊 input + 新發現的 **/usecase Create pattern misalignment**（create UC input 無 aggId、id 由 service UUID 生，但 skill emit `input.<aggId>`）。entangled + 高風險，獨立處理。
  - **PA-F1 殘留**：command method body + invariant rule body 仍 honest TODO（intended human boundary，三方共識不自動填）。
  - **test-gen dogfood TG-F1/TG-F2**（前 session）：create happy-path 結構完整非語意免費 / create aggId cleanup（withTestBundle 無法 pre-register UUID-minted stream）。屬 test-gen skill 後續。
