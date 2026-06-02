# Phase 1.u — command precondition scaffold + `#error` domain holes

## 來源

討論：`docs/discussions/2026-06-02-domain-scaffold-emitter.md`（R2 consensus，三方）。本 task 實作 ADD-清單的 **C1 + C2 + A1**（scaffold-emitter 第一批，codegen 本地化）。A2（read-side Dto-convert）/ A5（intent-elicitation domain-fill skill）/ A4（error enum generic cases）/ rich-nested when 為後續 phase。

## 目標

把 `genesis new` 生成的 write-side domain 層從「`fatalError` 佔位（runtime 才炸、能 silent compile-pass）」升級為 **scaffold-emitter**：
- **C1 + A1**：command method body emit「bundle precondition 註解 scaffold + build-event frame 註解 + `#error` 編譯期洞」（取代 `fatalError("not implemented")`）。bundle 的 `useCase.preconditions` 機械帶進 scaffold（user 明確要求 pre/post-condition 從 bundle 來）。
- **C2**：非-strict-safe `when(event:)` reducer 從 `fatalError("GENESIS-TODO...")` 改 `#error` 編譯期洞 + structure 註解。

核心安全約束（discussion D2，已 spot-verify）：未填 DOMAIN 洞 = **`#error("GENESIS-TODO: ...")`**，編譯期斷，非 runtime fatalError。等同 test-gen `.disabled` 的 domain-code 版 —— 半填的 domain 不能 silent compile-pass。

`#error` 機制（probe 實證 + Codex 確認，narrow 到實際生成 shape）：生成的 command/when 都是 **`throws` / `Void`** body（非 `-> T`）;`#error` 在 `extension X { func f() throws { #error("...") } }` 內合法，emit 精準診斷。probe 用 2 個 `#error` 同檔 typecheck → **兩者皆 surface**（多重性成立，非只第一個）。`#error` 是 parse-time diagnostic，不影響 `swift package resolve`（spec 假設 resolve 綠、只 `swift build` 失敗）—— resolve 不 typecheck source。impl pickup 時可再 probe 確認 toolchain 行為。

**設計脈絡（discussion D9）**：「人填洞」= 人說意圖 → LLM 寫（intent-driven）。`#error` 是 LLM filler 的完成合約（grep `#error` → 填 → build 綠 = 填完）；scaffold + bundle precondition 註解 = LLM filler 的 prompt context。本 phase 只產 scaffold + 洞；填洞由人/A5 skill（後續）做。

## 介面合約（Interface Contract）

### C1 + A1 — command method scaffold（`CommandExtension.swift.template` + `UseCaseRenderer`）

`CommandExtension.swift.template` 的 command method body：

```swift
extension {Aggregate} {
    package func {useCaseCamelCase}({CommandParams}) throws {
{PreconditionScaffold}
        // Build {EventTypeName} from the args above (+ self.id), then apply it:
        //   let event = {EventTypeName}(<map command args>)
        //   try self.apply(event: event)
        // Post-conditions are enforced by ensureInvariant() (DDDKit runs it pre+post every apply) — do NOT add post-checks here.
        #error("GENESIS-TODO: {useCaseCamelCase} — implement precondition guard(s) + build & apply {EventTypeName}")
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches {EventTypeName}.
    package func when(event: {EventTypeName}) throws {
{WhenBody}
    }
}
```

`{PreconditionScaffold}`（`UseCaseRenderer.renderCommandExtension` 從 `useCase.preconditions` 算，新增該參數）：
- preconditions 非空：每條一行 `        // PRECONDITION (from bundle): <NL precondition>`，後接一行 `        // DOMAIN: implement the guard(s) above; throw the matching ContextError<{Aggregate}Error> case.`
- preconditions 空：`        // PRECONDITION (from bundle): none declared.`
- **errorCode 不自動接**（discussion D5 + Codex LOW #3）：precondition NL → ContextError case 是語意非結構對應;且生成的 `ContextError` factory（`AggregateRenderer.renderError`）**只從 aggregate invariants 生**，precondition 對應的 case 可能根本不存在 → 自動接會 invent/猜錯 case。scaffold 只放 NL 註解 + DOMAIN marker，case 由人/LLM 選。

### C2 — non-strict-safe `when` reducer（`UseCaseRenderer.buildWhenBody`）

`buildWhenBody` **維持現「strict-safe → assigns / 否則 X」兩分支結構**，只把 X 從 `fatalError` 換 `#error` + structure 註解：
1. **strict-safe scalar**（payload 非空、全欄位同名同型非集合非 new/old）→ emit `self.<f> = event.<f>`（**不變**，1.t D5 保留）。
2. **其餘**（含 **payload 為空**、type-mismatch、集合、new/old rename、nested）→ emit structure 註解 + `#error`：
```swift
        // {EventTypeName} state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // DOMAIN: assign the relevant self.<field> from event.<field> (with any needed conversion / collection op).
        #error("GENESIS-TODO: implement when({EventTypeName}) state transition")
```
（rich nested config-replace 結構推斷 = discussion D7 defer，本 phase 只到 structure 註解 + `#error`。）

> **Codex audit HIGH**：**不**把 empty-payload 當 clean no-op —— buildWhenBody 無事件語意知識，零 payload 事件仍可能需 deterministic state change（設 status flag / 清空集合 / 標 inactive）。維持現 `allStrictSafe = !payloadFields.isEmpty`（空 payload → 非 strict-safe → `#error` fail-loud），不引入 silent no-op。

### ensureInvariant honest-hole（Codex audit MED #5b：本 phase 一起做，不 defer）

**改動**：`ensureInvariant()` body 改為 **conditional**：
- aggregate **有** bundle 宣告 invariant（且未實作）→ emit invariant 註解 obligation（1.t D4 既有）+ **`#error("GENESIS-TODO: implement ensureInvariant (<N> declared invariants)")`**。
- aggregate **無** invariant → 維持 **empty no-op**（無洞;無宣告 invariant 的 aggregate 合法地不檢查）。

**為何不違反 discussion C4/D4 lock**：D4「ensureInvariant 保持 runnable no-op、不 default throw/fatalError」拒的是 **runtime throw/fatalError**（因 DDDKit `apply()` pre+post 跑它 → runtime throw 會炸所有 apply）。`#error` 是 **編譯期** directive，**不在 runtime 執行** → 不觸發 pre+post 問題（填完才編譯、編譯後 runtime 行為與 D4 同）。故 D4 的技術理由對 `#error` 不適用;D4 當時未考慮 `#error`（D2 本討論才引入）。把 ensureInvariant 納入 = 消除本 phase 唯一剩的 silent 洞（有宣告 invariant 卻 no-op 編譯過），與 honest-hole 一致。

### 不變
- create UC 不生 command extension（1.t.3 / D6）。
- scalar when codegen-fill（1.t D5）。
- 無 invariant 的 aggregate 的 ensureInvariant = empty no-op。
- `/usecase` execute body 的 `fatalError("TODO(/usecase skill)")`（Phase 1.o，不同檔不同層）。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/CommandExtension.swift.template` | command body：`// GENESIS-STUB...` + `fatalError("not implemented")` → `{PreconditionScaffold}` + build-event 註解 frame + post-condition 註解 + `#error` |
| `Sources/GenesisCore/UseCaseRenderer.swift` | `renderCommandExtension` 新增 `preconditions: [String]` 參數 + 算 `{PreconditionScaffold}`；`render` 傳 `useCase.preconditions`；`buildWhenBody` 三分支（scalar / empty-payload no-op / `#error`）|
| `Tests/GenesisCoreTests/UseCaseRendererTests.swift` | 3 處 assert 從 `fatalError("GENESIS-TODO: implement state transition...")` → `#error("GENESIS-TODO: implement when(...)...")`；加 precondition scaffold 測（有 preconditions → command body 含 `// PRECONDITION (from bundle): <NL>`；無 → `none declared`）+ command body 含 `#error` 不含 `fatalError("not implemented")` |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | `testEndToEndSwiftPackageResolveAndBuild`（env-gated）：改 assert exit code 2 + stderr 含 `swift build failed` + 含 `GENESIS-TODO` + **不**含 `swift package resolve failed`（Codex MED：`genesis new` 把 build 失敗包成 `✗ swift build failed (last 40 lines)`，stderr 必含 error:/file:line，故「僅含 GENESIS-TODO」不可靠;改驗「resolve 過、build 因 GENESIS-TODO 失敗」的契約）|
| `Sources/GenesisCore/Resources/Templates/v0.1/CLAUDE.md.template` | （Codex MED）描述 stub 的句子 `fatalError("not implemented")` → `#error("GENESIS-TODO: ...")`（generated project 的 onboarding 說明同步）|
| `Sources/GenesisCore/Resources/Templates/v0.1/Aggregate.swift.template` + `AggregateRenderer.renderAggregate` | （Codex MED #5b，見下 ensureInvariant 段）ensureInvariant 有宣告 invariant → `#error`;無 → no-op |

### 受影響但不需改
- NewCommandTests:288（`ucContent` = Usecase execute 檔，非 command extension）— 不受影響。
- `--skip-build` 整合測試 — 只 resolve 不 typecheck，`#error` 不觸發。
- impl 時 grep 確認無其他測試 assert command-body 含 `fatalError("not implemented")`。

## 實作步驟

### Step 1：CommandExtension.swift.template command body
1. command body 改成介面合約所列（`{PreconditionScaffold}` placeholder + build-event 註解 + post-condition 提示 + `#error("GENESIS-TODO: {useCaseCamelCase} ...")`）。when body 仍 `{WhenBody}`。

### Step 2：UseCaseRenderer renderCommandExtension + 算 PreconditionScaffold
1. `render`：`renderCommandExtension(...)` 呼叫加 `preconditions: useCase.preconditions`。
2. `renderCommandExtension` 簽名加 `preconditions: [String]`。
3. 算 `preconditionScaffold`：空 → `"        // PRECONDITION (from bundle): none declared."`；非空 → 每條 `"        // PRECONDITION (from bundle): \(p)"` join + 尾行 DOMAIN marker。
4. template vars 加 `PreconditionScaffold` + `useCaseCamelCase`（emit `#error` 訊息需 ucCamel，已有）。

### Step 3：buildWhenBody（兩分支，只換 fatalError → #error）
1. 維持 `allStrictSafe = !payloadFields.isEmpty` + 逐 payload 檢查（不動判定邏輯）。
2. 全 strict-safe → assigns（不變）。
3. 否則（含空 payload）→ structure 註解 + `#error("GENESIS-TODO: implement when(\(eventTypeName)) state transition")`（取代現 fatalError 字串）。**不**加 empty-payload no-op 分支（Codex HIGH：空 payload 仍可能需 mutate，維持 fail-loud）。

### Step 3b：ensureInvariant conditional `#error`（Codex MED #5b）
1. `AggregateRenderer.renderAggregate`：已算 `invariantObligations`。新增:`invariants` 非空 → ensureInvariant body = obligations 註解 + `#error("GENESIS-TODO: implement ensureInvariant (\(spec.invariants.count) declared invariants)")`;空 → 維持現 no-op 註解（無 `#error`）。
2. `Aggregate.swift.template`：ensureInvariant body 改用 `{EnsureInvariantBody}` 單一 placeholder（renderAggregate 組好 conditional 內容），取代現寫死的註解 + NOTE。

### Step 3c：CLAUDE.md.template（Codex MED #5a）
1. 描述 stub 的 `fatalError("not implemented")` → `#error("GENESIS-TODO: ...")`。

### Step 4：測試
1. `UseCaseRendererTests`：(a) 3 處 `fatalError(...state transition...)` → `#error(...when(...)...)`；(b) 加測：有 preconditions 的 UC → command body 含 `// PRECONDITION (from bundle): <NL>` + `#error`；無 preconditions → `none declared`；(c) command body 含 `#error` 不含 `fatalError("not implemented")`。
2. `NewCommandTests.testEndToEndSwiftPackageResolveAndBuild`：改 assert exit 2 + stderr 含 `swift build failed` + 含 `GENESIS-TODO` + 不含 `swift package resolve failed`。
3. `AggregateRendererTests`：加測 ensureInvariant —— 有 invariant aggregate → ensureInvariant body 含 `#error`;無 invariant fixture（如 minimal-bundle 若無 invariant）→ 無 `#error`（驗 conditional）。

### Step 5：build + test + regen 驗證（見驗收）

## 失敗路徑

| 條件 | 行為 |
|---|---|
| fresh gen `swift build`（domain 未填）| **編譯失敗，surface 一或多個 `GENESIS-TODO` `#error` 診斷**（probe 證多重性;intended honest signal 非 bug）。填完所有洞才 build 綠 |
| precondition NL 含特殊字元（換行/引號）| renderCommandExtension sanitize 單行化（同 1.t invariant 註解處理）|
| UC 無 preconditions | scaffold = `none declared`（不留空洞，command body 仍有 build-event frame + `#error`）|
| event payload 空 | when → `#error`（fail-loud，非 no-op;Codex HIGH）|
| aggregate 無 invariant | ensureInvariant = empty no-op（無 `#error`）|

## 不改動的部分
- scalar when codegen-fill（1.t D5）/ create command skip（1.t.3 D6）/ create convenience init（1.t.1）。
- 無 invariant aggregate 的 ensureInvariant = empty no-op。
- `/usecase` `/api` `/readmodel-mutation` `/test-gen` SKILL.md。
- DDDKit / bundle schema（用既有 `useCase.preconditions` 欄位，不改 schema）。

### Non-goals（行為層）
- **不** auto-fill command precondition predicate / errorCode（人/LLM 填；errorCode 不自動接，D5）。
- **不**做 rich nested when 結構推斷（config-replace guard→removeAll→append；D7 defer）。
- **不**建 intent-elicitation domain-fill skill（A5，後續 phase）。
- **不**做 read-side Dto-convert（A2，後續）。
- **不**保證 fresh gen build green（與 capstone 前狀態相反 —— 見已知限制）。
- ensureInvariant 的 `#error` 僅「有宣告 invariant」時;**不**自動填 invariant check 邏輯（人/LLM）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -3          # Genesis 本身編譯
swift test 2>&1 | tail -5           # 全 pass（含更新後 UseCaseRendererTests）

# regen IAM（--skip-build：codegen 本身不跑 build）
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1

# C1+A1：promoteUser command body — precondition scaffold + #error，無 fatalError("not implemented")
PROMO="$TMP/Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+PromoteUser.swift"
grep -q '// PRECONDITION (from bundle): status == Active' "$PROMO"
grep -q '#error("GENESIS-TODO: promoteUser' "$PROMO"
! grep -q 'fatalError("not implemented")' "$PROMO"

# C2：promoteUser when（newJobTitle 非 strict-safe）→ #error，非 fatalError
grep -q '#error("GENESIS-TODO: implement when(UserPromoted)' "$PROMO"
! grep -q 'fatalError("GENESIS-TODO: implement state transition' "$PROMO"

# ensureInvariant（UserAccessProfile 有 3 invariant）→ #error（Codex MED #5b）
ENT="$TMP/Sources/UserAccessProfileAggregate/Entity/UserAccessProfile.swift"
grep -q '#error("GENESIS-TODO: implement ensureInvariant' "$ENT"

# fresh gen 不再 build green（honest signal）：build 失敗且只因 #error
( cd "$TMP" && swift build 2>&1 | grep -q 'GENESIS-TODO' ) && echo "fresh gen blocked by #error holes (intended) OK"
rm -rf "$TMP"

# create UC 無 command extension（D6 不變）
TMP2=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP2" --skip-build --no-git 2>&1 | tail -1
test ! -f "$TMP2"/Sources/UserAccessProfileAggregate/Entity/Commands/UserAccessProfile+CreateUserAccessProfile.swift
rm -rf "$TMP2"
```

> 註：fresh-gen `swift build` 需網路抓 DDDKit + plugin（CI 視情況）；最低限度上述 grep + UseCaseRendererTests 涵蓋 scaffold/`#error` 形狀。env-gated `testEndToEndSwiftPackageResolveAndBuild` 跑真 build 驗 resolve 綠 + build 因 `#error` 失敗。

### Human 補做
- [ ] regen IAM，對某 UC 用人/LLM 說 domain 邏輯填掉 command + when 的 `#error`，確認填完後 `swift build` 綠（驗 scaffold 引導 + `#error` 合約閉環）。
- [ ] 確認 `#error` 編譯訊息對「人說意圖→LLM 寫」流程是好 context（greppable、precondition 註解在旁）。
- [ ] 確認生成專案 onboarding（CLAUDE.md）描述與新 `#error` 行為一致。

## 已知限制
- **fresh gen 不再 build green（capstone reversal，intended）**：domain 洞（command / when / ensureInvariant-with-invariants）用 `#error` → 生成專案在 domain 填完前無法編譯。honest signal（domain 未填的 aggregate 本不該 ship/run），反轉 Phase 1.t.2 capstone 的「fresh gen swift build EXIT 0」性質。fill 流程：gen → fill skills（機械）→ 人/LLM 填 domain 洞 → build 綠。
- **errorCode 不自動接**：precondition scaffold 只放 NL 註解，case 由人/LLM 選（生成 enum 只含 invariant errorCodes）。
- **rich nested when 未生結構**：config-replace 等只到 structure 註解 + `#error`，guard→removeAll→append 骨架 defer（D7）。
- **無 invariant aggregate 的 ensureInvariant 仍 empty no-op**：合法（無宣告 invariant 不檢查）;非 silent 洞。

### 依賴關係
- 軟相依（done）：Phase 1.t（D4/D5）、1.t.1（convenience init）、1.t.3（D6 create skip）。
- supersede：`2026-06-02-when-reducer-fill-skill.md` 窄結論（其餘 bare fatalError → 本 phase guided scaffold + `#error`）。
- 後續：A2（Dto-convert）、A5（intent-elicitation domain-fill skill）。
