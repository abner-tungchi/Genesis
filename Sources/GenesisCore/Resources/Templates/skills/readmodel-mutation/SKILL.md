---
name: readmodel-mutation
description: Genesis fill-in skill for projector when() bodies (read side; sibling of /api and /presenter-fill). Inside a Genesis-bootstrapped project, /readmodel-mutation <presenterName> classifies EVERY `_ = readModel; _ = event` stub that Phase 1.g leaves in `<presenterName>Presenter.swift` as mechanical / aggregate-id / reuse-from-aggregate / ask / manual, fills the deterministic ones, proposes read-side equivalents of the aggregate's already-filled `when(event:)` (write-side semantics a human already confirmed), asks semantic multiple-choice questions via AskUserQuestion for the rest, shows ONE review table, writes once after confirmation, and logs every non-mechanical decision to docs/readmodel-mutation-provenance.md. AI writes the code, the human answers semantics: it never guesses delta (add/remove) vs snapshot semantics and never aborts the whole run because one method has no pattern. Only touches when() bodies.
argument-hint: [presenterName]
disable-model-invocation: true
allowed-tools: Read, Edit, Write, Glob, Grep, AskUserQuestion
---

# /readmodel-mutation — Fill projector when() bodies（批次分類 + 審閱表）

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

對 `<presenterName>Presenter.swift` 內每個 `when(readModel: inout ReadModelType, event: <E>) throws`，把 Phase 1.g 留下的 stub（`// TODO(Phase 1.g)` 註解 + `_ = readModel` / `_ = event`）換成實際 mutation body。
分工：**AI 寫程式、人回答語意**。先把**每個**方法分類：確定的直接填；可沿用寫入端已確認語意的做成提案；語意不明的用選擇題問；整理成**一張審閱表**一次確認，再**一次寫入**。

### 絕對約束（不可違反）

- **只動 when() body 內的 stub**；不動 type signature / typealias / buildReadModel / coordinator / categoryRule / imports。
- **不動 ReadModel** swift、**不動 aggregate**（`Entity/` 只讀）；**不寫 openapi.yaml** / event.yaml / Package.swift / bundle JSON / 任何 *.yaml。唯一另寫的檔是 `docs/readmodel-mutation-provenance.md`。
- **不動 read-side AS body**（/presenter-fill 範疇）。一次一 presenter；scaffold-once + idempotent per-method。
- **不猜增減語意**：payload 是差量（加入／移除）還是快照（整欄取代），事件名與型別都判斷不出；猜錯會**編譯通過但語意錯**。delta 動詞（`Granted | Revoked | Added | Removed | Deleted | Assigned`）事件永遠不套整欄取代的 pattern，只能沿用 aggregate 已確認的 `when(event:)`（提案，人確認才寫）或問人。
- **不因單一方法無法處理就中止**：沒有 pattern 的方法歸 reuse-from-aggregate / ask / manual，其餘方法照常處理，全部結果列在報表。
- 提案與問答結果**未經人確認不寫**。人選 skip → 該方法整段 stub 原封不動（aggregate-id 那行也不寫，下次重跑會重新分類）。

## Phase 0 — arg 檢查

`$ARGUMENTS` = presenter / projector 名（e.g. `GetPermissions`、`GetContractNotes`），設 `presenterName`。空 → exit 1：`usage: /readmodel-mutation <presenterName>`。

## Phase 1 — Locate Presenter + ReadModel

Glob 兩種 module 路徑合併（Phase 1.k.2 後 cross-agg projector 在 context module）：

- `Sources/*Aggregate/Usecase/Projector/<presenterName>/<presenterName>Presenter.swift`（per-agg）
- `Sources/*/Projector/<presenterName>/<presenterName>Presenter.swift`，排除 `*Aggregate`（context-level）

判定：0 match → exit 1：`prerequisite missing: <presenterName>Presenter.swift not found; run /readmodel + genesis new`；≥2 match → exit 4：`ambiguous presenter <presenterName> in [...]; manual disambiguation needed`；1 match → `<readModelTypeName>` = `<stripGet(presenterName)>ReadModel`，verify `<readModelTypeName>.swift` 在 projector 同 dir，缺 → exit 1。

## Phase 2 — Parse projector + per-method 狀態（idempotent）

Read presenter，抽出每個 `package func when(readModel: inout ReadModelType, event: <E>) throws` 的 body block，記 `<E>`。每個 body 判定（line-based，容 whitespace / trailing comment）：

| 狀態 | 判定 | 動作 |
|---|---|---|
| 未填 | `_ = readModel`、`_ = event` 兩行都在，除 stub 註解外沒有其他 statement | 進 Phase 4 分類 |
| 已填 | 無 placeholder，且有 mutation（`readModel.` 指派 / `.append(` / `.removeAll(` / `[i].`）**或** no-op 標記 `// readmodel-mutation: no-op` | skip（重跑不碰） |
| 半填 | 其他：只剩一個 placeholder、placeholder 與 mutation 並存、或 body 無 mutation 且無 no-op 標記 | exit 4：`partial fill detected in when(...event: <E>)` |

半填在**寫入前**檢查：一次列出全部半填方法，什麼都不寫。沒有未填方法 → 報表 `nothing to do` exit 0。

no-op 標記（人選「不影響」時由本 skill 寫入；**不含** `_ = readModel` / `_ = event`，空 body 照樣編譯）：

```swift
        // readmodel-mutation: no-op — <理由>
```

## Phase 3 — 讀輸入（全部唯讀）

1. **ReadModel**：`<readModelTypeName>.swift` 的 stored properties（name + Swift 型別；區分 scalar / `[X]` / `Set<X>` / nested struct / `<X>Dto`；記 Optional）。**key 欄位** = `var id: String { <key> }` 回傳的欄位（`buildReadModel` 已由 input.id 設好）：只由 set anchor 寫，其他事件不提問、不寫。
2. **event.yaml**（per-agg：`Sources/<A>Aggregate/event.yaml`；context-level：各事件所屬 aggregate 的 event.yaml）：每個 `<E>` 的 `properties`（name + type）、`kind`、`aggregateRootId.alias`。plugin 產的 Swift 事件型別有 `event.<alias>: String`（沒宣告 alias 時叫 `aggregateRootId`），它不在 `properties` 裡。
3. **aggregate 寫入端語意**（reuse 用；Grep `func when(event: <E>)` 於 `Sources/*Aggregate/Entity/`）：
   - 一般事件：`Sources/<A>Aggregate/Entity/Commands/<A>+<UC>.swift` 的 `package func when(event: <E>) throws`。
   - createdEvent：`Entity/<A>.swift` 的 rehydration `init?(first createdEvent: <E>, ...)` 把 `createdEvent.<f>` 傳給 full init，full init 的 `self.<f> = <f>` 等同 `self.<f> = event.<f>`。
   - 該 `when(event:)` body（createdEvent 則看 full init 的指派）含 `GenesisTODO`（`/domain-fill` skip 留下的洞）或 placeholder → **不可沿用**。同檔 command method 的洞不影響。
   - 有 `docs/domain-fill-provenance.md` 時，找該 when 的列：人當時口述的原文放進審閱表「依據」。
4. **Dto-convert 輸入**：對型別名以 `Dto` 結尾的 stored field `<X>Dto`，**grep symbol**（不要求 local type decl）找 initializer，範圍 `Sources/**/Usecase/Projector/**/*.swift` + `Sources/**/Adapter/Dto/**/*Dto*.swift`（含 `<X>Dto+Domain.swift` extension initializer）。鎖定**唯一 non-throwing 單參數** `init(from <label>: <D>)`；有多個 `init(from:)` overload（schema + domain、或 `init(from decoder:) throws`）時，除非能精確鎖定「參數型別 == event field 型別且 non-throwing」的唯一一個，否則該 field「不可 Dto-convert」。
5. **projector-wide field-writer map**：每個 readModel field 會被哪些 event 寫（single-writer 檢查用）。

## Phase 4 — 分類（每個未填方法恰屬一類）

**aggregate-id（確定）**：readModel 有欄位名 == 該事件 `aggregateRootId.alias`（例 `employeeAccessId`）且型別 `String` / `String?` → `readModel.<f> = event.<alias>`。只有一行，**合併**進該方法最後的 body（任何類別都帶，skip / manual 除外）。

**mechanical**：依 priority 試下列 pattern（命中第一個即用；aggregate-id 欄位不在此寫；key 欄位只由 set anchor 寫）：

1. 名含 `Removed` / `Deleted` 且 event 有 `*Id` 對應某 collection elem id → **removeAll**：`readModel.<col>.removeAll { $0.<idField> == event.<idField> }`
2. 名含 `Edited` / `Updated` / `Renamed` 且 event 有 `*Id` locator + 其他 fields → **updateAt**：`guard let i = readModel.<col>.firstIndex(where: { $0.<idField> == event.<idField> }) else { return }` + `readModel.<col>[i].<f> = event.<f>`
3. 名含 `Added` 且 payload fields ⊇ collection elem fields 全集（同名同型）→ **append struct**：`readModel.<col>.append(.init(<f1>: event.<f1>, <f2>: event.<f2>))`
4. target field 型別是 `<X>Dto`（單一，非 collection）→ 試 **Dto-convert**（下方三條件）；先於 anchor/scalar 判（`<X>Dto` 用 scalar 會型別不符）
5. 名含 `Created`（anchor）→ **set anchor**：同名同型 scalar 逐行 `readModel.<f> = event.<f>`（collection 初始空，**不**在 anchor event append）
6. 名含 `Set` / `Edited` 且 payload 全 scalar 直對 readModel 同名同型 scalar → **set scalar**：`readModel.<f> = event.<f>`
7. event 有單一 `[X]` field 對應 readModel `Set<X>`，且 verb 不在 delta 黑名單 → **assignList**：`readModel.<setField> = Set(event.<arr>)`（delta 動詞是差量，整欄取代會錯）

**Dto-convert 三條件**（全成立才填；type-closure 是必要非充分：`init(from:)` 存在只證明「可轉型」，不證明「該覆寫」）：

- A. conversion-closure：target field（去 `?`）= `<X>Dto`；`<X>Dto` 有唯一 non-throwing `init(from: <D>)`；event 有唯一 `<D>` 型別 payload field `<g>`。
- B. replace-verb：verb ∈ 白名單 `Created | Set | Edited | Updated | Renamed`；∈ delta 黑名單 → 不 match。
- C. single-writer：該 field 只被單一 event 寫（field-writer map）；多 writer = domain 語意 → 不 match。
- emit `readModel.<field> = <X>Dto(from: event.<g>)`。OC ground truth：`IndustrialTypeEdited` → `IndustrialTypeDto(from: event.industrialType)`。反例 `GetPermissions.permissionDto`（memberwise `PermissionDto` 無 `init(from:)` + grant/revoke multi-writer）→ 不 match。

**待決欄位**：排除 key、aggregate-id、mechanical 已寫的欄位後，readModel 欄位若 (a) payload 有同名欄位（型別可不同），或 (b) aggregate 對 `<E>` 的寫入端語意指派了同名 state 欄位 → 待決，逐欄判：

- **reuse-from-aggregate（提案）**：aggregate 該段已填，且對此欄位是**單一運算式**的指派 → 擷取該運算式，依下節轉成讀取端寫法，連同來源片段進審閱表；人確認才寫。
- **ask**：其餘待決欄位（aggregate 該段是洞、沒有同名 state、片段不是單一運算式、或轉換需要人決定）。
- 方法沒有 mechanical 行、沒有待決欄位，而 readModel 還有 key / aggregate-id 以外的欄位（例：aggregate 只改了 read model 沒有的欄位）→ 整個事件一題 ask：「此事件是否影響這個 read model？」

**manual**（留空殼，報表說明原因）：reorder（名含 `Reordered` / `Moved` / `Sorted`）、insert-at-position（payload 有 index / position / before* / after*）、跨事件條件（要看其他 state 才能決定）、custom type wrap（非 Dto 自訂型別要建構）、append struct 但 collection elem 有 field 不在 payload（需 default，如 OC `uniqueCode: nil, traits: []`）。

**方法類別** = 其中最需要人的一項：manual > ask > reuse-from-aggregate > mechanical > aggregate-id（只有 aggregate-id 行時才是 aggregate-id 類）。同一 body 可合併多類的行（例：set anchor + aggregate-id + reuse）。

### reuse 轉換（aggregate 片段 → 讀取端）

`<o>` = 讀取端舊值：readModel 欄位 Optional 時 `readModel.<f> ?? []`，否則 `readModel.<f>`。型別相同時照抄運算式（左邊 `self.<f>` → `readModel.<f>`，右邊的舊值 → `<o>`）；型別不同時：

| aggregate 片段（state `Set<X>`） | readModel `[X]`（陣列有順序） |
|---|---|
| `self.<f> = event.<g>`（payload `Set<X>`） | `readModel.<f> = event.<g>.sorted()`（Set 無順序，排序才可重現；X 非 Comparable → ask） |
| `.union(event.<g>)` / `formUnion` / `insert` | 不重複追加、保留順序（下方第一段） |
| `.subtracting(event.<g>)` / `subtract` / `remove` | 移除（下方第二段） |

```swift
        var <f> = <o>
        for element in event.<g> where !<f>.contains(element) { <f>.append(element) }
        readModel.<f> = <f>
```

```swift
        var <f> = <o>
        <f>.removeAll { event.<g>.contains($0) }
        readModel.<f> = <f>
```

aggregate 是 `[X]`、readModel 是 `Set<X>` → `Set(...)` 包起來。其他差異（Optional 以外的型別轉換、含 `if` / `guard` / `switch` / 迴圈的片段）→ 不轉，歸 ask，片段放進「依據」。

### ask 題目（AskUserQuestion，選項依 payload 形狀產生）

一題 = 一個（方法, 待決欄位），或一個「整個事件」。question 帶事件 payload、readModel 欄位型別、aggregate 對此事件做了什麼（附片段，或「aggregate 未改此欄位」）。每題 2–4 個 options，AskUserQuestion 自動附 Other：

| 形狀 | options |
|---|---|
| payload 集合 → 同名 readModel 集合（元素型別相同） | 加入（聯集；陣列＝不重複追加、保留順序）／移除（差集）／不影響（no-op）／skip |
| payload scalar → 同名 readModel scalar | 覆寫（`readModel.<f> = event.<f>`，型別不同時附轉換）／不影響（no-op）／skip |
| 整個事件（沒有同名欄位） | 不影響（no-op）／skip |

- **一定含**「不影響（no-op）」與「skip」。覆寫（payload 是完整快照）、其他寫法、不同名欄位之間的對照（例：roles → permissions）→ 選 Other 口述；不同名欄位**不**自動配成選項。
- 選「不影響（no-op）」時標記理由寫 `<E> 不改變 <欄位>（使用者確認）`；Other 以「no-op：」開頭 = no-op 並以人寫的理由入標記；其他 Other 文字 = 口述：先回述 `語意理解：<paraphrase>` 再轉 Swift，回述與程式碼一起放進整表確認。只轉寫人說的，不腦補。
- 每次 AskUserQuestion 最多 4 題，依審閱表順序分批。

## Phase 5 — 審閱表 → 問答 → 整表確認（一次呈現）

5a. 印審閱表（每個未填方法一列；已填的方法另列一行 `already filled`）：

| # | when(event) | 類別 | 提議的程式碼 / 問題 | 依據 |
|---|---|---|---|---|
| 1 | PrivilegeGranted | reuse-from-aggregate | aggregate-id 1 行 + 聯集 3 行（貼完整程式碼） | `Entity/Commands/<A>+GrantPrivilege.swift`：`self.permissions = (self.permissions ?? []).union(event.permissions)`；domain-fill 口述原文；Set 聯集 → 陣列不重複追加、保留順序 |
| 2 | RolesAssigned | ask | Q：RolesAssigned 是否影響 permissions？ | payload `roles: [String]`；aggregate 只改 roles |

5b. 問 ask 列（上節）。
5c. 把回答換成程式碼（no-op → 標記；skip → 保留 stub），重印審閱表與將寫入的 diff，用 `AskUserQuestion` 一題確認整表：options「照表寫入」「全部 skip（不寫）」；逐列修改用 Other（`#列號：改法`，改法可為 skip / no-op / 口述）。改過只重印變動列再確認，直到「照表寫入」。

只有 mechanical / aggregate-id 列（沒有 reuse / ask）→ 不問，直接寫。

## Phase 6 — 一次寫入 + provenance

- 整表確認後一次寫入：每個要填的方法，把整段 stub（`// TODO(Phase 1.g)` 註解 + 兩個 placeholder）換成 body，行序：mechanical → aggregate-id → reuse / ask → no-op 標記。skip / manual 的方法不動。
- 每個非 mechanical 的決定（reuse 確認、ask 回答含 no-op 與 skip、口述）append 一列到 `docs/readmodel-mutation-provenance.md`；檔案不存在就用 Write 建立。格式比照 domain-fill provenance（多行 Swift 用 `<br>` 接）：

```markdown
# readmodel-mutation provenance

/readmodel-mutation 非 mechanical 決定的來源紀錄。mechanical 與 aggregate-id（確定性規則）不在此列。

| presenter:when(event):欄位 | 類別 | 依據（沿用的 aggregate 片段 / 人回答原文） | 填入 Swift |
|---|---|---|---|
```

## Phase 7 — 報表 + exit code

每方法一行：`filled <E> (<類別>)` / `no-op <E> (<理由>)` / `skipped <E> (user)` / `manual <E> (<原因>)` / `skipped <E> (already filled)`；另列提問題數、provenance 新增列數，並提醒 `swift build` 驗 emitted body 對 plugin 產的事件型別。

| exit | 意義 |
|---|---|
| exit 0 | 每個方法都有結果：填入、no-op、使用者明確 skip、manual 留空殼並說明原因、或原本已填（全部列在報表） |
| exit 1 | 前置缺：arg 空、presenter / ReadModel / event.yaml 找不到 |
| exit 3 | 未填方法全部是 manual，沒有任何可做（什麼都沒寫，報表說明每個原因） |
| exit 4 | 同名 presenter 多處；或偵測到半填（寫入前，什麼都不寫） |

## Framework constraints / 與其他 skills 的關係

- `ReadModelType` 由 projector typealias 推導；event payload struct 由 plugin 從 event.yaml 生成；`package` access modifier 與既有 imports（`DDDCore`、`EventSourcing`、`KurrentSupport`、`{Ctx}Shared`）不動。
- 上游：`/readmodel` + `/presenter` + `genesis new`（Phase 1.g + 1.k.2 projector scaffold）。寫入端語意來自 `/domain-fill`（或 codegen 的 strict-safe reducer）：reuse 讓同一件事不必問兩次。
- sibling：`/api`（write-side fill）/ `/presenter-fill`（read-side AS fill）。與 `/domain-fill` 的差別：domain-fill 只轉寫人口述、不提案；本 skill 的提案只來自已確認的寫入端語意或確定性規則，增減語意不明時一律問人。
- 不重疊：projector 的 type signature / framework wiring（1.g 範疇）；ReadModel.swift 結構（`/readmodel` 範疇）。
