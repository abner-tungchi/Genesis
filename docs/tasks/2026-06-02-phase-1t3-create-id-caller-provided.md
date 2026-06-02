# Phase 1.t.3 — create id 對齊 caller-provided（PA-F6）

## 來源

`docs/discussions/2026-06-01-full-pipeline-parity-audit.md`（**PA-F6**，full skill-run dogfood 揪出）。**user 拍板（2026-06-02）= caller-provided（對齊 OC）**，故跳過 /discuss（方向已定），直接 write-spec → audit-spec → impl。

部分**撤回 Phase 1.t.1**：1.t.1 把 create-init 對齊到 Genesis 既有的（OC-misaligned）「create 無 aggId / server-gen UUID」前提；PA-F6 證 OC 是 caller-provided（`CreateAuditQuotingInput` 有 `quotingId`、usecase 用 `input.quotingId` 非 UUID）。adapter 層（AS Input / ApiHandler `input.path.<aggId>` / openapi）**早已照 OC**，是 usecase 層 + 1.t.1 走偏。

## 目標

讓 create UC 全鏈一致為 **caller-provided aggId**（對齊 OC）：create Input 帶 aggId、`/usecase` Create pattern 用 `input.<aggId>`（非 UUID）、create init `id:` 由 caller 傳。**保留** 1.t.1 的 input-only convenience init（IAM 的 derived payload 欄位 permissions/roles/status 仍不在 create input，仍需 honest TODO；只是 `id:` 改由 caller 提供）。

## 介面合約

### D-PAF6a — UseCaseRenderer.renderInput：create 不再 skip aggId
`renderInput` 移除 `isCreateUseCase` 的 aggId-skip 分支 → **create UC Input = `[aggId] + businessFields + [operatorId]`**（與非-create 同序，OC 一致）。`isCreateUseCase` 其他用途（D6 command-extension skip）**不動**。

生成的 `CreateUserAccessProfileInput` 將從 `(userId, department, jobTitle, operatorId)` 變為 `(userAccessProfileId, userId, department, jobTitle, operatorId)`。

### D-PAF6b — /usecase SKILL.md Create pattern：用 input.<aggId>（撤回 1.t.1 UUID）
```swift
        do {
            let <agg> = try <A>(id: input.<aggId>, <inputBusinessField>: input.<inputBusinessField>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.operatorId)
            return .init(id: input.<aggId>, message: nil)
        } catch let error as ContextError<<A>Error> { throw error }
        catch let error as DDDError { throw error }
        catch { throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error]) }
```
- id 來源從 `UUID().uuidString`（1.t.1）改回 `input.<aggId>`（create Input 現有 aggId）。
- Phase 3 prose：create UC Input **有** aggId（第一個 field），與非-create 同；移除 1.t.1 加的「create UC Input 無 aggId / id 由 service UUID 生」prose。
- Phase 4 Create：non-id init param 驗在 input business fields（不變）；id 來源 = `input.<aggId>`（不再 UUID）。

### 不變（保留）
- **1.t.1 convenience init**（`AggregateRenderer`）：IAM derived 欄位仍不在 input → 仍 emit input-only convenience init（honest fatalError TODO）。caller 傳 `id`，convenience init 的 `id:` 參數即 caller-provided。`createdUseCase.input`（bundle）不含 aggId（aggId 是 UseCaseRenderer 對 Input FILE 注入；AggregateRenderer 的 inputBusinessFields = bundle input 去 alias/operatorId 不受本 task 影響）。
- **D6**（create skip command extension）、adapter 層、ContextError factory、ensureInvariant、when reducer — 全不動。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/UseCaseRenderer.swift` | `renderInput` 移除 create aggId-skip（create Input 加 aggId 首位）|
| `Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md` | Create pattern `id = input.<aggId>`（撤 UUID）；Phase 3/4 prose 改「create 有 aggId」|
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | （Codex audit MED）更新 `testCreateUseCaseInputOmitsAggId`（→ rename `testCreateUseCaseInputContainsAggId`，assert create input **有** aggId）+ `testCosmogonyBundleEndToEnd`（create-no-aggId assertion 反轉為 has-aggId）。這兩個是唯一 assert「create 無 aggId」的測試（Codex 確認 GenesisCoreTests/* 無此類）|

## 實作步驟
1. `UseCaseRenderer.renderInput`：把 `if isCreateUseCase { businessFields + [operatorIdField] } else { [aggIdField] + businessFields + [operatorIdField] }` 改為一律 `[aggIdField] + businessFields + [operatorIdField]`（移除 create 分支）。保留 `isCreateUseCase` 於 D6 command-skip。
2. `/usecase SKILL.md`：Create pattern code block id 改 `input.<aggId>`、return `.init(id: input.<aggId>, message: nil)`；Phase 3 prose 改 create 有 aggId（撤 1.t.1 的 no-aggId 段）；Phase 4 Create id 來源改 input.<aggId>。
3. 更新 `Tests/GenesisIntegrationTests/NewCommandTests.swift`（Codex 確認唯一處）：`testCreateUseCaseInputOmitsAggId`（rename + 反轉 assert：create input **有** `useraccessprofileId`/`userAccessProfileId`，且順序為 aggId 首、operatorId 末）+ `testCosmogonyBundleEndToEnd` 的 create-no-aggId assertion 反轉。可加 `UseCaseRendererTests` create input 順序 regression。
4. swift build + swift test；regen IAM 驗 CreateUserAccessProfileInput 有 userAccessProfileId 首位 + convenience init 仍在 + D6（create 無 command extension）仍成立。

> **Codex audit 確認（無 code 變更需求）**：(a) `isCreateUseCase` 只用於 renderInput aggId-skip（本 task 改）+ render() D6 command-skip（不動）— 互相獨立。(b) convenience init emission 由 `createdUseCase.input`（**bundle**，無 aggId）filter alias/operatorId + derivedFieldNames 驅動 —— **不依賴生成的 Input file**，故 UseCaseRenderer 注入 aggId 不影響 convenience init；caller 端 `try <A>(id: input.<aggId>, <business>...)`：有 derived → 命中 4-arg convenience、無 derived → 命中 designated（deterministic）。(c) **/api 無需改** —— create AS Input 本就有 aggId，`/api` server-generated-ID variant（Service 有 *Id 但 AS 無）不觸發。

## 失敗路徑
| 條件 | 行為 |
|---|---|
| 既有測試 assert create input 無 aggId | 更新該測試（語意已改：create 現有 aggId）|
| derived 欄位仍在（IAM）| convenience init（1.t.1）續存，honest TODO |

## 不改動的部分
- 1.t.1 convenience init 邏輯 / AggregateRenderer create-init。
- D6 command-extension skip。
- adapter 層 / openapi / ContextError factory / ensureInvariant / when reducer。
- DDDKit / bundle schema。

### Non-goals
- 不改 derived 欄位來源（permissions/roles/status 仍 honest TODO；是否進 create input 屬 bundle-authoring，非 codegen）。
- 不動 server-side id 生成的任何殘留（全面改 caller-provided）。
- 不改其他 UC（非 create）。

## 驗收標準

### Agent 必做
```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test 2>&1 | tail -3

TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1
CIN="$TMP/Sources/UserAccessProfileAggregate/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileInput.swift"
# create Input 精確欄位順序 = aggId 首、operatorId 末（Codex MED：勿用寬鬆 grep）
python3 -c "import re,pathlib; t=pathlib.Path('$CIN').read_text(); fs=re.findall(r'package let (\w+):', t); assert fs==['userAccessProfileId','userId','department','jobTitle','operatorId'], fs; print('create input order OK:', fs)"
# convenience init（1.t.1）仍在
grep -q 'package convenience init(id: String, userId: String, department: String, jobTitle: String) throws' "$TMP"/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift
# D6：create 仍無 command extension
test ! -f "$TMP"/Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+CreateUserAccessProfile.swift
rm -rf "$TMP"

# /usecase skill Create 用 input.<aggId>（Create block 內無 UUID）
python3 -c "import re,pathlib; t=pathlib.Path('Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md').read_text(); b=re.search(r'### Create pattern.*?### Update pattern', t, re.S).group(0); assert 'UUID().uuidString' not in b, 'UUID still in Create block'; assert 'input.<aggId>' in b, 'input.<aggId> missing'; print('Create pattern OK')"
```

### Human 補做
- [ ] regen + 對 createUserAccessProfile 跑 /usecase → 命中 Create pattern、用 input.userAccessProfileId（caller-provided）、convenience init fatalError TODO 待人填 derive。
- [ ] 全鏈一致確認:openapi path aggId → ApiHandler → AS Input → usecase input.aggId → init id，無 UUID。

## 已知限制
- IAM create 的 derived 欄位（permissions/roles/status）仍 human（convenience init TODO）——caller-provided 解決的是 id 來源，非 derived 欄位來源（後者屬 bundle/domain）。

### 依賴關係
- 撤回部分 Phase 1.t.1（UUID + create-aggId-skip）；保留 1.t.1 convenience init。
- 軟相依：Phase 1.t / 1.t.1 / 1.t.2。
