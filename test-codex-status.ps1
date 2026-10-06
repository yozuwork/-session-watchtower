$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'cc-vscode-hud.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CodexStatusEntries' }, $true)
Invoke-Expression $fn.Extent.Text
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('hud-test-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
$file = Join-Path $fixture 'session.jsonl'
function Check-State($event, $expected, $partial = '') {
    $meta = @{ type = 'session_meta'; payload = @{ cwd = 'C:\projects\demo'; source = 'vscode' } } | ConvertTo-Json -Compress
    $record = @{ type = 'event_msg'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); payload = @{ type = $event } } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($file, "$meta`n$record`n$partial")
    $script:codexNextScan = $null
    $result = @(Get-CodexStatusEntries -SessionsPath $fixture)
    if ($result.Count -ne 1 -or $result[0].State -ne $expected) { throw "Expected $expected for $event" }
}
try {
    Check-State 'task_started' 'thinking'
    Check-State 'task_complete' 'done'
    Check-State 'turn_aborted' 'stopped'
    Check-State 'task_complete' 'done' '{"type":'
    Check-State 'task_started' 'thinking'
    (Get-Item $file).LastWriteTime = (Get-Date).AddMinutes(-11)
    $script:codexNextScan = $null
    if ((Get-CodexStatusEntries -SessionsPath $fixture).State -ne 'unknown') { throw 'Stale active state' }
    [IO.File]::WriteAllText($file, 'invalid json')
    $script:codexNextScan = $null
    if (@(Get-CodexStatusEntries -SessionsPath $fixture).Count -ne 0) { throw 'Malformed log was not skipped' }
    'PASS: start, complete, abort, partial write, stale state, malformed log; PowerShell syntax.'
} finally {
    [IO.File]::Delete($file)
    [IO.Directory]::Delete($fixture)
}
