# One-click launcher for AI Config Manager.
# Usage: irm https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main/bootstrap.ps1 | iex
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$dir = Join-Path $HOME "AI-Config-Manager"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$base = "https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main"
foreach ($f in @("AI-Config-Manager.ps1", "AI-Config-Presets.json")) {
    Invoke-WebRequest -Uri "$base/$f" -OutFile (Join-Path $dir $f) -UseBasicParsing
}

Write-Host "Installed to: $dir" -ForegroundColor DarkGray
& (Join-Path $dir "AI-Config-Manager.ps1")
