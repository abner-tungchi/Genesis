---
topic: "No-bundle read-side skill 設計：建 readmodel/projection/presenter/read-api/test，重現 OC AuditQuotingAggregate 架構、不經 bundle"
status: consensus
created: "2026-06-14"
updated: "2026-06-14"
participants:
  - Claude (Opus 4.8)
  - understanding workflow auditquoting-readside-inventory（wf_d9e76c6c-c92；3-lens read-side inventory + synthesis）
  - design discuss workflow read-skill-design-discuss（wf_b34faef0-447；3-lens arch/integration/scope + synthesis）
facilitator: Claude
rounds_completed: 1
mode: default
grounding: 全程 file-traced 對照 OC AuditQuotingAggregate（read 側全層）+ Genesis read-side 模板
premises:
  fixed:
    - "skill 是 LLM prose（如 /readmodel、/test-gen），裝進 Genesis-generated 專案、直接寫檔（Read/Write/Edit/Glob/AskUserQuestion），不寫 bundle.readModels[]。"
    - "北極星：(1) 目標架構=AuditQuoting 讀側；(2) 整合約束=Genesis-form 編得過；(3) 無 bundle→互動+infer 既有專案。"
  overturned:
    - "（修正）原 inventory 建議 3 skill（/read-scaffold + /read-fill + /read-test）→ discuss 改為 2 net-new（/read-projector + /read-view）+ 復用既有 /readmodel-mutation + /presenter-fill。"
---

# No-bundle read-side skill 設計

## 議題
user 要一個（或數個）**不經 bundle** 的 skill，在 Genesis-generated 專案內互動式建出完整讀路徑（readmodel + projection + presenter + read-api + test），結構等同 OC AuditQuotingAggregate（亦為驗證條件）。

## 關鍵發現（file-traced）
OC 讀側有**兩種物理不同 shape**：
- **passthrough projector**（`Usecase/Projector/Get<Noun>/`，16 dirs）：ReadModel + Presenter[+ co-located element DTO] + projection.js + projection-model.yaml entry。讀 model 在 GET 當下由 Presenter coordinator on-demand 重播 JS-projected `OC_Get<Noun>-<id>` link stream。
- **aggregating view**（`Adapter/Get<View>/`，4 個：GetOperationInfo/GetEvidenceInfo/GetPredecessorServiceInfo/GetQuotingProofs）：一個 ApplicationService fan-out 多個 presenter + discriminator switch + not-applicable rule，output 是 discriminated-enum DTO；**不**進 projection-model.yaml（compose 既有 presenter、不 project 新 stream）。

→ 一個 skill 硬包兩種 shape 會內部分支、糊掉 idempotency。故拆 2。aggregating AS body 有真 judgment（discriminator/variant/fieldset 矩陣 + not-applicable），`/presenter-fill` 對 >1-field 直接 exit 3 → 不能交它，`/read-view` 自己從 mini-spec 生 body（無 fatalError 洞）。

## 決策（8 forks 全鎖，詳見 spec 表）
- **D-SPLIT**：`/read-projector`（passthrough unit）+ `/read-view`（aggregating API）；復用 `/readmodel-mutation`（when body）+ `/presenter-fill`（trivial passthrough AS）。test 折進各 skill 條件產，不獨立 /read-test。
- **D-Q1a/b/c**：ApiHandler 只 append read method（Genesis-form 非 generic）；notFound 預設 generic、有 not-applicable rule 自動切 named（atomic 3-file lockstep）；422 條件式（有 rule 才 emit，handler/openapi 一致）。
- **D-Q2**：無 QueryError→ApiError mapper；inline raw-case catch；`/read-view` handler 含 DTO→Components.Schemas response switch。
- **D-Q3**：`/read-view` 消費 persisted YAML mini-spec（discriminator/variants/notApplicable），首跑互動產出、replay 讀檔；on-disk tree 仍唯一 SSOT。
- **D-Q4**：Input 命名 layer-determined（presenter `Get<Noun>Input:CQRSProjectorInput`、AS `Get<View>ApplicationServiceInput`）。
- **D-Q5**：test tier 依 shape 條件（projector→Projector tier；view→AS+Api tier）。
- **D-Q6**：element/output DTO 由擁有其檔的 skill co-located 產、glob-skip if 已存在。
- **D-Q7**：2-class idempotency（Class A own-file glob-skip；Class B shared-file key-anchored upsert + fail-closed on ambiguous）；on-disk tree 唯一 SSOT、無 shadow JSON。
- **D-Q8**：`Task.sleep(0.5)` seam + prerequisite header；poll helper defer。
- **D-placement**：passthrough→Projector/+projection-model.yaml；aggregating→Adapter/、不進 projection-model.yaml。
- **carry-over guard**：`/read-projector` 讀 event.yaml 驗 `key.fromEventPayload` 存在（補 no-bundle 失去的 ReadModelRenderer compile-time guard；錯 = silent-empty read）。

## 驗證計畫
clean-room golden-structure compare + build gate + idempotency gate（agent 自動）：fresh Genesis 專案（AuditQuoting write-side 形）→ install 2 skill → 驅動 16 projector + 4 view → 結構 golden-compare OC（檔案集/placement/projection-model/openapi 422-conditionality/test tier/id-rename/named-vs-generic）+ `swift build` clean + 跑第二次零 diff。read-test 行為腿走 Human gate（Docker+KDB+/reset-projection）。

## 開放問題（user）
無 blocking。唯一可選 product framing：named-error auto-on-when-not-applicable（已採，對齊 AuditQuoting）vs explicit opt-in（1-line tweak）。per-invocation 的 events/key.fromEventPayload（/read-projector）與 mini-spec（/read-view）是 skill 互動的固有輸入、非 pre-spec 決策。

## 下次指引
spec_ready=true。NEXT → write-spec（done：`docs/tasks/2026-06-14-no-bundle-read-skills.md`）→ audit-spec → impl（M1 read-projector → M2 read-view）→ impl-review → clean-room validation。
