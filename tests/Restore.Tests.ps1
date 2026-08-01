$ErrorActionPreference = "Stop"
$code = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) "AI-Config-Manager.ps1") -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
$defs = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$defs | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
if (-not (Get-Command Restore-Backup -ErrorAction SilentlyContinue)) { throw "functions not loaded" }

$pass = 0; $fail = 0
function T($name, $cond) {
    if ($cond) { $script:pass++; Write-Host "  ok: $name" -ForegroundColor DarkGreen }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("aimg-restore-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    # Make a target + two backups with distinct mtimes, then pick the newest.
    $target = Join-Path $tmpDir "cfg.json"
    Set-Content $target '{"version":3}'
    $b1 = "$target.backup-20250101-010101-0000001"
    $b2 = "$target.backup-20250102-020202-0000002"
    Set-Content $b1 '{"version":1}'
    Set-Content $b2 '{"version":2}'
    (Get-Item $b2).LastWriteTime = (Get-Item $b1).LastWriteTime.AddHours(1)

    $latest = Get-LatestBackup $target
    T "latest picks newest mtime" ($latest.Name -match "0000002")

    # Restore: current file gets a fresh backup, then content becomes version 2.
    $keep = Backup-File $target
    Copy-Item $b2 $target -Force
    $content = Get-Content $target -Raw
    T "restore wrote backup content" ($content -match '"version":2')
    T "restore itself backed up prior state" ((Test-Path $keep) -and ((Get-Content $keep -Raw) -match '"version":3'))

    # Backup regex should NOT match a stray unrelated file.
    Set-Content (Join-Path $tmpDir "cfg.json.backup-20250103") "x"
    $latest2 = Get-LatestBackup $target
    T "backup regex filters malformed names" ($null -eq $latest2 -or $latest2.Name -match "\d{8}-\d{6}-\d+$")

    # Get-ToolConfigPaths returns known paths.
    $claude = @(Get-ToolConfigPaths "Claude Code")
    T "claude path known" ($claude.Count -eq 1 -and $claude[0] -match "settings\.json")
    $codex = @(Get-ToolConfigPaths "Codex")
    T "codex paths known" ($codex.Count -eq 2)
} finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Restore-backup tests: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
