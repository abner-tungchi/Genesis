# Phase 1.u.1 — genesis new tolerate #error domain holes（fix rollback regression）

## 來源

Phase 1.u（`#error` domain 洞）引入的 regression，更新 README 時發現。**user 拍板 = tolerate-#error**。

**Regression**：`NewCommand` 後置驗證跑 `swift package resolve` →（除非 `--skip-build`）`swift build -c release`，失敗即 `throw .swiftBuildFailed` → `writer.rollback()`（刪光輸出）。Phase 1.u 後 fresh gen 必有 `#error("GENESIS-TODO")` domain 洞 → `swift build` 必失敗 → **`genesis new`（不加 `--skip-build`）rollback 自己的輸出**。即 README 範例 `genesis new IAMContext --from-bundle ./bundle.json` 留不下任何東西。

## 目標

讓 `genesis new` 預設仍跑 `swift build`（保留 codegen 編譯驗證 —— 真語法 bug 仍要 rollback），但**當 build 失敗「只因 GENESIS-TODO `#error` 洞」→ 視為 success-with-holes（不 rollback，印『N domain holes to fill』）**;任何**非 `#error`** 的 build error（真 codegen 壞）→ 維持 rollback。

這對齊 honest-hole 哲學：`#error` 是 intended 的「待人填」訊號（非失敗）;其他 error 才是真失敗。

## 介面合約

### 分類：build 失敗是否「只因 #error 洞」（source-line cross-check，非 stderr 子字串）

helper 放 **GenesisCore**（可被 `GenesisCoreTests` 單元測;Codex MED#4 —— private in Genesis 執行檔測不到）：
```
public static func buildFailureIsOnlyDomainHoles(stderr: String, projectRoot: URL) -> Bool
```

**規則（Codex HIGH：不靠 stderr 子字串信任，cross-check 實際 source 行 + 對任何看不懂的失敗保守 rollback）**：

1. 收集 stderr 所有含 `error:` 的行（比 `": error: "` 廣，含 `ld: error:` / 無 file 前綴的 `error:` / `1 error generated` 類）。
2. **每一條 error 行都必須**：
   - match `^<path>.swift:<line>:<col>: error: GENESIS-TODO:`（精確 compiler diagnostic shape），**且**
   - 讀 `projectRoot/<path>` 第 `<line>` 行，literal 含 `#error("GENESIS-TODO`（cross-check 真的是 #error directive，非字串注入 / 巧合文字）。
   - 任一條不符（plain `error:`、`ld: error:`、linker `link command failed`、launch/timeout 文字、source 行非 #error）→ 回 **false**（真失敗 / 看不懂 → rollback）。
3. 額外保守：stderr 含 linker / driver 失敗標記（`ld: `、`link command failed`、`Linking` 後接 error）→ 回 false。
4. 必須**至少一條**已 cross-check 的 GENESIS-TODO #error diagnostic → 回 true;否則（無 error 行 / 全不符）false。

> 為何 cross-check source 行：`#error("GENESIS-TODO: ...")` 含 bundle 衍生文字（aggregate/UC 名，BundleParser 只驗非空），stderr 子字串比對可被注入 spoof。讀 source 第 N 行確認是真 `#error(` directive，杜絕「字串裡剛好有 GENESIS-TODO」誤判。保守原則：**看不懂的失敗一律 rollback**（壞專案存活 比 多 rollback 一次 危險）。

### NewCommand build 分支改動

```
if !skipBuild {
    let build = ProcessRunner.run(... ["build", "-c", "release"] ...)
    if build.exitCode != 0 {
        if BuildFailureClassifier.buildFailureIsOnlyDomainHoles(stderr: build.stderr, projectRoot: outputURL) {
            domainHolesRemain = true   // success-with-holes：不 throw、不 rollback
        } else {
            throw GenesisError.swiftBuildFailed(stderr: build.stderr)  // 真錯 → rollback
        }
    }
}
```

success print 加 holes 提示（當 `domainHolesRemain`）：
```
✓ Genesis: wrote N files ... ; <K> domain holes (#error GENESIS-TODO) remain — fill them (deterministic fill skills + /domain-fill) then `swift build`.
```
`<K>` = generated Sources 內 `#error("GENESIS-TODO` 出現數（grep 輸出 dir 算;build stderr 可能 early-stop 少算，以 source grep 為準）。

### 不變
- `--skip-build`：仍跳過整個 build 步（resolve 仍跑）。
- resolve 失敗 → 仍 `swiftPackageResolveFailed` → rollback（deps/manifest 真壞）。
- 非-#error build error → 仍 rollback（真 codegen 壞，保留驗證價值）。
- `--no-git` / git pre-flight / writer.commit/rollback 機制不動。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/BuildFailureClassifier.swift`（新檔）| `public enum BuildFailureClassifier { public static func buildFailureIsOnlyDomainHoles(stderr:projectRoot:) -> Bool }` —— source-line cross-check 分類（見介面合約）。放 GenesisCore 才能被 GenesisCoreTests 單元測（Codex MED#4）|
| `Sources/Genesis/Commands/NewCommand.swift` | build 分支：失敗時 `BuildFailureClassifier.buildFailureIsOnlyDomainHoles(stderr:projectRoot:outputURL)` 判定;只因 #error → `domainHolesRemain = true`（不 rollback）+ success print 加 holes count 提示;否則 throw `.swiftBuildFailed`（rollback）|
| `Tests/GenesisCoreTests/BuildFailureClassifierTests.swift`（新檔）| 純字串/fixture 單元測（非 env-gated）：holes-only→true / mixed `file:line: error:`→false / plain `error:`→false / `ld: error:`→false / `link command failed`→false / timeout-launch 文字→false / 無 error→false / source 行非 #error（spoof：字串含 GENESIS-TODO 但非 directive）→false |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | `testEndToEndSwiftPackageResolveAndBuild`（env-gated）改 assert **exit 0 + 專案保留**（不 rollback）+ stdout「domain holes remain」（`.build` 視為 optional evidence 非 build-proof，因 resolve 先跑也會建 .build）|

### 不需改
- GenesisError（複用既有 `swiftBuildFailed`）。
- codegen / skills / DDDKit。

## 實作步驟

### Step 1：BuildFailureClassifier（GenesisCore，source-line cross-check）
1. 新 `Sources/GenesisCore/BuildFailureClassifier.swift`。`buildFailureIsOnlyDomainHoles(stderr:projectRoot:)`：
   - 取 stderr 含 `error:` 的行。
   - 每行 must match `<path>.swift:<line>:<col>: error: GENESIS-TODO:` → 取 path+line → 讀 `projectRoot/<path>` 第 line 行 literal 含 `#error("GENESIS-TODO` → 過;任一不符（plain error / ld:/linker / source 行非 #error）→ return false。
   - 含 linker 失敗標記（`ld: ` / `link command failed`）→ false。
   - ≥1 已 cross-check 的 → true;否則 false。

### Step 2：NewCommand build 分支
1. 加 `var domainHolesRemain = false`。
2. build 失敗 → if `BuildFailureClassifier...(stderr:, projectRoot: outputURL)` → `domainHolesRemain = true`（不 throw）;else throw `.swiftBuildFailed`。
3. success print：`domainHolesRemain` 時加 holes count（grep `#error("GENESIS-TODO` in `outputURL/Sources`）+ 填洞提示。

### Step 3：測試
1. `BuildFailureClassifierTests`（GenesisCore，非 env-gated）：上述 fixture shapes（含 ld:/timeout/spoof false-positive）。source-line cross-check 的測用臨時 dir 寫一個含 `#error("GENESIS-TODO` 的 .swift + 一個不含的，餵對應 stderr。
2. `NewCommandTests.testEndToEndSwiftPackageResolveAndBuild`（env-gated）：改 assert exit 0 + 專案保留（Package.swift 存在）+ stdout「domain holes remain」。

### Step 4：verify（見驗收）

## 失敗路徑

| 條件 | 行為 |
|---|---|
| build 失敗，stderr 全 GENESIS-TODO #error | success-with-holes（不 rollback，印 holes 提示，exit 0）|
| build 失敗，有非-#error error | `swiftBuildFailed` → rollback（真 codegen 壞）|
| resolve 失敗 | `swiftPackageResolveFailed` → rollback（不變）|
| `--skip-build` | 跳過 build（resolve 仍跑;不變）|

## 不改動的部分
- `#error` 機制 / Phase 1.u 洞。
- resolve 階段 / git pre-flight / writer rollback 機制。
- `--skip-build` 語意。

### Non-goals（行為層）
- **不**移除 build 步（保留 codegen 編譯驗證 —— 真語法 bug 仍 rollback）。
- **不**改 resolve 行為。
- **不**用 resolve-only 預設（user 選 tolerate-#error 而非 resolve-only）。
- **不**改 #error 洞本身 / 任何 skill。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test 2>&1 | tail -5   # 含 BuildFailureClassifierTests（false-positive shapes）

# classifier 在 GenesisCore（可單元測）+ NewCommand 引用
grep -q 'BuildFailureClassifier' Sources/GenesisCore/BuildFailureClassifier.swift
grep -q 'BuildFailureClassifier.buildFailureIsOnlyDomainHoles' Sources/Genesis/Commands/NewCommand.swift
# false-positive 防護測在
grep -qiE 'ld:|link command failed|spoof|非 ?#error' Tests/GenesisCoreTests/BuildFailureClassifierTests.swift
```

### Human 補做
- [ ] 有網路環境跑 `genesis new IAMContext --from-bundle <bundle>`（**不加** --skip-build）→ 確認：(a) exit 0;(b) 專案**保留**（非 rollback）;(c) stdout 印「N domain holes remain」。
- [ ] 人為在 template 植入真語法錯（非 #error）→ `genesis new` → 確認 rollback（真錯仍刪輸出，驗 codegen 編譯驗證保留）。

## 已知限制
- holes count 以 source grep 為準（build stderr 可能 compiler early-stop 少算）。
- classifier 靠 compiler diagnostic 格式 `file:line:col: error: GENESIS-TODO:` + source-line cross-check;若 Swift 改診斷格式需同步。保守設計（看不懂 → rollback）使誤判偏向「多 rollback」非「壞專案存活」。
- success-with-holes **不 rollback** → 生成專案 + SwiftPM 副作用（`.build/`、`Package.resolved`）留在 disk;`writer.rollback()` 本只清 writer-tracked 檔/dir，這些副作用本就不在其管轄（LOW：rollback ≠「刪光一切」）。
- 端到端 build 驗證需網路（DDDKit），CI 靠 classifier 單元測 + Human 補做。

### 依賴關係
- 修 Phase 1.u 的 regression（軟相依 1.u done）。
- 無 hard 阻塞。
