# Phase 1.x — codegen emit Usecase execute() orchestration body（D1）

## 來源

討論：`docs/discussions/2026-06-02-codegen-vs-retrofit-skill-boundary.md`（R2 consensus）**D1**：deterministic fill（usecase orchestration）收回 codegen。本 task 實作其中 **usecase orchestration（execute body）** 那一塊（api wiring / readmodel type-closure 為後續 phase）。

## 目標

`UseCaseRenderer` 生成 `{UC}Usecase.swift` 時，**直接 emit 完整 execute() orchestration body**（Create / Update / Delete pattern：`repository.find → aggregate.<command>(...) → repository.save → return Output` + catch ladder），取代現在的 `fatalError("TODO(/usecase skill): ...")` stub。

理由（討論 D1 + 你戳的點）：execute 是純 orchestration、type/結構可機械導、無業務判斷 → 屬 codegen。且 codegen **自己同時生成 Input 與 command 簽名**（同源 useCase.input），所以兩邊保證一致，比 `/usecase` skill 的 structural-detection 更可靠（skill 是事後讀 code 重推導）。

效果：`genesis new` 後機械層直接是真 code，**少一個手動 `/usecase` 步驟**。業務判斷仍在 command/when/ensureInvariant 的 `#error` 洞（`/domain-fill`）。

**誠實區分（不可混淆）**：execute body codegen-complete **≠ 專案 build 綠**。execute 呼叫的 command 本身仍有 `#error` 洞（Phase 1.u），module 要等 `/domain-fill` 填完 command 才編譯。`{UC}Usecase.swift` 這個檔本身會是完整無洞（它只是呼叫一個存在的 method）。

## 介面合約

### Pattern 選擇（codegen-time，deterministic）

在 `render()`（已有 `useCase` / `isCreateUseCase` / `ucCamel` / `commandFields`）算 `executeBody`：

1. **Create**：`isCreateUseCase`（`ucCamel` prefix `create`/`establish`，既有判定）→ Create body（呼叫 aggregate init，**無** command extension，D6）。
2. **Delete**：`ucCamel` lowercased prefix `delete` → Delete body（`repository.delete`，無 command call）。
3. **Update**：其餘 → Update body（呼叫 command method）。
4. **defensive fallback**：理論上 well-formed bundle 每 UC 都落 1-3（create→init / 非-create→command extension〔D6 只跳 create〕/ delete-prefix→delete）。若真無法解析（非-create 卻無 command extension，不該發生）→ emit `#error("GENESIS-TODO: unrecognized usecase orchestration for {ucCamel}; hand-fill execute body")`（保守，與 scaffold-emitter 一致;不亂生）。

> **一致性保證（已驗 code）**：`render()` 傳給 `renderCommandExtension` 的 `commandFields` **就是 `useCase.input`（verbatim）**;command 簽名逐欄位由它生。故 Update body **逐 `useCase.input` 欄位** emit `<name>: input.<name>`（同序同源）→ 與 command 簽名保證一致。`useCase.input` = aggId + business（bundle raw input **不含 operatorId**;operatorId 由 `renderInput` 合成進 Input 型別）。operatorId **不傳 command**，只給 `repository.save(userId: input.<operatorId>)`。
>
> **Create init 一致性（已驗 code）**：Create body 的 init 非-id 參數 = `useCase.input.filter { name != aggId && name != "operatorId" }`（**與 `AggregateRenderer` 生 convenience init 用的同一 filter 同序**）→ `try <A>(id: input.<aggId>, <每 businessField>: input.<businessField>)` 保證命中 init 簽名。

### 三個 body 模板（移植自 `/usecase` SKILL.md Phase 5，SSOT 一致）

`<agg>` = lowerCamel aggregate;`<A>` = UpperCamel;`<aggId>` = Input 首欄位名;`<operatorId>` = Input 的 operatorId 欄位名。

**Create**（`<initArgN>` = create init 非-id 參數 = input business fields，順序依 init 簽名）：
```swift
        do {
            let <agg> = try <A>(id: input.<aggId>, <initArg1>: input.<initArg1>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.<operatorId>)
            return .init(id: input.<aggId>, message: nil)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
```

**Update**（`<cmdArgN>` = command 簽名參數，逐一 `input.<cmdArgN>`）：
```swift
        guard let <agg> = try await repository.find(byId: input.<aggId>) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: <A>.self, aggregateRootId: input.<aggId>)
        }
        do {
            try <agg>.<ucCamel>(<cmdArg1>: input.<cmdArg1>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.<operatorId>)
            return .init(id: <agg>.id, message: nil)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
```

**Delete**：
```swift
        guard let <agg> = try await repository.find(byId: input.<aggId>) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: <A>.self, aggregateRootId: input.<aggId>)
        }
        do {
            try await repository.delete(byId: <agg>.id, userId: input.<operatorId>)
            return .init(id: <agg>.id)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
```

### 不變
- `{UC}Usecase` protocol / Input / Output / Service / Command extension（含 `#error` 洞）/ Aggregate / ensureInvariant 結構不動。
- create convenience-init 的 `fatalError("GENESIS-TODO: derive non-input...")`（Phase 1.t.1）**不動**（Create body 呼叫該 init;init 內的 fatalError 是既有 runtime 洞，非本 phase scope）。
- `/usecase` SKILL.md **不動**（見下「skill 重定位」）。
- `{UC}Output { id: String?, message: String? }` 兩欄位結構（Delete 用 `.init(id:)` 省 message）。

### skill 重定位（D4，本 phase 不改 skill code，只記定位）
`/usecase` → **migration-only**（服務 codegen 版本過舊、只 emit 過 stub 的 legacy 專案）。對 D1-生成的新專案，execute 已填 → `/usecase` 的 idempotent Phase 2 判「已填」→ exit 0 skip（無害、向後相容）。本 phase **不刪、不改** `/usecase` SKILL.md。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Usecase.swift.template` | execute body 的 `fatalError("TODO(/usecase skill)...")` → `{ExecuteBody}` placeholder |
| `Sources/GenesisCore/UseCaseRenderer.swift` | `render()` 算 `executeBody`（Create/Update/Delete pattern，用既有 isCreateUseCase + commandFields + Input 欄位）→ 傳給 `renderUsecase`；`renderUsecase` 簽名加 `executeBody`，template var 加 `{ExecuteBody}`。加 `buildExecuteBody(...)` helper |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | 第 286 行斷言 flip：`ucContent` 從「**含** `fatalError("TODO(/usecase skill)")`」→「**不含** stub + **含** execute body（如 `repository.save(aggregateRoot:`）」 |
| `Tests/GenesisCoreTests/UseCaseRendererTests.swift` | 加測：Create UC → execute 含 `try <A>(id: input.<aggId>` + `repository.save`;Update UC → 含 `repository.find(byId:` + `try <agg>.<uc>(` + `repository.save`;Delete UC → 含 `repository.delete(byId:`;皆不含 `fatalError("TODO(/usecase skill)")` |

### 不需改
- `/usecase` `/api` `/readmodel-mutation` `/domain-fill` SKILL.md。
- AggregateRenderer / ApiRenderer / 其他 renderer。
- bundle schema / DDDKit。

## 實作步驟

### Step 1：Usecase.swift.template
1. execute body 內那行 `fatalError("TODO(/usecase skill): ...")` → `{ExecuteBody}`（保持 8-space 縮排由 buildExecuteBody 內含）。

### Step 2：UseCaseRenderer buildExecuteBody + render 接線
1. 加 `buildExecuteBody(ucCamel:aggregate:aggIdName:operatorIdName:commandFields:isCreateUseCase:createInitBusinessArgs:) -> String`：
   - isCreateUseCase → Create body（init: id + createInitBusinessArgs〔= input business fields〕）。
   - prefix `delete` → Delete body。
   - 否則 → Update body（command call 用 commandFields）。
   - 無法解析 → `#error(...)` fallback。
2. `render()`：算所需參數（aggIdName = input 首欄位;operatorIdName = input 的 operatorId 欄位;commandFields = 與 renderCommandExtension 同源那串;createInitBusinessArgs = input business fields）→ 呼叫 buildExecuteBody → 傳給 renderUsecase。
3. `renderUsecase` 簽名加 `executeBody: String`，vars 加 `"ExecuteBody": executeBody`。

### Step 3：測試（NewCommandTests flip + UseCaseRendererTests 三 pattern）

### Step 4：build + test + regen 驗證（見驗收）

## 失敗路徑

| 條件 | 行為 |
|---|---|
| Create UC | Create body（init + save）|
| Delete-prefix UC | Delete body（find + delete）|
| 一般 UC（有 command extension）| Update body（find + command + save）|
| 非-create 卻無 command extension（不該發生）| `#error` fallback（不亂生）|
| command 含 operatorId? | 否 —— command 簽名 = aggId + business;operatorId 僅 save(userId:) |

## 不改動的部分
- command/when/ensureInvariant 的 `#error` 洞（Phase 1.u）—— execute 呼叫它們，洞由 `/domain-fill` 填。
- create convenience-init fatalError（1.t.1，既有）。
- `/usecase` SKILL.md（migration-only 定位，code 不動）。

### Non-goals（行為層）
- **不**做 api wiring / readmodel type-closure 收回 codegen（同 D1 原則，後續 phase）。
- **不**改 / 不刪 `/usecase` skill（D4 migration-only，靠 idempotent skip 向後相容）。
- **不**動 create init 的 fatalError（1.t.1 既有 runtime 洞）。
- **不**處理多-command 分支 orchestration（bundle 1-UC-1-command 模型不表達它;OC RemoveServiceItems 那種非 bundle-expressible，手寫）。
- **不**保證 fresh gen build 綠（command `#error` 洞仍在;execute 完整不代表 module 編譯）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test 2>&1 | tail -5   # 含 NewCommandTests flip + UseCaseRendererTests 三 pattern

# regen IAM（--skip-build）
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1
AGG="$TMP/Sources/UserAccessProfileAggregate"   # 註：fixture aggregate 名以 fixture 為準

# Update UC（promoteUser）：execute 有真 body，無 stub
PU="$AGG/Usecase/Port/In/PromoteUser/PromoteUserUsecase.swift"
grep -q 'repository.find(byId: input.' "$PU"
grep -q 'try .*\.promoteUser(' "$PU"
grep -q 'repository.save(aggregateRoot:' "$PU"
! grep -q 'fatalError("TODO(/usecase skill)' "$PU"

# Create UC：execute 用 init
CU="$AGG/Usecase/Port/In/CreateUserAccessProfile/CreateUserAccessProfileUsecase.swift"
grep -qE 'try .+\(id: input\.' "$CU"
grep -q 'repository.save(aggregateRoot:' "$CU"
! grep -q 'fatalError("TODO(/usecase skill)' "$CU"

# command 仍有 #error 洞（execute 完整 ≠ build 綠）
grep -rq '#error("GENESIS-TODO' "$AGG/Entity/Commands/"
rm -rf "$TMP"
```

### Human 補做
- [ ] regen + 對某 UC 確認 execute body 正確（command call 參數對齊 command 簽名、save 用 operatorId）。
- [ ] 確認 `/usecase` 對 D1-生成專案 idempotent skip（exit 0，不重填）。
- [ ] 填完 command `#error`（/domain-fill）後 `swift build` 綠（驗 execute 接線正確）。

## 已知限制
- execute codegen-complete **≠ build 綠**：command `#error` 洞仍需 `/domain-fill`。
- create body 呼叫的 init 仍含 `fatalError`（1.t.1，derive 非-input 欄位）→ runtime 洞，待遷 `#error` / 手填（既有，非本 phase）。
- 多-command 分支 orchestration 不 codegen（bundle 不表達）。
- api wiring / readmodel type-closure 尚未收回（D1 後續 phase）。

### 依賴關係
- 軟相依（done）：Phase 1.t.1（create init）、1.t.3（create aggId caller-provided）、1.u（command #error 洞，execute 呼叫的對象）。
- 來源：discussion `2026-06-02-codegen-vs-retrofit-skill-boundary.md` D1。
- 後續：api wiring 收回 / readmodel type-closure 收回（D1 同原則）;A3 bundle-first retrofit（D3）;manifest role 兩態（D6）。
