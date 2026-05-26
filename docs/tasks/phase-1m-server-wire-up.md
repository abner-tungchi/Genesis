# Phase 1.m — Server target wire-up (HTTP MVP, OC-aligned)

## 來源

OC ground truth：`Sources/OCServer/OCServer.swift` + Package.swift `.executable(name: "OCServer")` + `.executableTarget(...)` + deps `Hummingbird` / `OpenAPIHummingbird` / `Logging` / 各 aggregate target / context target。

依賴 Phase（全 done）：phase-1i（per-agg ApiHandler）、phase-1k.2（context-level ApiHandler + cross-agg）、phase-1l（Usecase Input OC alignment）、其他 Phase 1.a-1.l。

## 目標

補完 Genesis 最後一塊架構缺口 —— **Server entry codegen**。產 `Sources/<Context>Server/<Context>Server.swift` `@main` + Hummingbird Router + 自動 register 所有 ApiHandler + bind HTTP port，讓 `genesis new` 出來的專案可 `swift run <Context>Server` 直接起 HTTP service。**v1 純 HTTP scope**（D1，user 拍板）—— projection subscription wiring 留 explicit `// TODO: subscribe events + wire projectors` 區塊，由 user 後續手填。

**OC alignment**：對齊 OC `OCServer.swift` 核心結構（@main + KDB client from env + Router + registerHandlers + Application.runService），**排除** OC business-specific（Bearer auth / CORS 白名單 / GCS / OC Middleware target / persistent subscription + retry）。

**OC-divergence 報告**：見 spec § OC-divergence。

---

## 介面合約

### 新增 Server target

- 路徑：`Sources/<contextName>Server/<contextName>Server.swift`
- target name：`<contextName>Server`（e.g. `IAMContextServer`）
- product：`.executable(name: "<contextName>Server", targets: ["<contextName>Server"])`
- target type：`.executableTarget(...)`

### Server.swift 結構（emit 由 ServerRenderer）

```swift
import <each aggregate target>
import <contextName>          // when hasContextLevelPresenter
import <contextName>Shared
import DDDKit
import Foundation
import Hummingbird
import KurrentDB
import Logging
import OpenAPIHummingbird

import struct <Aggregate1Aggregate>.ApiHandler
import struct <Aggregate2Aggregate>.ApiHandler
// ... per aggregate that has handler emit
import struct <contextName>.ApiHandler  // when hasContextLevelPresenter


@main
@MainActor
struct <contextName>Server {
    static let logger = Logger(label: "<contextName>")

    static func main() async throws {
        let router = Router()
        // TODO: add middleware (CORS / auth / logging) as needed for your project.

        let esdbSettings = ProcessInfo.processInfo.environment["ESDB_URL"]
            ?? "kurrent://admin:changeit@localhost:2113?tls=false"
        let settings: ClientSettings = try esdbSettings.parse()
        let kdbClient = KurrentDBClient(settings: settings)

        let serverURL = URL(string: "/")!

        try <Aggregate1Aggregate>.ApiHandler(kdbClient: kdbClient)
            .registerHandlers(on: router, serverURL: serverURL, middlewares: [])
        try <Aggregate2Aggregate>.ApiHandler(kdbClient: kdbClient)
            .registerHandlers(on: router, serverURL: serverURL, middlewares: [])
        // ... per aggregate
        try <contextName>.ApiHandler(kdbClient: kdbClient)                       // when hasContextLevelPresenter
            .registerHandlers(on: router, serverURL: serverURL, middlewares: [])

        // TODO(Phase 1.m v2): projection subscription wiring
        //   - Stream naming: Genesis projection JS uses `$ce-<SourceCategoryPrefix><Aggregate>`
        //     (e.g. `$ce-IAMUserAccessProfile`，非 `$ce-UserAccessProfile`)，
        //     prefix 由 ReadModelRenderer 從 contextName 衍生（IAMContext → "IAM"，OpportunityContext → "OC"）。
        //     詳見 docs/decisions.md Phase 1.g ratification 的 SourceCategoryPrefix 規則。
        //   - Create KurrentDB persistent subscription per stream
        //   - Setup EventBus + EventMappers per source aggregate
        //   - Dispatch RecordedEvent via mappers → eventBus → projectors
        //   - Until subscription is wired, read endpoints return empty/notFound
        //     (projection state stays empty without event ingestion).
        //   See OC `OCServer.swift` for production-level pattern with retry/nack.

        let portString = ProcessInfo.processInfo.environment["PORT"] ?? "8080"
        let port = Int(portString) ?? 8080
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: port))
        )
        logger.info("starting <contextName>Server on 0.0.0.0:\\(port)")
        try await app.runService()
    }
}
```

### Package.swift 改動

`PackageRenderer`：

1. **頂層 deps 加**（conditional：當 `anyAggregateNeedsOpenApi || hasContextPresenter`）：
   ```swift
   .package(url: "https://github.com/swift-server/swift-openapi-hummingbird", from: "2.0.0"),
   .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
   .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
   ```
2. **products 加**：`.executable(name: "<contextName>Server", targets: ["<contextName>Server"])`（conditional：當 `hasAnyHandler`）
3. **targets 加** Server executableTarget（conditional 同上）：deps = 各 aggregate target + context target（when hasContextPresenter）+ ContextShared + DDDKit product + Hummingbird product + OpenAPIHummingbird product + OpenAPIRuntime product + Logging product。

> **audit H1 fix**：deps **不 emit** `Foundation`（standard library 自動可用）和 explicit `KurrentDB` package/product（與 OC OCServer 一致 — KurrentDB 透過 DDDKit 的 KurrentSupport target 傳遞性提供，Genesis 既有 aggregate target 也是此模式）。

### ServerRenderer（新檔）

`Sources/GenesisCore/ServerRenderer.swift`：

```swift
public enum ServerRenderer {
    public static func render(
        bundle: FullBundle,
        contextName: String,
        existingPaths: Set<String> = []
    ) throws -> [(path: String, content: String, role: String)] {
        // 1. determine which aggregates need handler register（has write UC OR has read presenter）
        let aggregatesWithHandler = bundle.aggregates.filter { agg in
            bundle.useCases.contains { uc in uc.aggregateSpecId == agg.aggregateSpecId && !ApiRenderer.isReadUseCase(uc.useCase) }
            || bundle.presenters.contains { $0.aggregateRef == agg.name }
        }
        let hasContextPresenter = PresenterPlacementResolver.hasContextLevelPresenter(bundle: bundle)

        // 2. skip emit when 無 ApiHandler at all
        guard !aggregatesWithHandler.isEmpty || hasContextPresenter else { return [] }

        // 3. emit Server.swift via template
        // ...

        return [(path, content, "server")]
    }
}
```

scaffold-once：`existingPaths.contains(serverPath)` → skip。

### Hummingbird transport 對應 openapi 生成

`registerHandlers(on:serverURL:middlewares:)` 由 `swift-openapi-hummingbird` package 提供 extension（add to `APIProtocol`-conforming types via `OpenAPIHummingbird` import）。

openapi-generator-config.yaml **不**改（OC 也沒在 config 指定 transport，僅 `generate: [types, server]`）。transport magic 由 import 啟動。

### NewCommand wiring

加 Step 2.3.7 ServerRenderer：

```swift
for file in try ServerRenderer.render(bundle: bundle, contextName: contextName, existingPaths: existingServerPaths) {
    try plan(file.path, file.content, file.role)
}
```

`scanExistingApiPaths` 簽名加 `contextName: String` 參數（audit M2 — 既有簽名只收 `bundle`，但 NewCommand 支援 CLI `contextName` override；不能用 `bundle.context`）。Server.swift 路徑：`Sources/<contextName>Server/<contextName>Server.swift`。

### Test target 不變

Phase 1.l 之前的 test target 仍指向 aggregate targets。Server target **不**進 test deps（純 HTTP wiring 不需測試 codegen 內容；human E2E 透過 `swift run` 驗）。

---

## OC-divergence 報告

| OC 有但 Genesis 不會 emit（business-specific） | 為什麼 |
|---|---|
| Bearer / CORS / Logging middleware | auth strategy / CORS policy / logging 因專案而異 |
| GoogleCloudStorage / `Storage<StandardContextMetadata>` | OC PDF blob storage 商業邏輯 |
| 自家 `Middleware` / `FileStorageContext` target | OC private packages |
| context handler `storage:` init param | OC-specific extension（Genesis context handler 只有 `kdbClient:`） |
| `$ce-<X>` 寫死 stream subscription + retry/nack | OC production-level，且 D1 user 選擇 defer |
| EventBus + per-agg EventMappers initial setup | 同上 |
| `register(kdbClient:eventBus:storage:)` helper | OC business helper |

| Genesis 自加（不在 OC） | 為什麼 |
|---|---|
| `PORT` env var with default 8080 | 通用設計（OC hardcoded 24101） |
| `// TODO(Phase 1.m v2): projection subscription wiring` 區塊 | 顯示性提示 user 後續需補完 |
| logger.info startup line | basic observability |

---

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/v0.1/Server/Server.swift.template` | **新檔** — emit Server entry |
| `Sources/GenesisCore/Resources/Templates/v0.1/PackageServerTarget.swift.template` | **新檔** — emit Package.swift executableTarget block |
| `Sources/GenesisCore/ServerRenderer.swift` | **新檔** |
| `Sources/GenesisCore/PackageRenderer.swift` | 加 Server deps (hummingbird/openapi-hummingbird/swift-log)、Server product、Server target；conditional emit |
| `Sources/Genesis/Commands/NewCommand.swift` | Step 2.3.7 ServerRenderer + scanExisting Server.swift path |
| `Sources/GenesisCore/Resources/Templates/v0.1/Package.swift.template` | 加 `{ServerProductLine}` + `{ServerTargetBlock}` placeholder |
| `Tests/GenesisCoreTests/ServerRendererTests.swift` | **新檔** — emit test for handler register lines / TODO block / port env var |
| `Tests/GenesisCoreTests/PackageRendererTests.swift` | 加 conditional Server target emission test |
| `Sources/GenesisCore/Version.swift` | 不變 |
| `docs/decisions.md` | Phase 1.m ratification |
| `docs/architecture.md` | §10.18 Server wire-up flow |
| `docs/tasks/registry/phase-1m-server-wire-up.json` | **新檔** |

---

## 實作步驟

### Step 1 — Server.swift.template

emit @main struct + 各 import + KDB client + Router + handler register + TODO block + Application.runService。template 變數：

- `{ContextName}` / `{ContextNameServer}`（= `{ContextName}Server`）
- `{AggregateImports}` — `import <A>Aggregate` per aggregate with handler
- `{ContextImport}` — `import <contextName>` 當 hasContextPresenter，否則空
- `{HandlerImports}` — `import struct <X>.ApiHandler` per handler (per-agg + context)
- `{HandlerRegistrations}` — `try <X>.ApiHandler(kdbClient:).registerHandlers(...)` per handler

### Step 2 — PackageServerTarget.swift.template

emit `.executableTarget(name:, dependencies:, ...)` block。template 變數：`{ContextName}` / `{AggregateDepLines}` / `{ContextDep}`（conditional）。

### Step 3 — ServerRenderer

實作 pure function：
1. compute `aggregatesWithHandler` set + `hasContextPresenter`
2. 兩者皆空 → return `[]`（無 ApiHandler 不 emit Server）
3. render template
4. return `[(path, content, "server")]`

### Step 4 — PackageRenderer 改動

- `needsServer = !aggregatesWithHandler.isEmpty || hasContextPresenter`（重用既有 lookup logic）
- 頂層 deps：`needsServer` true 時加 hummingbird + openapi-hummingbird + swift-log
- products list：`needsServer` true 時加 `.executable(name: "<C>Server", targets: ["<C>Server"])`
- targets list：`needsServer` true 時加 Server target block

新 placeholder `{ServerProductLine}` / `{ServerTargetBlock}` 在 Package.swift.template。

### Step 5 — NewCommand wiring

加 Step 2.3.7：

```swift
for file in try ServerRenderer.render(bundle: bundle, contextName: contextName, existingPaths: existingApiPaths) {
    try plan(file.path, file.content, file.role)
}
```

`scanExistingApiPaths` 加 Server.swift path 偵測。

### Step 6 — Tests

`ServerRendererTests`：
- bundle 全無 handler（無 write UC 無 read presenter） → render returns `[]`
- per-agg handler only → server emit handler register line 對應 aggregate
- per-agg + context-level → emit both registers
- import lines 對齊 aggregates + optional context
- `// TODO(Phase 1.m v2)` block 存在

`PackageRendererTests` 加：`needsServer` true 時 emit Server target + Server product。

### Step 7 — Real E2E

`genesis new IAMContext --from-bundle iam-cross-agg-presenter-bundle.json --output /tmp/p1m-e2e` →
1. `Sources/IAMContextServer/IAMContextServer.swift` 含 `@main` + UserAccessProfileAggregate.ApiHandler + IAMContext.ApiHandler 兩個 register
2. Package.swift 含 hummingbird/openapi-hummingbird/swift-log deps + Server target + product
3. `swift build` Build complete（不 swift run，因 KurrentDB 不必啟動，但 build 證實 wire 對）

---

## 失敗路徑

| 場景 | 處理 |
|---|---|
| Bundle 全無 handler（aggregates 但無 write UC 無 presenter） | ServerRenderer 回 `[]`，Server target 不 emit |
| 既有 Server.swift（user 手改過） | scaffold-once skip |
| Package.swift 結構不符 | TemplateRenderer 例外鏈 |

---

## 不改動的部分

- per-agg / context-level ApiHandler emission 不動（Phase 1.i / 1.k.2 既有）
- openapi.yaml / openapi-generator-config.yaml 不動
- 任何 fill skill 不動
- ContextShared / ReadModel / Projector / Aggregate Entity 不動

### Non-goals（行為層）

- 本 task **不包含** projection subscription wiring（D1 user 選 MVP only，留 TODO 給 v2）
- 本 task **不包含** auth / CORS / Logging middleware（business-specific，user 自加）
- 本 task **不包含** GoogleCloudStorage / Blob storage（OC 商業邏輯）
- 本 task **不包含** persistent subscription with retry/nack（v2 候選）
- 本 task **不包含** Hummingbird router middleware customization（user 後續加）
- 本 task **不 bump 版本**

---

## 驗收標準

### Agent 必做

```bash
# A1. ServerRenderer + templates 存在
test -f Sources/GenesisCore/ServerRenderer.swift
test -f Sources/GenesisCore/Resources/Templates/v0.1/Server/Server.swift.template
test -f Sources/GenesisCore/Resources/Templates/v0.1/PackageServerTarget.swift.template

# A2. PackageRenderer 加 Server conditional deps + product + target
grep -F 'hummingbird' Sources/GenesisCore/PackageRenderer.swift
grep -F 'openapi-hummingbird' Sources/GenesisCore/PackageRenderer.swift
grep -F 'executableTarget' Sources/GenesisCore/PackageRenderer.swift

# A3. NewCommand 加 ServerRenderer step
grep -F 'ServerRenderer.render' Sources/Genesis/Commands/NewCommand.swift

# A4. E2E：iam-bundle 重生 → Server.swift 含 register 行
rm -rf /tmp/p1m-test && mkdir -p /tmp/p1m-test
./.build/debug/genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-bundle.json --output /tmp/p1m-test --no-git --skip-build >/dev/null
test -f /tmp/p1m-test/Sources/IAMContextServer/IAMContextServer.swift
grep -F '@main' /tmp/p1m-test/Sources/IAMContextServer/IAMContextServer.swift
grep -F 'try UserAccessProfileAggregate.ApiHandler' /tmp/p1m-test/Sources/IAMContextServer/IAMContextServer.swift
grep -F 'registerHandlers(on: router' /tmp/p1m-test/Sources/IAMContextServer/IAMContextServer.swift
grep -F 'TODO(Phase 1.m v2)' /tmp/p1m-test/Sources/IAMContextServer/IAMContextServer.swift

# A5. Cross-agg fixture → 各 source aggregate handler + context handler 都 register（audit M3）
rm -rf /tmp/p1m-cross && mkdir -p /tmp/p1m-cross
./.build/debug/genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cross-agg-presenter-bundle.json --output /tmp/p1m-cross --no-git --skip-build >/dev/null
grep -F 'try UserAccessProfileAggregate.ApiHandler' /tmp/p1m-cross/Sources/IAMContextServer/IAMContextServer.swift
grep -F 'try PermissionAggregate.ApiHandler' /tmp/p1m-cross/Sources/IAMContextServer/IAMContextServer.swift
grep -F 'try IAMContext.ApiHandler' /tmp/p1m-cross/Sources/IAMContextServer/IAMContextServer.swift

# A6. swift build 在新 e2e tree 通過
cd /tmp/p1m-test && swift build
cd -

# A7. 全 unit + integration tests PASS
swift build
swift test
```

### Human 補做

- [ ] `cd /tmp/p1m-test && swift build` PASS（已含 A6 自動）
- [ ] 手動讀 Server.swift 確認 import 順序、register 行對齊 OC pattern、TODO 區塊清楚
- [ ] （optional, requires KurrentDB local）`swift run IAMContextServer` 起 HTTP service；`curl http://0.0.0.0:8080/...` 試 endpoint（write OK；read 返回空因無 subscription，符合 MVP only scope）

---

## 已知限制

1. **MVP only scope**（D1）：projection subscription 留 `// TODO(Phase 1.m v2)` 區塊；user 須手填 KurrentDB subscription + EventBus 才能讓 read 真實工作
2. **無 auth / CORS / logging middleware**：business-specific，user 自加
3. **無 persistent subscription / retry/nack**（v2 候選）
4. **無 GoogleCloudStorage / blob storage** integration（OC 商業邏輯，不通用）
5. **`PORT` env var default 8080**（OC 用 24101，Genesis 用通用 default）
6. **`ESDB_URL` env var default `kurrent://admin:changeit@localhost:2113?tls=false`**（與 OC 一致 dev default）
7. **依賴關係**：Phase 1.a-1.l 皆 done
8. **不 bump 版本**

## Audit findings resolution (Codex external 2026-05-26)

| ID | 嚴重 | 問題 | 修法 |
|---|---|---|---|
| H1 | 高 | Server target deps 列 `Foundation` (illegal) + 隱含 KurrentDB top-level package（未聲明）| deps 改為 aggregate targets + ContextShared + DDDKit product + Hummingbird/OpenAPIHummingbird/OpenAPIRuntime/Logging products；不 emit Foundation 或 explicit KurrentDB（透過 DDDKit/KurrentSupport 傳遞性） |
| M2 | 中 | `scanExistingApiPaths` 只收 `bundle`，但 Server.swift 路徑用 CLI `contextName`（可能 override `bundle.context`）| 簽名加 `contextName: String` |
| M3 | 中 | Cross-agg E2E assertion 漏 `PermissionAggregate.ApiHandler` register | 加 grep；補 context-only fixture（無 per-agg handler）測試 |
| M4 | 中 | TODO stream name 用 `$ce-<A>`，但 Genesis projection JS 用 `$ce-<SourceCategoryPrefix><A>` | 改 TODO wording 明示 SourceCategoryPrefix 規則 + 指向 Phase 1.g 文件 |

## Sign-off

- [x] write-spec output reviewed
- [x] **audit-spec pass — Codex external 2026-05-26**：1H + 3M 全套修進 spec
- [x] decisions.md ratification + architecture.md §10.18
- [x] registry status: ready → **done**（ServerRenderer + Server.swift.template + PackageServerTarget.swift.template + PackageRenderer conditional Server emission + NewCommand Step 2.3.7 wiring + TemplateRendererTests bump (新 ServerDependencies placeholder)。Real E2E PASS: iam-cross-agg-presenter-bundle 重生 → IAMContextServer.swift @main + 3 ApiHandler (PermissionAggregate + UserAccessProfileAggregate + IAMContext) register + TODO subscription block + ESDB_URL/PORT env vars + Application.runService → swift build Build complete + IAMContextServer.swift.o compiled。212/212 tests PASS）
