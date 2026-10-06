# cc-status.ps1
# 由 Claude Code hooks 呼叫,把當前狀態寫成 state\<session-id>.json
# 用法: powershell -NoProfile -File cc-status.ps1 -State running

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('thinking', 'running', 'waiting', 'done', 'end')]
    [string]$State
)

# hook 絕對不能拖慢或中斷 Claude Code,所以全程吞掉錯誤
$ErrorActionPreference = 'SilentlyContinue'

function Get-Short {
    param([string]$Text, [int]$Max = 34)
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, $Max) + '...'
}

try {
    $stateDir = Join-Path $PSScriptRoot 'state'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

    # hook 的事件資料從 stdin 進來(一定要用 UTF8 讀,不然 [Console]::In 會照系統
    # codepage 解碼,中文就變亂碼——Claude Code 傳進來的 JSON 是 UTF-8 bytes)
    $raw = ''
    try {
        $stdinStream = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stdinStream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
    } catch { }

    $evt = $null
    if ($raw -and $raw.Trim()) {
        try { $evt = $raw | ConvertFrom-Json } catch { }
    }

    # session_id 當檔名,這樣多個 VS Code 視窗不會互相蓋掉
    $sid = 'unknown'
    if ($evt -and $evt.session_id) { $sid = [string]$evt.session_id }
    $sid = $sid -replace '[^\w\-]', '_'
    if ($sid.Length -gt 40) { $sid = $sid.Substring(0, 40) }

    $file = Join-Path $stateDir "$sid.json"

    # session 結束就把狀態檔清掉
    if ($State -eq 'end') {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        exit 0
    }

    # 專案名稱 = cwd 的最後一層
    $project = ''
    if ($evt -and $evt.cwd) { $project = Split-Path ([string]$evt.cwd) -Leaf }

    # 組出人看得懂的一行細節
    $detail = ''
    if ($State -eq 'running') {
        $tool = [string]$evt.tool_name
        $detail = $tool
        $ti = $evt.tool_input

        if ($ti) {
            if ($ti.file_path) {
                $detail = "$tool  " + (Split-Path ([string]$ti.file_path) -Leaf)
            }
            elseif ($ti.command) {
                $detail = "Bash  " + (Get-Short ([string]$ti.command) 34)
            }
            elseif ($ti.pattern) {
                $detail = "$tool  " + (Get-Short ([string]$ti.pattern) 34)
            }
            elseif ($ti.description) {
                $detail = "$tool  " + (Get-Short ([string]$ti.description) 34)
            }
        }
    }
    elseif ($State -eq 'waiting') {
        if ($evt -and $evt.message) {
            $detail = Get-Short ([string]$evt.message) 40
        }
        else {
            $detail = '需要你回覆'
        }
    }

    # cwd 全路徑也存起来:專案資料夾底下開了子資料夾(例如 FdaHealth\frontend)在跑
    # Claude Code 時,VS Code 視窗標題只會顯示上層資料夾名稱,只靠 leaf 比對會兜不起來,
    # 所以連全路徑一起存,讓 HUD 可以用路徑片段回頭比對到正確的上層視窗
    $cwd = ''
    if ($evt -and $evt.cwd) { $cwd = [string]$evt.cwd }

    $payload = [ordered]@{
        session = $sid
        project = $project
        cwd     = $cwd
        state   = $State
        detail  = $detail.Trim()
        ts      = (Get-Date).ToString('o')
    }

    $payload | ConvertTo-Json -Compress | Set-Content -Path $file -Encoding UTF8
}
catch {
    # 靜默失敗,絕不影響主流程
}

exit 0
