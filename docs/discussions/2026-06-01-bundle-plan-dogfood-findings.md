# /bundle-plan skill — Dogfood findings（2026-06-01，首次執行）

第一次實跑 Phase 1.r 的 `/bundle-plan` skill（手動照 SKILL.md 執行，dogfood）。bundle = 乾淨的 `Cosmogony IAMContext.json`、generated project = `/tmp/genesis-iam-final/`。

findings 累積在此，dogfood 跑完一次撿起來改 `Sources/GenesisCore/Resources/Templates/skills/bundle-plan/SKILL.md`（+ 必要時 Phase 1.r spec / registry）。

---

## F1 — §5 Error Cases 應從 method-X 改機械（invariant 是 aggregate-wide）

**現況 SKILL.md（Phase 4）**：§5 error cases 列為「LLM 依 §3 invariants 推一版 → user 逐 UC 確認」（method X 互動）。

**finding**：錯估了 invariant model。OC `AuditQuoting.ensureInvariant()` 證實 — invariant 是 **aggregate 守護的不變量**，`ensureInvariant()` 把**全部** invariant check 一次跑，且**每次 mutation 後都呼叫**（非 per-UC 挑選）。每個 check 內部自己有 state guard 可能 early-return no-op，但全部都被呼叫。

**正確 model**：
- 每個 write UC 的 §5 = aggregate 的**全部** invariant（與 §3 同源，機械）
- 唯一 per-UC 差異 = `aggregateNotFound`：update/delete UC（走 `repository.find`）會 throw；create UC 不會。靠 useCase prefix（create/establish）機械判定。

**要改**：
- SKILL.md Phase 4：§5 從「LLM 推 + 逐 UC 確認」降級成**機械產出**（全 invariant + create/update 決定 aggregateNotFound）。只有 §6 Gherkin 留 method-X（LLM 推 + user 確認）。
- 連帶：Phase 4 標題/描述（「method X §5/§6」）改成「§6 method X；§5 機械」。
- spec MD（2026-06-01-phase-1r）對應段落同步。

**含意**：Phase 4 互動量大減（§5 不再逐 UC 問），只剩 §6 Gherkin 要逐 UC 過。

**之前我犯的錯（記錄供對照）**：dogfood 時我一度建議「grantPrivilege 拿掉 userIdNotExist 因 update 時 user 已存在」— 錯。user 指正：invariant 每次變更全檢，不是 per-UC 子集。

---

## F2（minor note，非設計缺陷）— §6 Gherkin behavior-level 與 §2 business input 分層

§6 Gherkin 寫 behavior-level（提 operator + aggId `userAccessProfileId`，因為那是 API 真實樣子），跟 §2 Bundle Reference（純 business input）刻意分層。codegen 注入 operatorId + aggId，所以 Gherkin 自然會提到它們。

**處理**：不是 finding/bug。只在 SKILL.md Phase 4 §6 段**補一句註記**「Gherkin 寫 behavior-level（含 operator + aggId），與 §2 business input 分層，此落差刻意」。低優先。

---

## 非 finding — F3 / F4（dogfood 流程造成，非 skill 缺陷，不記）

dogfood 當下一度列了 F3（§6 Examples 是 placeholder 值 `v-userId`/`["p1"]`）+ F4（§6 error scenario 的 Given 太抽象，中文 invariant title 直接塞 Gherkin）。**經 review 判定兩者都不是 skill 缺陷**：

- method-X 設計就是「LLM 推一版 → user 逐 UC 確認時補真值 / 改具體 Given」。
- 本次 dogfood 跑 (ii) 批次模式、跳過逐 UC §6 確認 → 所以 Examples 停在 placeholder、Given 停在抽象。
- 真實合法值 + 具體 Given **本來就是 user 在 §6 確認步驟補的** → 跳過確認才會空泛。

→ F3/F4 描述的是「確認步驟被跳過」的後果，不是 skill 設計問題。**不記成 finding**，避免誤導之後改 SKILL.md 的判斷。教訓：dogfood 抄捷徑造成的產出品質落差，別當成 skill bug。

---

## 撿起來要做的（#57 範圍 — 縮減後）✅ DONE 2026-06-01

只剩 2 項，已全部套用：
1. **F1** ✅：SKILL.md Phase 4 — §5 從 method-X 改機械（aggregate-wide invariant + create/update 決定 aggregateNotFound，含 ensureInvariant 註解）；Phase 4 標題改「§5 機械 + §6 method-X」；Phase 5 template §5 行對齊；Phase 1.r spec MD 同步。
2. **F2** ✅：SKILL.md Phase 4 §6 補 behavior-level 分層註記（含 operator + aggId，與 §2 business input 分層）+ Phase 1.r spec MD 同步。

verification greps 仍全 PASS、swift build PASS。

<!-- 後續 findings append 在下面 -->
