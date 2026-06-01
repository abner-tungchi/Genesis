# AI Agent 討論區

此目錄用於 Claude、Codex (GPT-5.4)、Gemini 三方的持久化討論。

## 使用方式

```bash
/discuss new <topic>            # 建立新討論（default：先做 scope confirmation）
/discuss new <topic> --explore  # skip scope confirmation，讓 AI 自己 propose framing
/discuss continue               # 接續最近的討論
/discuss continue <file>        # 接續指定討論
/discuss status                 # 顯示所有討論狀態
/discuss list                   # 列出所有討論檔案
```

## 規則

1. **只新增不修改**：已記錄的 Round 和 Decision 不得修改
2. **標記身份**：每段發言必須標記 Agent 身份
3. **Premises 明示**：frontmatter 區分 `fixed`（AI 不可挑戰）與 `proposed`（AI 可 stress-test）
4. **R1 不含 ranking**：sub-topic 用中性 C1/C2/C3... 編號，避免 anchoring
5. **Evidence required for `agreed`**：共識必須引 file path / spec section / 歷史 case；純推理共識自動降 `majority`
6. **Synthesis rejection log（HARD）**：synthesis round 必須列「我拒絕了哪些建議+為什麼」
7. **Scope creep guard with appeal**：AI 提 out-of-scope 議題時 user 拍板；另一個 AI 支持則自動 review-queue
8. **更新共識看板**：每輪結束後更新
9. **寫下次指引**：每輪結束後更新，確保下一輪能接續

## Tool-failure 透明度

若任一 agent 派不出，把實際情況寫進 `meta_note`，不要美化成「epistemic signal」。R2 synthesis 缺一方時，verdict 對於該 disputed 議題標註「未經第三方驗證」。
