---
topic: Phase 1.q — /bundle-plan skill + Genesis skill home migration (per-project → global)
status: ready
date: 2026-05-28
origin: 1-on-1 (Claude + user) — no multi-LLM workflow (avoids session limit retry; topic narrow + decisions locked upfront)
references:
  - docs/tasks/2026-05-27-phase-1p-write-dto.md (immediate predecessor)
  - ~/.claude/skills/write-ddd-spec/SKILL.md (related but standalone; not migrated in 1.q)
  - Sources/GenesisCore/Resources/Templates/skills/ (current per-project skill source)
  - OC `Adapter/EditBusinessTaxFilingMethod/BusinessTaxFilingMethodDto.swift` (write-side DTO pattern, depends on 1.p)
  - Cosmogony Event Storming Tool (bundle JSON producer, parallel track for schema v2)
---

# Phase 1.q — /bundle-plan skill + skill home migration

## 議題定義

### 背景

Phase 1.p ship 後，Genesis 已能從 bundle JSON 一鍵 codegen 出可 build 的 Swift DDD project（86 files for IAM bundle）。後續 per-feature 開發依賴 4 個 fill-in skills（`/usecase`, `/api`, `/presenter-fill`, `/readmodel-mutation`）— **目前由 `genesis new` 安裝到 `<project>/.claude/skills/`**（per-project copy）。

User 在 Layer 2 dogfood + Layer 3 規劃時識別到 2 個結構性問題：

**問題 1**：bundle JSON 已是 spec，缺一個 planner 把 bundle 拆成可逐個執行的 task spec — 每個 UC 一份 8-section spec，內含 §3 invariants（從 bundle 自動填）+ §5 error cases + §6 Gherkin scenarios（LLM 推測 + user 確認）。這個工作目前由 `write-ddd-spec` skill 部分覆蓋（per-UC interactive），但 (a) 它是 OC 手寫時代產物，下游接 `/tdd-implement` 而非 Genesis 路線；(b) 它一次只做 1 UC，沒有 bundle-wide planner 的角度。User 想要新 skill `/bundle-plan` 接管「整 bundle → N 份 task spec」的職責。

**問題 2**：per-project skill 安裝模式造成兩個痛點：
- 同樣的 skill 散落在每個 Genesis-bootstrapped project 內 `<project>/.claude/skills/`，更新時 N 個 project 要各自處理
- Skill 跟 Genesis CLI 邏輯耦合（bundle schema、template 路徑、emit pattern），但 install 是分離的 → 版本不對齊風險

User 拍板：**所有 Genesis-相關 skill 改為全局安裝**（`~/.claude/skills/`），包括新做的 `/bundle-plan` 和既有 4 個 fill-in skills。`genesis new` 從此**不再** emit project-level skill。

### 目標

1. 新增 `/bundle-plan` skill，把 bundle JSON 拆成 N 份 per-UC task spec（method X — gap fill 在 plan 時完成，execute 時純機械）。
2. 把 `Sources/GenesisCore/Resources/Templates/skills/` 內 4 個 skill 從 per-project install 改為全局 install。
3. 新增 `genesis install-skills` 命令（一次性安裝到 `~/.claude/skills/`）。
4. `genesis new` 拿掉 skill emission。

### 範圍

#### 討論內

- `/bundle-plan` skill 設計（input/output/interaction flow）
- per-UC task spec 格式（沿用 contract-first 8-section，但 sourced from bundle + LLM）
- bundle diff replan 機制（`/bundle-plan --replan` 對比新舊 bundle 產 amendment task）
- `genesis install-skills` 命令設計（一次性、覆蓋 policy、版本檢查）
- Skill 跟 Genesis CLI 版本對齊機制（auto upgrade-skills + skill 啟動時 version check）
- 既有 `<project>/.claude/skills/` 處理策略（保留 vs 提示移除）

#### 討論外（Non-goals）

- 不改 `/usecase`, `/api`, `/presenter-fill`, `/readmodel-mutation` 的 skill 行為 — 只搬家，不改邏輯（Phase 1.q.1 / 1.r 處理）
- 不做 Cosmogony bundle schema v2 對接（Phase 1.p 依賴 schema v2，1.q 不額外處理）
- 不取代 `write-ddd-spec` 既有 skill — 它仍是 per-UC interactive，與 `/bundle-plan` bundle-wide 互補（討論末尾另議）
- 不處理 codegen 本身（`/bundle-plan` plan-only，codegen 仍由 `genesis new` CLI 操作）
- 不處理 task spec 執行 runner（執行邏輯由 `/pickup` 或 fill-in skills 自行處理）
- 不處理多 user / 多機 sync 場景（單 user 假設）

### 約束

- Single-user / single-machine — install 策略可以激進，不必處理 sync 衝突
- Bundle schema 變動慢（Cosmogony 由 user 控制）— version mismatch 是低頻事件
- 既有 Genesis-bootstrapped project 數量極少（IAM context dogfood 是唯一 real bundle 案例）— migration cost 可接受
- `~/.claude/skills/` 在多個 project 共享 — 任何 skill 修改影響全 project，需謹慎

---

## 決策紀錄

### D1. `/bundle-plan` 是 plan-only，不做 codegen

**Decision**: `/bundle-plan` 純 planner，不呼叫 `genesis new`、不 emit Swift code。Codegen 仍由 user 手動跑 `genesis new --from-bundle X`。

**Rationale**: User 偏好保留 codegen 為人為操作（檢查、暫停、調整 adapter config 的時機）。把 codegen 跟 planning 解耦，職責清楚 — planner 動 markdown，codegen 動 Swift。

### D2. Task granularity = per-UC

**Decision**: 1 UC = 1 task spec 檔。IAM bundle 7 UC → 7 份 task spec MD。

**Rationale**: User 看法 — 每個 UC 都有業務邏輯 + 測試需求，這個組合最穩。Per-aggregate 顆粒太大、commit unit 不好 review；mixed scheme task 數爆炸。

### D3. Task 順序 = sequential

**Decision**: Task 嚴格順序執行，前一個 done 才能跑下一個。Plan 階段產 task list 時排好順序（至少 createUC 先於 update/delete UC，因為 aggregate id existence anchor 約束）。

**Rationale**: 最簡單、最好追蹤 progress。Dependency graph 過早優化；user 自選順序容易出錯。未來真撞到瓶頸再升級。

### D4. Bundle 改了 → diff replan

**Decision**: `/bundle-plan --replan` 比對新舊 bundle，產 amendment task。已 done 的 task 對應 UC 變了 → 產「Phase X: update <UC> signature」amendment task；未 done 的 task 對應 UC 變了 → 重寫該 task spec 並 reset status；UC 整個刪了 → mark task `superseded`；新 UC → append new task。

**Rationale**: User 偏好 (b) — replan 比 lock 體驗好。實作成本 medium（diff bundle JSON 結構並非 trivial，但 schema 結構穩定）。Phase 1.q 範圍內先做 happy path（add/modify UC），UC 刪除 / aggregate 大改造放 Phase 1.q.1。

### D5. Method X — gap fill 在 plan 時完成（不在 execute 時）

**Decision**: `/bundle-plan` 跑完，每份 task spec 都「完整」：
- §1 Goal / §2 Bundle Reference / §7 Cross-aggregate 從 bundle 機械填
- §3 Invariants 從 bundle `invariants[]` 機械填
- §5 Error Cases / §6 Gherkin Scenarios 由 LLM 推測一版 → user 確認 / 修改 → 寫入 spec

Plan session 變長（IAM 7 UC × 確認 §5+§6 兩段 = 14+ turn），但執行階段 task 是純機械 — skill 讀完整 spec、不再打斷 user。

**Rationale**: User Q5 拍板「LLM 產出推測 + 使用者確認、修改」自然導向 method X — gap 必須在 spec 寫完前確認，否則 execute 時還是會問。Plan 階段是「batch 思考時機」，比執行時零碎打斷更尊重 user 專注度。Spec 變 review artifact，未來想看「當時這個 UC 業務怎麼想的」直接打開檔案。

### D6. Task spec 角色 = runbook + skill input（兩者並行）

**Decision**: Task spec 同時是：
- **Runbook（給 user 看）**：spec 內含 step list（「run /usecase X」「run /api X」「run swift test」），user 可逐步追 progress
- **Skill input（給 skill 讀）**：skill 執行該 step 時讀對應 § 段落取得 context（§3 invariants → validation body、§5 errors → error case throws、§6 Gherkin → test cases）

(a) "task lists commands" 跟 (b) "skill reads spec" 是同一機制的兩種說法，在 method X 前提下無分歧。

**Rationale**: 在 method X 下，spec 在執行前已完整 → skill 純讀、不問 → 兩種 framing 等價。User 對 (a)/(b) 的猶豫是「擔心 spec 不完整時擾民」，但 method X 消除了該擔心。

### D7. Task spec 儲存位置 = generated project 的 `docs/tasks/`

**Decision**: `/bundle-plan` 把 task spec 寫到 generated project 的 `docs/tasks/<UseCaseName>.md`（如 `docs/tasks/CreateUserAccessProfile.md`）。**NOT** Genesis CLI repo 自己的 `docs/tasks/`。

**Rationale**: Generated project 是獨立 repo、用自己的 `docs/tasks/`。Genesis CLI 開發本身用 `docs/tasks/<date>-phase-X-xxx.md`（phase prefix）— 兩者格式不同、目錄不同、不會撞。User Q7 確認 (a)。

### D8. Skill 安裝位置 = 全局 `~/.claude/skills/`

**Decision**: `/bundle-plan` 跟既有 4 個 fill-in skill 全部住在 `~/.claude/skills/{bundle-plan, usecase, api, presenter-fill, readmodel-mutation}/`。**NOT** 在 generated project 內 `.claude/skills/`。

**Rationale**: User Q8 確認 (a)。理由：
- 一個 Genesis 安裝對應一套 skill，跨所有 generated project
- 更新時改一處、全 project 自動受益
- Skill 邏輯跟 bundle schema 強耦合，由 Genesis 是 schema 權威 → 安裝集中
- Single-user / single-machine 場景下沒有 sync 痛點

### D9. `genesis new` 停止 emit project-level skill

**Decision**: `genesis new` 內 `Sources/GenesisCore/Resources/Templates/skills/` 的 install 邏輯整段移除。Generated project 內**不再**出現 `.claude/skills/` 目錄。

**Rationale**: 跟 D8 配套 — 既然 skill 全局住，project 級不應該 emit。保留 project-level 會造成「兩處同名 skill 哪個生效」的歧義（Claude Code 通常 prefer project-local）。乾淨切。

### D10. `genesis install-skills` = 一次性命令

**Decision**: 新增 CLI 命令 `genesis install-skills`：
- 把 `Sources/GenesisCore/Resources/Templates/skills/` 內所有 skill 部署到 `~/.claude/skills/`
- 一次性運行（user 跑 `brew install genesis` 後手動跑一次，或由 `brew upgrade genesis` 觸發）
- 不需要每次 `genesis new` 都跑

**Rationale**: User 確認「一次性」即可。不必每 project 拉一次新版本。

### D11. Upgrade policy = 覆蓋

**Decision**: `genesis install-skills` 對既存 `~/.claude/skills/<name>/` **直接覆蓋**，不做 3-way merge、不問 user。

**Rationale**: User 拍板「覆蓋」。理由：
- Skill 是 Genesis 出的 release artifact，user 手調 SKILL.md 是 anti-pattern
- 3-way merge 複雜度高、衝突處理痛苦
- 真要客製化，可以 fork Genesis repo 改 template，install-skills 從 fork 出

### D12. 版本對齊 = brew upgrade 自動 install + skill runtime version check

**Decision**: 兩層 safety：
1. **Brew formula 加 post-upgrade hook**：`brew upgrade genesis` 自動跑 `genesis install-skills`，使 skill 版本永遠跟 CLI 對齊
2. **Skill 啟動時 version check**：每個 skill 在 SKILL.md frontmatter 加 `requiredGenesisVersion: ">= X.Y"`，skill 第一步呼叫 `genesis --version` 比對，落後直接 abort 提示 user upgrade

**Rationale**: (c) auto upgrade-skills 是主要機制（user 不會忘記 sync）；(b) runtime check 是 backup（user 手動安裝舊 Genesis 也不會 silent corruption）。兩層 cost 都低、互補。

### D13. 既存 `<project>/.claude/skills/` 處理 = 警告 + 不自動刪

**Decision**: `genesis install-skills` 跑時掃 user `~/JiaBao/` 下所有 git repo，若發現 `<repo>/.claude/skills/{usecase,api,presenter-fill,readmodel-mutation}/` 存在，stderr 印 warning：

```
⚠ Found project-local Genesis skills at /path/to/project/.claude/skills/.
  These will SHADOW global skills. Consider removing manually:
    rm -rf /path/to/project/.claude/skills/{usecase,api,presenter-fill,readmodel-mutation}
```

不自動刪 — user 可能改過 / 在用 / 還沒準備好。

**Rationale**: 自動刪 user 檔案太激進；不警告又會 silent shadow。中間路。Single-user 場景下警告就夠 — user 看到就會處理。

---

## 開放問題（spec 階段再收斂）

### Open1. `requiredGenesisVersion` 字串比對精度

D12 提到 skill frontmatter 加 `requiredGenesisVersion: ">= X.Y"`。但：
- 「X.Y」是 SemVer 還是 phase ID（`phase-1.q`）？
- Skill 在 SKILL.md 內，怎麼動態執行 version check？SKILL.md 是 markdown，沒有 code execution
- 要靠 skill 第一步**告訴 Claude 跑**「`genesis --version` 然後手動比對」嗎？

可能解法：skill SKILL.md 內 Step 0 寫死「先呼叫 `genesis --version`，若版本 < X.Y 直接 exit」。但這變成 skill 邏輯的一部分、不是 frontmatter。

### Open2. `/bundle-plan --replan` 的 diff 演算法細節

D4 提了高層方向（add/modify/delete UC / aggregate state field 改），但具體：
- 怎麼判定「兩個 UC 是同一 UC」？用 `useCaseSpecId` UUID（Cosmogony 給的）就好嗎？穩定嗎？
- 怎麼判定「同一 UC 的 input field 改了」？逐欄比對 name + type？
- 已 done task 對應 UC 改了 → amendment task spec 內容怎麼寫？是「diff text + skill 跑」還是「重整段 spec 標 status: needs-update」？

### Open3. `/bundle-plan` 跟既有 `write-ddd-spec` 共存

`write-ddd-spec` skill 仍存在、仍是 per-UC interactive。Phase 1.q 不砍它（per scope boundary）。但 `/bundle-plan` 也產 per-UC spec — 兩者輸出對 user 看起來會否混淆？

可能解法：
- (a) `/bundle-plan` 內部直接 call `write-ddd-spec` 處理每個 UC（重用既有 skill）
- (b) `/bundle-plan` 自己實作 per-UC spec gen 邏輯，`write-ddd-spec` 變 deprecated
- (c) 兩者分流：`/bundle-plan` 從 bundle 批次處理（auto inference），`write-ddd-spec` 仍是 manual single-UC 入口（無 bundle 時用）

我傾向 (a) 重用，但 spec 階段才確認。

### Open4. `genesis install-skills` 跨 OS 路徑差異

`~/.claude/skills/` 在 macOS / Linux 一樣，但若未來 Genesis 跨平台支援 Windows，路徑會是 `%USERPROFILE%\.claude\skills\`。Phase 1.q 是否就要設計成跨平台、還是先寫死 macOS path？

### Open5. Skill 共用程式碼的問題

`/bundle-plan`, `/usecase`, `/api` 都會解析 bundle JSON — 是否共用一份 bundle parser helper？Skill 是 markdown SKILL.md，不能 import 他 skill 的程式碼。每個 skill 內各自寫 bundle parsing logic 是現實，但會有 drift 風險。

可能解法：
- (a) 每個 skill 各自寫（高 drift）
- (b) 共用 helper 放在 `~/.claude/skills/_shared/bundle-utils.md` 之類，被 skill `Read` 進來（不算 import，但提供唯一 source of truth）
- (c) 強制 skill 都跑 `genesis bundle-parse <path>` CLI 命令、CLI 是真權威 parser，skill 拿 JSON output 解析

(c) 最乾淨但 Genesis 要加新 CLI subcommand。先記，spec 階段再決定。

---

## 分歧紀錄（minority opinions）

無 — 本次討論為 1-on-1（Claude + user），無多 LLM 平行對審。所有 D1-D13 為 user 直接拍板，Claude 提建議並標註偏好（D5 method X、D8 全局 skill）皆獲確認。

若 spec 階段（Phase 1.q write-spec）想多 LLM 補審，建議：
- 跑 `audit-spec --external codex` 對 Codex 補審
- 或對 D12 版本對齊機制單獨開 sub-discussion（Gemini 強項）

---

## 後續行動

1. **Phase 1.p 仍是當前優先 ship**（依賴 Cosmogony schema v2）。Phase 1.q 排在 1.p / 1.p.1 之後。
2. Phase 1.q spec 寫作（`write-spec` from 此 discussion MD）建議等 1.p ship 完再啟動 — 避免 1.p.1 `/api` skill 更新 跟 1.q 的 skill 搬家撞到 ApplicationService TODO marker 解析邏輯。
3. 安排順序：**1.p → 1.p.1 → 1.q**，其中 1.q 開始時把 1.p.1 ship 出的 `/api` skill 一併搬到全局。
4. Phase 1.q.1 預留：UC delete / aggregate 大改造 / cross-OS 路徑 / shared bundle parser CLI 命令（若 Open5 選 (c)）。
