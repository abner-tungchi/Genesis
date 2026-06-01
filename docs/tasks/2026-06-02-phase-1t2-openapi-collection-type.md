# Phase 1.t.2 — OpenAPI collection 型別修正（PA-F5）

## 來源

`docs/discussions/2026-06-01-full-pipeline-parity-audit.md`（**PA-F5**，由 /api 端到端 dogfood 揪出）。

**為何不另開 /discuss**：這是 forced 機械 bug（collection 型別應映射成 OpenAPI `type: array`，無設計取捨），如 Phase 1.t.1 的 /usecase Create pattern 修正同性質 → 直接 spec + impl（記錄於此存檔）。

## 目標

修 `OpenApiYamlRenderer` 對 collection 欄位的型別映射 bug：Cosmogony bundle 用 **bracket 記法** `Array[String]` / `Set[String]`，但 `yamlType` 只認 angle `Array<>`/`Set<>`+ 純 `[` → bracket collection 落到 `default` fallback `type: string`。結果 grantPrivilege/assignRoles 的 `permissions`/`roles`（`Array[String]`）在 openapi.yaml 被生成 `type: string`，導致：(1) 生成的 API 契約錯誤（array 暴露成 string）；(2) `/api` fill 編譯失敗（`payload.permissions: String` 無法塞進 AS Input `[String]`）。

## 介面合約

- 新增 `OpenApiYamlRenderer.collectionElementType(of:) -> String?`：辨識 `Array<X>`/`Set<X>`/`Array[X]`/`Set[X]`/`[X]`（去 `?`），回傳元素型別，否則 nil。
- `yamlType(for:)`：array 偵測改用 `collectionElementType(of:) != nil`（涵蓋 bracket）。
- requestBody field 渲染：collection 欄位 emit `type: array` + `items:\n  type: <elementType>`（非單一 `type: <yamlType>`），對齊 response 端 array 寫法。

## 改動檔案

| 檔案 | 改動 |
|---|---|
| `Sources/GenesisCore/OpenApiYamlRenderer.swift` | 加 `collectionElementType(of:)`；`yamlType` array 偵測改用它；requestBody properties 迴圈 collection → `type: array` + `items` |
| `Tests/GenesisCoreTests/OpenApiYamlRendererTests.swift`（新檔）| `collectionElementType` / `yamlType` bracket+angle 單元測試 + render 端 `permissions` → `type: array` + `items`、非 `type: string` |

## 實作步驟
1. 加 `collectionElementType(of:)`（angle + bracket + 純 `[`，去 `?`）。
2. `yamlType` array 分支改用 `collectionElementType(of:) != nil`。
3. requestBody field 迴圈：`if let elem = collectionElementType(of: field.rawType)` → emit array + items；else 原樣。
4. 新增 OpenApiYamlRendererTests。

## 失敗路徑
- nested collection（如 `Array[Array[String]]`）→ items.type 會是 `array` 但缺 inner items（v1 限制，罕見，標 TODO；本 task 不處理 nested-of-nested）。
- collection of DTO/custom type → items.type 走 yamlType fallback `string`（v1 簡化；$ref 留後續，與既有 Decimal/Date fallback 一致）。

## 不改動的部分
- response 端 array 渲染（已正確 type: array + items + $ref）— 不動。
- Decimal/Date → string 的 v1 簡化 — 不動。
- 其他 renderer — 不動。

### Non-goals
- 不處理 nested collection / collection-of-DTO 的精確 items $ref（v1 簡化，與既有一致）。
- 不改 response schema 渲染。

## 驗收標準

### Agent 必做
```bash
cd /Users/abnertsai/JiaBao/Mendesky/Genesis
swift build 2>&1 | tail -2
swift test 2>&1 | tail -3   # 261 pass（含 3 新 OpenApiYamlRendererTests）

# regen → openapi permissions 為 array
TMP=$(mktemp -d)
swift run genesis new IAMContext --from-bundle Tests/GenesisIntegrationTests/Fixtures/iam-cosmogony-bundle.json --output "$TMP" --skip-build --no-git 2>&1 | tail -1
python3 -c "import yaml,json; d=yaml.safe_load(open('$TMP/Sources/UserAccessProfileAggregate/openapi.yaml')); s=d['components']['schemas']['GrantPrivilegeRequest']['properties']['permissions']; assert s.get('type')=='array', s; print('permissions schema:', json.dumps(s))"
rm -rf "$TMP"
```

### Human 補做
- [ ] regen IAM + 對 grantPrivilege 跑 /usecase + /api fill → generated 專案 `swift build` 通過（已實測：parity-fills2 EXIT 0）。

## 已知限制
- collection-of-DTO / nested collection 的 items 仍 v1 簡化（fallback string，與 Decimal/Date 一致）。

### 依賴關係
- 軟相依：Phase 1.t / 1.t.1（同 parity audit 來源）。無 hard 阻塞。
