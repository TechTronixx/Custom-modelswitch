$ErrorActionPreference = "Stop"
$code = Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) "AI-Config-Manager.ps1") -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
$defs = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$defs | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
if (-not (Get-Command Get-ScrollWindow -ErrorAction SilentlyContinue)) { throw "functions not loaded" }

$pass = 0; $fail = 0
function T($name, $cond) {
    if ($cond) { $script:pass++; Write-Host "  ok: $name" -ForegroundColor DarkGreen }
    else { $script:fail++; Write-Host "  FAIL: $name" -ForegroundColor Red }
}

# --- Repair-JsonEmptyKeys ---
$j = '{"success":true,"data":[],"usable_group":{"":["x"]}}'
$r = Repair-JsonEmptyKeys $j
T "sanitizer renames empty key" ($r -match '"__empty__":\["x"\]' -and $r -notmatch '""\s*:')
$null = ($r | ConvertFrom-Json)  # must not throw
T "sanitized JSON parses" $true

# --- Truncate-Text ---
T "truncate short text unchanged" ((Truncate-Text "short") -eq "short")
$long = "a" * 1000
$tr = Truncate-Text $long
T "truncate caps length" ($tr.Length -lt 1000 -and $tr -match "truncated")

# --- Get-ModelsEndpoint ---
T "endpoint from /v1 base" ((Get-ModelsEndpoint "https://x.com/v1") -eq "https://x.com/v1/models")
T "endpoint appends /v1" ((Get-ModelsEndpoint "https://x.com") -eq "https://x.com/v1/models")
T "endpoint strips trailing slash" ((Get-ModelsEndpoint "https://x.com/") -eq "https://x.com/v1/models")

# --- Merge-Models ---
$m = Merge-Models @("b","a","b") @("a","c")
T "merge dedupes and sorts" (($m -join ",") -eq "a,b,c")
$m2 = Merge-Models $null $null
T "merge handles nulls" ($null -ne $m2 -and $m2.Count -eq 0)

# --- Backup-File ---
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("aimg-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    $f = Join-Path $tmpDir "cfg.json"
    Set-Content $f "{}"
    $b1 = Backup-File $f
    $b2 = Backup-File $f
    T "backup returns path" (Test-Path $b1)
    T "backup collisions avoided" ($b1 -ne $b2)
} finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

# --- Set-TomlValue root-vs-table placement ---
$t = "[model_providers.custom]`r`nname = `"x`"`r`n"
$t2 = Set-TomlValue $t "model" "gpt-5"
T "TOML root key before table" ($t2.StartsWith("model = `"gpt-5`""))
$t3 = Set-TomlValue $t2 "model" "other"
T "TOML root key replaced in place" (($t3 -match "(?m)^model = `"other`"") -and ($t3 -notmatch "other.*model"))
$t4 = Set-TomlBareValue $t3 "disable_response_storage" "true"
T "TOML bare bool root" ($t4 -match "(?m)^disable_response_storage = true")

# --- Set-TomlEnvPolicyValue ---
$t5 = Set-TomlEnvPolicyValue "model = `"x`"`r`n" "MY_API_KEY" "secret"
T "TOML env table appended" ($t5 -match "(?m)^\[shell_environment_policy\.set\]")
$t6 = Set-TomlEnvPolicyValue $t5 "MY_API_KEY" "newsecret"
T "TOML env key replaced" (($t6 -match "(?m)^MY_API_KEY = `"newsecret`"") -and ($t6 -notmatch "MY_API_KEY = `"secret`""))

# --- Assert-PresetValid ---
$okPreset = [PSCustomObject]@{
    id="p"; label="P"
    claude = [PSCustomObject]@{ baseUrl="https://a.com"; curatedModels=@() }
    opencode = [PSCustomObject]@{ baseUrl="https://a.com/v1"; providerKey="p"; providerName="P"; npmPackage="@ai-sdk/openai-compatible"; curatedModels=@() }
}
try { Assert-PresetValid $okPreset; T "valid preset accepted" $true } catch { T "valid preset accepted" $false }
$badPreset = [PSCustomObject]@{ id=""; label="Bad"; claude = [PSCustomObject]@{baseUrl=$null}; opencode = [PSCustomObject]@{baseUrl="x";providerKey="";providerName="";npmPackage=""} }
try { Assert-PresetValid $badPreset; T "bad preset rejected" $false } catch { T "bad preset rejected" ($_.Exception.Message -match "invalid") }

# --- Save-Json BOM-less ---
$tmpDir2 = Join-Path ([IO.Path]::GetTempPath()) ("aimg-test2-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir2 | Out-Null
try {
    $jf = Join-Path $tmpDir2 "out.json"
    Save-Json ([PSCustomObject]@{ a=1; b=@(1,2) }) $jf
    $bytes = [IO.File]::ReadAllBytes($jf)
    T "Save-Json is BOM-less" ($bytes[0] -ne 0xEF -and $bytes[0] -ne 0xBB)
} finally { Remove-Item $tmpDir2 -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Functional tests: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
