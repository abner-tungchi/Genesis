---
name: usecase
description: Genesis fill-in skill (4th sibling, write-side domain orchestration). Inside a Genesis-bootstrapped project, /usecase <useCaseName> fills the `fatalError("TODO(/usecase skill)")` stub in `{UC}Usecase.swift` extension's `execute(input:)` body with one of 3 OC-aligned patterns (Create / Update / Delete) — calling `repository.find/save/delete` + aggregate method + standard catch ladder. Requires Phase 1.l (Usecase Input contains aggId + operatorId).
argument-hint: [useCaseName]
disable-model-invocation: true
allowed-tools: Read, Edit, Glob, Grep
---

# /usecase — Fill Usecase extension execute() body

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

對 `{UC}Usecase.swift` 內 `extension {UC}Usecase { execute(input:) async throws -> Output }` body，把 Phase 1.g/1.h codegen 產出的 `fatalError("TODO(/usecase skill)")` stub 替換為 OC pattern。**3 patterns**：Create / Update / Delete。前置條件：Phase 1.l 已 done（`{UC}Input` 含 aggId + operatorId）。

### 絕對約束（不可違反）

- **只動** `{UC}Usecase.swift` 內 extension default execute() body 的 `fatalError("TODO(/usecase skill)")` 替換
- **不動 Aggregate** Entity / Command extension / Usecase Input / Output / Service
- **不動** read-side（/presenter-fill / /readmodel-mutation 範疇）
- **不寫 openapi.yaml** / event.yaml / Package.swift / bundle JSON / 任何 *.yaml

## 輸入解析

`$ARGUMENTS` = lower-camel UC 名（e.g. `createUserAccessProfile`、`promoteUser`）。空 → exit 1。設 `ucCamel = $ARGUMENTS`、`ucPascal = UpperCamel(ucCamel)`。

## Phase 0 — Read-UC + arg 檢查

`ucCamel` lowercased prefix `get` / `list` / `find` → exit 2：`read UC not supported in /usecase; use /presenter-fill for read-side AS body`。

## Phase 1 — Locate {UC}Usecase.swift

Glob `Sources/*Aggregate/Usecase/Port/In/{ucPascal}/{ucPascal}Usecase.swift`：

- 0 match → exit 1：`prerequisite missing: {ucPascal}Usecase.swift not found; run genesis new`
- ≥2 match（同名跨 aggregate）→ exit 4：`ambiguous use case {ucPascal} in [...]; manual disambiguation`
- 1 match → 取 `<A>` = aggregate 名（path `Sources/<A>Aggregate/...`）

Verify `{ucPascal}Input.swift` + `{ucPascal}Output.swift` 存在，否則 exit 1。

## Phase 2 — Idempotent structural invariant（per body）

抽 extension default execute() body block：

| 狀態 | 判定 | 動作 |
|---|---|---|
| 已填 | 含 `repository.find` 或 `try <A>(id:`（Create）+ `repository.save` 或 `repository.delete`，且**無** `fatalError("TODO(/usecase skill)")` | exit 0 skip |
| 未填 | 含 `fatalError("TODO(/usecase skill)")` | 套 pattern fill |
| 半填 | 兩者皆非 | exit 4：`partial fill detected in {ucPascal}Usecase; manual repair needed` |

## Phase 3 — Parse Input + Aggregate

從 `{ucPascal}Input.swift` 取 fields（**含 create UC**：aggId 首位 + 業務欄位 + operatorId 末位）→ 設 `<aggId>` = 第一個 field 名（aggregate identityName）。**create UC 的 aggId 為 caller-provided**（Phase 1.t.3 / PA-F6，對齊 OC `CreateAuditQuotingInput.quotingId`；非 server-gen UUID）。`<businessFields>` = Input fields 去 aggId + operatorId。

從 `Sources/<A>Aggregate/Entity/<A>.swift` 取 create 用的 init 簽名（Create pattern 需）：Phase 1.t.1 後，當 createdEvent payload 含非-input 衍生欄位時，entity emit 一個 **input-only `package convenience init(id: String, <inputBusinessField>: <T>, ...)`**（非-id 參數 == input business fields）；無衍生欄位時則用 designated `init(id: String, ...)`（簽名亦 == input business fields）。兩者皆可由 `try <A>(id: input.<aggId>, <businessField>: input.<businessField>, ...)` 命中。
從 `Sources/<A>Aggregate/Entity/Commands/<A>+{ucPascal}.swift` 取 `package func {ucCamel}(<arg1>: <T1>, ...) throws` 簽名（Update pattern 需）。

## Phase 4 — Pattern detection（structural-first，prefix 只作 hint）

判定順序：

1. **Delete**：`ucCamel` lowercased prefix `delete` → Delete pattern
2. **Create**：prefix `create` / `establish` **且** `<A>` 有 create init（Phase 1.t.1 input-only `convenience init(id:, ...)`，或無衍生欄位時的 designated `init(id:, ...)`）→ 逐 non-id init param 驗在 input business fields 同名同型 → 全 OK → Create；任一缺 → exit 3：`Create init expects field '<X>' not in input; manual hand-fill required`。**create UC 的 id = caller-provided `input.<aggId>`**（Phase 1.t.3 / PA-F6，create Input 含 aggId）。
3. **Update**（structural，無 prefix gate；audit H2）：`<A>+{ucPascal}.swift` 含 `package func {ucCamel}(` → parse method args label list **依簽名順序**，驗每 label 在 input business fields 集合 → 全 OK → Update；任一缺 → exit 3：`Update method '{ucCamel}' expects arg '<X>' not in input; manual hand-fill required`
4. 都不符（無 init / 無 Command extension）→ exit 3：`pattern not recognized; manual hand-fill required`

## Phase 5 — Emit body（替換 fatalError stub）

`<agg>` = lowerCamel aggregate name；`<A>` = UpperCamel。

### Create pattern

> **id = caller-provided `input.<aggId>`**（Phase 1.t.3 / PA-F6，create Input 含 aggId，對齊 OC）。`<initArgN>` = create init（input-only convenience init 或 designated）的 non-id 參數，逐一由對應 `input.<businessField>` 提供（順序依 init 簽名）。

```swift
        do {
            let <agg> = try <A>(id: input.<aggId>, <initArg1>: input.<initArg1>, <initArg2>: input.<initArg2>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.operatorId)
            return .init(id: input.<aggId>, message: nil)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
```

### Update pattern

```swift
        guard let <agg> = try await repository.find(byId: input.<aggId>) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: <A>.self, aggregateRootId: input.<aggId>)
        }
        do {
            try <agg>.{ucCamel}(<methodArg1>: input.<methodArg1>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.operatorId)
            return .init(id: <agg>.id, message: nil)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
```

`<methodArg>` 等以 Command extension 簽名順序為準（**非** input field 順序）。

### Delete pattern

```swift
        guard let <agg> = try await repository.find(byId: input.<aggId>) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: <A>.self, aggregateRootId: input.<aggId>)
        }
        do {
            try await repository.delete(byId: <agg>.id, userId: input.operatorId)
            return .init(id: <agg>.id)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
```

> **Output shape**：Genesis emit `{UC}Output { id: String?, message: String? }` 兩 field 結構存在。Delete 用 `.init(id:)` 省略 message（struct field 仍 default nil）；Create/Update 顯式 `.init(id:..., message: nil)`。

## Framework constraints（沿用，不可破壞）

- `repository.find(byId:)` / `.save(aggregateRoot:, userId:)` / `.delete(byId:, userId:)` 為 DDDKit Repository
- `DDDError.aggregateNotFound(usecase:, aggregateRootType:, aggregateRootId:)` + `DDDError.executeUsecaseFailed(usecase:, input:, userInfos:)` 為 DDDKit infra
- `ContextError<<A>Error>` 為 Phase 1.f `{Ctx}Shared` infra

## 與其他 skills 的關係

- 上游：`genesis new`（Phase 1.g/1.h codegen scaffold + Phase 1.o unified TODO marker）+ Phase 1.l（Usecase Input 含 aggId + operatorId）+ /api（write-side AS body fill）
- sibling：`/api`（AS body）/ `/presenter-fill`（read AS body）/ `/readmodel-mutation`（projector when() body）
- 第四個 in-place fill skill — 補完 domain 層 orchestration（先前所有 fill 都到 service.execute 為止；本 skill 填 service.execute 真實邏輯）
