---
topic: "6-step skill pipeline 整體可行性 + skill 邊界釐清"
status: consensus
created: "2026-05-13"
updated: "2026-05-13"
participants:
  - Claude (Opus 4.7)
  - Codex (GPT-5.4)
  - Gemini
facilitator: Claude
rounds_completed: 3
related_discussions:
  - docs/discussions/2026-05-12-swift-ddd-scaffold-restructure.md (D1-D14)
---

# 6-step skill pipeline 整體可行性 + skill 邊界釐清

## 議題定義

### 背景

User 手繪了一個完整的 DDD/ES decision flow（6 步）：

```
Step 0: 畫 Event Storming（外部 ES Tool）
Step 1: ES output (JSON)
Step 2: 根據 JSON 建立專案架構 by CLI       ← 已在前一 discussion 達成 R3 共識
Step 3: 將 JSON 拆解成一個個的 spec by skill
Step 4: 列成 Task 並實作 by skill（含 TDD loop）
        - 先寫測試 → 確認測試邏輯 → 先 use case → 跑 Test
Step 5: 實作 read model by skill
Step 6: 實作 API by skill
```

User 同事**實際在用**的 skill（focus 範圍）：
- `event-storming` —— per-feature 業務釐清（commands.md / invariants.md / errors.md / event.yaml 草稿）
- `usecase` —— 從業務文件產 Input/Output/Usecase/Service/Tests/UsecaseCall
- `readmodel` —— 產 ReadModel/Presenter/Projection/Tests + 部署
- `strict-review` —— 10 年視角嚴格 review
- `write-ddd-spec` ← user 新提議用來填 Step 3 缺口

**前次 discussion 共識（D1-D14）**已決定 Step 2 由新 `/swift-ddd` CLI + skill 處理。

### 目標

1. 評估 `write-ddd-spec` 能否填補 Step 3 缺口；若能，需要哪些更新
2. 審視整個 6-step pipeline 的可行性，每一步的 skill 是否吻合架構
3. 釐清 5 個邊界問題：
   - event-storming → usecase 銜接是否強制 fail-fast
   - event-storming 中 hardcoded context（AuditQuoting / CompanyRegistrationQuoting）跨專案問題
   - readmodel 依賴 `test-review-commit`（不在 focused list）的處理
   - write-ddd-spec vs event-storming 的 SSOT 重疊（invariants / errors / test scenarios）
   - Step 6（API 實作）是真缺還是包在現有 skill

### 範圍

**在範圍內**：
- 4 個 focused skill + write-ddd-spec
- 6-step 整體 pipeline 設計
- Skill 邊界與依賴關係

**不在範圍內**：
- Step 2 細節（已 D1-D14 決議）
- Event Storming Tool 內部實作
- Swift DDD/ES 慣例本身

### 約束

- D1-D14 共識（前次 discussion）為 baseline
- focused skill 是 user 同事實際使用版本，**不可隨意改成 user 平常用的版本**
- `write-ddd-spec` 在 user 本機 `.claude/skills/`，可考慮更新

### 子議題

- [ ] ST1：`write-ddd-spec` 是否能填補 Step 3 缺口？需要什麼更新？
- [ ] ST2：6-step pipeline 整體可行性與完整性
- [ ] ST3：5 個 skill 邊界釐清
- [ ] ST4：跟 R3 v2 設計（/swift-ddd CLI）的整合

---

## 重要觀察（給三方參考）

### write-ddd-spec 的真實能力（Claude 已讀完 SKILL.md）

**能做的**：
- 吃 bundle.json + UseCaseName → 產 8 段 contract-first spec
- §1 Goal、§2 Bundle Reference、§7 Cross-aggregate Effects **自動萃取**
- §3 Invariants、§5 Error Cases、§6 Gherkin Test Scenarios **互動補**
- 輸出到 `docs/tasks/<UseCase>.md`

**不能做的**：
- **不是 batch 模式**：要為每個 UC 各跑一次（IAMContext 7 個 UC = 7 次 invocation）
- **不更新 .ai/contexts/**：這是 event-storming 的責任
- **不產 source code**：給 tdd-implement / usecase skill 用

**關鍵 design statement**（SKILL.md line 18-22）：
> 與 event-storming 互補：先用 event-storming 釐清業務（更新 .ai/contexts/），再用 write-ddd-spec 產 per-UC 實作 spec。

### SSOT 重疊危機

**event-storming 產出**（`.ai/contexts/<Aggregate>/`）：
- `commands.md`：Guards 表格、業務規則、`when(event:)` 狀態變更
- `invariants.md`：aggregate-level 不變式
- `errors.md`：可拋出的錯誤類型

**write-ddd-spec 產出**（`docs/tasks/<UseCase>.md`）：
- §3 Invariants & Business Rules
- §5 Error Cases（三欄表）
- §6 Gherkin Test Scenarios

**重疊**：invariants、errors、test scenarios 兩邊都有。**誰是 SSOT？** 若兩邊都改，怎麼同步？

### 下游消費者錯位

- `write-ddd-spec` 說輸出給 `tdd-implement` 或 `usecase` skill（SKILL.md line 260-262）
- 但 **`usecase` skill 實際上讀 `.ai/contexts/`，不讀 `docs/tasks/`**（usecase SKILL.md line 91-97）
- → **pipeline 在 Step 3 → Step 4 之間斷裂**

### event-storming 硬編碼 context

```
# event-storming/SKILL.md line 50-52
- 若功能名稱或描述中出現 AuditQuoting 相關詞彙 → AuditQuoting
- 若出現 CompanyRegistrationQuoting 相關詞彙 → CompanyRegistrationQuoting
- 若無法判斷 → 詢問使用者
```

→ 移到 IAMContext 專案會卡。

### readmodel 依賴外部 skill

`readmodel` SKILL.md Step 6 呼叫 `test-review-commit` skill —— **不在 focused list**。是缺漏還是 user 同事另外有一份？

### Step 6（API）真實情況

`usecase` skill 產：Input、Output、Usecase、Service、Tests、UsecaseCall。
**沒提 API handler / OpenAPI binding**。`scaffold` 階段產的 `Adapter/ApiHandler.swift` 是空 stub。
→ Step 6 確實是缺口，沒有 skill 負責填 `ApiHandler.swift`。

---

## 討論紀錄

### Round 1 — 2026-05-13

#### 🤖 Claude (Opus 4.7)

##### ST1：write-ddd-spec 能否填補 Step 3 缺口？

**立場**：**部分能填**，但需要 3 個更新才能真正 work。Per-UC 模式是設計選擇，**不應該強制改成 batch**。

**論點**：

1. **write-ddd-spec 設計本身正確**，per-UC contract-first + Gherkin §6 是好設計：
   - §1/§2/§7 自動萃取 = LLM 做機械題 ✓
   - §3/§5/§6 互動補 = LLM 做判斷題 ✓
   - Gherkin 強制 = 下游 test 可機械驗證 ✓
   
2. **但有 3 個 bug 阻礙它銜接整個 pipeline**：

   **Bug A：下游接錯**
   - SKILL.md line 260：「下一步：跑 /tdd-implement 或 /usecase」
   - 但 `usecase` skill **不讀 docs/tasks/<UC>.md**，只讀 `.ai/contexts/<Agg>/commands.md`
   - → `docs/tasks/<UC>.md` 產出後**沒人消費**
   
   **Bug B：SSOT 重疊**
   - `docs/tasks/<UC>.md §3 §5 §6` vs `.ai/contexts/<Agg>/{invariants,errors,test-scenarios}.md`
   - 兩邊都寫 invariants/errors/tests，**沒寫誰是 master**
   - 一旦 user 在 docs/tasks 修了什麼，commands.md 不會跟著動 → drift
   
   **Bug C：缺 batch 模式入口**
   - IAMContext 7 個 UC，user 要跑 7 次 `/write-ddd-spec`
   - 每次都互動問 §3/§5/§6 → user 累
   - 但**強制 batch 化是錯方向**（§3/§5/§6 是 per-UC 業務判斷）
   - 該有的是 **`/write-ddd-spec --all <bundle>`**：批次 §1/§2/§7 自動填 + 列出待補 §3/§5/§6 的 UC 清單，**讓 user 按優先順序逐個跑互動**

3. **填補 Step 3 後的真實工作流**：

```
Step 2: /swift-ddd init                          產 .ai/contexts/ 空骨架 + Sources/ stub
Step 3a: /write-ddd-spec --all bundle.json       產 docs/tasks/<UC>.md 骨架 (§1/§2/§7 + §3/§5/§6 TODO)
Step 3b: 對每個 UC 跑 /write-ddd-spec <UC>       人類補 §3/§5/§6
Step 3c: /event-storming <Feature>               同時更新 .ai/contexts/<Agg>/{commands,invariants,errors}.md
        ←─── BUT WAIT，這變兩次寫業務知識？SSOT 問題重來
```

**ST1 結論**：write-ddd-spec 能填 Step 3，**但前提是先解 SSOT 重疊問題（ST3）**。

##### ST2：6-step pipeline 整體可行性

**立場**：6-step **架構正確**，但**現有 skill 沒有 100% 覆蓋**，且**缺 cross-step 銜接機制**。

| Step | 對應 skill | 覆蓋狀態 |
|------|----------|---------|
| 0 | (ES Tool 外部) | 外部 ✓ |
| 1 | (bundle.json export) | 外部 ✓ |
| 2 | `/swift-ddd init`（R3 設計中） | ⚠️ 重做中 |
| 3 | `write-ddd-spec` + `event-storming` 互補 | ⚠️ **下游斷裂 + SSOT 重疊** |
| 4 | `usecase` | ✓ 完整 |
| 5 | `readmodel` | ⚠️ 依賴 test-review-commit |
| 6 | (無) | 🔴 **缺口** |
| 橫切 | `strict-review` | ✓ 完整 |

**整體可行性盲區**：

a. **沒有 pipeline orchestrator**：user 要手動知道「先跑 X 再跑 Y」。沒有 skill 引導 next-step。
b. **沒有 status tracking**：哪個 UC 已 specced / 已 implemented / 已 reviewed？要 user 自己記。
c. **strict-review 觸發時機不明**：per-UC 跑？per-PR 跑？per-feature 跑？

##### ST3：5 個 skill 邊界釐清

**B1：event-storming → usecase 銜接（強制 fail-fast？）**
- **立場**：應該 fail-fast。usecase skill Step 2 已經讀 commands.md，**若該 feature 區塊不存在或是 TODO，直接拒絕並提示「先跑 /event-storming <Feature>」**
- 成本：usecase SKILL.md 加 5 行檢查
- 收益：避免 user 跳過業務釐清直接產 source code → 產出半套

**B2：event-storming hardcoded context**
- **立場**：必須移除 hardcoded mapping，改成「**auto-discover .ai/contexts/ 子目錄 + 不確定就問 user**」
- event-storming SKILL.md line 49-52 改成：
  ```
  判斷所屬 Context：
  1. Scan .ai/contexts/ 子目錄 → 作為候選
  2. 若 feature name / 描述匹配某 context 的 commands.md 既有 command 命名模式 → 自動推
  3. 否則 → 列出候選請 user 選
  ```
- 跟 usecase skill 的 auto-discovery (Step 0) 對齊

**B3：readmodel ↔ test-review-commit**
- **立場**：要嘛把 test-review-commit 納入 focused list、要嘛 readmodel 改寫 Step 6 拆出 sub-steps（跑測試 → review → commit），不依賴外部 skill
- 建議後者，理由：readmodel 是 user 同事在用的「焦點 skill」，其他 skill 都不依賴 test-review-commit，**這條依賴是 outlier**

**B4：write-ddd-spec vs event-storming SSOT 重疊（最關鍵）**
- **立場**：以 `.ai/contexts/` 為 master SSOT，`docs/tasks/<UC>.md` 是**派生視圖**（derived view）。具體做法：
  
  | 內容 | 寫入 | 派生到 |
  |------|------|-------|
  | Invariants | `.ai/contexts/<Agg>/invariants.md`（master） | `docs/tasks/<UC>.md §3` 自動引用/quote |
  | Errors | `.ai/contexts/<Agg>/errors.md`（master） | `docs/tasks/<UC>.md §5` 自動引用 |
  | Test scenarios | `.ai/contexts/<Agg>/test-scenarios.md`（master） | `docs/tasks/<UC>.md §6` Gherkin（人補） |
  | Goal / Bundle Ref / Cross-agg | `docs/tasks/<UC>.md` only | (bundle.json 派生) |
  | Gherkin scenarios | `docs/tasks/<UC>.md §6`（master） | `.ai/contexts/<Agg>/test-scenarios.md` 引用 |

- 對 write-ddd-spec 的修改：§3/§5 改成「**讀 .ai/contexts/<Agg>/{invariants,errors}.md 並 quote 進來**」而非互動問
- 對 event-storming 的修改：產 commands.md 時，**同時掛載建議的 Gherkin scenario 名稱**到 test-scenarios.md（不寫 body，body 在 write-ddd-spec §6 補）

**B5：Step 6（API skill）真缺**
- **立場**：確實缺，建議新 skill `/api`，但**範圍限制**在「依 OpenAPI spec 產 ApiHandler.swift + DTO」，**不碰業務邏輯**
- 或者：擴 `usecase` skill 多產 ApiHandler.swift（**反對**，違反 SRP）
- 推薦獨立 skill，因為 API 層的 DTO ↔ Input/Output mapping、HTTP status code 對應 §5 error 都是獨立判斷題

##### ST4：跟 R3 v2 設計（/swift-ddd CLI）的整合

**立場**：`/swift-ddd` CLI 不該擴張到 Step 3。CLI 做機械題（scaffold + diff + apply + adapter），spec 拆解（Step 3）是 LLM 判斷題，留給 skill。

但需要 **2 個 cross-cutting 設計**：

1. **`/swift-ddd init` 完成後印「下一步」提示**：
   ```
   ✅ Scaffold complete.
   下一步：
     /write-ddd-spec --all bundle.json   ← 批次產 spec 骨架
   ```

2. **`/swift-ddd diff` 偵測新 UC 時提示**：
   ```
   ── NEW USE CASES (3) ──
   建議跑：
     /write-ddd-spec bundle.json UseCase1
     /event-storming UseCase1
   ```

---

#### 🔧 Codex (GPT-5.4)

##### ST1：write-ddd-spec 能否填補 Step 3 缺口？

- Claude Bug A 基本對。`write-ddd-spec/SKILL.md:259-261` 提示「下一步 /usecase」，但 `usecase/SKILL.md:92-97` 實際只讀 `.ai/contexts/{Context}/{commands,invariants,errors,test-scenarios,reference}.md`，**不讀 `docs/tasks/<UC>.md`** → orphan output。
- Claude Bug B 只說對一半。**更大的洞是 `test-scenarios.md` contract 沒接上**：`write-ddd-spec` 宣稱 `event-storming` 會產 `.ai/contexts/<Aggregate>/test-scenarios.md`，`usecase` 也把它當輸入（`usecase/SKILL.md:96,153-160`），但 **`event-storming` 實際輸出清單沒它**（`event-storming/SKILL.md:17-21,185-189`）。**Missing producer**，不是 drift。
- Bug C 是「pipeline UX gap」不是 correctness bug。write-ddd-spec single-UC 是 spec 設計，缺 `--all` 拖慢 Step 3 但不違反現有 spec。
- `--all batch + per-UC interactive` 該兩段式：
  - `/write-ddd-spec --all bundle.json` 機械題：掃 useCases[]、建 `docs/tasks/<UC>.md` 骨架、填 §1/§2/§7、§3/§5/§6 標 TODO、更新 `docs/tasks/_index.md`
  - `/write-ddd-spec --resume <UC>` 或 `/write-ddd-spec bundle.json <UC>` 補 §3/§4/§5/§6/§8
- 跳過 event-storming 直接用 write-ddd-spec 應允許，但**不能假裝能直接接 /usecase**。兩條 lane：
  - 主線：event-storming → write-ddd-spec → usecase（team 慣例）
  - 支線：write-ddd-spec → tdd-implement（spec-first，沒 .ai/contexts/）
- 具體修法：
  - write-ddd-spec Step 7 改文案，commands.md 沒該 feature → 提示 `/event-storming`（+8~12 LoC）
  - 新增 `--all` / `--resume` 流程 + `_index.md`（+45~70 LoC）
  - usecase Step 2 加 optional read：若 `docs/tasks/<Feature>.md` 存在，讀 §4/§6 補強測試與命名，commands.md 仍 required（+20~35 LoC）
  - test-scenarios SSOT 改成 `docs/tasks/<UC>.md §6`；`.ai/contexts/.../test-scenarios.md` 若保留只做 index/summary（+30~45 LoC）

##### ST2：6-step pipeline 整體可行性

- Claude 漏 3 個更實際的 blocker：
  1. **Step 3→4 artifact contract 斷裂**比 Step 6 更早爆
  2. **test-scenarios.md 有 consumer 沒 producer**
  3. **readmodel 不只依賴 test-review-commit，還依賴 reset-projection**（`readmodel/SKILL.md:145-153`）；focused list 少 2 個外部 skill
- 不建議新長 `/ddd-pipeline` skill。D10 已收斂單一 `/swift-ddd`。orchestrator 逆方向。
- 狀態分三層：
  - `.scaffold-manifest.json`：bundle hash、generated files（D5 定案）
  - `docs/tasks/<UC>.md` frontmatter：`status: drafting|specced|stormed|implemented|readmodeled|api-wired|reviewed`
  - `docs/tasks/_index.md`：從 frontmatter 匯總的看板，不反向當 master
- Critical path 不是 Step 6 API，是 **Step 3/4 handshake**。第二名才是 readmodel 外部依賴。
- 實作量：`/swift-ddd status|next` + `_index.md` schema：+60~120 LoC + ~30 LoC template；frontmatter 狀態約定：+15~25 LoC

##### ST3：5 個邊界釐清

- **B1 分級 fail-fast，不一律 hard fail**：
  - 缺 `commands.md ## {Feature}` 區塊或仍 TODO → usecase 必停（會直接產 command code）
  - 缺 `docs/tasks/<UC>.md` 或 test-scenarios.md → warn-and-degrade（usecase 仍可從 guards 生成基本測試）
- **B2 auto-discovery 需 ambiguity gate**：詞彙打分 +「最高分唯一且領先第二 ≥ 3 分」才自動選；top-2 接近就直接列候選讓 user 選
- **B3 不要現在就 inline test-review-commit**。先查清楚它與 reset-projection 實際做什麼。若沒時間做依賴盤點，readmodel 最低限度自給版本只能 inline 已寫明行為（重置 projection、跑 presenter tests、staging 規則）。**fallback 而非首選**
- **B4 不接受 Claude 全部以 .ai/contexts/ 為 master 的單向說法**。**Content-type split**：
  - `.ai/contexts/{Context}/invariants.md` + `errors.md`：aggregate-level domain catalog
  - `commands.md`：command guards + `when(event:)` 摘要
  - `docs/tasks/<UC>.md`：per-UC high-level goal、完整 Gherkin、transport mapping
  - **HTTP Status 明顯是 adapter/API concern，不該回灌成 aggregate SSOT**
- **B5 新 /api skill v1 只做 binding，不做 OpenAPI authoring**。輸入：`docs/tasks/<UC>.md` + `.ai/contexts/{Context}/config.md` + `.ai/conventions/api.md` + 可選 `.ai/contexts/{Context}/api.md`。輸出：`Adapter/{Feature}/` DTO、ApiHandler.swift wiring、error/status mapping tests。估 ~180~260 LoC

##### ST4：跟 R3 v2 整合

- init hint **不該只印一句**「去跑 write-ddd-spec」。應印 worklist：`MISSING_CONTEXT_DOCS` / `MISSING_TASK_SPECS` / `READY_FOR_USECASE` 三段
- diff 也要同時檢查 `docs/tasks/<UC>.md` 存在性 + frontmatter 狀態 + commands.md feature 區塊
- **init 不該預設自動 chain `/write-ddd-spec --all`**。混 deterministic CLI + interactive LLM，邊界又糊。若要 convenience 只能 opt-in（`--print-spec-commands`）
- CLI 判斷可 deterministic：
  - commands.md 無 feature 區塊 → `event-storming required`
  - docs/tasks/<UC>.md 不存在或 §3/§5/§6 仍 TODO → `write-ddd-spec required`
  - 兩者都缺 → 兩個都建議，先 event-storming 後 write-ddd-spec
  - 兩者都齊 → 建議 `/usecase`
- 實作量：hint logic +40~80 LoC、`_index.md` initial render +20~30 LoC

---

#### 🌐 Gemini

> **Stance up front**：**`write-ddd-spec` 應該刪掉**。它是 SSOT duplication 戴了 fancy 帽子。「contract-first 8 段 spec」是 spec-bureaucracy，違反 Evans「the model IS the document」。Claude R1 用 3 個 patch 救它，**那些 patch 治症狀不治本**。

##### ST1：write-ddd-spec 填補 Step 3？(No. Delete it.)

**Claude 診斷對**：3 個 bug 真實存在。

**Claude 錯**：把 3 個 bug 當可修補 surface defects。它們是**同一個架構錯誤的三個症狀**：per-UC 不是 DDD/ES 的獨立知識邊界，**aggregate 才是**。

Evans 線：
1. Ubiquitous language 住在 bounded context / aggregate 層級
2. Use case 是 model 的「使用視角」，不是另一份 model
3. write-ddd-spec §3/§5/§6 直接拷貝 aggregate 的 invariants/errors/scenarios 到 per-UC 文件 → 把 model 切碎放進 per-UC 文件夾，**anemic spec sprawl**：每加 UC 複製業務知識，每改 invariant 追 N 份 spec

**Conway check**：
- write-ddd-spec 在 `~/.claude/skills/`（user 個人）
- 其他四個在 `~/Downloads/skills/`（同事共用）
- 這不是地理偶然，是 **organizational signal**：team 工作流是「ES → `.ai/contexts/` → /usecase → /readmodel」，write-ddd-spec 是 user 個人偏好的「先生 doc 再 code」中介層。**把個人 ceremony 升級成 team contract 是 Conway 反向**

**完全吸收方案**：
- §1 Goal：bundle.json 已有，CLI scaffold 時印 `<UC>.swift` 註解 header 即可
- §2 Bundle Reference：bundle.json **本身就是 reference，link 不要 copy**
- §3 Invariants：already in `.ai/contexts/<Agg>/invariants.md`
- §5 Errors：already in `.ai/contexts/<Agg>/errors.md`
- §6 Gherkin：**唯一真正貢獻**。但 usecase skill 已會根據 commands.md + test-scenarios.md 產 Swift Testing tests，Gherkin 反而是中介翻譯層。**若 team 要 Gherkin，加進 event-storming Step 9 輸出 test-scenarios.md 即可**
- §7 Cross-aggregate：bundle 機械推導進 commands.md 「備註」段
- §8 Implementation Notes：要嘛沒人看，要嘛 PR description 寫

**Evans「model IS the document」**：當你維護 model 的「另一份摘要」，那份 99% 會 drift。**SSOT 唯一可靠執行是「只有一份」**，不是「指定哪份是 master」。

**ST1 結論**：
- write-ddd-spec **刪掉**
- Gherkin §6 併進 event-storming 的 test-scenarios.md
- Step 3 不需獨立 skill —— **event-storming 本來在做這事，只是還沒以 bundle.json 為輸入**。修法：`event-storming --from-bundle <bundle.json> <UC>` 模式：吃 bundle、跳過 Step 4 機械題、只問 invariants/errors
- 若 user 堅持保留 write-ddd-spec 當個人 ceremony，放 `~/.claude/skills/` **永遠不要進 team pipeline 圖**

##### ST2：6-step 是 graph 不是 pipeline

**4 個 cycle**（不只 Step 4 TDD loop）：
- C1 (Step 4 TDD)：user 已知
- C2 (Step 5 → Step 1)：實作 read model 發現新 query 需要新 event payload → 回 ES tool
- C3 (Step 6 → Step 3 → Step 4)：API 發現某 error 對應不同 HTTP status → 回 commands.md
- C4 (Step 4 → Step 0)：實作時發現業務理解錯誤 → 回 ES tool 改 policy

→ **「pipeline orchestrator」前提錯**。Linear DAG orchestrator 第一次 cycle 就撞牆。

**Unix philosophy 對**：個別 skill 各做一件 + user 知道順序。理由：
1. Skill 之間真正的 contract 是**檔案系統狀態**，不是 orchestrator state machine
2. Cycle 永遠存在；orchestrator 必須處理 partial re-run → 重新發明 Make/Bazel
3. User 學一次「ES → /event-storming → /usecase → /readmodel」就會了

**Status tracking**：D5 把 provenance 切到 manifest 的精神延伸到 status。**不要做 _index.md**，再加 human-edited mutable 多 writer 檔會重新引入 provenance 問題。`/swift-ddd status` CLI subcommand 從 manifest 派生即可。

**strict-review timing**：
- 不該做 git pre-commit / pre-push（會被 `--no-verify` 殺死）
- 維持 user 主動 + 輕量 pre-commit hook 只查 mechanical things（forbidden symbols、import order、`!` force-unwrap）

##### ST3：5 個邊界釐清（強力立場）

**B1**：default fail-fast **但不該 hard fail**：
- Default：commands.md 缺 → 拒絕 + 提示
- Escape hatch：`--skip-business-check` + 強制寫一句 commit message
- 「default strict + opt-out explicit」是 Postel + Hyrum's Law 張力的穩定解

**B2**：為什麼當初 hardcoded？因為 auto-discovery 在「feature → aggregate」**本質模糊**。修法：
1. scan `.ai/contexts/` 列候選
2. 比對 commands.md 命名模式
3. **≥2 候選 → 一律問 user，不要猜**
4. 結果記到 `_routing.md`（user 行為快取，不是規則）

key insight：**discovery（有什麼）≠ routing（該去哪）**。當初混淆是根因。

**B3**：**強烈反對 inline substeps**。test-review-commit 顯然在 user 同事那邊存在（不然 readmodel 不會 reference）。**去把它加進 focused list，不要 inline**。

Evans/DDD lens：test-review-commit 是**橫切關注**，像 strict-review。Inline 進 readmodel = 其他 skill 也要各自 inline → DRY 違反 + skill bloat。**升級成 first-class focused skill**。

**B4**：同意 Claude `.ai/contexts/` 是 master，**反對「派生視圖」執行方式**。雙向 SSOT 不存在。

乾淨答案：**`.ai/contexts/` 是唯一可寫 source；docs/tasks/<UC>.md 不存在**（因為 write-ddd-spec 被刪）。若要 per-UC 視圖：`/swift-ddd show-uc <UC>` 從 bundle + .ai/contexts/ 即時組合到 stdout。**不要落地檔案**。

**B5**：**反對新 /api skill**。原因：API 是 thin transport，OpenAPI 已是 SSOT。Step 6 該做的：
1. **CLI subcommand `/swift-ddd api-gen <openapi.yaml>`**：機械題，產 ApiHandler.swift + DTO + DTO ↔ Input/Output mapping
2. **`.ai/contexts/<Agg>/api.md`**：人類補的 HTTP status code 對應規則 + DTO 命名 quirks。**Context-level 規則，不是 per-UC**
3. §5 error → HTTP status mapping **放回 commands.md 多一欄**

**Skill 門檻原則**：skill 是 LLM judgment 介面，CLI 才是機械題介面。**「OpenAPI → ApiHandler」是機械題 → 屬 CLI 不屬 skill**。

##### ST4：CLI 永不印 skill name

「CLI 印 skill name 是 Hyrum's Law 等級的耦合」。一旦印 → 三件事發生：
1. CLI 變成知道 skill ecosystem 的元件，skill 改名 CLI 也要改
2. User 肌肉記憶會固化某個推薦順序
3. D11 manifest 純 state 的設計意圖被破壞（state 該說「現況」，不該說「下一步」）

**乾淨解**：CLI 只輸出 structured state，**user/IDE/orchestrator 讀 manifest 決定下一步**。
- `/swift-ddd init` 結尾：`✅ Manifest: .swift-ddd/manifest.json`
- `/swift-ddd diff` 結尾：`── NEW (3) ──\nFoo.bar, Foo.baz, Bar.qux\n── REMOVED (0) ──`。**不印 skill 字串**
- 「下一步建議」放 `CONTRIBUTING.md`，人類 onboarding 學會。CLI 別插嘴

##### 給 Codex 的挑釁

預判 Codex 會主張保留 + 用 derived view 修 B4。

反挑釁：
- **derived view 實務會崩**。給具體雙向同步機制：user 在 `docs/tasks/<UC>.md §3` 修一條 invariant，怎麼回寫 `.ai/contexts/<Agg>/invariants.md`？除非有 file watcher + parser + diff merge tool，否則就是人類手動同步 = drift
- **per-UC spec 維護成本被低估**：IAMContext 7 UC → 30 UC，30 份 docs/tasks 各含 §3/§5/§6 重複業務知識。改一條 invariant 要 sweep 30 份

##### 一句話

刪 write-ddd-spec；Step 3 由 event-storming `--from-bundle` 承接；Step 6 由 `/swift-ddd api-gen` CLI 承接，不要新 skill；不要 orchestrator，manifest 就是 state SSOT；test-review-commit 升級 focused skill；hardcoded context 換成「discovery + routing cache」；CLI 永不印 skill name。三層分工：**skill 做業務判斷、CLI 做機械題、檔案系統做 SSOT**。

---

### 📌 Round 1.5 — 使用者錨點（2026-05-13）

User 對 OQ1 / OQ2 / OQ3 給出明確答覆：

| 問題 | User 答覆 | 採納立場 |
|------|----------|---------|
| **OQ1: write-ddd-spec 存廢** | **保留 + 修 3 bug** | Codex 立場 |
| **OQ2: Step 6 API** | **新 /api skill** | Claude/Codex 立場 |
| **OQ3: test-review-commit / reset-projection** | **升級為 first-class focused skill** | Gemini 立場 |

**Round 2 工作範圍因此縮窄為**：
- ✅ write-ddd-spec 留著 → docs/tasks/<UC>.md 存在 → 必須有 SSOT 分工規則（OQ4 強制走 Codex「content-type split」）
- ✅ 新 `/api` skill 確定 → 需 spec 邊界
- ✅ test-review-commit 升 focused skill → 需 spec 跟 strict-review 切分
- ⚠️ 仍待解決：
  - **SSOT content-type split 具體規則**：哪個檔擁有哪些 content？跨檔引用怎麼做？drift 防護？
  - **`/api` skill 具體邊界**：v1 範圍、輸入輸出、跟 usecase / OpenAPI 的關係
  - **test-review-commit 跟 strict-review 邊界**：誰在哪個時機跑？
  - **最終 milestone roadmap**：在 D1-D14 之上多了 4 個工作項目

---

## Round 2 議題（2026-05-13 啟動）

### R2-Q1：SSOT content-type split 具體規則

採 Codex 立場（content-type split），需明確：

| 檔案 | 擁有的 content type | 跨檔引用方式 |
|------|-------------------|------------|
| `.ai/contexts/{Ctx}/invariants.md` | aggregate-level invariants | ? |
| `.ai/contexts/{Ctx}/errors.md` | error catalog + HTTP status | ? |
| `.ai/contexts/{Ctx}/commands.md` | command guards + `when(event:)` 摘要 | ? |
| `.ai/contexts/{Ctx}/test-scenarios.md` | 摘要 / index | ? |
| `.ai/contexts/{Ctx}/api.md`（新） | context-level API conventions | ? |
| `docs/tasks/<UC>.md` | per-UC §1/§2/§4/§6 Gherkin/§7/§8 | quote 形式引用 invariants/errors |

具體要回答：
- §3 §5 在 docs/tasks 是「複製內容」還是「quote with link」？
- 改一條 invariant 怎麼確保 docs/tasks 同步？（fail-fast in write-ddd-spec？file watcher？manual sweep？）
- test-scenarios.md 是「Gherkin scenario 名稱 index」還是「短摘要」？

### R2-Q2：/api skill 邊界

新 skill scope：
- 輸入：?
- 輸出：?
- 觸發時機：在 usecase 之後？並行？
- 跟 `Adapter/ApiHandler.swift`（scaffold 產的空 stub）的關係？
- 跟 OpenAPI 的關係：消費 openapi.yaml？產出 openapi.yaml？

### R2-Q3：test-review-commit / reset-projection 升 focused skill 後的職責切分

- test-review-commit vs strict-review：誰跑什麼？什麼時機？
- reset-projection：是 readmodel 內部步驟還是獨立 skill？

### R2-Q4：最終 milestone roadmap

D1-D14 共識 + 本次 4 個新工作：
1. write-ddd-spec 修 3 bug + --all/--resume mode（Codex ~150 LoC）
2. event-storming `--from-bundle` mode（讓它從 bundle 萃取結構）+ remove hardcoded contexts
3. /api skill 設計實作（Codex ~180-260 LoC）
4. test-review-commit + reset-projection 升為 focused skill

新的 milestone 排序怎麼安排？跟 D11 的 M1-M4 怎麼整合？

---

### Round 2 — 2026-05-13

#### 🔧 Codex (GPT-5.4) — Round 2

##### R2-Q1：SSOT content-type split

選 **B/C hybrid**，反對 A。Gemini 對「30 份 sweep」批評對，但解法不是刪 docs/tasks，是把重複段落變「**generated projection with hard freshness checks**」。

| File | Owns | Reference |
|------|------|-----------|
| `.ai/contexts/<Ctx>/invariants.md` | invariant 全文 + **stable ID** + 適用 commands/features + 對應 error ID | 被 commands/docs/tasks 用 markdown link 引用 |
| `.ai/contexts/<Ctx>/errors.md` | Domain error catalog + stable ID + Swift error symbol + 觸發語意 | 同上 |
| `.ai/contexts/<Ctx>/commands.md` | Per-command guards + state transition + 用到的 invariant IDs / error IDs | /usecase 消費；write-ddd-spec 過濾 §3/§5 |
| `.ai/contexts/<Ctx>/test-scenarios.md` | **Scenario registry only**：ScenarioID + feature + type + title。**不放完整 Gherkin** | docs/tasks/<UC>.md §6 以 scenario ID 對應 |
| `.ai/contexts/<Ctx>/api.md` | Context-level transport：Feature→operationId、auth、default error→HTTP、problem type | /api skill 消費 |
| `docs/tasks/<UC>.md` | §1/§2/§4、**完整 §6 Gherkin**、§7/§8。§3/§5 是 **generated reference blocks** 不是人工 SSOT | markdown link 回 .ai/contexts/ |

`docs/tasks/<UC>.md` frontmatter + generated block：
```md
---
useCase: User.createUser
status: specced
sourceRefs:
  invariants: [.ai/contexts/User/invariants.md#inv-user-id-unique]
  errors: [.ai/contexts/User/errors.md#err-duplicate-user-id]
sourceHashes:
  invariantsMd: sha256:...
  errorsMd: sha256:...
---

## 3. Invariants & Business Rules
<!-- GENERATED:BEGIN -->
- `INV-user-id-unique` — userId globally unique. Source: `.ai/contexts/User/invariants.md#inv-user-id-unique`
<!-- GENERATED:END -->

## 5. Error Cases
<!-- GENERATED:BEGIN -->
| Condition | Domain Error | HTTP | Sources |
|---|---|---|---|
| duplicate userId | `.duplicateUserId` | 422 | errors.md#err-duplicate-user-id, api.md#default-error-status |
<!-- GENERATED:END -->
```

**Drift prevention 4 條一起上**：
1. `.ai/contexts/*` 每條 invariant/error 都要 stable ID
2. `write-ddd-spec --all` 只建骨架；`--resume <UC>` 重算 §3/§5 + 更新 sourceHashes
3. `/usecase` 發現 sourceHashes 落後 → hard fail，提示「run /write-ddd-spec --resume <UC>」
4. §3/§5 是 tool-owned block；人工改動會被 --resume 覆蓋。**人只編 §4/§6/§8**

##### R2-Q2：/api skill 邊界

v1 **consume only**，不產 openapi.yaml。

**Required inputs**：
- `docs/tasks/<UC>.md`、`.ai/contexts/<Ctx>/{config,api,errors}.md`、`.ai/conventions/api.md`
- `{SourcesRoot}/Usecase/Port/In/{Feature}/{Feature}{Input,Output,Usecase}.swift`
- `openapi/openapi.yaml`

**Outputs**：`Adapter/{Feature}/{Request,Response,Mapper,Handler}.swift` + update `ApiHandler.swift` + tests

**Trigger order**：必須在 /usecase 之後；可與 /readmodel 並行。

**Route/method 解析**：
1. 讀 `.ai/contexts/<Ctx>/api.md` 的 operation map（`Feature → operationId`）
2. 用 operationId 到 openapi.yaml 找唯一 operation
3. path/method/schema 以 OpenAPI 為 SSOT
4. Feature == operationId 且唯一 → 可省略 api.md

**Error → HTTP mapping 位置**：
- **不放 errors.md**（domain catalog 不該混 transport）
- **放 `.ai/contexts/<Ctx>/api.md`**：
  ```md
  ## Default Error Status
  | ErrorId | HTTP | ProblemType |
  | ERR-duplicate-user-id | 422 | duplicate-user-id |

  ## Operation Overrides
  | Feature | ErrorId | HTTP |
  | CreateUser | ERR-user-not-found | 404 |
  ```

##### R2-Q3：邊界

| Skill | 做 | 不做 | 時機 |
|-------|---|------|------|
| **test-review-commit** | `swift test --no-parallel`、讀 working tree diff、對照 commands/docs §6 做 feature-slice review、commit | PR-level critique、10-year quality、unrelated files | 每個 usecase/readmodel/api slice 完成後 |
| **strict-review** | PR/feature-branch 深度 review：10-year、cross-context consistency、design debt、規範引用 | 跑 commit、auto stage、每 slice 必經 gate | feature 完整後、PR 前/中 |

**順序**：
- 日常：`/usecase` or `/readmodel` or `/api` → `test-review-commit`
- 合併前：feature branch 完整 → `strict-review`

**reset-projection 獨立 skill**（Gemini 對）：
- readmodel 負責產 ReadModel/Presenter/Projection/Tests
- reset-projection 負責 KurrentDB reset + projection deploy + smoke check

##### R2-Q4：Milestone

**新排序**（先打通 IAMContext 主線，不是先做滿 scaffold v2）：

1. **M1**：scaffold hotfix + normalization + fail-fast，~3d
2. **W2**：event-storming --from-bundle + auto-discovery + ambiguity gate + test-scenarios.md producer，~2.5-3d，~160-220 LoC
3. **W1**：write-ddd-spec 3 bug fixes + --all/--resume + generated §3/§5 + freshness gate，~2d，~130-170 LoC
4. **W4**：promote test-review-commit + reset-projection，~2-3d，~120-180 LoC
5. **W3**：/api skill v1 binding，~3-4d，~180-260 LoC
6. **M2**：scaffold v2 secondary，~2d
7. **M3**：diff/apply/manifest，~6-7d
8. **M4**：transaction safety + rename，defer

**最卡 IAMContext 的不是 /api 也不是 M3 diff，是 M1 之後的 W2**。沒有 event-storming portability，主線根本進不了 Step 3/4。

單 lane 總 ~18-21d；兩 lane 並行 critical path ~13-15d；只跑主線 ~12.5-15d。

---

#### 🌐 Gemini — Round 2

> **Stance reset**：OQ1/OQ2 我輸了，不再 relitigate。Job：把 Codex 即將 over-engineer 的部分擋住。

##### R2-Q1：SSOT — Codex 漏了 Option D（最乾淨）

Codex 三選：A 複製、B link/quote、C name-only。我加一個 **D**：

> **`docs/tasks/<UC>.md` 是 derived artifact，不是 hand-edited file**

- 像 `.scaffold-manifest.json` 一樣，每次 /write-ddd-spec 從 bundle.json + .ai/contexts/ 機械重新渲染
- §1/§2/§7：從 bundle.json 渲染
- §3/§5：render time **transclude** from invariants.md/errors.md，rendered file 附 `<!-- generated-from: .ai/contexts/Foo/invariants.md@<sha> -->`
- §6 Gherkin：**唯一人類手編的欄位**。**存回 `.ai/contexts/<Agg>/test-scenarios.md`** 鍵入 UC 名稱（這就是 Codex 抓的 missing producer 的解！）
- §4/§8：optional，存 `.ai/contexts/<Ctx>/notes/<UC>.md`

**Evans「model IS the document」用 build pipeline 強制執行**。docs/tasks 變 view over real SSOT。write-ddd-spec 保留 UX，drift **結構上不可能**因為重跑就 rebuild。

**推薦 D，B 是 fallback。A 拒絕**。

**Enforcement（Codex 會 under-spec）**：
1. frontmatter sourceHashes（同 Codex）
2. **CI check**：`swift run swift-ddd verify-specs` 重算 hashes 失敗則 CI red（~30 LoC）
3. write-ddd-spec 開頭 re-read sources，hash stale → warn before 互動。**無 file watcher**（YAGNI）
4. **無雙向同步**。docs/tasks §3/§5 編輯被 convention 禁止；CI hash check 強制執行。User 改 §3 → hash mismatch → CI red → 改 invariants.md 才對

**Postel 反向**：對人類嚴格（only invariants.md 可寫），對讀者寬鬆（docs/tasks 可閱讀）。

##### R2-Q2：/api skill — 防禦性極小化

User override 我，OK。但 skill 必須 **defensively small** 否則變下一個怪物。

| 維度 | Hard limit |
|------|-----------|
| Inputs | `docs/tasks/<UC>.md` (§5)、`.ai/contexts/<Ctx>/api.md`、`Adapter/<Feature>/ApiHandler.swift` stub |
| Outputs | `Adapter/<Feature>/{DTO.swift, ApiHandler.swift, ApiHandlerTests.swift}` only |
| Responsibilities | (a) DTO↔Input/Output mapping、(b) §5 error→HTTP status、(c) wire UsecaseCall 進 ApiHandler |
| **NOT** | OpenAPI authoring、route registration、auth/middleware、validation 超過 DTO decode、integration tests |
| Max LoC of SKILL.md | **200 lines**（event-storming 是 reference ceiling） |
| Max steps | **6**（parity with usecase） |
| 依賴其他 skill | **zero**，只讀檔案 |

**Mechanical vs judgment**（防止 bloat 的紀律）：
- Mechanical 70%（CLI-eligible in v2）：DTO struct gen、ApiHandler skeleton、UsecaseCall wiring、basic decode-error tests
- LLM judgment 30%（justifies skill-ness）：§5 error→HTTP status（404 vs 409 vs 422 contextual）、DTO field naming（domain name leaks transport）、partial-success response shape

**Anti-bloat 寫進 SKILL.md**：
1. 不寫 `Adapter/<Feature>/` 外的檔。要碰 Sources/Domain → skill 停，指 user 去改 .ai/contexts/
2. 不讀 invariants.md。API 層不該編碼 domain rules
3. **不寫 openapi.yaml**。若需 OpenAPI sync → v2 + CLI subcommand
4. **一次一個 UC**，無 batch（同 write-ddd-spec 的 Conway 邊界）

**結論**：/api skill = `usecase` skill 的 transport 兄弟，同 shape、同 scope discipline。>200 LoC SKILL.md 或讀 domain files 即 rotted。

##### R2-Q3：邊界

**test-review-commit 推測 responsibilities**：
1. 跑 `swift test --filter`（diff-touched test targets）
2. 讀 diff + test output，brief review：missing assertions、brittle assertions、coverage holes、golden-file leaks
3. clean → commit；否則 print findings 停下

**為何分離（architectural reason 不是便利）**：

| Skill | Lens | Timing | Diff size | Cost |
|-------|------|--------|----------|------|
| test-review-commit | **transactional** — 現在 land 安全嗎？ | post-implementation, per logical change | small (1 feature) | cheap，常跑 |
| strict-review | **archaeological** — 10 年存活嗎？ | pre-PR/on-demand, per feature/module | large (cumulative) | expensive，rare |

合併違反 **separation of cadences**：10-year lens 跑 per-commit 變 lint（稀釋）或 user-hostile（每 commit block）。

**Triggers**：
- test-review-commit：post-implementation，user-invoked，從 usecase/readmodel/api Step N 內呼叫。**不是 git hook**（`--no-verify` 殺死）
- strict-review：pre-PR，user-invoked，manual cadence
- CI：只跑 mechanical checks（build/test/hash-verify）。兩 skill 都不 auto-run CI

**Shared primitives（DRY 防護）**：
- `swift run swift-ddd diff --since HEAD~1 --format=json`（D-series 已設計）：兩 skill 都消費
- 微小 `.ai/conventions/review.md` 共享 review style
- **不共享 LLM prompts**（不同 cadence 不同 lens）

**reset-projection 獨立 focused skill**（同 R1 B3）。理由：operational concern 不是 modeling。inline 進 readmodel 混淆「design projection」與「rerun projection」，未來 event replay/snapshot rebuild 都會要相同 primitive。Scope ~150 LoC SKILL.md，CLI-eligible v2。

##### R2-Q4：Roadmap

**Conway**：1 人團隊 + 4 件新事 + D1-D14 baseline = thrash。**切波**。

**YAGNI scan**：
| Item | IAMContext 必要？ | Defer？ |
|------|-----------------|--------|
| W1 | **Yes**（Step 3 blocks 4） | No |
| W2 | **Partial** — auto-discovery yes、--from-bundle no | **Split**：auto-discovery 現做，--from-bundle 延後 |
| W3 | **Yes** —— Step 6 是 ship gate | No |
| W4 | **No** — readmodel 可 inline 為 fallback | **Defer** 到第 2 個 consumer 出現 |

**Critical path**：
1. D1-D14 baseline
2. **W2a：event-storming auto-discovery**（~0.5d）—— 無此 IAMContext 連 event-storming 都不能用
3. **W1：write-ddd-spec 3 bugs + content-type split + CI hash check**（~2.5d）
4. **W3：/api skill v1**（~3d if scope held to 200 LoC）—— Step 6 ship gate
5. **W2b：--from-bundle**（~1d）—— UX 改善非 blocker
6. **W4：promote test-review-commit + reset-projection**（~1.5d）—— 第 2 consumer 出現再做

```
M1 (D1-D5):    /swift-ddd init core
M2 (D6-D10):   /swift-ddd diff + manifest
M2.5 (NEW):    W2a event-storming auto-discovery       [0.5d, unblock IAMContext]
M3 (D11-D14):  CLI distribution + skill plumbing
M4 (NEW):      W1 write-ddd-spec + SSOT enforcement    [2.5d]
M5 (NEW):      W3 /api skill v1（capped）              [3d]
M6 (deferred): W2b + W4                                [as-needed]
```

**反對 Codex 把 W4 排第 4 順位**：promoting primitive with one consumer = speculative generality。**第 2 個 consumer 出現再 promote**。

**反對 status tracking 層**（`_index.md` + frontmatter state machine + `/swift-ddd status` render）—— 1 人團隊知道自己 code 在哪個 state。**Defer 到第 2 人加入**。

##### 一句話

write-ddd-spec lives, but **render-don't-edit**；/api skill lives, but cap at 200 LoC + 1 folder；test-review-commit ≠ strict-review 因為 cadences differ；defer 一切非 ship-critical。**最便宜的防 drift 是讓 hand-editing derived view 結構上不可能**。

---

#### 🤖 Claude — R2 close-out

##### 收斂評估

R2 兩個 agent **大幅收斂**，只剩兩個 trade-off 需 user 拍板：

**1. SSOT 嚴格度**（Codex 寬鬆 vs Gemini 嚴格）：

| | Codex（B/C hybrid） | Gemini（Option D） |
|--|---|---|
| §3/§5 性質 | tool-owned block，被 --resume 覆蓋（user 不該編但能編） | 完全 generated derived，CI hash 強制不能編 |
| §6 Gherkin | docs/tasks 是 master | 存回 .ai/contexts/test-scenarios.md |
| 額外 CI | sourceHashes frontmatter 檢查 | hash check + CI gate |
| LoC | ~150 | ~180（多 CI 步驟） |

**我傾向 Gemini Option D**，理由：
- Gemini 抓到「**§6 Gherkin 存回 test-scenarios.md** 同時解了 Codex R1 抓的 missing producer 問題」—— 一石二鳥
- Codex「user 不該編但能編」是 social contract 不是 structural contract，git history 證明 social contract 會被破壞
- Option D 的 ~30 額外 LoC 換結構上不可能 drift，明確值得

**2. W4 timing**（Codex 排第 4 vs Gemini 延後）：

我傾向 **Gemini**：promote primitive with one consumer = speculative generality。延後到第 2 個 consumer。

##### 一致同意的設計（D-decisions for this discussion）

| # | 決定 |
|---|------|
| **D15** | SSOT content-type split：`.ai/contexts/` 為各 content type 的單一 source；`docs/tasks/<UC>.md` 是 derived view，§3/§5 GENERATED block + sourceHashes frontmatter + CI hash check |
| **D16** | §6 Gherkin master 位置 = **`.ai/contexts/<Agg>/test-scenarios.md`**（Gemini Option D 解 Codex 提的 missing producer） |
| **D17** | error → HTTP mapping 位置 = **`.ai/contexts/<Ctx>/api.md`** (NOT errors.md)。errors.md 是 domain catalog，api.md 是 transport |
| **D18** | /api skill v1 scope hard limits：max 200 LoC SKILL.md、6 steps、只寫 `Adapter/<Feature>/`、不讀 invariants.md、不寫 openapi.yaml、一次一 UC |
| **D19** | test-review-commit vs strict-review：**separation of cadences**（transactional per-slice vs archaeological per-PR）。test-review-commit 從 usecase/readmodel/api 內呼叫，strict-review user 主動呼叫 |
| **D20** | reset-projection 升 first-class focused skill（與 readmodel 解耦） |
| **D21** | event-storming hardcoded contexts 移除，改 auto-discovery + ambiguity gate；feature→aggregate routing cache 寫到 `.ai/contexts/_routing.md` |
| **D22** | event-storming → usecase 銜接：default fail-fast + escape hatch `--skip-business-check` + 強制 commit message |
| **D23** | Roadmap：M1 → M2 → **W2a event-storming auto-discovery (0.5d, IAMContext 不可阻塞)** → M3 → **W1 write-ddd-spec 修補 (2.5d)** → **W3 /api skill (3d capped)** → defer W2b + W4 |
| **D24** | 反對 pipeline orchestrator + 反對 `_index.md` + 反對 CLI 印 skill name —— D11 manifest 原則延伸到 status |

##### 兩個待 user 拍板




---

## 共識看板

| # | 子議題 | Claude | Codex | Gemini | 狀態 |
|---|--------|--------|-------|--------|------|
| ST1 | write-ddd-spec 填 Step 3 | 修 3 bug + `--all` mode | 修 + `--resume` + content-type SSOT split | **刪掉**，併 Gherkin 進 event-storming | **disputed（最大分歧）** |
| ST2-orchestrator | Pipeline orchestrator | 沒明說 | 不建議新長，`/swift-ddd status` 即可 | 不做，Unix philosophy | **majority：no orchestrator** |
| ST2-status | Status tracking | docs/tasks/_index.md | 三層：manifest + frontmatter + _index.md | 不做 _index.md，CLI 派生 | **disputed** |
| ST3-B1 | event-storming → usecase fail-fast | hard fail-fast | **分級** fail-fast（缺 commands → 停；缺 docs/tasks → degrade） | default strict + explicit opt-out | **majority：strict default + escape hatch** |
| ST3-B2 | event-storming hardcoded context | scan + 問 user | scan + 詞彙打分 + ambiguity gate | discovery + routing cache | **majority：scan + 問 + 快取** |
| ST3-B3 | readmodel ↔ test-review-commit | inline substeps | 先查清楚，inline 是 fallback | **升級為 focused skill**（不 inline） | **majority：先查清楚再決定** |
| ST3-B4 | SSOT 重疊 | .ai/contexts 為 master, docs/tasks 派生 | **content-type split**（HTTP/per-UC vs domain）| .ai/contexts 唯一可寫，per-UC 視圖 CLI 即時組合 | **disputed** |
| ST3-B5 | Step 6 API | 新 `/api` skill | 新 `/api` skill v1 只做 binding | **不新 skill**，`/swift-ddd api-gen` CLI | **disputed** |
| ST4 | CLI 印 skill name | init/diff 印 skill 名 | 印 worklist，不自動 chain | **永不印 skill name**，只輸出 structured state | **majority：minimal output** |

---

## 決策紀錄

| # | 決定 | 達成日期 | 依據 Round | 備註 |
|---|------|---------|-----------|------|
| D15 | **SSOT 採 Gemini Option D**：`.ai/contexts/` 為唯一可寫 source；`docs/tasks/<UC>.md` 是 100% machine-rendered derived view，**CI hash check 強制人類不可手改**（user 拍板 2026-05-13） | 2026-05-13 | R2+user | Gemini「架構強制」立場勝出 |
| D23-W4 | W4（test-review-commit + reset-projection 升 focused skill）**defer 到 W3 /api 完成後再決定**（user 拍板 2026-05-13） | 2026-05-13 | R2+user | 避免 speculative generality |
| D25 | Canvas sync 採 **Option B**：`.proposed-canvas-ops.json` 中間檔 + plan/apply 分離 CLI subcommand。Audit trail via git | 2026-05-13 | R3 | Codex+Gemini 獨立都選 |
| D26 | `es_clear_board` 硬排除 sync flow + **type-level guard**（CanvasWriteOp enum 不含 + unit test） | 2026-05-13 | R3 | 兩方共識 |
| D27 | Typed confirm "I CONFIRM REMOVE X" 是 security theater → 採 **backup + 單一 y/N**（prevent → recover） | 2026-05-13 | R3 | Gemini 立場勝 |
| D28 | Sync 不做 concurrent locking（YAGNI，1 人 + monthly + 5 年 0 觸發）；team 出現時做 git 3-way merge style 不做 per-entity hash | 2026-05-13 | R3 | Gemini 立場勝 |
| D29 | MCP adapter layer：`CanvasMCP.swift` thin wrapper，sync 透過 adapter 不直接呼叫 MCP op | 2026-05-13 | R3 | Codex 提，Gemini 同意 |
| D30 | Proposal 綁 `entityId + expected pre-image`，不只 hash（防 ABA problem） | 2026-05-13 | R3 | Codex 提 |
| D31 | Sync 是 `/swift-ddd` CLI subcommand 不是獨立 skill（D10 哲學延伸：90% mechanical 10% judgment → CLI） | 2026-05-13 | R3 | Gemini 立場 |
| D32 | **Cosmogony 確認為純 hard delete + 無 history**（user 2026-05-13 確認）→ backup 升為 **mandatory**，是 canvas write 唯一安全網 | 2026-05-13 | R3+user | 影響 W5b safety 設計與 ROI |
| D33 | **W5b 插進 M6 最末，commit 一定要做**（user 2026-05-13 拍板）→ 不是 trigger-driven defer。理由：Cosmogony 無 undo + audit trail 重要 + 未來多 context | 2026-05-13 | R3+user | Codex 提案勝 |

---

### 📌 Round 2.5 — Code → Canvas 反向 drift 議題（user + 架構師 raise，2026-05-13）

**User 從架構師那帶來的新觀察**：

> 實務上比較常發生的不是 canvas 改了 code 沒同步，而是 **code 改了沒回更 canvas**。所以反向 drift 路徑比正向更值得做。

**回顧 Gemini R1 的 prophecy**（前次 discussion）：

> 真實 SSOT 不是 bundle JSON，是業務專家腦中的 ubiquitous language；bundle 與 code 都是它的投影。雙向同步在 round-trip engineering **不是違規而是標配**（UML 工具、Sparx EA）。但 reverse sync 工程成本高，所以實務上不選，**但理由不該是「違反 SSOT」這個假命題**。

Claude R1 用「違反 SSOT」打發掉 reverse sync，**現在被證明拒絕理由是錯的**。

### 📌 Round 2.6 — MCP CRUD 能力盤點（2026-05-13）

User 已連上 Cosmogony MCP。**比預期強很多**：

| 類別 | 操作數 | 代表 |
|------|------|------|
| Read | 3 | es_get_board / es_list_contexts / es_get_project |
| Create | 14 | es_add_note / es_add_invariant / es_add_command_for_event / es_create_context… |
| **Update** | 14 | **es_update_event_properties / es_update_invariant / es_update_state_properties / es_rename_context**… |
| **Delete** | 7 | es_delete_note / es_delete_invariant / es_delete_context / **es_clear_board（核彈）** |

**這對反向 drift 是好消息**：rename / 改型別 / 改 invariant 文字都可以走 MCP，不必開 ES Tool UI。**真實 bidirectional sync 可行**。

---

## Round 3 議題（2026-05-13 啟動）

### R3-Q1：MCP CRUD 改變設計空間嗎？

Claude 提案：
- Layer 1 `swift-ddd verify-canvas` CLI（純 read，BOTH directions drift report）
- Layer 2 `/swift-ddd sync-canvas` skill（CRUD via MCP，3-tier safety）
- Layer 3 nuclear ops（`es_clear_board`）排除在 sync flow 外

需討論：
- 設計可行嗎？
- 有什麼盲區？
- D9 adapter pattern（.proposed.yaml + git diff）vs canvas sync（MCP stage + ES Tool UI confirm）—— 兩者該不該長一樣？

### R3-Q2：3-tier safety model 對嗎？

Claude 提案：
- 🟢 NEW (es_add_*)：批次 confirm
- 🟡 UPDATED / RENAMED (es_update_*)：個別 confirm + before/after diff
- 🔴 REMOVED (es_delete_*)：打字確認「I CONFIRM REMOVE X」
- ☢️ NUCLEAR (es_clear_board)：完全排除

需討論：
- 分級對嗎？
- 「打字確認」UX 是否過頭 / 不夠？
- 「個別 confirm」會不會讓 batch sync 痛到 user 不用？
- 備份策略（pre-write `es_get_board` → local JSON）夠嗎？

### R3-Q3：Concurrent edit / optimistic locking

MCP 沒看到 version / etag / locking 機制。多 user 並寫 canvas 怎麼處理？

Claude 提案：
- 寫前抓 board hash
- 每寫一筆 re-read 該 entity 確認沒被改
- 抓到 conflict → abort + 提示重跑

需討論：
- 真實 conflict scenario：兩人同時跑 sync-canvas？sync 時別人在 ES Tool UI 改？
- 重跑成本與資料安全 trade-off
- 「per-entity check」 vs 「whole-board snapshot compare」哪個對

### R3-Q4：跟 D9 adapter pattern 對稱性

D9：adapter.yaml LLM 產 → `.proposed.yaml` → user git diff merge

新 canvas sync：MCP 直接 write → user 在 ES Tool UI 看新增的 entity confirm

需討論：
- 兩者該不該長一樣？
- 是否要有 `canvas.proposed.json` 中間檔，user 先 git diff 看計畫，再 apply？
- 還是 MCP 直接 write 後 user 進 ES Tool 看？
- Trade-off：中間檔多一步 vs 直接 write 但 destructive 風險

### R3-Q5：Roadmap 修正

當前順序：M1 → M2 → W2a → M3 → W1 → W3 → defer W2b/W4

加 W5a (verify-canvas, 2d) + W5b (sync-canvas, 5-6d) 後該怎麼插？
- W5a 在 M3（diff CLI）後立刻做？
- W5b 跟 W3 並行？
- 或 W5a + W5b 一起延後到 W3 ship 後做？

---

### Round 3 — 2026-05-13

#### 🔧 Codex (GPT-5.4)

**R3-Q1**：3-layer 方向可行，但 Layer 2 不該直接 write，應拆 **plan + apply**：
- `swift-ddd verify-canvas`（read + report）
- `swift-ddd plan-canvas-sync` → `.swift-ddd/canvas-ops/<ts>.proposed.json`
- `swift-ddd apply-canvas-ops` → 讀 proposal、backup、confirm、hash check、執行、journal
- `es_clear_board` 永遠不進 sync pipeline

LoC：W5a `verify-canvas` ~300-450、W5b `sync-canvas` ~600-900。

**R3-Q2**：3-tier 大方向對，但要加 **provenance** 維度。同樣 NEW：deterministic code facts 推的 vs LLM 補的 prose 不同風險。

UX：NEW 先看 summary、UPDATED **按 tier confirm 不逐筆**、REMOVED 一次對整批 typed confirm。

備份 v1：full snapshot rotate 20 份即可，sidecar metadata 記 proposal hash + base hash + created_at。

es_clear_board 做 **type-level guard**（CanvasWriteOp enum 不含 clearBoard + unit test）。

**R3-Q3**：純 hash 是 best-effort（無 CAS）。建議 **chunk-level check**：
- 綠色 5-10 筆/chunk、黃色 1-3/chunk、紅色 1/chunk
- 每 chunk：pre-hash → 執行 → post-verify → 進下一

Abort 明確承認 partial writes、列已套用/未套用 op IDs、要 user re-plan 不要直接重跑。

Claude 漏的分散式問題：torn writes、partial visibility、**ABA problem**（hash 同值但 entity 已重建）。proposal 必須綁 `entityId + expected pre-image`，不只 hash。

**R3-Q4**：選 **Option B**。Review 應發生在 write 前。Stale proposal 用 base_board_hash 防護，apply 不符就拒絕。

**R3-Q5**：`M1 → M2 → W2a → M3 → W5a → W1 → W3 → W5b`。W5a 產生真實 drift corpus，W5b 不該在無 W5a 實戰資料前硬上。

---

#### 🌐 Gemini

> R1 prophecy（reverse sync ≠ SSOT 違規）vindicated **不等於 reverse sync 該全做**。Claude 從拒絕反向 180 度轉到「3-tier + locking + typed confirm」**是 over-correction**。

**R3-Q1**：Canvas 不是 co-SSOT 是 **co-projection**。SSOT 住業務專家腦中，bundle/code 都是 derived。Helland：operations log > current-state mutation。

Cosmogony MCP 穩定性：建議 adapter pattern（`CanvasMCP.swift` thin wrapper）但不要 over-engineer。

**Conway**：User = 1 人 monthly cadence。Layer 2 sync **應該是 CLI subcommand 不是獨立 skill**（90% mechanical 10% judgment → 歸 CLI）。Sync 是 verify 的 superset。

**R3-Q2 — 大半是劇場**：

> **Prevent vs Recover 原則**：花在 prevent → user 痛 → 跳 `--force` = 零保護。花在 recover → user 順 + 出事可救。

「I CONFIRM REMOVE X」是 theater：
1. Habituation：第 3 次 user paste from history
2. False security：打字 ≠ 理解後果
3. UX hostile：10 個 REMOVED = 10 次打字 → user 跳 --force = 零保護

CLI 傳統選 recover：`git branch -D` / `rm -rf` / `kubectl delete` / Postgres `DROP TABLE` 都不要 typed confirm。唯一典範 `terraform destroy` 也只 production tier。

| Tier | Claude | Gemini 修正 |
|------|--------|------------|
| 🟢 NEW | 批次 | ✅ |
| 🟡 UPDATED | 逐筆 | **批次 + 完整 diff list**（10 個 yes/n 後判斷力喪失） |
| 🔴 REMOVED | 打字 | **顯示 REMOVED + backup 路徑 + 單一 y/N**（backup 才是真保護） |
| ☢️ clear_board | 排除 | ✅ |

**Cosmogony recovery story 是 user 該先調查的**：
| Cosmogony 行為 | 設計 |
|---------------|------|
| 完整 history（Figma 式） | safety 全 over-engineering |
| trash / soft delete | backup belt-and-suspenders，single confirm 夠 |
| 純 hard delete 無 history | backup mandatory，typed confirm 仍 theater |

**未知答案就設計 typed confirm = premature**。

**R3-Q3 — premise 該丟**：1 人 + monthly，**5 年內同時跑兩 sync 機率 ≈ 0**。Claude 的 per-entity hash 是 dead weight：~80 LoC + 0 次觸發 = 死碼。

git 是世界最大 concurrent edit reconciliation tool，**它不 lock**。學 git：optimistic + 3-way merge。

| 階段 | 設計 |
|-----|------|
| M1（1 人 now） | **不做 locking**，pre-write `es_get_board` backup 是 enough |
| M2（team 出現） | whole-board snapshot diff（git 3-way merge），**不是** per-entity hash |

Trigger：第 2 個 canvas writer 出現時討論。

**R3-Q4**：選 **Option B**（同 Codex）。理由不是 UX，是 governance + auditability：

Helland：current state 是 lossy。Operations log 保留 intent。**Mutate canvas directly = lose intent forever**。

5 年後場景：「為何 invariant X 被 remove？」
- Option A：無解
- Option B：`git log --all -- .proposed-canvas-ops.json`

Option A 唯一 advantage 是「少一步」—— 而那一步就是 audit trail 本身。

**R3-Q5 — 殘酷 YAGNI**：

**W5a 砍到 0.5d 純檔案 diff**：
```
swift-ddd verify-canvas
  → 讀 bundle.json + .ai/contexts/*/{commands,events,invariants}.md
  → 印 drift report
```
**不碰 MCP**。user 看完報告**自己進 ES Tool UI 修**。

**真正的痛是「不知道有 drift」，不是「修 drift 太慢」**。0.5d 解 80% value。

**W5b 只有 trigger 出現才做**：
- monthly 抱怨手動 > 30 min
- 第 2 個 context 加入
- 第 2 個 writer 加入
- Cosmogony 無 undo/history

否則 W5b 是「architecture aesthetics, not engineering」。

修正 Roadmap：
```
M1-M3 (D1-D14): unchanged
M3.5: W2a auto-discovery   [0.5d]
M4:   W1 write-ddd-spec    [2.5d]
M5:   W3 /api skill v1     [3d]
M5.5: W5a-min verify-canvas [0.5d]
M6:   W2b, W4, W5b         [trigger-driven, 可能永遠不做]
```

##### 一句話
typed confirm 是劇場，backup 才是保護；concurrent locking 對 1 人 team 是 YAGNI；Option B `.proposed-canvas-ops.json` 勝；W5a 砍 0.5d，W5b defer 到 trigger。**先請 user 問 Cosmogony recovery story 再 lock in safety design**。

---

#### 🤖 Claude — R3 close-out

##### 兩 agent 強力共識（採納）

| 項目 | 共識 |
|------|------|
| **Option B**（plan + apply 中間檔） | 兩方獨立都選，Helland + D9 + git audit |
| **es_clear_board 硬排除 + type-level guard** | 兩方同意 |
| **「I CONFIRM」是 security theater** | 兩方反對，改 backup + 單一 y/N |
| **逐筆 confirm** | 兩方反對，應 batch 同 tier 一次 |
| **Cosmogony recovery story 是先決條件** | Gemini 點出，未知答案就設計 safety = premature |
| **W5a 該先 ship，W5b 該 defer** | 兩方同意，只是 W5a 範圍 disputed |

##### 我採納 Gemini 立場（撤回我 R2.6 提案）

- **W5a 砍到 0.5d 純檔案 diff**，不碰 MCP（80% value 在 visibility 不在 auto-sync）
- **不做 concurrent locking**（YAGNI，1 人 + monthly + 5 年 0 觸發）
- **Sync 是 CLI subcommand 不是獨立 skill**（D10 哲學延伸）
- **Backup-then-go 取代多層 confirm**（prevent → recover）

##### 我採納 Codex 立場

- **plan + apply 分離**（兩個 CLI subcommand）
- **provenance 維度**加進 risk tier（LLM-inferred prose ≠ deterministic code facts）
- **adapter layer 包 MCP**（`CanvasMCP.swift`）
- **ABA problem 防護**：proposal 綁 entityId + expected pre-image

---


| D16 | §6 Gherkin master 位置 = `.ai/contexts/<Agg>/test-scenarios.md`；docs/tasks §6 是 transclude view | 2026-05-13 | R2 | Gemini Option D 一石二鳥解 missing producer |
| D17 | error→HTTP mapping 位置 = `.ai/contexts/<Ctx>/api.md`，不放 errors.md | 2026-05-13 | R2 | Codex+Gemini 同意 transport ≠ domain |
| D18 | /api skill v1 hard limits：max 200 LoC SKILL.md、6 steps、只寫 Adapter/<Feature>/、不讀 invariants、不寫 openapi.yaml、一次一 UC | 2026-05-13 | R2 | Gemini anti-bloat |
| D19 | test-review-commit vs strict-review：separation of cadences（transactional vs archaeological） | 2026-05-13 | R2 | Codex+Gemini 同意 |
| D20 | reset-projection 升 first-class focused skill，與 readmodel 解耦 | 2026-05-13 | R2 | Gemini operational≠modeling 立場 |
| D21 | event-storming：移除 hardcoded contexts，改 auto-discovery + ambiguity gate；routing cache 寫 `.ai/contexts/_routing.md` | 2026-05-13 | R1 | Codex+Gemini 同意 |
| D22 | event-storming → usecase 銜接：default fail-fast + escape hatch `--skip-business-check` + 強制 commit message | 2026-05-13 | R1 | Codex+Gemini 同意 |
| D23 | Roadmap：M1 → M2 → W2a (auto-discovery 0.5d) → M3 → W1 (write-ddd-spec 2.5d) → W3 (/api 3d) → defer W2b + W4 | 2026-05-13 | R2 | Gemini critical path 排序 |
| D24 | 反對 pipeline orchestrator + 反對 `_index.md` + CLI 永不印 skill name（D11 原則延伸） | 2026-05-13 | R1+R2 | 三方同意 |

---

## 開放問題

### OQ1（根本問題）：write-ddd-spec 的存廢
- **Codex**：保留 + 修 3 bug + content-type split SSOT，~150-200 LoC
- **Gemini**：**完全刪掉**，Gherkin 併進 event-storming，per-UC 視圖用 CLI 即時組合
- **TCO 試算**：保留方案 ~200 LoC + 長期維護 N 份 docs/tasks drift 風險；刪除方案 0 LoC + 修 event-storming `--from-bundle` mode + 失去 spec-first 支線
- **需 user 拍板**：你的工作習慣是「先寫 spec 再 code」（保留 write-ddd-spec），還是「業務直接落地 .ai/contexts/，code 直接從那邊出」（刪掉）？

### OQ2：Step 6 API skill 還是 CLI subcommand？
- Claude/Codex：新 skill `/api`
- Gemini：CLI `/swift-ddd api-gen`（機械題不該 skill 化）
- 關鍵變數：API 層需要 LLM judgment 嗎？（HTTP status mapping、DTO 命名 quirks）

### OQ3：test-review-commit / reset-projection 該怎麼處理？
- Codex/Gemini 共識：**先去看 user 同事的 test-review-commit/reset-projection skill 內容**再決定
- 不在 focused list 但 readmodel 依賴它們 —— 是漏 export 還是刻意排除？

### OQ4：SSOT 分工 — content-type split 還是 master/derived 還是「只有一份」？
- Claude：master/derived（一份權威 + 一份視圖）
- Codex：content-type split（domain vs per-UC vs transport 各自獨立）
- Gemini：只有一份（`.ai/contexts/` 唯一可寫）
- 這直接決定 OQ1 答案

### OQ5：CLI output 的耦合度
- Claude：印 skill 名稱當 next-step hint
- Codex：印 worklist 結構化 segments
- Gemini：**永不印 skill name**，只輸出 manifest delta
- 這跟 D11 manifest 原則一致性有關

---

## 下次討論指引

### 進度摘要

Round 1 完成。**最大分歧出現在 ST1（write-ddd-spec 存廢）**：

- **Codex**：保留 + 修 3 bug + content-type split SSOT（~150-200 LoC）
- **Gemini**：**完全刪掉**，併入 event-storming + CLI 即時組合 per-UC 視圖
- Claude R1 站 Codex 那邊（修而非刪），但 Gemini 的 Evans/Conway 論證很強

其餘子議題大致 majority：
- 無 orchestrator
- 無 _index.md（CLI 派生即可）
- event-storming → usecase 採「strict default + escape hatch」
- event-storming hardcoded：scan + ambiguity gate
- readmodel test-review-commit：**先去看那個 skill 內容**再決定 inline / 升級
- CLI output：minimal，不該 print skill name

### 待處理事項

**Round 2 之前必須先解 OQ1**：write-ddd-spec 存廢取決於 user 工作習慣。其他子議題會跟著 OQ1 走。

並列要做：
- 去 user 同事工作環境找 `test-review-commit` / `reset-projection` skill 的 SKILL.md 看內容（解 OQ3）
- 確認 IAMContext repo 是否已有任何 `docs/tasks/` 內容

### 閱讀建議

下一輪 reviewer 必讀：
- Codex ST1 提的 "test-scenarios.md missing producer" 觀察
- Gemini ST1 Evans + Conway 論證（write-ddd-spec 是 user 個人 ceremony 不該升 team contract）
- Gemini ST2 的 4 個 cycle（C1-C4）說明為什麼不該做 orchestrator
- Gemini ST3 B3 提的「橫切關注」論點（test-review-commit 應升 first-class skill）

### 注意事項

- ST1 的決定會骨牌：刪掉 write-ddd-spec → 不需 docs/tasks/<UC>.md → SSOT 自動單一化 → OQ4 自動解
- 保留 write-ddd-spec → 必須處理 SSOT 重疊 → OQ4 需要明確 content-type split rules
- 別忘了 D1-D14 baseline：CLI 是 swift run（不打包 binary）、單一 `/swift-ddd` skill、git 為 transaction、stateless
