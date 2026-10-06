# Claude Code 狀態浮窗 (cc-hud)

VS Code 縮到工作列時，用一個永遠置頂的小視窗看 Claude Code 在做什麼。

```
┌──────────────────────────────┐
│ CLAUDE CODE                  │
│ [!] 全局搜尋工具 - 等你回覆   │
│     需要你回覆   14:32:07     │
└──────────────────────────────┘
```

## 架構

```
Claude Code ──hooks──> cc-status.ps1 ──寫──> state\<session-id>.json
                                                      │
                                      cc-hud.ps1 ──每 0.8 秒讀──┘
```

刻意不去解析 `~/.claude/projects/*.jsonl`。那是未公開的內部格式，版本一升就會壞掉。
Hooks 是有文件的公開介面，穩定得多。

## 安裝

**1. 放檔案**

把 `cc-status.ps1` 和 `cc-hud.ps1` 複製到：

```
C:\Users\boyou.chen\.claude\hud\
```

（`state\` 子目錄會自動建立。如果你放別的路徑，記得同步改下一步的 JSON。）

**2. 設定 hooks**

打開 `C:\Users\boyou.chen\.claude\settings.json`，把 `hooks-snippet.json` 裡的
`hooks` 區塊合併進去。如果檔案原本已經有 `hooks`，要手動把各事件合併，不要整段覆蓋。

改完重開 Claude Code session 才會生效。

**3. 啟動浮窗**

```
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\boyou.chen\.claude\hud\cc-hud.ps1"
```

建議做成捷徑丟到 `shell:startup`（Win+R 貼上就會開啟啟動資料夾），開機自動跑。

## 操作

| 動作 | 效果 |
|---|---|
| 左鍵拖曳 | 移動視窗 |
| 滑鼠移上去 | 變半透明，看得到底下的東西 |
| 右鍵 / Esc | 關閉 |

## 狀態

| 顯示 | 意義 | 來源 hook |
|---|---|---|
| `[~]` 思考中 | 剛送出訊息，正在想 | `UserPromptSubmit` |
| `[>]` 執行中 | 正在跑工具（會顯示工具名和檔名） | `PreToolUse` |
| `[!]` 等你回覆 | 要權限或在問你問題 ← **最重要的那個** | `Notification` |
| `[v]` 完成 | 這一輪回答結束 | `Stop` |

同時開多個 VS Code 視窗跑不同專案時，每個 session 各佔一列（最多顯示 4 個）。

## 可以再加的

- **配上音效**：在 `cc-status.ps1` 的 `waiting` 分支加一行
  `[Console]::Beep(880, 200)`，這樣你視線不在螢幕上也知道它在等你。
- **Windows 原生通知**：`Install-Module BurntToast`，然後在 `waiting` / `done`
  分支呼叫 `New-BurntToastNotification`。
- **閒置時自動隱藏**：`state\` 全空或全是 `done` 超過 N 秒就 `$win.Hide()`。

## 排錯

- **浮窗一直顯示「沒有進行中的 session」**
  → 去看 `state\` 有沒有產生 `.json`。沒有的話是 hooks 沒觸發，用 `/hooks`
  指令或 `claude --debug` 確認設定被讀到了。

- **每次觸發都閃一下黑色視窗**
  → 確認 hook 指令裡有 `-WindowStyle Hidden`。還是會閃的話，用一支
  `.vbs` 包一層（`WScript.Shell.Run(cmd, 0, False)`）就能完全無視窗。

- **PowerShell 說禁止執行腳本**
  → 指令裡已經帶了 `-ExecutionPolicy Bypass`，正常不會遇到。手動跑的話加上同樣參數。

## 注意

Hook 事件名稱（`PreToolUse` / `Notification` / `Stop` / `SessionEnd`）和傳入的
JSON 欄位名（`session_id` / `cwd` / `tool_name` / `tool_input` / `message`）
是照官方 hooks 介面寫的，但這部分偶爾會調整。`cc-status.ps1` 對缺欄位的情況
都有防護（顯示會退化，不會壞掉），不過如果某個狀態一直抓不到細節，
對一下最新文件：https://docs.claude.com/en/docs/claude-code/hooks

## VS Code HUD：Codex 狀態

執行同資料夾的 `cc-vscode-hud.exe`，即可在對應的 VS Code 專案下看到 Codex 狀態。Claude 與 Codex 同時使用時會分列顯示。

- 自動讀取 `%CODEX_HOME%\sessions`（未設定時使用 `%USERPROFILE%\.codex\sessions`），不需要修改 Codex 設定。
- 每 3 秒檢查最近兩小時更新的紀錄，顯示思考中、執行中、完成、已中止；詢問輸入的工具呼叫顯示等你回覆。
- 執行中的紀錄超過 10 分鐘沒有更新會顯示狀態未知；這不代表工作一定停止。
- 本機 JSONL 是相容性讀取方式，格式改變或未寫入紀錄時可能無法判讀；不保證能偵測所有權限確認狀態。只對應已開啟的 VS Code 視窗。
- 驗證：`powershell -NoProfile -ExecutionPolicy Bypass -File .\test-codex-status.ps1`。
# -session-watchtower
