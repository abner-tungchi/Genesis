# Phase 1.t.1 — create-init 對齊 input + /usecase Create pattern 修正

## 來源

討論：`docs/discussions/2026-06-01-domain-layer-codegen-gap.md`（**D3** consensus：create-init 簽名對齊 use-case Input、payload 衍生欄位 human）+ `docs/discussions/2026-06-01-full-pipeline-parity-audit.md`（**PA-F2**）。

本 task 是 Phase 1.t 明確 defer 的 D3。實作中發現的連帶 misalignment（**/usecase Create pattern 用 `input.<aggId>` 但 create UC input 無 aggId、id 由 service UUID 生**）是 **單一強制解**（create input 結構上無 aggId — `UseCaseRenderer` 對 create UC skip aggId 注入；id 必為 server-gen UUID，codegen 既有註解已載明），無設計取捨 → 不另開 /discuss，折入本 spec 作為 D3 的機械必然後果。

## 目標

讓 create UC 能被 `/usecase` Create pattern 機械 fill（目前 exit 3：`Create init expects field 'permissions' not in input`）。根因 = 生成的 create-init 簽名來自 **event payload 全欄位**（含 `permissions/roles/status` 等非 input 的衍生欄位），與 use-case Input（`userId/department/jobTitle`）脫節（PA-F2）。

解法（D3 + 低風險 init 設計）：
- 維持現有 **designated full-payload init**（建+apply CreatedEvent）+ **rehydration init** **不動** → **event replay 正確性不受影響**（rehydration 仍走 designated init 設全 state）。
- **新增** 一個 **input-only convenience init**（簽名 = create UC input business fields），body = `// GENESIS-TODO` + `fatalError`（衍生欄位是 domain/external 知識，honest obligation）。**只被 create caller（`/usecase` Create pattern）呼叫，rehydration 不呼叫它 → 不影響 replay。**
- 修 `/usecase` skill Create pattern：`id` 改 `UUID().uuidString`（非 `input.<aggId>`），call input-only init。

## 介面合約（Interface Contract）

### D3a — input-only convenience init（`AggregateRenderer.renderAggregate` + `Aggregate.swift.template`）

**僅當 `derivedFields` 非空才 emit**。當 `derivedFields.isEmpty`（input business fields 已涵蓋全部 payload）→ **不 emit**（designated init 簽名已 == input business fields，create caller 直接用 designated；再加會 signature 衝突）。

> **input business fields 計算（Codex audit HIGH 修正）**：`inputBusinessFields = createdUseCase.input.filter { $0.name != alias && $0.name != "operatorId" }` —— **必須同時 filter `operatorId`**（與 `UseCaseRenderer.renderInput` 的 `businessFields` 算法一致；`operatorId` 是 save metadata 概念，非 entity state，且若 bundle author 把它放進 input 也要排除）。`derivedFields` = `payloadFields`（已去 alias）中 name 不在 `inputBusinessFields` names 者。

```swift
    // Create entry point for callers (e.g. {CreateUC}Service). The use-case Input does NOT carry the
    // non-input createdEvent payload field(s) [{DerivedFieldNames}], so deriving them is domain logic.
    package convenience init(id: String{CreateInputInitParams}) throws {
        // GENESIS-TODO: derive non-input createdEvent payload field(s) [{DerivedFieldNames}] from input
        // and/or external source, then delegate to the full init:
        //   try self.init(id: id, <inputField>: <inputField>, {DerivedFieldNames}: <derived>)
        fatalError("GENESIS-TODO: derive non-input payload field(s) [{DerivedFieldNames}] and delegate to the full init")
    }
```

- `{CreateInputInitParams}` = create UC input business fields（`createdUseCase.input` 去掉 alias）：`, userId: String, department: String, jobTitle: String`。
- `{DerivedFieldNames}` = `payload - input` 的欄位名 join（如 `permissions, roles, status`）。
- **designated init + rehydration init 一字不改**（保 replay）。
- `convenience init` 與 designated init 簽名不同（參數較少）→ Swift overload 解析無衝突；create caller 的 N-arg 呼叫精確命中 convenience，rehydration 的 full-arg 命中 designated。
- `fatalError` 在 `convenience init` 內合法（`Never` 滿足「必須 delegate」的路徑要求，fatalError 路徑不需 delegate）。**只 create caller 觸發**（runtime honest crash 直到 human 填），rehydration 不經此 init。

### D3b — /usecase skill Create pattern（`Templates/skills/usecase/SKILL.md`）

Create UC 的 id 是 server-generated UUID（create input 無 aggId）。Create pattern emit 改為：

```swift
        let <agg>Id = UUID().uuidString
        do {
            let <agg> = try <A>(id: <agg>Id, <inputBusinessField>: input.<inputBusinessField>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.operatorId)
            return .init(id: <agg>Id, message: nil)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
```

- `id` 來源從 `input.<aggId>` 改為 `UUID().uuidString`（create input 無 aggId）。
- init 參數 = input business fields（命中 D3a 的 convenience init，或 derivedFields 為空時的 designated init）。

**須同步的所有 create-specific prose（Codex audit MED：不只 Phase 3/4）**：
- **frontmatter description** + **task intro**：移除/修正「Phase 1.l 後 Input 含 aggId + operatorId」對 create UC 的暗示（create UC Input **無** aggId）。
- **Phase 3 parse Input**：「`<aggId>` = 第一個 field 名」對 create UC 錯（create input 無 aggId）。改為：create UC 不取 `<aggId>`、`id = UUID().uuidString`；非 create 維持第一 field = aggId。
- **Phase 4 Create**：偵測/驗證對象改為「create UC 的 input business fields ⊇ 該 init 非-id 參數」（D3a convenience init 參數 == input business fields → 必通過；不再驗 `input.<aggId>`）。
- **Phase 5 Create pattern code block**：如上 UUID 版。
- **「與其他 skills 的關係」/ Phase 0** 等 create 描述順帶校對。
- **Phase 2 idempotent detector 不動**（明確聲明）：填好的 create body 仍含 `try <A>(id:` + `repository.save` → 既有偵測仍成立，無需改。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template` | 加 `{CreateInputConvenienceInit}` placeholder（在 designated init 與 rehydration init 之間或之後）|
| `Sources/GenesisCore/AggregateRenderer.swift` | `renderAggregate` 算 inputFields / derivedFields；derived 非空 → 生 convenience init 區塊，否則空字串 |
| `Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md` | Create pattern：`id = UUID().uuidString`、call input-only init、return `.init(id: <newId>)`；Phase 3/4 文字同步 |
| `Tests/GenesisCoreTests/AggregateRendererTests.swift` | 加測：(a) derived 非空（IAM create）→ 生 input-only convenience init（簽名 == input business fields、body fatalError TODO）+ designated/rehydration 不變；(b) **boundary**：synthetic create UC input 涵蓋全 payload（`derivedFields.isEmpty`）→ **不**生 convenience init（Codex audit MED：IAM 測不到「不生」分支）|

## 實作步驟

### Step 1：renderAggregate 算 input/derived + convenience init
1. `renderAggregate`：`inputBusinessFields` = `createdUseCase.input.filter { $0.name != alias && $0.name != "operatorId" }`（resolve type）；`payloadFields` 已有（去 alias）；`derivedFields` = payloadFields 中 name 不在 inputBusinessFields names。
2. derived 非空 → 組 convenience init 字串（CreateInputInitParams = inputFields 的 `, name: Type`；DerivedFieldNames = derived names join）；否則 `""`。
3. 加 template var `CreateInputConvenienceInit`。

### Step 2：Aggregate.swift.template 加 placeholder
1. 在 designated init 之後、rehydration init 之前（或之後）插 `{CreateInputConvenienceInit}`（單獨一行展開；空字串時不留多餘空行 — 用既有 trim 慣例）。

### Step 3：/usecase SKILL.md Create pattern
1. Create pattern code block：`id = UUID().uuidString` + call input-only init + `return .init(id: <newId>, message: nil)`。
2. Phase 3/4：Create 偵測/驗證文字改為對 input business fields（移除「input.<aggId>」假設；create input 無 aggId）。

### Step 4：測試 + regen 驗證
1. AggregateRendererTests 加 convenience init 測（IAM create UC）。
2. swift build + swift test。
3. regen IAM → 驗 convenience init 生成 + designated/rehydration 不變。
4. （Human）dogfood：對 regen 專案跑 `/usecase createUserAccessProfile` → 應命中 Create pattern（不再 exit 3）、fill 後 swift build。

## 失敗路徑

| 條件 | 行為 |
|---|---|
| input == payload（無衍生）| **不**生 convenience init（designated 簽名已 == input；避免 signature 衝突）|
| derived 欄位含 alias / operatorId | 已在 inputFields/payloadFields 計算時去除（alias filter；operatorId 不在 entity payload）|
| convenience init 與 designated 簽名意外相同 | 僅 derived 非空才生 → 簽名必不同（少 derived 參數）；input==payload 不生 |
| /usecase Create pattern 改後對 input==payload UC | id 仍 UUID、call designated init（參數 == input）→ 正常 |

## 不改動的部分

- **designated full-payload init + rehydration init** — **一字不改**（replay 正確性核心，D3 風險隔離）。
- Phase 1.t 已實作的 D2/D4/D5/D6 — 不動。
- `when(event:)` / ensureInvariant / command method body — 不動。
- DDDKit / bundle schema / event.yaml — 不動。

### Non-goals（行為層）
- 本 task **不**自動 derive payload 衍生欄位（human domain logic；honest fatalError TODO）。
- 本 task **不**改 designated/rehydration init（保 replay）。
- 本 task **不**加 bundle payload provenance 標記（開放問題，defer）。
- 本 task **不**改其他 fill skill（/api 等）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -3
swift test 2>&1 | tail -5

# regen IAM
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -2
ENT="$TMP/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift"

# D3a: input-only convenience init 精確簽名（含 operatorId 排除 → 無 operatorId 參數；無 permissions/roles/status）
grep -q 'package convenience init(id: String, userId: String, department: String, jobTitle: String) throws' "$ENT"
! grep -q 'package convenience init(id: String, userId: String, department: String, jobTitle: String, operatorId' "$ENT"   # operatorId 不該進 convenience init
# convenience body 是 honest fatalError TODO
grep -q 'GENESIS-TODO: derive non-input payload field' "$ENT"
# designated full-payload init 仍在（精確：含 permissions/roles/status 全 payload）
grep -q 'package init(id: String, userId: String, department: String, jobTitle: String, permissions: Set<String>, roles: Set<String>, status: EmployeeStatus) throws' "$ENT"
# rehydration init 不變
grep -q 'required convenience init?(first createdEvent: UserAccessProfileCreated' "$ENT"
rm -rf "$TMP"

# D3b: /usecase skill Create pattern 用 UUID、移除 input.<aggId> 假設、create-input prose 已更新
grep -q 'UUID().uuidString' Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md
! grep -q 'input.<aggId>' Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md   # 舊 create aggId 假設已移除（注意：非 create Update/Delete 仍用 input.<aggId>，故 grep 須限定 Create pattern 區段——impl 時以 Create code block 內無 input.<aggId> 為準）
```

> **D3a boundary（`derivedFields.isEmpty` → 不生 convenience）由 renderer unit test 覆蓋**（IAM regen 一定有 derived，測不到「不生」分支）：在 `AggregateRendererTests` 加 synthetic create UC，input 涵蓋全 payload（derivedFields 空）→ assert 輸出**不含** `package convenience init`（只有 designated）。另一測：derived 非空 → assert 含 convenience init。

### Human 補做
- [ ] 對 regen IAM 專案跑 `/usecase createUserAccessProfile` → 確認命中 Create pattern（不再 exit 3）、生成 execute body call input-only init + UUID。
- [ ] 手填 entity convenience init（derive + delegate）後 `swift build` 通過。
- [ ] 確認 replay 行為不變（designated/rehydration 未動）—— 既有 find/replay 測試（需 KDB）仍綠。

## 已知限制

- create UC 的 domain 完整性仍 human（衍生欄位 derive + event build）——本 task 只讓 create UC **可被 /usecase 機械 fill 到 orchestration 層**（init 簽名對齊），entity convenience init body 仍 honest fatalError TODO。
- create 至 runtime 真正可跑需 human 填 convenience init（derive + delegate designated）。
- payload provenance 無機械標記（衍生欄位來源仍靠 human 判斷）。

### 依賴關係
- 前置（done）：Phase 1.t（D2/D4/D5/D6）、domain-gap discussion（D3 consensus）。
- 無 hard 阻塞。
