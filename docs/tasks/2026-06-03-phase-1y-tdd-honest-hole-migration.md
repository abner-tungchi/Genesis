# Phase 1.y — TDD honest-hole migration（#error → GenesisTODO throw-marker + genesis verify）

## 來源

討論：`docs/discussions/2026-06-03-tdd-first-honest-hole.md`（R2 consensus，adversarial workflow 3-lens + 2 載重事實 Claude 親驗）。**ATOMIC migration**：反轉 Phase 1.u（#error）+ Phase 1.u.1（BuildFailureClassifier）+ 重寫 test-gen + 新增 `genesis verify`。test-gen rewrite 與 genesis verify 是**同 PR 硬前置**（否則 no-op ensureInvariant silent fake-green，比 #error 更糟）。

## 目標

user 確認純 TDD（test-first，逐 usecase）。`#error` 是編譯期 build-gate、unconditional all-or-nothing → 一個洞沒填整專案編不過、`swift test` 0 test → **消滅增量 TDD red-green**。改成：**domain 洞 = 會編譯、跑了丟 `GenesisTODO.notImplemented` 的 throw-marker**（fresh gen 編得過、test 跑得起來、紅在對的 test）。honest-hole 信號從 build-gate **刻意換成 test-gate（test 紅）+ release-gate（`genesis verify`）** —— 換取 TDD，代價是 enforcement 從「編譯器無條件」變 conditional（test 要存在+正確+有跑）。

**兩載重事實（Claude 親驗，spec 依賴）**：
1. Swift Testing `#expect(throws: ContextError<<A>Error>.self)` 收到 `GenesisTODO` → **乾淨紅**（`expected error of type ContextError<...>, but notImplemented(...) of type GenesisTODO was thrown instead`;value-capture `e?.error` 為 nil 也紅）。correct-type 綠。**前提：marker 型別要活到 test**。
2. Phase 1.x 的 execute catch-ladder 末支 `catch { throw DDDError.executeUsecaseFailed(...) }` 會**吞掉 GenesisTODO 包成 DDDError** → 必須在 catch-all 前插 `catch let error as GenesisTODO { throw error }`（載重 fix，否則 marker 型別死在 usecase 邊界）。

## 介面合約（Interface Contract）

### 洞表示（per-hole，依在 apply() 路徑上的位置 + catch-ladder 邊界）

DDDKit `apply(event:)`：`ensureInvariant()[pre] → when(happened:) → ensureInvariant()[post] → add`。ensureInvariant 每次 apply 前後跑。

| 洞 | Phase 1.u/1.t 現狀 | 1.y 改成 | 理由 |
|---|---|---|---|
| **ensureInvariant**（有 declared invariant）| `#error` | **no-op + invariant 註解 obligation**（revert Phase 1.t D4）| 每次 apply 跑;throw → createX fixture seed 即失敗 → 全 aggregate test 紅在 seed 而非 assertion。**強制 no-op**。invariant 的紅由「戳該 invariant 的 test」給 |
| **command body** | `#error` | `throw GenesisTODO.notImplemented("<ucCamel>")`（command 是 `throws`）| 在 usecase-call/When 跑,非 replay;throw 只紅呼叫它的 test |
| **非-strict-safe when** | `#error` | `throw GenesisTODO.notImplemented("when(<Event>)")` | 在 apply(E) 跑;紅「測該 UC 的 test」+ 連帶紅「用 E 當 Given 的 test」（TDD bottom-up 可接受）|
| **create convenience init**（derived field）| `fatalError`（1.t.1）| `throw GenesisTODO.notImplemented("<A>.init derive [...]")`（init 已 `throws`）| fatalError **crash 整個 test process**(殺整 suite);throw 只紅一個 test。**reclassified seed-path 洞**（紅 create-fixture-dependent test = 誠實的 derivation-unimplemented 信號，不宣稱「只影響自己」）|

### GenesisTODO marker 型別（per-aggregate 檔，NOT {Context}Shared）

emit 到 **aggregate target**（如 `Sources/<A>Aggregate/Entity/<A>GenesisTODO.swift`，或併入 `<A>Error.swift`），**不放 {Context}Shared** —— 因 `{SharedImport}` 是條件式（只在有 DTO/customType 時 emit），no-DTO bundle 的 aggregate 沒 import → 放 Shared 會「找不到型別 → 編不過 → 0 test」（正是要殺的失敗）。

```swift
package enum GenesisTODO: Error, Sendable {
    case notImplemented(String)
}
```
（`Sendable` 因跨 async usecase 邊界 throw。per-aggregate 檔 → aggregate 內 command/when/ensureInvariant/init 直接可見，免 cross-import。）

### Transparent channel（載重 fix）

`UseCaseRenderer.buildExecuteBody` 有**單一共用** `catchLadder` 字串(create/delete/update 三分支共用)。在最終 `} catch {`（`throw DDDError.executeUsecaseFailed`）**之前**、與既有 `} catch let error as DDDError {` **同 16-space 縮排**插入：
```
} catch let error as GenesisTODO {
    throw error
```
讓 command/when 丟的 GenesisTODO **型別活著穿過 usecase 邊界到 test**（否則被包成 DDDError → test 收到 wrong-type 但無法辨識）。**一次插入即覆蓋三分支**（共用字串）—— 勿補三處。

### genesis verify（新 CLI subcommand）— 非循環 backstop

`genesis verify`（在 generated project root 跑）：
1. **marker 殘留檢查**：grep `GenesisTODO.notImplemented` 於 `Sources/`；有 → 報「N domain holes remain（未填）」+ 列位置。
2. **invariant-test 存在檢查（破循環核心）**：對每個 declared invariant errorCode，斷言 `Tests/` 有 ≥1 個 **enabled（非 `.disabled`）** test 引用它;無 → fail「invariant <code> 無 enabled test」。
   - **errorCode 來源（audit HIGH：bundle 不在生成樹內）**：bundle JSON **不被 `genesis new` 複製進生成專案**（`.ai/` 只有 .scaffold-manifest.json〔path/sha256/role,無 invariant 資料〕）。→ errorCode 從 **`Sources/<A>Aggregate/<A>Error.swift` 的 enum case** 取（`AggregateRenderer.renderError` 每 invariant emit 一個 `case <errorCode>`,自動排除 no-invariant 的 `case placeholder`）—— 編譯後的 source of truth,不需 bundle。
   - **enabled-test 偵測（audit HIGH：非 line grep,需 comment+disabled-aware）**：對 `Tests/**/*.swift`（**含 `.generated` 與 `.authored` 兩半**）：先 strip line+block comment（test-gen 的 `.generated` 模板把 `#expect(error?.error == .<code>)` 放在 `// ...` 註解裡 → 裸 grep 會假陽性）→ 以 `@Test` 宣告切段 → 每段記 (a) attribute list 是否含 `.disabled`、(b) body 是否引用 `.<errorCode>`（或 `ContextError<<A>Error>.<code>`）→ 斷言 ≥1 段「引用該 code **且** 非 .disabled **且** 非註解」。**殘留風險**（hand-rolled string-built code 規避偵測）明文承認,比照 BuildFailureClassifier 的 spoofing 立場。
   - 這是 no-op ensureInvariant 的 honesty backstop：**不靠 test-gen 合成 invariant-tripping state（它合成不出）,只查「enabled test 存在」這個結構事實**。
3. exit code：全過 → 0;有殘留 marker 或 invariant 缺 test → 非 0（供 CI required-check / pre-release gate）。

**預設接線（開放#1）**：CLI subcommand + user 接 CI required-check（advisory 形式 ship，wiring 由 user CI 決定）。

### test-gen TDD rewrite（HARD same-change 前置）

deployed `test-gen/SKILL.md` 改：
- **enabled 紅 test lane（backstop）**：每 §3 invariant / §5 error 產**一個 enabled**（非 `.disabled`）test，用 `#expect(throws: ContextError<<A>Error>.self){...}; #expect(error?.error == .<code>)` → 對 GenesisTODO 紅,實作後綠。
- **窄 disabled lane**：只留「Given 需人補、test-gen 無法合成的 multi-step prerequisite chain」→ `.disabled` + honest「blocked: prerequisite <cmd> unfilled」（避免 confusing collateral-red）。
- **typed-thunk 存活但改丟 GenesisTODO**：arrange-placeholder `let input: <UC>Input = { /* GENESIS-TODO */ throw GenesisTODO.notImplemented(...) }()` —— **絕不 fatalError**（enabled test 跑到 fatalError crash 整 suite）。type-complete 讓部分填的 test 仍編譯（Codex Swift 6.2.3 實證 .disabled/enabled body 皆 type-check）。

### 不變
- scalar when codegen-fill（1.t D5）/ create UC 無 command extension（1.t.3 D6）/ execute orchestration codegen（1.x D1）。
- `/usecase` `/api` `/readmodel-mutation` `/presenter-fill` `/domain-fill` 的**填洞職責**（只是 domain-fill 的 grep target 改，見下）。
- DDDKit / bundle schema / 真 KurrentDB test 模型。

## 改動檔案

| 檔案 | 改動 | 步 |
|---|---|---|
| `AggregateRenderer.swift` | 新增 GenesisTODO per-aggregate 檔 render（role + manifest entry + scaffold-once）;ensureInvariant `#error` → no-op + 註解;create init fatalError → GenesisTODO throw | 1,3,4 |
| `UseCaseRenderer.swift` | buildExecuteBody catchLadder 插 `catch let error as GenesisTODO { throw error }`;buildWhenBody 非-strict `#error` → GenesisTODO throw | 2,3 |
| `CommandExtension.swift.template` | command body `#error` → GenesisTODO throw（保留 precondition scaffold 註解 + build-event frame 註解）| 3 |
| `Aggregate.swift.template` | **無變更**（audit:ensureInvariant 的 `#error` 是 `AggregateRenderer` 的 `ensureInvariantBody` 注入,template 只有 `{EnsureInvariantBody}` placeholder;改在 renderer）| — |
| `Sources/Genesis/Commands/VerifyCommand.swift`（新）+ Genesis.swift subcommands | `genesis verify`（marker grep + invariant-enabled-test 斷言）| 5 |
| `test-gen/SKILL.md` | enabled 紅 test lane + 窄 disabled lane + thunk 改 throw GenesisTODO | 6 |
| `NewCommandTests.swift`（新 regression）| 生成「有 invariant + derived create + 非-strict when」的 bundle → `swift build` EXIT 0 | 7 |
| `BuildFailureClassifier.swift` + `BuildFailureClassifierTests.swift` | **刪除** | 8 |
| `NewCommand.swift` | 移 domainHolesRemain 分支 / holesSuffix / countDomainHoles → build!=0 unconditional `throw swiftBuildFailed` | 8 |
| `NewCommandTests.swift`（env-gated e2e）| 反轉斷言：fresh gen build **EXIT 0**（無 'domain hole' suffix）| 8 |
| `domain-fill/SKILL.md` | discovery grep `#error("GENESIS-TODO` → `GenesisTODO.notImplemented`;tri-state/完成報告 re-key;version-aware **反轉**（#error→legacy-warn-regenerate / GenesisTODO→current）;create-init 納入 fill scope | 9 |
| `CLAUDE.md.template` | stub 描述「will NOT compile until filled」→「compiles but test RED + `genesis verify` FAILS until filled;grep GenesisTODO」 | 9 |
| `SkillInstallerTests.swift` | 若 skill 數不變則不動（verify 是 CLI 非 skill）| — |

## 實作步驟（ordered；STEP 8 必須最後）

依討論 ordered change-list（STEP 0 載重事實已親驗）：
1. **STEP 1** GenesisTODO per-aggregate 檔:`AggregateRenderer.render` 加一行 `outputs.append(try renderGenesisTODO(spec:dir:))`（比照 renderError）,回 `("\(dir)/Entity/\(spec.name)GenesisTODO.swift", content, "genesisTodo")`。**audit MEDIUM 矯正**:role 是 write-only label（auto-flows,ManifestRenderer 只讀 templateVersion）→ **無 manifest plumbing 要設**;**scaffold-once 對 aggregate-target 檔不存在**（`<A>Error.swift`/`<A>.swift` 無 existingPaths 保護,靠全域 `checkNoConflicts` gate —— regen 既有 dir 是 hard conflict 非 per-file skip）→ **不需加 per-file guard**（純 codegen、無 human-fill surface）。
2. **STEP 2** catch-ladder rethrow（載重）。
3. **STEP 3** 遷 3 domain #error site：command body + 非-strict when → GenesisTODO throw;ensureInvariant → no-op（drop #error）。
4. **STEP 4** create-init fatalError → GenesisTODO throw。
5. **STEP 5** `genesis verify` subcommand（marker grep + invariant-enabled-test 斷言）。
6. **STEP 6** test-gen SKILL.md rewrite（enabled 紅 lane + 窄 disabled lane + thunk throw GenesisTODO）。
7. **STEP 7** regression test（**audit MEDIUM:必須 offline source-level 才真 gate**）:in-process 跑 renderer 於兩個 fixture —— (a) 有 invariant + derived-field create + 非-strict when 的 bundle、(b) **no-DTO bundle**（驗 per-aggregate GenesisTODO 在無 Shared import 時仍編得過,這是 D2 存在的理由,IAM fixture 有 DTO 不覆蓋）—— grep 產出字串斷言 `throw GenesisTODO.notImplemented` 出現 **且 ZERO `#error(`**。**這個 offline grep 才是 STEP 8 的真 gate**（`swift build` 需網路抓 DDDKit → env-gated 在 CI 會 skip → 擋不住 incomplete migration）。另留一個 env-gated real-build smoke：`genesis new` **不加 --skip-build**（跑真 `-c release` build,即 STEP 8 還原的那條路）斷言 EXIT 0。先確認 iam-cosmogony fixture 真含三種洞。
8. **STEP 8（最後）** 移 BuildFailureClassifier + NewCommand 還原 + 反轉 env-gated e2e 斷言。
9. **STEP 9** docs sync（CLAUDE.md.template + domain-fill SKILL.md grep 反轉 + version-aware 反轉）。

## 失敗路徑

| 條件 | 行為 |
|---|---|
| fresh gen `swift build` | **EXIT 0**（marker 編得過;反轉 1.u.1 capstone-reversal，回到「build green」）|
| `swift test`（domain 未填）| test 跑得起來、**紅在對應 test**（GenesisTODO throw）;增量 TDD ✓ |
| `genesis verify`（有殘留 marker）| 非 0 + 列位置（release-gate） |
| `genesis verify`（invariant 無 enabled test）| 非 0（no-op ensureInvariant 的 honesty backstop） |
| no-DTO bundle | GenesisTODO 在 per-aggregate 檔 → 可見 → 編得過（不踩條件-import 雷）|
| 不完整 migration（某 site 仍 #error）| STEP 7 regression test 擋（build 非 0）→ 不可進 STEP 8 |

## 不改動的部分
- scalar when / create skip / execute orchestration codegen（1.t D5 / 1.t.3 D6 / 1.x D1）。
- fill skill 的填洞職責（domain-fill 只改 grep target）。
- DDDKit / bundle schema / 真 KDB test 模型。

### Non-goals（v1 邊界，開放問題預設；user 可改）
- **adapter/presenter 的 5 個 fatalError site（domain 層外）**：v1 **不改**（defer + 文件標）。它們仍會 crash test process 若被 exercise，但不在 domain test 紅路徑;擴 blast radius。後續 phase 一起改 throw-marker。（開放#2 預設）
- **in-flight #error 專案 migration**：v1 **regenerate-from-scratch**（IAMContext 是 dogfood;不做 #error→marker 一次性 rewrite pass）。（開放#3 預設）
- **precondition/enum-cardinality gap**：command precondition 丟的 ContextError case 可能不在生成的 `<A>Error`（只從 invariant 生）→ 無 enum case 可正向斷言 → v1 **接受 precondition 洞只有 marker-red、無 positive-assertion backstop**（文件標）。（開放#4 預設）
- **KurrentDB 紅的歧義**（hole-unfilled vs DB-down vs arrange-wrong）：v1 **接受 + 文件標**（user 已確認 test 本來就要 local KDB;不加 in-memory store，D9）。（開放#5 預設）
- **read-model/presenter test lane**：defer（test-gen scope = usecase/application layer）。
- **不**維護雙模式（#error build-gate + marker）—— single codegen mode。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test 2>&1 | tail -5   # 全 pass（含新 regression + 反轉的 e2e 斷言 + 移除 BuildFailureClassifierTests）

# regen IAM（--skip-build）
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1
AGG="$TMP/Sources/UserAccessProfileAggregate"
# 洞 = GenesisTODO throw，無 #error
! grep -rq '#error("GENESIS-TODO' "$AGG"
grep -rq 'throw GenesisTODO.notImplemented' "$AGG/Entity/Commands/"
# ensureInvariant no-op（audit HIGH 修:negate 正向 grep,原 grep -qv 邏輯反轉永不 fail）
! sed -n '/func ensureInvariant/,/^    }/p' "$AGG/Entity/UserAccessProfile.swift" | grep -q 'GenesisTODO'
sed -n '/func ensureInvariant/,/^    }/p' "$AGG/Entity/UserAccessProfile.swift" | grep -qE 'No invariants declared|GENESIS-TODO: implement aggregate invariants'  # 正向:no-op 註解在
# GenesisTODO 型別在 aggregate target（非 Shared;audit:zsh glob nomatch 會 abort → 用 ls 2>/dev/null）
ls "$AGG"/Entity/*GenesisTODO.swift >/dev/null 2>&1 || grep -rq 'enum GenesisTODO' "$AGG/Entity/"
# catch-ladder rethrow
grep -q 'catch let error as GenesisTODO' "$AGG/Usecase/Port/In/PromoteUser/PromoteUserUsecase.swift"
# fresh gen 編得過（marker 不擋 build）
( cd "$TMP" && swift build 2>&1 | tail -2 )  # 期望 EXIT 0（需網路抓 DDDKit;CI 視情況）
# genesis verify 在（marker 殘留 → 非 0）
( cd "$TMP" && swift run --package-path /Users/abnertsai/JiaBao/Mendesky/Genesis genesis verify 2>&1 | grep -qiE 'hole|invariant|GenesisTODO' )
rm -rf "$TMP"
# BuildFailureClassifier 已移除
! test -f Sources/GenesisCore/BuildFailureClassifier.swift
```

### Human 補做
- [ ] regen IAM → 對 promoteUser 做一輪真 TDD：跑 test 看紅（GenesisTODO）→ 填 command/when → test 綠;確認別的 test 不受影響（增量）。
- [ ] 填一個 invariant 的 ensureInvariant → 對應 invariant test 由紅轉綠;`genesis verify` 通過。
- [ ] 確認 `genesis verify` 對「invariant 無 enabled test」會 fail（honesty backstop）。
- [ ] 確認 fresh gen `swift build` EXIT 0（反轉 1.u.1 capstone）。

## 已知限制
- honest-hole 信號 **relocated-and-WEAKENED**：build-gate（無條件）→ test-gate + release-gate（conditional：test 要存在+正確+有跑）。刻意換 TDD。`genesis verify` 是 enforcement 的新家,只在被 invoke（CI/pre-release）時 load-bearing。
- precondition 洞無 positive-assertion backstop（enum-cardinality gap）。
- adapter/presenter fatalError 仍 crash test process（defer）。
- marker-count == 0 ≠ done（只代表「洞都動過」;done 還要 invariant/error test 綠 + genesis verify 過）。

### 依賴關係
- **反轉**：Phase 1.u（#error）、1.u.1（BuildFailureClassifier）。
- **重整**：test-gen R2（`2026-06-03-test-gen-real-test-redesign.md` 的 disabled-until-filled → enabled-red）。
- 軟相依（done）：1.t.1（create init）、1.x（execute codegen + catch-ladder）。
- 來源：discussion `2026-06-03-tdd-first-honest-hole.md` D1-D6 + ordered change-list。
- 後續：adapter/presenter fatalError → marker;read-model test lane;new-usecase bundle-first retrofit（A3）。
