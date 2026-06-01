---
name: bundle-plan
description: Genesis planning skill. Inside a Genesis-bootstrapped project, /bundle-plan <bundle.json> splits a Cosmogony bundle into N per-UC contract-first task specs under docs/tasks/, filling §1/§2/§3/§7 mechanically from the bundle and §5/§6 via LLM-inference + per-UC user confirmation (plan-time gap fill, method X). Plan-only — never runs codegen. Supports --replan to diff a changed bundle against existing task specs. Requires `genesis bundle-parse` (Phase 1.q).
argument-hint: <bundle.json> [--replan]
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# /bundle-plan — Split a Cosmogony bundle into per-UC task specs

> Genesis version: {GenesisVersion} · Generated: {Date}

## 你的任務

把一份 Cosmogony bundle JSON 拆成 **N 份 per-UC task spec**（每個 write use case 一份，寫到 generated project 的 `docs/tasks/<UseCaseName>.md`），每份是 contract-first 8-section spec。§1/§2/§3/§7 從 bundle 機械填，§5/§6 由你先推測一版 → user 逐 UC 確認後寫入（**method X**：gap 在 plan 階段一次補完，下游 fill skill 執行時純讀不再打斷 user）。

### 絕對約束（不可違反）

- **plan-only** — 絕不呼叫 `genesis new`、絕不 emit Swift code、絕不跑 codegen。本 skill 只動 `docs/tasks/*.md` markdown。
- **不自己解析 bundle JSON schema** — 一律透過 `genesis bundle-parse <path>` 拿 canonical parse 結果（Genesis 是 schema 權威，避免 drift）。
- **只產 write UC 的 task spec** — read UC（`get` / `list` / `find` 開頭）不產（read-side 由其他流程處理）。
- **不改既有 skill** — 與 `write-ddd-spec` 分流並存（後者是無 bundle 時的 manual single-UC 入口），不呼叫它。

## 輸入解析

`$ARGUMENTS`：
| 形式 | 處理 |
|------|------|
| `<bundle.json>` | 全新 plan：對 bundle 每個 write UC 產 task spec |
| `<bundle.json> --replan` | diff 模式：對比既有 `docs/tasks/*.md` 與新 bundle |
| 空 / 無 bundle 路徑 | **exit 1**：`usage: /bundle-plan <bundle.json> [--replan]` |

`bundle.json` 路徑不存在 → **exit 1**：`bundle not found: <path>`。

## Phase 0 — 取得權威 parse 結果

**不要自己讀 / parse bundle JSON 的 schema**。改跑：

```bash
genesis bundle-parse <bundle.json>
```

- `genesis` 不在 PATH → **exit 1**：`genesis CLI not on PATH; run 'genesis install-skills' from the Genesis repo or fix PATH`。
- `genesis bundle-parse` exit ≠ 0（bundle invalid）→ 把它的 stderr 原樣印給 user，然後 **exit**（bundle 有問題，user 先修 bundle 再重跑）。
- 成功 → stdout 是 canonical FullBundle JSON。從中取：
  - `context`
  - `aggregates[]`（含 `aggregateSpecId` / `name` / `identityName` / `invariants[]`）
  - `useCases[]`（含 `useCaseSpecId` / `useCase` / `aggregate` / `aggregateSpecId` / `input[]{name,rawType}` / `emittedEvent` / `eventPayload[]{name,rawType}` / `preconditions[]`）
  - `readModels[]`（含 `eventRefs[]{name,sourceAggregate}` — §7 cross-aggregate 反查用）

## Phase 1 — 定位 generated project + 既有 task specs

- 確認 cwd 是 generated project root：存在 `.ai/contexts/` **或** `Package.swift`。都沒有 → **exit 1**：`not inside a Genesis-bootstrapped project; cd into the generated project root first`。
- task spec 目標目錄 = `docs/tasks/`（相對 project root）。
- 全新 plan：`docs/tasks/` 不存在 → `mkdir -p docs/tasks`。
- `--replan`：`Glob docs/tasks/*.md`，讀每檔 frontmatter 的 `useCaseSpecId` + `status`，建 `specId → 既有 spec 路徑/status` 的 map。

## Phase 2 — write UC 篩選 + 排序

- **篩 write UC**：`useCase` lowercased **不**以 `get` / `list` / `find` 開頭。read UC 跳過。
- **排序（sequential）**：同一 aggregate 內，create UC（`useCase` lowercased prefix `create` / `establish`）排在其他 UC 之前。跨 aggregate 維持 bundle 內順序。每個 task spec frontmatter 記 `order: N`（1-based 全域序）。

## Phase 3 — 每 write UC 機械填 §1 / §2 / §3 / §7

對每個 write UC（`<ucPascal>` = UpperCamel(useCase)，`<A>` = aggregate name）：

### §1 Goal
`<useCase 的中文化動詞> <A>，發出 <emittedEvent> event`。例：`createUserAccessProfile` → `建立 UserAccessProfile，發出 userAccessProfileCreated event`。

### §2 Bundle Reference（auto-extracted）
直接從 parse 結果填：
- **Input**：每個 `input[]` 的 `name: rawType`
- **Emits**：`emittedEvent`
- **Payload**：每個 `eventPayload[]` 的 `name: rawType`
- **Traceability**：`useCaseSpecId` / `aggregateSpecId`

### §3 Invariants（機械填）
從該 UC 所屬 aggregate（`aggregateSpecId` 對應）的 `invariants[]` 填，每條列 `name` / `errorCode` / `rules`。無 invariants → 標 `（此 aggregate 無宣告 invariants）`。

### §7 Cross-aggregate Effects
從 bundle 結構推：掃 `readModels[].eventRefs[]`，若某 readModel 訂閱本 UC 的 `emittedEvent`（`eventRefs[].name == emittedEvent`）→ 列「此 event 被 ReadModel <name> 訂閱」。無 → 標 `（無跨 aggregate 訂閱）`。

## Phase 4 — §5 / §6 推測 + 逐 UC 確認（method X）

**一次處理完所有 write UC 的確認**（plan 是 batch 思考時機，不留到 execute 才零碎問）。對每個 UC：

### §5 Error Cases（你先推一版）
依 §3 invariants 推：每個 invariant → 一個 domain error case + HTTP status（三欄表 `條件 | Domain Error | HTTP Status`）。非 create UC 必加一條 `aggregateNotFound → 404`。印給 user：

```
[<ucPascal>] §5 推測的 error cases：
| 條件 | Domain Error | HTTP |
| ... |
確認 / 修改？（enter 接受 / 輸入修正 / skip 跳過標 TODO）
```

### §6 Gherkin Scenarios（你先推一版）
推 happy path（`Scenario Outline` + `Examples` 跑多組合法 input）+ 每個 §5 error 一個 `@error Scenario`。印給 user 同樣確認 / 修改 / skip。

user `skip` 或直接 enter 跳過某段 → 該段標 `TODO`，不留空白。

## Phase 5 — 寫 task spec MD

每 UC 寫 `docs/tasks/<ucPascal>.md`：

```markdown
---
useCase: <A>.<useCase>
useCaseSpecId: <uuid>
aggregate: <A>
sourceBundle: <bundle path>
order: <N>
status: ready
created: <YYYY-MM-DD>
runbook:
  - run /usecase <useCase>
  - run /api <useCase>
  - run swift test
---

# <ucPascal>

## 1. Goal
<§1>

## 2. Bundle Reference (auto-extracted)
<§2>

## 3. Invariants & Business Rules
<§3>

## 4. High-level Goal
（可選，user 補；未補標 TODO）

## 5. Error Cases
<§5 確認後>

## 6. Test Scenarios (Gherkin)
```gherkin
<§6 確認後>
```

## 7. Cross-aggregate Effects
<§7>

## 8. Implementation Notes
（可選）
```

**conflict check**（非 --replan）：`docs/tasks/<ucPascal>.md` 已存在 → 列出問 user `overwrite / skip`，不靜默覆蓋。

## Phase 6 — `--replan` diff

對比新 bundle 的 write UC（用 `useCaseSpecId` 當 identity）與既有 `docs/tasks/*.md` frontmatter `useCaseSpecId`：

| 情況 | 判定 | 動作 |
|------|------|------|
| **新 UC** | specId 在 bundle、既有 spec 無 | 走 Phase 3-5 append 新 task spec |
| **modified UC** | specId 兩邊都有，但逐欄比對 `input` / `emittedEvent` / `eventPayload` 有差 | 既有 spec `status: ready`（未跑）→ 重寫該 spec 保持 ready；既有 status 非 ready（已被 /pickup 跑過）→ 產 `docs/tasks/<ucPascal>-amendment-<YYYY-MM-DD>.md`（列出 changed fields）+ 原 spec status 改 `needs-update` |
| **removed UC** | specId 既有 spec 有、bundle 無 | 原 spec status 改 `superseded`（**不刪檔**，保留歷史）|
| **unchanged UC** | specId 兩邊都有、逐欄無差 | skip 不動 |

逐欄比對 = `input[]`（比 name + rawType 集合）/ `emittedEvent`（字串）/ `eventPayload[]`（比 name + rawType 集合）。

diff 完印 summary：`<N> added / <M> modified / <K> removed / <U> unchanged`。

## Framework constraints（沿用，不可破壞）

- `genesis bundle-parse` 是唯一 bundle 解析入口（Phase 1.q）— 不複製 schema parsing。
- task spec 8-section 格式與 `write-ddd-spec` 互通；但本 skill 是 bundle-wide 批次 + method X，**不**呼叫 `write-ddd-spec`。
- read UC 不在 scope。

## 與其他 skills 的關係

- 上游：Cosmogony bundle JSON（透過 `genesis bundle-parse` 消費）。
- sibling：`write-ddd-spec`（無 bundle 時 manual single-UC 入口，分流並存）。
- 下游：`/usecase` / `/api` / `/presenter-fill` / `/readmodel-mutation`（讀本 skill 產的 task spec 當 input，fill execute body）；`/pickup`（逐 task 執行）。
- 解耦：codegen 仍由 user 手動跑 `genesis new`（plan-only，與 codegen 分離）。
