# DDDKit 依賴修正 — Mendesky/DDDKit 1.12.4 → gradyzhuo/swift-ddd-kit 0.3.0

## 來源

本 task 由 `write-spec` 以 inline brief 啟動（無獨立 discussion MD）。背景見 memory `project-phase0-resolutions`（2026-05-14 重大更正段）。修訂對象：Phase 0 Q1、`phase-1a-package-swift-scaffold`、`phase-1b-aggregate-extraction`。

## 目標

Phase 0 Q1 鎖定的 DDDKit 來源 `Mendesky/DDDKit` 1.12.4 是錯的 fork。使用者 2026-05-14 確認正確的是 OpportunityContext（OC）實際使用的 `gradyzhuo/swift-ddd-kit`（pin `from: "0.3.0"`）。兩 fork API 不相容（`Repository` 協議、storage coordinator 型別、`AggregateRoot` 結構、plugin product 命名都不同）。本 task 修正 `genesis new` 產出的 `Package.swift` 依賴宣告與 `Repository` template，使產出專案能對正確 kit `swift package resolve`，並修訂 Phase 0 Q1 與相關 docs。Aggregate 結構對齊（conform plugin 產的 protocol）刻意不在本 task，留待 Phase 1.e。

---

## 介面合約（Interface Contract）

本 task **不改動任何 Genesis 的 Swift API**（renderer 函數簽章全部不變）。改動集中在 **resource template 檔的文字內容** 與 **docs**。受影響的「契約」是 Genesis 產出的 `Package.swift` 與 `{Aggregate}Repository.swift` 的內容。

### 產出的 `Package.swift` 依賴契約（改後）

- `swift-tools-version: 6.0` — **不變**（gradyzhuo kit 的 `Package.swift` 也是 `6.0`，已驗證）
- `platforms: [.macOS(.v15)]` — **移除 `.iOS(.v16)`**。理由：gradyzhuo kit 宣告 `.iOS(.v18)`，SwiftPM 不允許消費端 platform 低於依賴；OC（ground truth）的 `Package.swift` 只宣告 `.macOS(.v15)`；kit 的 transitive 依賴（`swift-kurrentdb` / grpc）偏 server-side。**子決策：採 macOS-only**（替代方案見「已知限制」）。
- dependency 行：`.package(url: "https://github.com/gradyzhuo/swift-ddd-kit.git", from: "0.3.0")`
- package identity = `swift-ddd-kit`（由 URL 末段推導，OC `Package.swift` 證實）
- ⚠️ **版本 pin 釐清**：OC 的 `Package.swift` manifest 宣告的下界是 `from: "0.1.0"`，僅 `Package.resolved` 顯示實際解析到 `0.3.0`。Genesis pin `from: "0.3.0"` 是**使用者決定的政策選擇**（鎖到當前 latest stable），不是「照抄 OC manifest」。spec 全文提到「pin 0.3.0」皆指此政策決定。

### 產出的 aggregate target 契約（改後）

- `.product(name: "DDDKit", package: "swift-ddd-kit")` — product 名 `DDDKit` **不變**，`package:` 由 `"DDDKit"` 改為 `"swift-ddd-kit"`
- `.plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit")` — plugin 名 `DomainEventGeneratorPlugin` **不變**（gradyzhuo 也有同名 plugin product，已驗證），`package:` 改 `"swift-ddd-kit"`
- **不**新增 `ModelGeneratorPlugin`（屬 Phase 1.e）

### 產出的 `{Aggregate}Repository.swift` 契約（改後）

對齊 gradyzhuo `Repository: Sendable`（非 `: AnyObject`）與 OC `AuditQuotingRepository` ground truth：

```swift
import DDDKit

package struct {Aggregate}Repository: EventSourcingRepository {
    package typealias AggregateRootType = {Aggregate}
    package typealias StorageCoordinator = KurrentStorageCoordinator<{Aggregate}>

    package let coordinator: StorageCoordinator

    package init(coordinator: StorageCoordinator) {
        self.coordinator = coordinator
    }
}
```

變更點 vs 現況：`final class` → `struct`；`var coordinator` → `let coordinator`；`ESDBStorageCoordinator<{Aggregate}>` → `KurrentStorageCoordinator<{Aggregate}>`；移除 `import Foundation`（struct body 不使用，對齊 OC）。

**gradyzhuo 協議事實**（write-spec step 3b 已驗證自 `OpportunityContext/.build/checkouts/swift-ddd-kit` 0.3.0）：

- `protocol Repository: Sendable { associatedtype AggregateRootType: AggregateRoot }` — `: Sendable` 而非 `: AnyObject` → Repository **可為 struct**
- `protocol EventSourcingRepository<StorageCoordinator>: Repository { associatedtype StorageCoordinator: EventStorageCoordinator; var coordinator: StorageCoordinator { get }; ... }` — `find` / `save` / `delete` / `purge` 皆有 extension default，thin shell 只需宣告 `AggregateRootType` / `StorageCoordinator` / `coordinator`
- `final class KurrentStorageCoordinator<StreamNaming: EventStreamNaming>: EventStorageCoordinator` — 位於 `KurrentSupport` target，被 `DDDKit` re-export，`import DDDKit` 即可用
- `KurrentStorageCoordinator<{Aggregate}>` 成立的前提是 `{Aggregate}: EventStreamNaming`；`AggregateRoot: EventStreamNaming` → 一旦 `{Aggregate}` conform `AggregateRoot`（Phase 1.e 完成後）即成立

> 🔴 **編譯期耦合**：本 task 完成時 `{Aggregate}` 尚未對齊 gradyzhuo `AggregateRoot`（見「已知限制」），故 Repository template 改動單獨亦無法 build-pass。本 task 驗證上限為 `swift package resolve` + `swift test`。

### event.yaml / event-generator-config.yaml — 驗證相容，本 task不改

write-spec step 3b 逐欄比對 gradyzhuo `EventDefinition.swift` + `PropertyDefinition.swift` vs Genesis `event.yaml.template` + `event.yaml.event.template` + `event-generator-config.yaml.template`，結論 **相容，本 task 不改**：

- `Event.Definition` 欄位 `kind` / `aggregateRootId.alias` / `properties[]` 全部對得上 Genesis 產出格式
- `properties` 解析優先吃 array-of-`{name, type}` 形式（即 Genesis 用的格式）；`PropertyDefinition.type` 用 `String` rawValue 轉 `PropertyType`，container 型別（如 `"[String]"`）落 `.custom` — Genesis 對 container 型別加引號的處理仍正確且必要
- `GeneratorConfiguration` 的 `dependencies` / `generate` / `aggregateRootName` 皆 optional → Genesis 的 `event-generator-config.yaml`（只有 `accessModifier: package`）對 gradyzhuo 仍有效

🔴 **Framework 備註**：SwiftPM build-tool plugin 的 `package:` 參數須等於 dependency 的 package identity；URL 末段為 `swift-ddd-kit.git` → identity `swift-ddd-kit`。若 `package:` 仍寫 `"DDDKit"`，`swift build` 會在 manifest 解析階段報「unknown package」。

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template` | dependency URL 改 gradyzhuo、version 改 `from: "0.3.0"`、platforms 移除 `.iOS(.v16)`（swift-tools 不動）|
| `Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template` | `.product` 與 `.plugin` 的 `package:` 由 `"DDDKit"` 改 `"swift-ddd-kit"` |
| `Sources/GenesisCore/Resources/Templates/v0.1/Repository.swift.template` | `final class`→`struct`、`var coordinator`→`let coordinator`、`ESDBStorageCoordinator`→`KurrentStorageCoordinator`、移除 `import Foundation` |
| `Tests/GenesisCoreTests/PackageRendererTests.swift` | `from: "1.12.4"` 斷言改 `from: "0.3.0"`；補 gradyzhuo URL 存在 / Mendesky URL 不存在的斷言 |
| `Tests/GenesisCoreTests/TemplateRendererTests.swift` | `testRenderActualPackageSwiftTemplate` 內 `from: "1.12.4"` → `from: "0.3.0"`、`.iOS(.v16)` 斷言改為「不含 `.iOS`」 |
| `Tests/GenesisIntegrationTests/NewCommandTests.swift` | `testEndToEndHappyPath`：`from: "1.12.4"`→`from: "0.3.0"`；`.iOS(.v16)` 斷言改為「不含 `.iOS`」；`.macOS(.v15)` 斷言保留 |
| `docs/tasks/phase-1a-package-swift-scaffold.md` | 頂部加 superseded-by `dddkit-correction` banner；於含 `Mendesky/DDDKit` / `1.12.4` / `.iOS(.v16)` 的具體段落（輸入來源、Package.swift 範本、設計理由、驗收命令）加 inline ⚠️ 修訂標記 |
| `docs/tasks/phase-1b-aggregate-extraction.md` | 頂部加 superseded-by `dddkit-correction` banner；於以下具體段落加 inline ⚠️ 修訂標記：`<Aggregate>Repository` 薄殼描述（`final class`→`struct`、`ESDBStorageCoordinator`→`KurrentStorageCoordinator`）、`Package.swift` 範本片段（Mendesky URL / `.iOS(.v16)`）、`PackageTarget` 片段（`package: "DDDKit"`）、`Repository.swift.template` 段（`ESDBStorageCoordinator` typealias）、「Storage coordinator 鎖定 ESDB」段、驗收標準的 `swift build` / `ESDBStorageCoordinator` grep / `DDDKit 1.12.4` 命令。**不做整檔重寫**（phase-1b 是歷史紀錄），只加 banner + inline 標記 |
| `docs/architecture.md` | DDDKit 來源 / Repository 形狀 / coordinator 相關段落更新 |
| `docs/decisions.md` | 仿 D24 Phase 1.d ratification 格式，加 Phase 0 Q1 修訂 entry |
| `/Users/abnertsai/.claude/plans/tool-tool-lexical-hamming.md` | §5 Q1 + §2.3 Package.swift 範本更新（或加 superseded 註記）|

**已確認不需改動的 call sites / 檔案**（write-spec step 3b 已逐一檢視）：

- `Sources/GenesisCore/PackageRenderer.swift` — 依賴宣告字串全在 `Package.swift.template` 文字內，`PackageRenderer` 僅做 `{var}` 替換，無 DDDKit 字串邏輯
- `PackageProduct.swift.template` / `PackageSharedProduct.swift.template` / `PackageSharedTarget.swift.template` / `PackageTestTarget.swift.template` — 已逐一確認無 `package: "DDDKit"` 或 DDDKit URL 引用
- `event.yaml.template` / `event.yaml.event.template` / `event-generator-config.yaml.template` — 已驗證與 gradyzhuo schema 相容
- `AggregateRenderer.swift` / `Tests/GenesisCoreTests/AggregateRendererTests.swift` — 不含 repository 內容斷言、不含依賴字串（`AggregateRendererTests` 對 repository 只斷言 path，本 task 不改 path）

---

## 實作步驟

### Step 1：`Package.swift.template`

1. dependency 行 `.package(url: "https://github.com/Mendesky/DDDKit.git", from: "1.12.4"),` → `.package(url: "https://github.com/gradyzhuo/swift-ddd-kit.git", from: "0.3.0"),`
2. `platforms` 區塊由 `.macOS(.v15),` + `.iOS(.v16),` 兩行改為只留 `.macOS(.v15),` 一行
3. `swift-tools-version: 6.0` 與其餘 template 結構不動

### Step 2：`PackageTarget.swift.template`

1. `.product(name: "DDDKit", package: "DDDKit")` → `.product(name: "DDDKit", package: "swift-ddd-kit")`
2. `.plugin(name: "DomainEventGeneratorPlugin", package: "DDDKit")` → `.plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit")`
3. `plugins:` list 不新增任何項目（`ModelGeneratorPlugin` 留 Phase 1.e）

### Step 3：`Repository.swift.template`

完整改後內容見「介面合約 > 產出的 `{Aggregate}Repository.swift` 契約」。逐項：

1. 移除 `import Foundation`，保留 `import DDDKit`
2. `package final class {Aggregate}Repository: EventSourcingRepository` → `package struct {Aggregate}Repository: EventSourcingRepository`
3. `StorageCoordinator` typealias 的 `ESDBStorageCoordinator<{Aggregate}>` → `KurrentStorageCoordinator<{Aggregate}>`
4. `package var coordinator: StorageCoordinator` → `package let coordinator: StorageCoordinator`
5. `init(coordinator:)` 與 `AggregateRootType` typealias 不變

### Step 4：tests

1. `PackageRendererTests.testRenderHasPerAggregateProductAndTarget`：將 `result.content.contains("from: \"1.12.4\"")` 斷言改為 `from: "0.3.0"`；新增 `result.content.contains("gradyzhuo/swift-ddd-kit")` 與 `!result.content.contains("Mendesky/DDDKit")` 兩條斷言
2. `TemplateRendererTests.testRenderActualPackageSwiftTemplate`：`result.output.contains("from: \"1.12.4\"")` → `result.output.contains("from: \"0.3.0\"")`；`result.output.contains(".iOS(.v16)")` 斷言改為 `!result.output.contains(".iOS")`
3. `NewCommandTests.testEndToEndHappyPath`：`content.contains("from: \"1.12.4\"")` → `content.contains("from: \"0.3.0\"")`；`content.contains(".iOS(.v16)")` 斷言改為 `!content.contains(".iOS")`（確認 iOS platform 已移除）；`content.contains(".macOS(.v15)")` 斷言保留
4. 實作時對整個 `Tests/` + `Sources/GenesisCore/Resources/Templates/` grep 確認無其他 `1.12.4` / `Mendesky/DDDKit` / `ESDBStorageCoordinator` / `.iOS(.v16)` 殘留斷言

### Step 5：docs + plan

> 原則：已 done 的 task spec（`phase-1a` / `phase-1b`）是**歷史紀錄**，不做整檔重寫；改用「頂部 superseded banner + 具體段落 inline ⚠️ 標記」。`decisions.md` / `architecture.md` / plan 則直接更新內文（它們是 live 文件）。

1. `docs/decisions.md`：加一條 Phase 0 Q1 修訂 ratification entry（仿 D24 Phase 1.d ratification 格式），載明 kit 由 `Mendesky/DDDKit` 1.12.4 改為 `gradyzhuo/swift-ddd-kit` 0.3.0、理由（OC 為 ground truth、兩 fork API 不相容）、影響範圍（Phase 0 Q1 / Phase 1.a / Phase 1.b）
2. `docs/tasks/phase-1a-package-swift-scaffold.md`：頂部加 superseded-by `dddkit-correction` banner；於以下含過時值的具體段落加 inline ⚠️ 標記 —「輸入來源」列的 `Mendesky/DDDKit/Package.swift` 路徑、Package.swift 範本片段（`.iOS(.v16)` / `Mendesky/DDDKit.git` / `from: "1.12.4"`）、設計理由段（`.iOS(.v16)` 對齊、`from: "1.12.4"` latest stable）、驗收命令（`grep from: "1.12.4"` / `grep .iOS(.v16)` / `grep Mendesky/DDDKit.git` / `swift package resolve` 確認 DDDKit 1.12.4）。每個標記指向 `dddkit-correction` 的對應新值。
3. `docs/tasks/phase-1b-aggregate-extraction.md`：頂部加 superseded-by `dddkit-correction` banner；於以下具體段落加 inline ⚠️ 標記 —「輸入來源」的 `Mendesky/DDDKit/Sources/DDDCore/Entity/Entity.swift` 路徑、`<Aggregate>Repository` 薄殼描述（`final class`→`struct`、`ESDBStorageCoordinator`→`KurrentStorageCoordinator`）、`Package.swift` 範本片段、`PackageTarget` 片段（`package: "DDDKit"`）、`Repository.swift.template` 段的 `ESDBStorageCoordinator` typealias、「🔴 Storage coordinator 鎖定 ESDB」整段、驗收標準中的 `ESDBStorageCoordinator` grep 與 `swift build` / `DDDKit 1.12.4` 命令。每個標記載明原決策是讀錯 kit（`Mendesky/DDDKit`）所致、正確值見 `dddkit-correction`。
4. `docs/architecture.md`：直接更新 DDDKit 來源、Repository 形狀（struct）、storage coordinator（KurrentStorageCoordinator）、platforms 的描述段落
5. plan `§5 Q1` 與 `§2.3` 的 Package.swift 範本：直接更新為 gradyzhuo 值（URL / `from: "0.3.0"` / macOS-only platforms / `package: "swift-ddd-kit"`），並於 §5 Q1 加一行註記指向 `dddkit-correction`

---

## 失敗路徑

本 task 純改 template 文字 + docs，**無新增 error path**。

- 既有失敗路徑不變：`genesis new` 的 git preflight 失敗（exit 3）、bundle parse 失敗（exit 1）、`swift package resolve` 失敗（exit 2）對應的 `GenesisError` case 與 exit code 完全不受影響。
- 唯一行為變化：`genesis new` 內部的 `swift package resolve` 步驟現在會抓 `gradyzhuo/swift-ddd-kit` 0.3.0 及其 transitive 依賴（`swift-kurrentdb` 等）。若網路 / git fetch 失敗，沿用既有 `GenesisError.swiftPackageResolveFailed`（exit 2）路徑，**不新增 case**。

---

## 不改動的部分

- `Sources/GenesisCore/PackageRenderer.swift`、`AggregateRenderer.swift` 及所有 renderer 程式碼 — 改動全在 template 文字檔
- `Aggregate.swift.template`、`CommandExtension.swift.template`、`AggregateError.swift.template` — aggregate 結構對齊屬 Phase 1.e
- `event.yaml.template`、`event.yaml.event.template`、`event-generator-config.yaml.template` — 已驗證與 gradyzhuo schema 相容
- `PackageProduct.swift.template`、`PackageSharedProduct.swift.template`、`PackageSharedTarget.swift.template`、`PackageTestTarget.swift.template` — 無 DDDKit 引用
- 所有 CLI flag、`NewCommand` / `InstallSkillsCommand` 行為、`GenesisError` cases
- `swift-tools-version`（維持 `6.0`，已驗證與 gradyzhuo kit 相容）

### Non-goals（行為層）

- 本 task 不包含 aggregate template 對 `{Aggregate}AggregateProtocol` 的 conformance 改寫（Phase 1.e）
- 本 task 不包含 `Entity/` 目錄搬移、Repository 搬到 `Usecase/Port/Out/`（Phase 1.e）
- 本 task 不包含掛載 `ModelGeneratorPlugin`、產生 `projection-model.yaml`（Phase 1.e）
- 本 task 不包含讓 `genesis new` 產出的專案能完整 `swift build`（需 Phase 1.e 一併落地）
- 本 task 不包含 event.yaml deleted-event block 的形狀調整（renderer 邏輯，未來評估）
- 本 task 不包含新增 iOS / 其他 platform 支援（採 macOS-only）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis

# 1. Package.swift.template 內容正確
grep -F 'gradyzhuo/swift-ddd-kit.git' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
grep -F 'from: "0.3.0"' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
! grep -F 'Mendesky/DDDKit' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template
! grep -F '.iOS(.v16)' Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template

# 2. PackageTarget.swift.template 內容正確
grep -F 'package: "swift-ddd-kit"' Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template
! grep -F 'package: "DDDKit"' Sources/GenesisCore/Resources/Templates/v0.1/PackageTarget.swift.template

# 3. Repository.swift.template 內容正確
grep -F 'struct {Aggregate}Repository' Sources/GenesisCore/Resources/Templates/v0.1/Repository.swift.template
grep -F 'KurrentStorageCoordinator<{Aggregate}>' Sources/GenesisCore/Resources/Templates/v0.1/Repository.swift.template
! grep -F 'final class {Aggregate}Repository' Sources/GenesisCore/Resources/Templates/v0.1/Repository.swift.template
! grep -F 'ESDBStorageCoordinator' Sources/GenesisCore/Resources/Templates/v0.1/Repository.swift.template

# 4. 無殘留 Mendesky kit 引用（templates + 全 Tests/ 掃 — 含 TemplateRendererTests / PackageRendererTests / NewCommandTests）
! grep -RF '1.12.4' Sources/GenesisCore/Resources/Templates/ Tests/
! grep -RF 'Mendesky/DDDKit' Sources/GenesisCore/Resources/Templates/ Tests/
! grep -RF 'ESDBStorageCoordinator' Sources/GenesisCore/Resources/Templates/ Tests/
! grep -RF '.iOS(.v16)' Sources/GenesisCore/Resources/Templates/ Tests/

# 5. docs 修訂標記存在（phase-1a/1b 是歷史紀錄，stale 字串會保留，故檢查「修訂標記存在」而非「字串消失」）
grep -F 'dddkit-correction' docs/tasks/phase-1a-package-swift-scaffold.md
grep -F 'dddkit-correction' docs/tasks/phase-1b-aggregate-extraction.md
grep -F 'gradyzhuo/swift-ddd-kit' docs/decisions.md
grep -F 'gradyzhuo/swift-ddd-kit' docs/architecture.md

# 6. 全 test suite 綠
swift test

# 7. e2e：產出專案 + resolve 抓 gradyzhuo kit
rm -rf /tmp/dddkit-fix-e2e && mkdir /tmp/dddkit-fix-e2e
( cd /tmp/dddkit-fix-e2e && git init -q )
BIN="$(swift build -c release --product genesis --show-bin-path)/genesis"
"$BIN" new IAMContext --from-bundle "/Users/abnertsai/Downloads/IAM Context Bundle.json" --output /tmp/dddkit-fix-e2e
grep -F 'gradyzhuo/swift-ddd-kit' /tmp/dddkit-fix-e2e/Package.swift
grep -F 'struct UserAccessProfileRepository' /tmp/dddkit-fix-e2e/Sources/UserAccessProfileAggregate/Adapter/UserAccessProfileRepository.swift
( cd /tmp/dddkit-fix-e2e && swift package resolve )
```

### Human 補做（需要人類介入）

- [ ] 檢視 `/tmp/dddkit-fix-e2e/Package.resolved`，確認 `gradyzhuo/swift-ddd-kit` 解析到的版本 ≥ `0.3.0`，且 transitive 依賴（`swift-kurrentdb` 等）成功解析。

> **完整 `swift build` 不在本 task 的驗收範圍**：本 task 完成後產出專案的 aggregate template 尚未對齊 gradyzhuo `AggregateRoot`，`swift build` 必然失敗（見「已知限制」）。`swift build` 的 build-pass 驗證屬 **Phase 1.e** 的驗收項，由該 task + `/pickup` 實作階段執行。本 task 的驗收上限明確為 `swift package resolve` + `swift test`。

---

## 已知限制

- **本 task 完成後 `genesis new` 產出的專案無法完整 `swift build`**：aggregate template 仍 conform 已不存在的 `Mendesky/DDDKit` `AggregateRoot` 形狀 — 使用了 gradyzhuo 沒有的 `CreatedEventType` associatedtype、且缺 gradyzhuo `AggregateRoot` 要求的 `init?(events:)`（gradyzhuo base extension 不提供 default）。完整 build 正確性需 **Phase 1.e**（aggregate conform plugin 產的 `{Aggregate}AggregateProtocol`）一併落地。本 task 驗證上限為 `swift package resolve` + `swift test`，與 Phase 1.a–1.d 既有慣例一致（全程未做 `swift build` 驗證）。
- **Repository ↔ Aggregate 編譯期耦合**：`KurrentStorageCoordinator<{Aggregate}>` 要求 `{Aggregate}: EventStreamNaming`（經 `AggregateRoot`）。aggregate 對齊前，Repository template 改動單獨也無法 build-pass。
- **platform 子決策**：採 macOS-only（移除 `.iOS(.v16)`）。替代方案為升 `.iOS(.v18)`，但 OC ground truth 為 macOS-only、且 kit transitive 依賴（`swift-kurrentdb` / grpc）偏 server-side，故採前者。若日後需 iOS target，須一併確認 `swift-kurrentdb` / grpc 在 iOS 的可用性。
- **event.yaml deleted-event block 形狀**：Genesis 對 deleted event 仍 emit `aggregateRootId` + fallback property block；OC 真實 event.yaml 的 deleted event 只有 `kind: deletedEvent`。gradyzhuo decoder 兩者皆吃（欄位 optional），不阻擋本 task；但生成的 `{Aggregate}Deleted` struct 形狀差異留待 Phase 1.b-renderer 後續評估，不在本 task。
- **依賴關係**：本 task 無前置 task（`depends_on` 為空）。**`phase-1e`（aggregate 結構修訂）依賴本 task** — Phase 1.e 的 aggregate 對齊必須建立在正確 kit 之上。
