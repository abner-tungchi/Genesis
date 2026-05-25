# /usecase skill v1 — fill Usecase extension execute() body (per-UC, 4 OC patterns)

## 來源

討論：`docs/discussions/2026-05-26-usecase-alignment-and-fill-skill.md`

OC ground truth refs：
- Update：`Sources/QuotationAggregate/Usecase/Port/In/EditFontSize/EditFontSizeUsecase.swift`、`AuditQuotingAggregate/.../EditPaidInCapital/EditPaidInCapitalUsecase.swift`
- Create：`Sources/QuotationAggregate/Usecase/Port/In/CreateQuotation/CreateQuotationUsecase.swift`
- Delete：`Sources/QuotationAggregate/Usecase/Port/In/DeleteQuotation/DeleteQuotationUsecase.swift`
- Update + Validator（v1 不支援，defer v2）：`Sources/QuotationAggregate/Usecase/Port/In/EditLetterTitle/EditLetterTitleUsecase.swift`

依賴 Phase：phase-1f / phase-1g / phase-1h / phase-1i / phase-1k / phase-1k.2 / phase-1l（gating, **必須先 done**）/ 2026-05-18-api-skill v6 / 2026-05-23-presenter-fill-skill / 2026-05-25-readmodel-mutation-skill。

## 目標

`/usecase <useCaseName>` 是 `/api`、`/presenter-fill`、`/readmodel-mutation` 之後的**第四個 in-place fill skill**。對 `{UC}Usecase.swift` 內的 `extension {UC}Usecase { execute(input:) async throws -> Output }` body，把 Phase 1.g/1.h 留下的 `fatalError("not implemented")` GENESIS-STUB 替換為實際 domain orchestration logic。依 3 patterns（Create / Update / Delete）對應 UC name prefix + aggregate Command extension grep 推測。

**v1 scope = Create + Update + Delete**（3 patterns）。Update+Validator → exit 3 manual hand-fill（v2 候選，需 validator class 偵測 + 注入機制）。

**前置條件**：Phase 1.l 已 done（Usecase Input 含 aggId + operatorId）—— 否則 body 無法 access `input.<aggId>` / `input.operatorId`。

---

## 介面合約

### Skill invocation

```
/usecase <useCaseName>
```

- `<useCaseName>`：lower-camel UC 名（e.g. `createUserAccessProfile`、`promoteUser`）
- 空 arg → exit 1

### Inputs the skill reads

| Path | Purpose | Required? |
|---|---|---|
| `Sources/<A>Aggregate/Usecase/Port/In/<UC>/<UC>Usecase.swift` | extension default execute() body 所在 | YES |
| `Sources/<A>Aggregate/Usecase/Port/In/<UC>/<UC>Input.swift` | 確認 aggId field name + business fields list（Phase 1.l 後含 aggId + operatorId） | YES |
| `Sources/<A>Aggregate/Usecase/Port/In/<UC>/<UC>Output.swift` | Output struct field（id, message?） | YES |
| `Sources/<A>Aggregate/Entity/<A>.swift` + `Sources/<A>Aggregate/Entity/Commands/<A>+<UC>.swift` | aggregate factory init / domain method signature（grep `try <Agg>(id:` / `package func <ucCamel>(`） | YES (Update/Create 各需其一) |
| `Sources/<A>Aggregate/<A>Error.swift` | catch ladder `ContextError<<A>Error>` branch 用 | OPTIONAL |

### Outputs the skill modifies

| Path | Operation |
|---|---|
| `Sources/<A>Aggregate/Usecase/Port/In/<UC>/<UC>Usecase.swift` | extension default execute() body 替換 `fatalError("not implemented")` 為 OC pattern body |

### Pattern detection heuristic

判定順序（**structural**，prefix 只作 confidence hint 不作 hard gate — audit H2）：

1. **Delete pattern**：UC name lowercased prefix `delete` → delete pattern
2. **Create pattern**：UC name lowercased prefix `create` / `establish` **且** `Entity/<A>.swift` 含 `package init(id: String, ...)`（非 default init） **且** 所有 non-id init params 都對應 input business fields（audit H1 防呆）→ create pattern
3. **Update pattern**（structural，prefix-agnostic）：`Entity/Commands/<A>+<UC>.swift` 存在且含 `package func <ucCamel>(` → update pattern。**不**以 prefix 為 gate（grantPrivilege / promoteUser / revokeRoles 等動詞 都走 Update）。
4. **Update + Validator（defer v2）**：v1 不偵測 validator class；含 validator 的 UC 會走 Update path，但 emit body 缺 `validator.X(...)` 一行 → user 自行補。
5. 不符任一（無 init、無 Command extension）→ exit 3：`pattern not recognized; manual hand-fill required`

### Patterns body emission

各 pattern body（注意 indent 8 spaces 因 extension default method）：

**Create pattern**（無 find）：

```swift
extension <UC>Usecase {
    package func execute(input: Input) async throws -> Output {
        do {
            let <agg> = try <Agg>(id: input.<aggId>, <initArg1>: input.<initArg1>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.operatorId)
            return .init(id: <agg>.id, message: nil)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
```

> **audit H1 — Create init mismatch 防呆**：Genesis `AggregateRenderer` 從 `createdUseCase.eventPayload`（而非 useCase.input）產 `<Agg>(id:, <payload-fields>:) throws` init —— eventPayload 可能比 input 多欄位（e.g. iam-bundle createUserAccessProfile：input={userId,department,jobTitle}, eventPayload={..., permissions, roles, status}）。Create pattern emission **必須**先 parse 真實 `Entity/<A>.swift` 的 `package init(id: String, <param1>: <T1>, ...)` 簽名，逐 param 對 input business fields 配對（同名同型）。**所有** non-id init params 都能 1:1 對應 → 走 Create。**任一缺**（即 init 要的 field 不在 input business fields 中）→ exit 3：`Create init expects field '<X>' not in input; manual hand-fill required`。

**Update pattern**：

```swift
extension <UC>Usecase {
    package func execute(input: Input) async throws -> Output {
        guard let <agg> = try await repository.find(byId: input.<aggId>) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: <Agg>.self, aggregateRootId: input.<aggId>)
        }
        do {
            try <agg>.<ucCamel>(<methodArg1>: input.<methodArg1>, ...)
            try await repository.save(aggregateRoot: <agg>, userId: input.operatorId)
            return .init(id: <agg>.id, message: nil)
        } catch let error as ContextError<<A>Error> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
```

> **audit M6 — Update method args 用 signature 順序**：`<methodArg1>: input.<methodArg1>` 等 args **依 Command extension 簽名順序** 而非 input field 順序。Parse `<A>+<UC>.swift` 的 `package func <ucCamel>(<arg1>: <T1>, <arg2>: <T2>, ...) throws` 取 label list，逐 arg 驗 `<argN>` 存在於 input business fields（aggId/operatorId 排除）。任一 missing → exit 3：`Update method '<ucCamel>' expects arg '<X>' not in input; manual hand-fill required`。

**Delete pattern**：

```swift
extension <UC>Usecase {
    package func execute(input: Input) async throws -> Output {
        guard let <agg> = try await repository.find(byId: input.<aggId>) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: <Agg>.self, aggregateRootId: input.<aggId>)
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
    }
}
```

> **audit M3**：Delete pattern 補 `ContextError<<A>Error>` catch branch（與 Create / Update 統一 catch ladder，多 catch 一個無害 case 也 compile pass）。

> `<agg>` 是 aggregate name lowerCamel（e.g. `userAccessProfile`）。
> **Output shape（audit L7）**：Genesis `UsecaseOutput.swift.template` 一律 emit `let id: String?` + `let message: String?`（兩 field 結構性存在所有 UC）。Delete 用 `.init(id: <agg>.id)`（init 省略 message 參數，但 struct field 仍存在 default nil）；Create/Update 顯式 `.init(id: <agg>.id, message: nil)`。
> `<agg>.id` — aggregate identityName 是 `id` property（per Phase 1.e `package let id: String`）。

### Idempotent structural invariant

整個 extension body block 內：

| 狀態 | 判定 | 動作 |
|---|---|---|
| 已填 | 含 `repository.find` 或 `try <Agg>(id:`（Create）+ `repository.save` 或 `repository.delete`，且**無** `fatalError("not implemented")` | exit 0 skip |
| 未填 | 含 `fatalError("not implemented")` 且含 `// GENESIS-STUB:` 註解 | 套 pattern fill |
| 半填 | 兩者皆非 | exit 4：`partial fill detected in <UC>Usecase; manual repair needed` |

### Exit codes

- `0`: success / already filled
- `1`: prerequisite missing — `<UC>Usecase.swift` / `<UC>Input.swift` / `<UC>Output.swift` 缺、或 arg 空
- `2`: out-of-scope — read UC (`get` / `list` / `find` prefix) → exit + hint「read UC 由 /presenter-fill 處理」
- `3`: pattern not recognized — UC name 不符 Create/Update/Delete prefix、或 aggregate 缺對應 Command extension / factory init / Update+Validator 等複雜 case → manual
- `4`: corrupted / half-filled / Usecase body shape 異常

### Framework constraints

- `repository.find(byId:)` / `.save(aggregateRoot:, userId:)` / `.delete(byId:, userId:)` 為 DDDKit Repository API（gradyzhuo/swift-ddd-kit）
- `DDDError.aggregateNotFound(usecase:, aggregateRootType:, aggregateRootId:)` + `DDDError.executeUsecaseFailed(usecase:, input:, userInfos:)` 為 DDDKit 提供
- `ContextError<<A>Error>` 為 Phase 1.f ContextShared infra

---

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md` | **覆寫**既有 placeholder（≤200 LoC） |
| `Tests/GenesisCoreTests/SkillInstallerTests.swift` | skill count 9 → 10、expected list 加 `usecase` |
| `docs/decisions.md` | /usecase skill v1 ratification |
| `docs/architecture.md` | §10.17 /usecase fill flow |
| `docs/tasks/registry/2026-05-26-usecase-skill.json` | **新檔** |

---

## 實作步驟

### Step 1 — SKILL.md

frontmatter `name: usecase` / `disable-model-invocation: true` / `allowed-tools: Read, Edit, Glob, Grep` / `argument-hint: [useCaseName]`。

5-Phase flow（與其他 fill skill 對稱）：

```
Phase 0: arg parse (空 → exit 1; read-UC prefix → exit 2)
Phase 1: locate {UC}Usecase.swift (Glob Sources/*Aggregate/Usecase/Port/In/{ucPascal}/)
         0/≥2 match → exit 1/4
Phase 2: idempotent structural invariant
         已填 → exit 0；半填 → exit 4；未填（含 GENESIS-STUB） → 續
Phase 3: parse Input + Output + Command extension
         → 推 aggId field name + business field list + {ucCamel} method args
Phase 4: pattern detection (Delete / Create / Update prefix 規則)
         無對應 → exit 3
Phase 5: emit OC pattern body (含 catch ladder)
```

### Step 2 — Pattern emission rules

per pattern emit 上述 body template，每個 placeholder 依 parse 結果 substitute。

### Step 3 — Tests + SkillInstallerTests bump 9 → 10

### Step 4 — Real E2E

依賴 Phase 1.l 已 done，iam-bundle regenerate 後：

1. `/usecase createUserAccessProfile` → Create pattern → emit body
2. `/usecase promoteUser` → Update pattern
3. （若有 Delete UC）→ Delete pattern
4. `swift build` → Build complete（Usecase body 真實 wire repository + aggregate）

### Step 5 — Docs

decisions.md ratification + architecture.md §10.17。

---

## 失敗路徑

| 場景 | exit | hint |
|---|---|---|
| arg 空 | 1 | `usage: /usecase <useCaseName>` |
| {UC}Usecase.swift 缺 | 1 | prerequisite missing |
| read UC prefix（get/list/find） | 2 | read-side 由 /presenter-fill 處理 |
| 同名 UC ≥2 modules | 4 | ambiguous |
| UC name 不符 Create/Update/Delete prefix | 3 | pattern not recognized; manual |
| Aggregate factory init / Command extension 缺 | 3 | required <Agg> method not found |
| 半填 | 4 | partial fill detected |
| idempotent re-run | 0 | nothing to do |

---

## 不改動的部分

- 不動 Usecase Input / Output struct（Phase 1.l 已注入 aggId+operatorId）
- 不動 Service struct（空殼 wrapper）
- 不動 Aggregate Entity / Command extension
- 不動 read-side（/presenter-fill / /readmodel-mutation 範疇）
- 不寫 openapi.yaml / event.yaml / Package.swift / 任何 *.yaml / bundle JSON

### Non-goals（行為層）

- 本 task **不包含** Update+Validator pattern（v2 候選，需 validator class detection + injection）
- 本 task **不包含** 跨 aggregate transactional UC（OC 罕見）
- 本 task **不包含** 自動推 aggregate method args（依賴 Command extension grep；不符 → exit 3）
- 本 task **不包含** custom factory init pattern（v1 假設 `try <Agg>(id:, <fields>:) throws`）
- 本 task **不 bump 版本**

---

## 驗收標準

### Agent 必做

```bash
S=~/.claude/skills/usecase/SKILL.md
B=Sources/GenesisCore/Resources/Templates/skills/usecase/SKILL.md

# A1. LoC + phase count
test -f "$S"
[ $(wc -l < "$S") -le 200 ]
[ $(grep -cE '^## (Phase [0-5]|Step [0-5]|步驟 [0-5])' "$S") -ge 5 ]

# A2. 3 patterns 明示
grep -F 'Create pattern' "$S"
grep -F 'Update pattern' "$S"
grep -F 'Delete pattern' "$S"

# A3. 關鍵 OC token
grep -F 'repository.find(byId:' "$S"
grep -F 'repository.save(aggregateRoot:' "$S"
grep -F 'DDDError.aggregateNotFound' "$S"
grep -F 'DDDError.executeUsecaseFailed' "$S"
grep -F 'ContextError<' "$S"

# A4. 不動範圍
grep -F '不動 Aggregate' "$S"
grep -F '不寫 openapi.yaml' "$S"

# A5. exit codes
grep -F 'exit 1' "$S"
grep -F 'exit 2' "$S"
grep -F 'exit 3' "$S"
grep -F 'exit 4' "$S"

# A6. mirror byte-identical
diff "$S" "$B"

# A7. SkillInstallerTests count 9→10
grep -F 'usecase' Tests/GenesisCoreTests/SkillInstallerTests.swift
swift build
swift test --filter SkillInstallerTests

# A8. install regression
mkdir -p /tmp/uc-install-test
./.build/debug/genesis install-skills --scope project --project-dir /tmp/uc-install-test --force
test -f /tmp/uc-install-test/.claude/skills/usecase/SKILL.md

# A9. docs
grep -F '/usecase skill' docs/decisions.md
grep -F '/usecase' docs/architecture.md
```

### Human 補做

- [ ] Phase 1.l done 後 iam-bundle regenerate → /api v6 填 + /usecase 填 createUserAccessProfile → swift build PASS
- [ ] Update UC（promoteUser）跑 /usecase → 確認 emit Update pattern + catch ladder
- [ ] Read UC（getX）跑 /usecase → exit 2
- [ ] 偽造 Aggregate 缺 Command extension → /usecase 跑 Update → exit 3

---

## 已知限制

1. **v1 = 3 patterns only**：Update+Validator 在 v2（需 validator class 偵測+注入機制）
2. **Aggregate factory init 慣例**：Create pattern 假設 `try <Agg>(id: String, <fields>:) throws`，custom factory 需 manual
3. **Aggregate method arg 直接 1:1 mapping**：Update pattern 假設 Command extension 簽名為 `func <ucCamel>(<field>: <Type>, ...) throws`，且 args 名稱與 Input field 名稱完全一致
4. **Output shape 假設**：`{UC}Output` 含 `id` field（Create/Update/Delete）+ optional `message: String?`（Create/Update has；Delete 無）—— 與 Phase 1.h Output renderer 預設一致
5. **catch ladder 一律 emit `ContextError<<A>Error>`**：即使 aggregate.<method> 不 throw 也無害
6. **不偵測 cross-aggregate transactional logic**（OC 罕見 case）
7. **不 retro-upgrade**：既有 v1 stub 已被 user 手填的 body 不會被覆寫（idempotent skip）
8. **不 bump 版本**
9. **依賴關係**：phase-1l（gating，必須先 done）+ phase-1f/1g/1h/1i/1k/1k.2 + 2026-05-18-api-skill v6 + presenter-fill / readmodel-mutation skills（全 done）

## Audit findings resolution (Codex external 2026-05-26)

| ID | 嚴重 | 問題 | 修法 |
|---|---|---|---|
| H1 | 高 | Create pattern 假設 `<Agg>(id:, <UC-input>:)`，但 Genesis aggregate init params 來自 eventPayload（可能多於 input）→ 直接 emit 會缺 args compile fail | 解析真實 `init(id:, ...)` 簽名 + 逐 non-id param 對 input business fields 配對；任一缺 → exit 3 |
| H2 | 高 | Update 用 prefix gate（Edit/Set/Rename/Add/Remove）會誤拒 `grantPrivilege`/`promoteUser`/`revokeRoles` | Update 改 **structural detection**：只要 Command extension `<A>+<UC>.swift` 含 `package func <ucCamel>(` 即 Update，prefix 只作 hint |
| M3 | 中 | Delete pattern 缺 `ContextError<<A>Error>` catch（與 Create/Update 不對稱） | Delete 補 ContextError catch branch |
| M6 | 中 | Update method args 用 input 順序而非 signature 順序，且未驗 label 存在 | parse Command method signature 取 label list 按順序 emit；任一 label 不在 input → exit 3 |
| L7 | 低 | Output shape 文字錯：Delete 「無 message field」誤導（field 仍存在 default nil） | reword：「Delete 用 `.init(id:)` 省略 message 參數，但 struct field 仍存在 default nil」 |

（M4+M5 在 Phase 1.l spec 修）

## Sign-off

- [x] write-spec output reviewed
- [x] **audit-spec pass — Codex external 2026-05-26**：2H+4M+1L 跨兩 spec 全套修（本 spec 對應 H1+H2+M3+M6+L7）。
- [x] Phase 1.l prerequisite done
- [x] decisions.md ratification + architecture.md §10.17
- [x] registry status: ready → **done**（SKILL.md 139 行 ≤200 + 14/14 mechanical gate PASS + 212/212 全 test suite PASS + real E2E swift build PASS：iam-bundle 重生（Usecase Input 含 aggId+operatorId + Usecase.swift 含 IAMContextShared import）→ 填 PromoteUserUsecase Update pattern → PromoteUserUsecase.swift.o compiled with `repository.find/save` + `try userAccessProfile.promoteUser(...)` + 完整 catch ladder）
