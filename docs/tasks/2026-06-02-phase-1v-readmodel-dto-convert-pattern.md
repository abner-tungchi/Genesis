# Phase 1.v — /readmodel-mutation Dto-convert pattern（A2）

## 來源

討論：`docs/discussions/2026-06-02-domain-scaffold-emitter.md`（A2）+ `docs/discussions/2026-06-02-when-reducer-fill-skill.md`（D2，locked 兩次）。type-closure-provable read-side reducer pattern。

## 目標

`/readmodel-mutation` SKILL.md 加第 6 pattern **Dto-convert**：當 read model 欄位型別是某 `<X>Dto`（enum/value DTO，宣告單參數 `init(from: <D>)`）且訂閱 event 帶 `<D>` 型別欄位 → 機械 emit `readModel.<field> = <X>Dto(from: event.<g>)`。這是 OC read-side reducer 的大宗形狀（IndustrialType / AccountingType / CustomerEstablishmentStatus…），型別系統可閉合證明對應 → 安全機械填（D1 mechanizability-by-type-closure）。

**邊界修正（important）**：A2 **不** 解 IAM GetPermissions exit-3。`PermissionDto` 是 memberwise `{userId, permissions}`、**無** `init(from:)`，且 GetPermissions 訂閱 grant/revoke 等**語意不同**的 event（grant=加、revoke=移除）→ 是 domain 語意非型別轉換 → 不在 A2 範圍，留 human/A5。A2 只 match「單一 domain value 經 `init(from:)` 包成 Dto」的 type-closure case。

## 介面合約

### 第 6 pattern — Dto-convert（加進 `/readmodel-mutation` SKILL.md）

**安全 = conversion-closure ∧ replace-verb ∧ single-writer 三條件全成立才 match**（Codex audit HIGH：type-closure 是**必要非充分** —— 「`D → XDto` 轉換存在」不等於「這個 event 該覆寫此 field」;還需「此 event 語意是 replace」+「此 field 無其他衝突 writer」）。

**偵測（全部成立才 match，否則 → exit-3 / 其他 pattern）**：

A. **conversion-closure（必要）**：
   1. read model stored field 型別（去 `?`）是某 `<X>Dto`。
   2. grep `<X>Dto` 的 initializer **symbol**（範圍 `Usecase/Projector/**/*.swift` + `Adapter/Dto/**/*Dto*.swift`，含 `<X>Dto+Domain.swift` extension initializer;不要求 local type decl）。找到**唯一一個** non-throwing 單參數 `init(from <label>: <D>)`，且 `<D>` 精確命中下方 event payload field 型別。
   3. **overload 排除**：若 `<X>Dto` 有多個 `init(from:)`（如 schema + domain 兩個、或 `init(from decoder:) throws`）→ 除非能精確鎖定「型別 == event field type 且 non-throwing」的唯一一個，否則**不 match**（保守，留 human）。
   4. 訂閱 event 有**唯一**型別為 `<D>` 的 payload field `<g>`。

B. **replace-verb（充分條件 1，可執行白名單）**：當前 `when` 的 event 名 verb 在 **replace-safe 白名單** `Created | Set | Edited | Updated | Renamed`。若 verb 在 **delta 黑名單** `Granted | Revoked | Added | Removed | Deleted | Assigned`（delta/transition 語意，非 replace）→ **不 match**（force exit-3）。

C. **single-writer（充分條件 2，projector-wide）**：先建 **projector-wide candidate map**（掃同 presenter 所有 `when`）;若**同一 `<field>` 有多個 event 寫它**（如 `GetPermissions.permissionDto` 掛 grant/revoke/assign…）→ 該 field 一律**不 match** Dto-convert（多語意 writer = domain，留 human）。僅當該 field 由**單一** replace-verb event 寫才 match。

**emit（三條件全過）**：
```swift
        readModel.<field> = <X>Dto(from: event.<g>)
```

**不 match（→ 既有「無 pattern → exit 3」/ 其他 pattern）**：
- memberwise struct 無 `init(from:)`（如 `PermissionDto`）。
- 多 `init(from:)` overload 無法精確鎖定 / throwing init。
- delta-verb event（grant/revoke/add/remove…）。
- 同 field 多 event writer（projector-wide conflict，如 GetPermissions）。

**優先級**：Dto-convert 判定置於 **set anchor 與 set scalar 之前**（field 型別為 `<X>Dto` 時 scalar `self.x = event.x` 會型別不符;且需先於 anchor，因 anchor `Created` event 也可能設此 field —— 但 anchor 多 field 設定優先既有 anchor pattern）。collection（append/removeAll/updateAt/assignList）仍優先（針對 collection field）。

### type-closure 論證（必要非充分；為何加 verb + single-writer 才不 silent-corrupt）

conversion-closure（`<X>Dto.init(from: <D>)` 存在 + event 有 `<D>` field）證明的是「**可以轉型**」，**非**「**該賦值**」（Codex HIGH #3）。`GetPermissions.permissionDto` 示範:payload 帶相關型別 ≠ replace 語意（grant 加、revoke 移除）。故 A2 安全需三條件:conversion-closure（轉得出）**∧** replace-verb（語意是覆寫）**∧** single-writer（無其他 event 也寫此 field）。三者皆**可執行檢查**（型別 grep / verb 白黑名單 / projector-wide field-writer map），非 domain ontology 猜測 → 仍符 D1「型別/結構可證明才填」。OC ground truth：`IndustrialTypeDto(from: event.industrialType)`（`IndustrialTypeEdited` = Edited verb ✓ replace、`industrialType` field 單一 writer ✓、`IndustrialTypeDto` 單一 non-throwing `init(from: IndustrialType)` ✓）。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/Resources/Templates/skills/readmodel-mutation/SKILL.md` | 加第 6 pattern「Dto-convert」：Phase 3（parse readModel field 型別 + 找 `<X>Dto` 的 `init(from:)`）+ Phase 4 pattern priority/detection + emit template + 不-match 邊界（memberwise / grant-revoke / 多參數 → 不 match，留既有 exit-3）|

### 不需改
- 既有 5 pattern（set scalar / set anchor / append struct / removeAll / updateAt / assignList）邏輯不動。
- SkillInstaller / install-skills count（編輯既有 skill，非新增）。
- codegen / 其他 skill。

## 實作步驟

### Step 1：SKILL.md Phase 3（parse）補 Dto-convert 偵測輸入 + projector-wide field-writer map
1. parse readModel stored field 型別;對型別名以 `Dto` 結尾者，**grep symbol**（非 local decl）找其 initializer，範圍 `Usecase/Projector/**/*.swift` + `Adapter/Dto/**/*Dto*.swift`（含 `<X>Dto+Domain.swift` extension init）。鎖定**唯一** non-throwing 單參數 `init(from <label>: <D>)`;有多 overload 無法精確鎖定 → 標該 field「不可 Dto-convert」。
2. **建 projector-wide field-writer map**：掃當前 presenter 所有 `when(...event:)`，記每個 readModel field 被哪些 event 寫。供 single-writer 檢查。

### Step 2：SKILL.md Phase 4 加 Dto-convert pattern（可執行三條件）
1. pattern priority：Dto-convert 判定置於 **set anchor + set scalar 之前**（field 型別 `<X>Dto`）;collection patterns 仍優先。
2. 三條件（介面合約 A/B/C）逐一可執行檢查 → 全過才 emit `readModel.<field> = <X>Dto(from: event.<g>)`：
   - A conversion-closure（型別 + 唯一 non-throwing init(from:) + event 有 `<D>` field）。
   - B replace-verb 白名單 `Created|Set|Edited|Updated|Renamed`;delta 黑名單 `Granted|Revoked|Added|Removed|Deleted|Assigned` → exit-3。
   - C single-writer（projector-wide field-writer map：同 field 多 event writer → exit-3）。
3. **不-match 邊界**寫清楚（memberwise / overload / delta-verb / multi-writer）→ 落既有「無 pattern → exit 3」（human / A5）。
4. 補 OC ground-truth 例（IndustrialTypeDto，Edited + 單 writer）+ 反例（PermissionDto memberwise + grant/revoke multi-writer 不 match）。
5. **修既有「5 patterns」措辭漂移**：SKILL.md 開頭/描述若寫「5 patterns」→ 改「6 patterns」（Codex MED：加第 6 後編號需一致）。

### Step 3：verify
- SKILL.md grep（見驗收，含 ordering / verb 白黑名單 / single-writer / search-scope）。install-skills 確認 readmodel-mutation 仍正常安裝（內容變、count 不變）。

### Step 4：對齊 A2 討論文字
- `docs/discussions/2026-06-02-domain-scaffold-emitter.md` 的 A2「解 GetPermissions exit-3」與本 spec 非目標衝突（Codex MED）→ 改為「解 OC enum/value-Dto-convert reducer 大宗;GetPermissions（memberwise+grant/revoke）非 A2 範圍，留 A5」。

## 失敗路徑

| 條件 | 行為 |
|---|---|
| readModel field 是 `<X>Dto` 但找不到 `init(from:)` | 不 match → 落既有 pattern / exit-3（不猜 memberwise）|
| memberwise DTO（PermissionDto）| 不 match → exit-3（human/A5）|
| `<X>Dto` 多 `init(from:)` overload / throwing | 無法精確鎖定唯一 non-throwing 型別命中 → 不 match → exit-3 |
| delta-verb event（Granted/Revoked/Added/Removed/Deleted/Assigned）| 不 match → exit-3（非 replace 語意）|
| 同 field 多 event writer（projector-wide conflict）| 該 field 一律不 match → exit-3（domain 語意）|

## 不改動的部分
- 既有 5 pattern。
- codegen（A2 是 read-side fill skill 行為，非 codegen）。
- write-side command/when（Phase 1.u）。

### Non-goals（行為層）
- **不**解 GetPermissions exit-3（memberwise + grant/revoke multi-writer = domain，A5/human）。
- **不** match memberwise / 多 overload / throwing `init(from:)` / delta-verb event / 多 writer field（型別/結構/語意不可證明就不填）。
- **不**動既有 5 pattern 邏輯。
- **不**新增 skill（編輯既有 /readmodel-mutation）。

## 驗收標準

### Agent 必做（可機器執行）

```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
SK=Sources/GenesisCore/Resources/Templates/skills/readmodel-mutation/SKILL.md
# 第 6 pattern Dto-convert 存在 + emit 形狀
grep -q 'Dto-convert' "$SK"
grep -qE 'readModel\.<field> = <X>Dto\(from: event' "$SK"
# 三條件可執行（conversion-closure + replace-verb 白黑名單 + single-writer）
grep -qE 'Created.*Set.*Edited.*Updated.*Renamed' "$SK"          # replace-safe 白名單
grep -qE 'Granted.*Revoked.*Added.*Removed.*Deleted.*Assigned' "$SK"  # delta 黑名單
grep -qiE 'single-writer|projector-wide|多.*writer|field-writer' "$SK"
grep -qiE 'overload|non-throwing|唯一' "$SK"                      # overload 排除
grep -qiE 'Adapter/Dto|projector.*\*\*|\+Domain' "$SK"            # search scope
# 邊界：memberwise / multi-writer 不 match
grep -qiE 'memberwise|PermissionDto' "$SK"
# priority：Dto-convert 在 scalar/anchor 之前
grep -qiE 'anchor.*scalar.*之前|之前.*scalar|before.*scalar' "$SK"
# 「5 patterns」措辭漂移已修（不該再出現 5 patterns 指 pattern 數）
! grep -qE '5 ?patterns|5 個 pattern|五個 pattern' "$SK"
# install-skills 仍含 readmodel-mutation（count 不變）
TMPHOME=$(mktemp -d); HOME="$TMPHOME" swift run genesis install-skills 2>&1 | grep -q 'readmodel-mutation'
grep -q 'Dto-convert' "$TMPHOME/.claude/skills/readmodel-mutation/SKILL.md"
rm -rf "$TMPHOME"
swift build 2>&1 | tail -2
swift test 2>&1 | tail -3   # skill count tests 不變（編輯既有 skill）

# A2 討論文字已對齊（不再宣稱解 GetPermissions exit-3）
! grep -q '解 GetPermissions exit-3' docs/discussions/2026-06-02-domain-scaffold-emitter.md
```

### Human 補做
- [ ] 對一個 enum-Dto read model（如手造或未來 OC-like bundle 生成的 IndustrialType-style projector）跑 `/readmodel-mutation`，確認 Dto-convert 正確 emit `readModel.x = XDto(from: event.y)`。
- [ ] 確認 GetPermissions（memberwise + grant/revoke）**不**被 Dto-convert 誤 match（仍 exit-3 / 留 human）。

## 已知限制
- A2 只覆蓋 type-closure 的單值 Dto-convert;memberwise / 多語意 read model（GetPermissions）仍 human/A5。
- `/readmodel-mutation` 是 LLM-executed skill（markdown）;pattern 正確性靠 SKILL.md 描述 + LLM 遵循，非 Swift 編譯期保證（不像 codegen #error）。fill 後靠 `swift build` 驗型別。

### 依賴關係
- 軟相依：Phase 1.t/1.u（domain scaffold）。
- 後續：A5（intent-elicitation domain-fill skill，處理 memberwise/語意 case 如 GetPermissions）/ A4。
