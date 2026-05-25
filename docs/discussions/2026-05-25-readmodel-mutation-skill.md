# /readmodel-mutation v2 skill — facts + 待決策（2026-05-25）

## 任務定位

Phase 1.g `ReadModelRenderer.renderWhenMethods` 對每個 readModel.events[] entry emit 一個 stub `when()`：

```swift
package func when(readModel: inout ReadModelType, event: {EventTypeName}) throws {
    // TODO(Phase 1.g): mutation logic not yet codegen'd. Hand-fill below, or wait
    // for /readmodel-mutation v2 skill. ...
    _ = readModel
    _ = event
}
```

→ user 必須手填「event 來了 readModel 怎麼變」。沒填 = readModel 永遠不更新 = read endpoint 拉到空。

`/readmodel-mutation` v2 補完此填空。

## Facts gathered

### F1. OC `when()` body patterns（80% 涵蓋的 5 大類）

| pattern | 範例 |
|---|---|
| **set scalar** | `readModel.fontSize = event.fontSize` |
| **set 多 field（anchor）** | `readModel.quotingCaseGroupingId = event.quotingCaseGroupingId` |
| **append struct entry** | `readModel.contractNotes.append(.init(noteId: event.noteId, uniqueCode: nil, traits: [], quotingCaseIds: [], note: event.note))` |
| **removeAll by predicate** | `readModel.contractNotes.removeAll { $0.noteId == event.noteId }` |
| **updateAt by id** | `guard let i = readModel.X.firstIndex(where: { $0.id == event.id }) else { return }; readModel.X[i].field = event.field` |

複雜 pattern（reorder via Dictionary + compactMap、insert-at-position with fallback）→ 屬 domain 特殊邏輯，v1 留 manual。

### F2. Genesis 端 stub 與 placeholder

`Sources/GenesisCore/ReadModelRenderer.swift` 的 `renderWhenMethods` 對每 event emit 上述 `_ = readModel; _ = event;` stub，註解明白指向 `/readmodel-mutation v2 skill`。
template `Presenter.swift.template` 有 `{WhenMethods}` placeholder。

### F3. 既有 fill-skill 模式（/api、/presenter-fill）已 proven

兩個前例都是 **in-place SKILL.md fill**：讀 scaffold + 用 AI 邏輯填 Swift body + structural-invariant 判 idempotent。≤200 LoC SKILL.md，無 DSL 設計開銷。

### F4. 「bundle-writing」模式（/readmodel、/presenter）

/readmodel 用 AskUserQuestion 寫 `bundle.readModels[]`；/presenter 寫 `bundle.presenters[]`。**design-time** 結構決策（哪些 event、哪些 storedField）→ bundle JSON → codegen。

## 待決策（gating）

### D1：v1 走 in-place fill 還是 bundle-writing？

**A. in-place fill（/presenter-fill sibling，建議）**

- skill 對指定的 `Sources/<A>Aggregate/Usecase/Projector/<Name>/<Name>Presenter.swift`，逐個 `when(readModel: inout R, event: E)` 方法填 body。
- AI 用 readModel.storedFields 型別 + event payload 型別 + 5 大 pattern 選法填。
- scaffold-once + structural-invariant 判 idempotent（含 `_ = readModel; _ = event;` placeholder 視為「未填」、含 readModel mutation 語句視為「已填」）。
- **Pros**：simpler scope（無 bundle schema 改、無 renderer 改）；與 /api、/presenter-fill 對稱；mutation 是 code-level 邏輯，本來就是 Swift 寫 Swift，不需 DSL 中間層；複雜 case AI 可彈性處理。
- **Cons**：source of truth 在 Swift（非 bundle）→ 重 `genesis new` 不會自動同步（但 scaffold-once 本就 protect existing fills）；bundle JSON 不含 mutation 規則（git history 看 mutation 變化要看 Swift）。

**B. bundle-writing（design-time DSL）**

- skill 互動詢問 user「event X 來了，readModel 哪個 field 怎麼變？」→ 寫進 `readModel.events[].mutation: {kind, ...}`。
- 擴 `ReadModelRenderer.renderWhenMethods` 讀此 DSL emit `when()` body。
- DSL covers 5 大 pattern（set/append/removeAll/updateAt/assignList）；超出 → fallback to manual hand-fill TODO。
- **Pros**：source of truth in bundle（與 /readmodel、/presenter 對稱）；重 `genesis new` regen 一致；mutation 規則明文化（自我描述）。
- **Cons**：scope 大很多（bundle schema 改 + renderer 改 + DSL 設計）；複雜 case fall back manual 反正還是要寫 Swift；user 寫的 DSL 跟最後生出來的 Swift 之間多一層轉譯，debug 變難。

### D2（小）：scope to ALL events or per-readModel?

無論 D1 選 A or B：

- **per-Presenter（建議）**：`/readmodel-mutation <PresenterName>` 一次填一個 presenter 的所有 when() body。對齊 /presenter-fill 的 per-presenter 模式。
- per-event：`/readmodel-mutation <PresenterName> <EventName>` 一次一個 method。粒度小但 user 要多次呼叫。

### D3：哪些 pattern 真的要 cover？

v1 必含 set scalar / append struct / removeAll predicate / updateAt by id。assignList 視範圍。reorder / insert-at-pos 一律 defer manual（hand-edit Swift）。

## 我的傾向

**D1 = A（in-place fill，與 /presenter-fill sibling）**。理由：

1. Mutation 是 implementation logic，不是 design-time 結構決策。bundle 該保存「哪些 event、哪些 stored field」（已 by /readmodel），mutation 屬於 Swift 寫法。
2. /api 和 /presenter-fill 已驗證此模式有效；走第三個 in-place fill 一致 + 維護便宜。
3. 複雜 case（reorder via Dictionary）DSL 不可能涵蓋 → fall back manual；AI 直填 Swift 反而更彈性。
4. scope 小：一個新 SKILL.md ≤200 LoC + 5 pattern 規則描述 + fixture + e2e。比 bundle-writing 路徑省一半工作。
5. 對 user 來說 mental model 簡單：所有 "fill" 都看 Swift body，不會有「為什麼 mutation 在 bundle 但其他 body 在 Swift」的不對稱。

但你之前提到「bundle schema extension + Phase 1.g renderer 連動」的描述偏 B，所以我先問你確認。

---

## 決策（user 2026-05-25）

- **D1 = A in-place fill**（與 /api、/presenter-fill 一致模式）。
- D2 = per-Presenter（一次填一個 presenter 的所有 when() body）。
- D3 = v1 cover 5 patterns（set scalar、set 多 field、append struct、removeAll predicate、updateAt by id）；reorder/insert-at-pos 留 manual hand-edit。

## v1 scope（locked）

1. SKILL.md ≤200 LoC，sibling to /presenter-fill；in-place edit Presenter.swift `when(readModel: inout R, event: E)` body。
2. Locate Presenter：per-agg `Sources/<A>Aggregate/Usecase/Projector/<Name>/<Name>Presenter.swift` 或 context-level `Sources/<contextName>/Projector/<Name>/<Name>Presenter.swift`（Phase 1.k.2 後 cross-agg projector 也在 context module）。
3. 5 patterns + heuristic：依 event name 命名（Created/Added/Removed/Updated/Edited/Reordered…）+ payload fields vs readModel storedFields 型別配對推測 pattern。AI 用 5 pattern sample 作 template、依 context substitute。
4. idempotent **per-method**（granular，非 whole-file）：each `when()` body 是否含 `_ = readModel; _ = event;` placeholder 視為未填、含 mutation 語句視為已填、半填 → exit 4。
5. exit codes 對齊 /presenter-fill：0 success；1 prerequisite missing；3 out-of-scope（無 5-pattern 對應、複雜 reorder 需 manual）；4 corrupted / half-filled。
6. real e2e：用 `iam-readmodel-bundle.json`（per-agg readModel + 2 events `userAccessProfileCreated`+`rolesAssigned`） → genesis new → /readmodel-mutation 填 → swift build PASS（projector compile-pass，含真實 mutation logic）。
