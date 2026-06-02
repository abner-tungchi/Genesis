---
topic: "when reducer fill — 新 skill vs 擴增既有 skill（read-side Dto-convert + write-side append-factory/config-replace）"
status: consensus
created: "2026-06-02"
updated: "2026-06-02"
participants:
  - Claude (Opus 4.8)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 2
mode: default
meta_note: |
  Codex async wrapper bug：R1 派出後回「task running in background」未返回實際分析（output 檔僅命令 log）。R2 共識標 agreed-pending-Codex。決定性論點（config-replace 不可機械化）由 Claude 親自 spot-verify OC 檔坐實，非靠 Codex 第三方，故 reframe 為證據強制。
premises:
  fixed:        # evidence-backed（OC survey + spot-verify，不可挑戰）
    - "OC AuditQuotingAggregate 69 個 when（51 write Entity-command + 18 read projector）survey + spot-verify：~75% 是機械 pattern、~12-15% 真·跨欄位 domain logic、~3% rename。"
    - "read-side 主導 pattern = Dto-convert：`readModel.x = <T>Dto(from: event.x)`（IndustrialType/AccountingType/CustomerEstablishmentStatus 全同形）。/readmodel-mutation 現有 5 pattern 不含它 → 這是 GetPermissions exit-3 的根因。"
    - "write-side 三型：scalar（~22%，D5 codegen 已做）/ append-factory `self.col.append(ServiceItem.standard(...))`（~18%）/ config-replace template `guard serviceItem→configs.removeAll(key)→configs.append(.init(key,.Xvalue(event.f)))`（~27%，gemini 數 ~14 個一模一樣）。後兩型 D5 目前 fatalError、無 skill。"
    - "真·人手寫（~12-15%，集中）：PriceServiceItems / RemoveTaxComplianceAudit cascade / *WithFilingMethodAdjustment adders / PredecessorAuditor fan-out。"
    - "既有 fill skill 模型：codegen 出 stub，skill in-place fill body（/usecase execute、/api AS、/readmodel-mutation read-side when、/presenter-fill read AS）。D5 是例外（write-side when 在 codegen 時就填 scalar / fatalError）。"
    - "Gemini 前討論警告：reducer 猜錯 = replay silent state corruption（比沒填更糟）。"
  proposed:     # challengeable
    - "write-side when-fill 應為「新 skill（write-side 對稱於 /readmodel-mutation）」而非擴 /readmodel-mutation（read-side、改名會說謊）或純 codegen（config-replace 需 config-key 推斷，codegen 一次性無 idempotency）。"
    - "read-side Dto-convert 應「擴 /readmodel-mutation 第 6 pattern」。"
    - "為一致性，把 D5 的 codegen-time scalar when 移到 skill（codegen 改出 stub），所有 when-fill 集中在 skill。"
---

# when reducer fill — 新 skill vs 擴增既有 skill

## 議題定義

### 背景
full skill-run dogfood + OC survey 發現:Genesis 的 `when` reducer（write-side Entity command + read-side projector）大多數（~75%）是機械 pattern，但目前 read-side `/readmodel-mutation` 缺 Dto-convert pattern（→ GetPermissions exit-3）、write-side 完全無 when-fill skill（D5 只 codegen scalar、其餘 fatalError）。要把可機械化的部分補上,對齊 OC 的可 fill 程度。

### 目標
定出:(1) write-side when-fill 是新 skill 還是擴既有 + 哪個;(2) read-side Dto-convert 擴 /readmodel-mutation 確認;(3) codegen vs skill 邊界 + D5 reconciliation;(4) pattern 集合 + human 邊界;(5) silent-corruption 防治。

### 範圍
- 討論內:when reducer fill 的 skill 架構（新 vs 擴）+ pattern 集合 + 邊界。
- 討論外:bundle schema、其他 fill skill 行為（除非 reconcile D5）、真·human ~12% 的 domain logic（維持手寫）。

### 子議題
- [ ] C1：**write-side when-fill = 新 skill vs 擴既有（/readmodel-mutation? /usecase?）vs 純 codegen?**（user 點名的核心）
- [ ] C2：read-side Dto-convert = 擴 /readmodel-mutation 第 6 pattern?
- [ ] C3：codegen-time vs skill-time + D5（codegen scalar）reconciliation（移到 skill 統一?）
- [ ] C4：pattern 集合（scalar / append-factory / config-replace / Dto-convert）+ human 邊界（~12% 怎麼 mark）
- [ ] C5：silent-corruption 防治（猜錯 reducer 的風險;idempotency / fatalError 保守 / confirm）

---

## 討論紀錄

### Round 1

#### Claude (Opus 4.8)

**總立場:write-side 開新 skill（對稱 /readmodel-mutation）、read-side 擴 /readmodel-mutation、D5 codegen scalar 移到新 skill 統一。理由是「對稱性 + 既有 fill 模型 + 可擴展性」。**

- **C1（核心:新 vs 擴）→ 新 skill**。理由:(1) **layer/scope**:write-side when 在 `Entity/Commands/`，read-side when 在 `Projector/`，是不同 aggregate 層;擴 `/readmodel-mutation`（名字明指 read）去填 write-side Entity 會 scope 說謊。(2) **對稱**:`/readmodel-mutation` 已是「read-side projector when fill」;write-side 該有對稱的「entity command when fill」（命名如 `/reducer` 或 `/command-mutation`）。(3) **不擴 /usecase**:/usecase 明文「不動 Entity/Command」，職責是 orchestration;塞 when-fill 進去違反其單一職責。(4) **不純 codegen**:append-factory（需 ServiceItem factory 形狀）+ config-replace（需 config-key↔event-field 推斷）比 scalar 重，且 codegen 一次性、無 idempotency/重跑;既有模型是「codegen stub + skill fill body」，when body 該循此。

- **C2（read-side Dto-convert）→ 擴 /readmodel-mutation 第 6 pattern**。Dto-convert（`readModel.x = <T>Dto(from: event.x)` 當 readModel 欄位型別是 `<T>Dto`）是 read-side 主導 case，純擴 /readmodel-mutation 既有 5-pattern 架構,零新檔。直接解 GetPermissions exit-3。

- **C3（codegen vs skill + D5 reconcile）→ when body 一律 skill-fill，codegen 改出 stub，D5 codegen scalar 移到新 skill**。一致性:每個 body（usecase/api/read when）都是 codegen-stub + skill-fill;D5 在 codegen 時填 scalar 是例外。新 write-side when skill 接管全部 when pattern（scalar + append-factory + config-replace），codegen 的 CommandExtension when 改回 honest stub（fatalError obligation）。這樣 when-fill 邏輯集中一處、可重跑、可擴。

- **C4（pattern + 邊界）**:新 write-side skill 的 pattern = scalar / append-factory（偵測 `self.<col>.append(<Factory>.<case>(...))` 形狀，col 是 collection state + event payload ⊇ factory args）/ config-replace（偵測 event 有 `<x>Id` locator + 單一 value field → guard+removeAll(key)+append）。**human 邊界**:多步/跨欄位/條件 → fatalError obligation（~12%，如 PriceServiceItems）。config-key↔event-field 的 mapping 若無法從命名推 → fatalError（保守）。

- **C5（silent-corruption 防治）**:沿用 Gemini 哲學 + /readmodel-mutation 既有 idempotency:(1) pattern 偵測不確定 → **fatalError obligation 而非猜**（replay crash 勝 silent corruption）;(2) 半填偵測 → exit 4;(3) 不靠「同名」單一信號,要型別 + collection-shape + factory-availability 多重確認才生。

**Evidence**:OC survey（本檔 fixed premises）;`/readmodel-mutation` SKILL.md（5-pattern 架構 + idempotency）;`AuditQuoting+EditDomesticTransferCount.swift`（config-replace template ×14 同形）;`AuditQuoting+AddAccounting.swift`（append-factory）;`GetIndustrialTypePresenter.swift`（Dto-convert）;Phase 1.t D5（codegen scalar when）。

**待 Codex / Gemini R1**:(i) C1 新 skill vs 擴...(ii) C3 D5 移 skill...(iii) config-replace 推斷可靠度...(iv) silent-corruption 保守度。

#### Codex (GPT-5.4)

⚠️ **未取得**:Codex 派至 `codex:codex-rescue` 後回「task running in background」（async wrapper bug，同前幾輪），output 檔僅有命令 log（讀了一堆 OC/renderer 檔 + 「我已有結論方向，現在只補行號」），**未返回實際 R1 分析**。per discuss tool-failure 透明度規則記此，不美化。下方 R2 對「config-replace mechanizability」「D5 reconcile」標：**Gemini 主張經 Claude 親自 spot-verify 坐實，非靠 Codex 第三方**。

#### Gemini

**淨立場 + REFRAME:軸不是「read-skill vs write-skill 對稱」，是「mechanizability-by-type-closure」—— 只在型別系統可閉合證明對應時才填，否則 fatalError（不論 read/write）。** read-side 剛好幾乎都能（Dto-convert/scalar）、write-side config-replace 剛好不能 → 結果看似不對稱、底層規則統一。

1. **config-replace 不可機械化（spot-verify hard veto，Claude 已親自複驗）**:config-key、event-field-name、value-wrapper 三者都無命名信號:
   - key ≠ event 名:`AccountBalanceDetailReportNeedEdited` → key `.standardReportingNeedsAccountBalanceDetailReport`（多 `standardReporting` domain prefix）。
   - value-wrapper 無信號:`.intValue`/`.stringValue(event.x.rawValue)`/`.boolValue`/`.dateValue(Date(timeIntervalSince1970:))` 沒有命名能導（`EditBusinessTaxFilingMethod` 要 `.rawValue`、`EditServiceItemStartDate` 要 Date 包裝）。
   - guard predicate shape 變異:`EditServiceItemStartDate` 多一條 `&& $0.workItemType == event.workItemType` + append 多 arg。
   → 機械化 = 猜 = silent corruption（user C4 風險的具體實例:`EditServiceItemStartDate` 表面跟 `EditDomesticTransferCount` 一模一樣只差一條 clause）。
2. **「~75% template」是 surface-shape 統計非 mechanizability**:config-replace 27% 是「偽 template」（每個含 key/wrapper/predicate 三個 human decision）。真正型別可閉合的只有 scalar 同名同型 + Dto-convert + append-factory(exact)。
3. **連 scalar 都有 name divergence**:`SalesEinvoiceUsageEdited` → `self.useSalesEinvoice = event.useEinvoice`。D5 現用同名查找 → 正確 fall through fatalError（D5 保守設計在此是對的）。
4. **write-side replay 猜錯 > read-side 一個量級**:read model 可 rebuild;write entity when 改的是 event 還原的 aggregate state → 餵 invariant + 下個 command → 生錯 event 進 **immutable** event store。保守度 write 必須更高。
5. **risks**:append-factory 的 payload-missing-field（factory args 須 ⊆ payload exact 否則 fatalError）;write-side 半填 = silent data loss（須 atomic emit-or-nothing）;75%/27% 統計來自**單一** aggregate（config-bag 是 OC 特有設計，非 Genesis 通用先驗）。

**C1-C5**:C1 → **都不開**（config-replace 不可機械 → 新 write skill 主 payload 空，剩 scalar〔已 codegen〕+ append-factory 撐不起;擴 /readmodel-mutation 成跨 read+write 更糟〔焊死兩軸〕）/ C2 → **擴 /readmodel-mutation Dto-convert 第 6 pattern**（型別可閉合，agree）/ C3 → **不撤 D5**（codegen 是 deterministic 正確分層，撤=拿可重現換整齊）/ C4 → **allowlist 非 denylist**（只在型別可證明時填，config-replace 全 fatalError）/ C5 → type-closure allowlist + write 比 read 再保守一級。

---

### Round 2 — Synthesis（Claude facilitator）

**收斂:採 Gemini 的 type-closure reframe。淨結果遠小於我 R1 —— 只做一件事:擴 /readmodel-mutation 加 Dto-convert pattern。write-side 不開新 skill、不撤 D5。**

我 R1 主張「write-side 開新 skill（對稱 /readmodel-mutation）+ 移 D5 scalar」是**被證據推翻**:Gemini spot-verify（我親自複驗）證 config-replace（write-side 機械 payload 的大宗 27%）**不可靠機械化** —— key/wrapper/predicate 三者皆無命名信號，機械化 = silent corruption（write-side 還污染 immutable event store）。扣掉 config-replace，write-side 機械只剩 scalar（已 D5 codegen）+ append-factory（OC-specific + payload-missing 風險），撐不起一個新 skill。

**Rejection log（HARD）**:
- ❌ **我 R1「write-side 開新 skill」**:拒絕。config-replace 不可機械（Gemini veto + Claude 複驗），新 skill 主 payload 空。
- ❌ **我 R1「D5 codegen scalar 移到 skill（一致性）」**:拒絕。Gemini 對 —— 「一致性」是美學，codegen 是 deterministic syntactic fill 的正確分層;撤回已 ship+驗的 D5 是拿可重現性換整齊。
- ❌ **我 R1「C4 denylist（排多步即機械填）」**:拒絕。會把 config-replace 偽 template 誤判成可填 → silent corruption。改 **allowlist（型別可閉合才填）**。
- ❌ **「擴 /readmodel-mutation 成泛 read+write when-fill」**:拒絕（Gemini）。焊死兩個本可獨立演化的軸（read `inout` value vs write reference-aggregate mutation、兩套 idempotency/exit）。

**部分採納（modify）**:
- 🟡 **append-factory（write-side ~18%）**:Gemini 標「條件安全」。採納為 **暫不做**（OC-specific ServiceItem factory + payload-missing 風險 + 單 aggregate 統計）。維持 D5 fatalError obligation;未來若多 aggregate 證明通用再議。
- 🟡 **C2 Dto-convert**:採納為**唯一 actionable** —— /readmodel-mutation 第 6 pattern，型別可閉合（readModel 欄位型別 `<T>Dto` + Dto 有 `init(from:<DomainT>)` + event 同名 `<DomainT>` field）。

**收斂決定（待 lock）**:
1. **D1 reframe**:fill 原則 = mechanizability-by-type-closure（型別可證明對應才機械填，否則 honest fatalError），取代「read/write 對稱」框架。
2. **D2**:擴 `/readmodel-mutation` 加 **Dto-convert（第 6 pattern）**:readModel 欄位型別為 `<X>Dto`（有 `init(from:)`）且 event 有對應 domain field → `readModel.<f> = <X>Dto(from: event.<g>)`。解 GetPermissions exit-3 + read-side 主流。**唯一要實作的。**
3. **D3**:**不開** write-side when-fill skill。config-replace + append-factory + ~12% 跨欄位 → honest fatalError obligation（人手寫，對齊 OC）。
4. **D4**:**不撤 D5** codegen scalar。
5. **D5(decision)**:write-side reducer 若未來要機械化,須 type-closure allowlist + atomic emit-or-nothing + 比 read 更保守（污染 immutable event store）。本輪不做。

---

## 共識看板（R2 後）

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| C1 | write-side when-fill 新 vs 擴 vs codegen | R2 改：**都不開** | （未返回）| 都不開 | **agreed-pending-Codex**（config-replace 不可機械，spot-verify 坐實）|
| C2 | read-side Dto-convert | 擴 /readmodel-mutation 第 6 pattern | （未返回）| 同 | **agreed-pending-Codex**（型別可閉合）|
| C3 | D5 reconcile | R2 改：**不撤 D5** | （未返回）| 不撤 | **agreed-pending-Codex** |
| C4 | pattern + 邊界 | R2 改：**allowlist（型別可閉合）** | （未返回）| allowlist | **agreed-pending-Codex**（denylist 會誤判 config-replace）|
| C5 | silent-corruption | type-closure + write 更保守 | （未返回）| 同 + immutable event store 污染 | **agreed-pending-Codex** |
| C6* | **reframe: mechanizability-by-type-closure** | 採納 | （未返回）| 提出 | **agreed-pending-Codex** |

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D1 | **fill 原則 = mechanizability-by-type-closure**（型別可證明對應才機械填，否則 honest fatalError）；取代「read/write 對稱」框架 | 2026-06-02 | R2 | Gemini reframe；Claude 採納 |
| D2 | **擴 `/readmodel-mutation` 加 Dto-convert（第 6 pattern）**：readModel 欄位型別 `<X>Dto`（有 `init(from:)`）+ event 對應 domain field → `readModel.<f> = <X>Dto(from: event.<g>)`。**唯一要實作的。** 解 GetPermissions exit-3 | 2026-06-02 | R2 | 型別可閉合 |
| D3 | **不開** write-side when-fill skill；config-replace + append-factory + ~12% 跨欄位 = honest fatalError obligation（人手寫，對齊 OC）| 2026-06-02 | R2 | config-replace 不可機械（spot-verify）|
| D4 | **不撤回 D5** codegen scalar（codegen 是 deterministic syntactic fill 正確分層）| 2026-06-02 | R2 | 撤 Claude R1 提案 |
| D5 | write-side reducer 未來若機械化 → type-closure allowlist + atomic emit-or-nothing + 比 read 更保守（污染 immutable event store）；本輪不做 | 2026-06-02 | R2 | append-factory 暫不做（OC-specific + 單 aggregate 統計）|

---

## 開放問題

1. **[未驗-Codex]** Codex async 未返回 → C1-C6 標 agreed-pending-Codex。但 config-replace mechanizability（決定性論點）已由 Claude 親自 spot-verify（非靠 Codex），reframe 為證據強制非純共識。
2. **[未來]** append-factory（write-side ~18%）+ Dto-convert 是否該推到其他 fill 層 —— 待多 aggregate 樣本（OC config-bag 是單一 aggregate 特性，非通用先驗）。

---

## 下次討論指引

### 進度摘要
**R2 收斂（採 Gemini type-closure reframe）。** 淨結果遠小於 Claude R1:**唯一 actionable = 擴 /readmodel-mutation 加 Dto-convert（D2）**。write-side 不開新 skill（config-replace 不可機械,spot-verify 坐實）、不撤 D5。Codex async 未返回（記 tool-failure;決定性論點已 Claude 複驗）。下一步 write-spec（/readmodel-mutation Dto-convert 擴充）。

### 待處理事項
write-spec:/readmodel-mutation 第 6 pattern（Dto-convert）。spec 階段定偵測信號（readModel 欄位型別 `<X>Dto` + `init(from:)` 存在 + event domain field 對應）+ 邊界（推不準 → 維持 exit-3）。

### 閱讀建議
- 本檔 R1（Gemini）+ R2 + 決策 D1-D5
- `/readmodel-mutation` SKILL.md（5-pattern 架構，加第 6）
- OC `Usecase/Projector/GetIndustrialType/GetIndustrialTypePresenter.swift`（Dto-convert ground truth）

### 注意事項
type-closure allowlist 原則:只在型別系統可證明對應時機械填。config-replace 偽 template 是 denylist 的反例。
