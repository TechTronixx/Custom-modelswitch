# AI Config Manager
#
# Arrow-key TUI to point Claude Code, OpenCode, and Codex at a custom gateway
# (AgentRouter, EuroModels, or any OpenAI/Anthropic-compatible base URL), and to
# launch Hermes Desktop's own model setup. Presets live in AI-Config-Presets.json;
# model lists are fetched live when the gateway allows it, with curated fallbacks.
#
# Requires Windows PowerShell 5.1+ or PowerShell 7+, and curl (curl.exe is
# bundled with Windows 10/11; pwsh's curl on Linux/macOS). Existing config files
# are backed up before every write.
#
# Usage:   powershell -ExecutionPolicy Bypass -File .\AI-Config-Manager.ps1
# Selftest: powershell -File .\AI-Config-Manager.ps1 -SelfTest

param([switch]$SelfTest)

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "AI Config Manager"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Platform detection (works in both Windows PowerShell 5.1 and pwsh 7+).
$script:IsWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ErrorAction SilentlyContinue) -and $IsWindows)
$script:IsLinux   = (Get-Variable IsLinux   -ErrorAction SilentlyContinue) -and $IsLinux
$script:IsMacOS   = (Get-Variable IsMacOS   -ErrorAction SilentlyContinue) -and $IsMacOS
$script:CurlBin   = if ($script:IsWindows) { 'curl.exe' } else { 'curl' }


# Pure scroll-window math (extracted so it can be self-tested without a TTY).
function Get-ScrollWindow {
    param([int]$Selected, [int]$Count, [int]$PageSize, [int]$CurrentTop)
    if ($Count -le $PageSize) { return 0 }
    if ($Selected -lt $CurrentTop) { return $Selected }
    if ($Selected -ge ($CurrentTop + $PageSize)) { return $Selected - $PageSize + 1 }
    return $CurrentTop
}

# ---------- UI helpers ----------

function Write-Banner([string]$Title) {
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $([string]::new([char]0x2500, $Title.Length + 2))" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Options,
        [string[]]$Header = @(),
        [int]$DefaultIndex = 0
    )
    if ($Options.Count -eq 0) { return -1 }
    $selected = [Math]::Min($DefaultIndex, $Options.Count - 1)
    $top = 0
    while ($true) {
        Clear-Host
        Write-Banner $Title
        foreach ($h in $Header) { Write-Host "  $h" -ForegroundColor DarkGray }
        if ($Header.Count -gt 0) { Write-Host "" }

        $pageSize = [Math]::Max(5, [Console]::WindowHeight - 9 - $Header.Count)
        $top = Get-ScrollWindow $selected $Options.Count $pageSize $top
        $last = [Math]::Min($top + $pageSize, $Options.Count) - 1
        for ($i = $top; $i -le $last; $i++) {
            if ($i -eq $selected) {
                Write-Host (" > {0}" -f $Options[$i]) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host ("   {0}" -f $Options[$i]) -ForegroundColor Gray
            }
        }
        if ($top -gt 0 -or $last -lt $Options.Count - 1) {
            Write-Host ""
            Write-Host "  ($($top + 1)-$($last + 1) of $($Options.Count))" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  Up/Dn navigate | Enter select | Esc back" -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            UpArrow   { if ($selected -gt 0) { $selected-- } }
            DownArrow { if ($selected -lt $Options.Count - 1) { $selected++ } }
            Home      { $selected = 0 }
            End       { $selected = $Options.Count - 1 }
            Enter     { return $selected }
            Escape    { return -1 }
        }
    }
}

function Pause-Screen {
    Write-Host ""
    Read-Host "Press Enter to continue" | Out-Null
}

# ---------- input helpers ----------

function Read-SecretPlain {
    $secure = Read-Host "Enter API Key" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Mask-Key([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return "(empty)" }
    if ($Key.Length -le 8) { return ("*" * $Key.Length) }
    return $Key.Substring(0,4) + ("*" * [Math]::Min(12,$Key.Length-8)) + $Key.Substring($Key.Length-4)
}

function Normalize-BaseUrl([string]$Url) { return $Url.Trim().TrimEnd("/") }

# Cap how much of a server response we echo back on failure. A huge body is
# noise in a TUI; the status code plus a short excerpt is enough to diagnose.
function Truncate-Text([string]$Text, [int]$Max = 800) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n...[truncated $($Text.Length - $Max) characters]"
}

# PS 5.1's ConvertFrom-Json throws on JSON object keys that are the empty string
# (AgentRouter's pricing payload has one, inside usable_group). Rename such keys
# to a harmless placeholder instead of regex-stripping a subtree, which is
# brittle when that subtree contains nested objects.
function Repair-JsonEmptyKeys([string]$Json) {
    return [regex]::Replace($Json, '("")\s*:', '"__empty__":')
}

function Get-ModelsEndpoint([string]$BaseUrl) {
    $b = Normalize-BaseUrl $BaseUrl
    if ($b -match "/v1$") { return "$b/models" }
    return "$b/v1/models"
}

# ---------- live model fetch ----------

function Get-LiveModels([string]$BaseUrl, [string]$ApiKey) {
    $endpoint = Get-ModelsEndpoint $BaseUrl
    Write-Host ""
    Write-Host "Fetching models from: $endpoint" -ForegroundColor DarkGray

    $tmp = [IO.Path]::GetTempFileName()
    try {
        $curlArgs = @(
            "-sS", "--fail-with-body",
            "--connect-timeout", "15",
            "--max-time", "45",
            "-H", "Authorization: Bearer $ApiKey",
            "-H", "Accept: application/json",
            "-o", $tmp,
            "-w", "%{http_code}",
            $endpoint
        )
        $status = & $script:CurlBin @curlArgs
        $exit = $LASTEXITCODE
        $body = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)

        if ($exit -ne 0 -or $status -notmatch "^2") {
            throw "Request failed. HTTP $status`n$(Truncate-Text $body)"
        }
        if ([string]::IsNullOrWhiteSpace($body)) {
            throw "Request succeeded (HTTP $status) but the response body was empty."
        }

        $json = $body | ConvertFrom-Json
        $ids = @()
        if ($null -ne $json.data) {
            $ids = @($json.data | ForEach-Object {
                if ($_ -is [string]) { $_ } elseif ($_.id) { [string]$_.id }
            })
        } elseif ($null -ne $json.models) {
            $ids = @($json.models | ForEach-Object {
                if ($_ -is [string]) { $_ }
                elseif ($_.id) { [string]$_.id }
                elseif ($_.name) { [string]$_.name }
            })
        }

        $ids = @($ids | Where-Object { $_ } | Sort-Object -Unique)
        if ($ids.Count -eq 0) { throw "API responded successfully, but no model IDs were found in data[].id or models[]." }
        return $ids
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# AgentRouter exposes its full model list (with IDs and supported endpoints) at a
# public, no-auth JSON endpoint behind the /pricing page. Unlike /v1/models and
# /api/models, this one is NOT client-gated (no 401). Returns data[].model_name
# and data[].supported_endpoint_types (e.g. ["anthropic","openai"]).
function Get-AgentRouterPricingModels([string]$Url) {
    Write-Host ""
    Write-Host "Fetching model list from: $Url" -ForegroundColor DarkGray
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $curlArgs = @(
            "-sS", "--fail-with-body",
            "--connect-timeout", "15",
            "--max-time", "45",
            "-H", "Accept: application/json",
            "-o", $tmp,
            "-w", "%{http_code}",
            $Url
        )
        $status = & $script:CurlBin @curlArgs
        $exit = $LASTEXITCODE
        $body = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        if ($exit -ne 0 -or $status -notmatch "^2") { throw "Request failed. HTTP $status`n$(Truncate-Text $body)" }
        if ([string]::IsNullOrWhiteSpace($body)) { throw "Request succeeded (HTTP $status) but the response body was empty." }
        # PS 5.1's ConvertFrom-Json throws on empty-string JSON keys; rename them
        # to a safe placeholder rather than regex-stripping the usable_group subtree.
        $json = Repair-JsonEmptyKeys $body | ConvertFrom-Json
        if (-not $json.success) { throw "Pricing API returned success=false.`n$(Truncate-Text $body)" }
        if ($null -eq $json.data) { throw "Pricing API returned no data." }
        return @($json.data)
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------- config writers ----------

function Backup-File([string]$Path) {
    if (Test-Path $Path) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $ticks = ([DateTime]::UtcNow.Ticks % 10000000).ToString("0000000")
        $backup = "$Path.backup-$stamp-$ticks"
        Copy-Item $Path $backup -Force
        return $backup
    }
    return $null
}

function Ensure-Parent([string]$Path) {
    $dir = Split-Path $Path -Parent
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Load-JsonObject([string]$Path) {
    if (!(Test-Path $Path)) { return [PSCustomObject]@{} }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return [PSCustomObject]@{} }
    try { return $raw | ConvertFrom-Json }
    catch {
        throw "Cannot safely edit $Path because it is not strict JSON. If it is JSONC with comments, back it up and convert it to JSON first."
    }
}

function Set-Prop($Object, [string]$Name, $Value) {
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else { $Object.$Name = $Value }
}

function Save-Json($Object, [string]$Path) {
    Ensure-Parent $Path
    # BOM-less UTF-8 is required: the Claude Desktop app's JSON.parse rejects files
    # that start with a BOM (PowerShell 5.1's Set-Content -Encoding UTF8 adds one).
    $json = $Object | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-HermesModelSetup {
    $hermes = Get-Command hermes -ErrorAction SilentlyContinue
    if ($null -eq $hermes) {
        Write-Host "Hermes is not installed. Install Hermes first, then rerun this option." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    Write-Host "Launching Hermes model setup. Complete prompts manually." -ForegroundColor Cyan
    & $hermes.Source model
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Hermes model setup exited with code $LASTEXITCODE." -ForegroundColor Yellow
    }
    Pause-Screen
}

function Configure-Claude([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
    $path = Join-Path $claudeDir "settings.json"
    $backup = Backup-File $path
    $cfg = Load-JsonObject $path

    if ($null -eq $cfg.PSObject.Properties["env"]) { Set-Prop $cfg "env" ([PSCustomObject]@{}) }
    Set-Prop $cfg.env "ANTHROPIC_BASE_URL" (Normalize-BaseUrl $BaseUrl)
    Set-Prop $cfg.env "ANTHROPIC_AUTH_TOKEN" $ApiKey
    Set-Prop $cfg.env "ANTHROPIC_MODEL" $Model
    Set-Prop $cfg "model" $Model

    Save-Json $cfg $path
    return @{ Path=$path; Backup=$backup }
}

# The Claude Desktop Electron app runs in "3P" mode and reads its gateway
# settings from a managed config file in the configLibrary: the active entry is
# the JSON file named by configLibrary/_meta.json -> appliedId. Its schema:
#   inferenceProvider            = "gateway"
#   inferenceGatewayBaseUrl      = <base URL>
#   inferenceGatewayApiKey       = <api key>
#   inferenceGatewayAuthScheme   = "x-api-key" | "bearer" | "sso"
#   inferenceModels              = [ "model-id", ... ]
# We rewrite that entry (backed up first). The app picks it up on next launch.
# Locate the Claude Desktop config root per platform. Windows uses the 3P-mode
# configLibrary under LOCALAPPDATA; macOS and Linux use the app's config dir,
# preferring the 3P-mode "Claude-3p" folder when present (macOS apps historically
# wrote under "Claude").
function Get-ClaudeDesktopConfigDir {
    if ($script:IsWindows) {
        return Join-Path $env:LOCALAPPDATA "Claude-3p"
    }
    if ($script:IsMacOS) {
        return Join-Path $HOME "Library/Application Support/Claude"
    }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
    $c3p = Join-Path $base "Claude-3p"
    if (Test-Path $c3p) { return $c3p }
    return Join-Path $base "Claude"
}

function Configure-ClaudeDesktop([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$AuthScheme) {
    $dir = Get-ClaudeDesktopConfigDir
    $libraryDir = Join-Path $dir "configLibrary"
    $metaPath = Join-Path $libraryDir "_meta.json"
    if (!(Test-Path $metaPath)) {
        throw "Claude Desktop configLibrary not found at $metaPath. Install and launch the Claude Desktop app once so it initializes its config."
    }
    $meta = Load-JsonObject $metaPath
    $appliedId = [string]$meta.appliedId
    if ([string]::IsNullOrWhiteSpace($appliedId)) {
        throw "No appliedId in $metaPath. Open the Claude Desktop app once so it writes its active config entry."
    }
    $cfgPath = Join-Path $libraryDir "$appliedId.json"
    $backup = Backup-File $cfgPath
    $cfg = Load-JsonObject $cfgPath

    $scheme = if ($AuthScheme) { $AuthScheme } else { "x-api-key" }
    Set-Prop $cfg "inferenceProvider" "gateway"
    Set-Prop $cfg "inferenceGatewayBaseUrl" (Normalize-BaseUrl $BaseUrl)
    Set-Prop $cfg "inferenceGatewayApiKey" $ApiKey
    Set-Prop $cfg "inferenceGatewayAuthScheme" $scheme
    Set-Prop $cfg "inferenceModels" @($Model)

    Save-Json $cfg $cfgPath
    return @{ Path=$cfgPath; Backup=$backup }
}

function Configure-OpenCode([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$ProviderKey, [string]$ProviderName, [string]$NpmPackage) {
    if ([string]::IsNullOrWhiteSpace($ProviderKey)) { throw "OpenCode provider key is empty; preset is missing 'opencode.providerKey'." }
    if ([string]::IsNullOrWhiteSpace($NpmPackage)) { throw "OpenCode npm package is empty; preset is missing 'opencode.npmPackage'." }

    $path = Join-Path $HOME ".config/opencode/opencode.json"
    $backup = Backup-File $path
    $cfg = Load-JsonObject $path

    Set-Prop $cfg '$schema' "https://opencode.ai/config.json"
    if ($null -eq $cfg.PSObject.Properties["provider"]) { Set-Prop $cfg "provider" ([PSCustomObject]@{}) }

    $modelObj = [PSCustomObject]@{}
    Set-Prop $modelObj $Model ([PSCustomObject]@{ name = $Model })

    $provider = [PSCustomObject]@{
        npm = $NpmPackage
        name = $ProviderName
        options = [PSCustomObject]@{ baseURL = (Normalize-BaseUrl $BaseUrl); apiKey = $ApiKey }
        models = $modelObj
    }

    Set-Prop $cfg.provider $ProviderKey $provider
    Set-Prop $cfg "model" ("$ProviderKey/" + $Model)

    Save-Json $cfg $path
    return @{ Path=$path; Backup=$backup }
}

# Set a document-ROOT key. Root keys must precede the first [table] header,
# otherwise TOML parses them as members of that table (e.g. windows.model).
# We split the text at the first table header, edit only the root portion, and
# strip any stray copy of this key from inside the tables (self-heals configs
# an earlier version may have mis-written).
function Set-TomlValue([string]$Text, [string]$Key, [string]$Value) {
    $escaped = $Value -replace '\\', '\\\\' -replace '"', '\\"'
    $line = '{0} = "{1}"' -f $Key, $escaped
    $pattern = "(?m)^\s*" + [regex]::Escape($Key) + "\s*=.*$"

    $firstTable = [regex]::Match($Text, '(?m)^[ \t]*\[')
    if ($firstTable.Success) {
        $head = $Text.Substring(0, $firstTable.Index)
        $tail = $Text.Substring($firstTable.Index)
    } else {
        $head = $Text
        $tail = ""
    }

    # Remove any misplaced copy of this key from within the tables.
    $tail = [regex]::Replace($tail, "(?m)^[ \t]*" + [regex]::Escape($Key) + "[ \t]*=.*\r?\n?", "")

    if ($head -match $pattern) {
        $head = [regex]::Replace($head, $pattern, $line, 1)
    } else {
        if ($head -and !$head.EndsWith("`n")) { $head += "`r`n" }
        $head += $line + "`r`n"
    }
    return $head + $tail
}

# Same root-placement logic as Set-TomlValue, but writes the value verbatim
# (no quotes) for bare TOML values like booleans/numbers.
function Set-TomlBareValue([string]$Text, [string]$Key, [string]$Value) {
    $line = '{0} = {1}' -f $Key, $Value
    $pattern = "(?m)^\s*" + [regex]::Escape($Key) + "\s*=.*$"

    $firstTable = [regex]::Match($Text, '(?m)^[ \t]*\[')
    if ($firstTable.Success) {
        $head = $Text.Substring(0, $firstTable.Index)
        $tail = $Text.Substring($firstTable.Index)
    } else {
        $head = $Text
        $tail = ""
    }

    $tail = [regex]::Replace($tail, "(?m)^[ \t]*" + [regex]::Escape($Key) + "[ \t]*=.*\r?\n?", "")

    if ($head -match $pattern) {
        $head = [regex]::Replace($head, $pattern, $line, 1)
    } else {
        if ($head -and !$head.EndsWith("`n")) { $head += "`r`n" }
        $head += $line + "`r`n"
    }
    return $head + $tail
}

# Set a key INSIDE the [shell_environment_policy.set] table (not root). Codex
# exposes these vars to shells it spawns for tools. If the table is missing we
# append it; if the key exists there we replace it in place.
function Set-TomlEnvPolicyValue([string]$Text, [string]$Key, [string]$Value) {
    $escaped = $Value -replace '\\', '\\\\' -replace '"', '\\"'
    $line = '{0} = "{1}"' -f $Key, $escaped

    # Locate the [shell_environment_policy.set] table body (up to the next header).
    $tablePattern = "(?ms)^([ \t]*\[shell_environment_policy\.set\][ \t]*\r?\n)(.*?)(?=^\s*\[|\z)"
    $m = [regex]::Match($Text, $tablePattern)
    if ($m.Success) {
        $header = $m.Groups[1].Value
        $body = $m.Groups[2].Value
        $keyPattern = "(?m)^[ \t]*" + [regex]::Escape($Key) + "[ \t]*=.*$"
        if ($body -match $keyPattern) {
            $body = [regex]::Replace($body, $keyPattern, $line, 1)
        } else {
            if ($body -and !$body.EndsWith("`n")) { $body += "`r`n" }
            $body += $line + "`r`n"
        }
        return $Text.Substring(0, $m.Index) + $header + $body + $Text.Substring($m.Index + $m.Length)
    }

    # Table absent: append a fresh one at end of file.
    if ($Text -and !$Text.EndsWith("`n")) { $Text += "`r`n" }
    return $Text + "`r`n[shell_environment_policy.set]`r`n" + $line + "`r`n"
}

function Configure-Codex([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$ProviderKey, [string]$ProviderName) {
    $dir = Join-Path $HOME ".codex"
    $authPath = Join-Path $dir "auth.json"
    $configPath = Join-Path $dir "config.toml"
    $authBackup = Backup-File $authPath
    $configBackup = Backup-File $configPath

    # The Codex desktop app gates on auth.json's auth_mode: while it's "chatgpt"
    # the app forces its built-in ChatGPT provider and ignores model_provider in
    # config.toml entirely. Switch to "apikey" and write BOTH key names the app
    # and CLI have used (OPEN_API_KEY, OPENAI_API_KEY).
    $auth = Load-JsonObject $authPath
    Set-Prop $auth "auth_mode" "apikey"
    Set-Prop $auth "OPEN_API_KEY" $ApiKey
    Set-Prop $auth "OPENAI_API_KEY" $ApiKey
    Save-Json $auth $authPath

    # Codex validates config.toml as all-or-nothing: ONE unsupported value makes
    # it discard the whole file and silently fall back to ChatGPT defaults. So a
    # built-in provider ID (openai) or a stale wire_api value breaks everything.
    $provider = if ($ProviderKey -and $ProviderKey -ne "openai") { $ProviderKey } else { "custom" }
    $envKey = ($provider.ToUpper() -replace '[^A-Z0-9]', '_') + "_API_KEY"

    $toml = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { "" }
    $toml = Set-TomlValue $toml "model_provider" $provider
    $toml = Set-TomlValue $toml "model" $Model
    $toml = Set-TomlValue $toml "preferred_auth_method" "apikey"
    # bare (non-quoted) root key; Set-TomlValue only writes quoted strings, so
    # handle the boolean here but with the same root-vs-table placement rules.
    $toml = Set-TomlBareValue $toml "disable_response_storage" "true"

    $sectionPattern = "(?ms)^\s*\[model_providers\." + [regex]::Escape($provider) + "\]\s*.*?(?=^\s*\[|\z)"
    $section = @(
        "[model_providers.$provider]"
        "name = `"$ProviderName`""
        "base_url = `"$(Normalize-BaseUrl $BaseUrl)`""
        # Do NOT write wire_api: Codex defaults to the Responses API, and pinning
        # it (chat/responses) has caused config rejection or 404s per gateway.
        "env_key = `"$envKey`""
    ) -join "`r`n"
    $section += "`r`n"
    if ($toml -match $sectionPattern) { $toml = [regex]::Replace($toml, $sectionPattern, $section, 1) }
    else {
        if ($toml -and !$toml.EndsWith("`n")) { $toml += "`r`n" }
        $toml += "`r`n$section"
    }
    # Keep the key in [shell_environment_policy.set] too, so shells Codex spawns
    # for tools inherit it.
    $toml = Set-TomlEnvPolicyValue $toml $envKey $ApiKey
    Ensure-Parent $configPath
    [IO.File]::WriteAllText($configPath, $toml, (New-Object Text.UTF8Encoding($false)))

    # env_key is resolved against the REAL process environment at Codex startup,
    # not the config's shell policy block. Persist a User env var so the provider
    # can find the key. (Takes effect only after the app is fully restarted.)
    # Windows persists via the registry; Linux/macOS append an export to the
    # user's shell rc (detected by an existing config file) since there is no
    # equivalent user-wide registry.
    if ($script:IsWindows) {
        [Environment]::SetEnvironmentVariable($envKey, $ApiKey, "User")
        [Environment]::SetEnvironmentVariable($envKey, $ApiKey, "Process")
    } else {
        $rcFile = @("$HOME/.bashrc", "$HOME/.zshrc", "$HOME/.profile") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $rcFile) { $rcFile = "$HOME/.profile" }
        $exportLine = "export $envKey=`"$ApiKey`""
        $rcText = if (Test-Path $rcFile) { Get-Content $rcFile -Raw } else { "" }
        if ($rcText -notmatch [regex]::Escape($envKey)) {
            if ($rcText -and -not $rcText.EndsWith("`n")) { $rcText += "`n" }
            [IO.File]::AppendAllText($rcFile, "`n# Added by AI Config Manager`n$exportLine`n", (New-Object Text.UTF8Encoding($false)))
        }
        Write-Host "  Persisted API key in $rcFile (restart your shell or run: source $rcFile)" -ForegroundColor DarkGray
    }

    return @(
        @{ Path=$authPath; Backup=$authBackup }
        @{ Path=$configPath; Backup=$configBackup }
    )
}

# Merge a live-fetched list with a preset's curated fallback (deduped, sorted).
# Used so a gateway always shows its known-good models even when the live list
# is partial, and so a failed live fetch degrades to the curated list.
# NOTE: `return ,@(...)` — the comma protects the empty-array case, which
# PowerShell otherwise unrolls to $null on its way out of the function.
function Merge-Models {
    param($Live, $Curated)
    return ,@( @($Live) + @($Curated) | Where-Object { $_ } | Sort-Object -Unique )
}

# Fetch the live model list for a preset, returning per-client lists.
# Presets with modelsApiUrl (AgentRouter) hit the public pricing JSON and split
# models by supported_endpoint_types; all other presets (EuroModels, Custom)
# share one OpenAI-compatible /v1/models endpoint, so the same list is offered
# to both clients. The claude block's baseUrl is for the Anthropic-compatible
# root and has no model-list endpoint of its own, so we fetch from the opencode
# (OpenAI-compatible) base URL instead.
function Fetch-PresetModels {
    param($Preset, [string]$ApiKey)
    if ($Preset.modelsApiUrl) {
        $pricing = Get-AgentRouterPricingModels $Preset.modelsApiUrl
        $claude   = @($pricing | Where-Object { $_.supported_endpoint_types -contains "anthropic" } | ForEach-Object { [string]$_.model_name })
        $opencode = @($pricing | Where-Object { $_.supported_endpoint_types -contains "openai" }     | ForEach-Object { [string]$_.model_name })
        return [PSCustomObject]@{ claude = $claude; opencode = $opencode }
    }
    $list = Get-LiveModels $Preset.opencode.baseUrl $ApiKey
    return [PSCustomObject]@{ claude = $list; opencode = $list }
}

# ---------- model picker ----------

function Pick-Model {
    param([string[]]$Models, [bool]$CanRefresh, [string]$GatewayLabel, [string]$ClientLabel)
    $opts = @($Models) + "[ Enter custom model ID ]"
    if ($CanRefresh) { $opts += "[ Refresh model list ]" }
    $opts += "[ Back ]"
    $header = @("Gateway: $GatewayLabel", "Client: $ClientLabel", "Available: $($Models.Count)")
    $idx = Show-Menu -Title "Select Model" -Options $opts -Header $header
    if ($idx -eq -1) { return @{ Action="Cancel"; Model=$null } }
    if ($idx -lt $Models.Count) { return @{ Action="Selected"; Model=$Models[$idx] } }
    $choice = $opts[$idx]
    if ($choice -match "custom") {
        $m = (Read-Host "Enter exact model ID").Trim()
        if ($m) { return @{ Action="Selected"; Model=$m } }
        return @{ Action="Cancel"; Model=$null }
    }
    if ($choice -match "Refresh") { return @{ Action="Refresh"; Model=$null } }
    return @{ Action="Back"; Model=$null }
}

# Loops the model menu (handling Refresh) until a model is chosen or the user backs out.
function Choose-Model {
    param([string[]]$InitialModels, [bool]$CanRefresh, [string]$GatewayLabel, [string]$ClientLabel, $Preset, [string]$ApiKey, [string]$Client)
    $models = $InitialModels
    while ($true) {
        $pick = Pick-Model $models $CanRefresh $GatewayLabel $ClientLabel
        switch ($pick.Action) {
            "Selected" { return $pick.Model }
            "Refresh" {
                try {
                    $fresh = Fetch-PresetModels $Preset $ApiKey
                    $models = Merge-Models $fresh.$Client $Preset.$Client.curatedModels
                } catch {
                    Write-Host ""
                    Write-Host "Refresh failed: $($_.Exception.Message)" -ForegroundColor Red
                    Pause-Screen
                }
                continue
            }
            default { return $null }  # Back / Cancel
        }
    }
}

# ---------- current config view ----------

function Show-Current {
    Clear-Host
    Write-Banner "Current Configuration"

    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
    $cp = Join-Path $claudeDir "settings.json"
    Write-Host "  Claude Code: $cp" -ForegroundColor Gray
    $c = $null
    if (Test-Path $cp) {
        try {
            $c = Get-Content $cp -Raw | ConvertFrom-Json
            Write-Host "    Base URL: $($c.env.ANTHROPIC_BASE_URL)"
            Write-Host "    Model:    $($c.model)"
            Write-Host "    API Key:  $(Mask-Key ([string]$c.env.ANTHROPIC_AUTH_TOKEN))"
        } catch { Write-Host "    Could not parse config." -ForegroundColor Yellow }
    } else { Write-Host "    No config found." -ForegroundColor DarkGray }
    # Claude Code also reads OS env vars; show what it actually inherits, and flag any divergence.
    $osBase = $env:ANTHROPIC_BASE_URL
    if ($osBase) {
        $cfgBase = if ($null -eq $c) { "" } else { [string]$c.env.ANTHROPIC_BASE_URL }
        $same = ($osBase -eq $cfgBase)
        $osTag = if ($same) { "matches settings.json" } else { "DIFFERS from settings.json" }
        $osColor = if ($same) { "DarkGray" } else { "Yellow" }
        Write-Host "    OS env:   ANTHROPIC_BASE_URL=$osBase ($osTag)" -ForegroundColor $osColor
        if ($env:ANTHROPIC_MODEL) { Write-Host "              ANTHROPIC_MODEL=$($env:ANTHROPIC_MODEL)" -ForegroundColor DarkGray }
    }

    Write-Host ""
    $osVars = @("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "OPENAI_API_KEY")
    Write-Host "  Windows environment variables" -ForegroundColor Gray
    foreach ($name in $osVars) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { Write-Host "    $name=$(if ($name -match 'KEY|TOKEN') { Mask-Key $value } else { $value })" }
    }

    Write-Host ""
    Write-Host "  Claude Desktop: 3P gateway config" -ForegroundColor Gray
    $cdDir = Get-ClaudeDesktopConfigDir
    $cdMeta = Join-Path $cdDir "configLibrary/_meta.json"
    if (Test-Path $cdMeta) {
        try {
            $cdM = Get-Content $cdMeta -Raw | ConvertFrom-Json
            $cdId = [string]$cdM.appliedId
            $cdCfgPath = Join-Path $cdDir "configLibrary/$cdId.json"
            if ($cdId -and (Test-Path $cdCfgPath)) {
                $cdCfg = Get-Content $cdCfgPath -Raw | ConvertFrom-Json
                Write-Host "    Config: $cdCfgPath"
                Write-Host "    Base URL:    $($cdCfg.inferenceGatewayBaseUrl)"
                Write-Host "    Auth scheme: $($cdCfg.inferenceGatewayAuthScheme)"
                Write-Host "    API Key:     $(Mask-Key ([string]$cdCfg.inferenceGatewayApiKey))"
                $models = @($cdCfg.inferenceModels | Where-Object { $_ })
                if ($models.Count -gt 0) { Write-Host "    Models:      $($models -join ', ')" }
            } else {
                Write-Host "    No active config entry (appliedId missing or file absent)." -ForegroundColor DarkGray
            }
        } catch { Write-Host "    Could not parse Claude Desktop config." -ForegroundColor Yellow }
    } else {
        Write-Host "    No configLibrary found (Claude Desktop not installed or not launched)." -ForegroundColor DarkGray
    }

    $op = Join-Path $HOME ".config/opencode/opencode.json"
    Write-Host "  OpenCode: $op" -ForegroundColor Gray
    if (Test-Path $op) {
        try {
            $o = Get-Content $op -Raw | ConvertFrom-Json
            $allProvs = @($o.provider.PSObject.Properties)
            $prefix = ($o.model -split "/")[0]
            $active = $allProvs | Where-Object { $_.Name -eq $prefix }
            if ($active) {
                Write-Host "    Provider: $($active.Name) (active)"
                Write-Host "    Base URL: $($active.Value.options.baseURL)"
                Write-Host "    Model:    $($o.model)"
                Write-Host "    API Key:  $(Mask-Key ([string]$active.Value.options.apiKey))"
                $others = @($allProvs | Where-Object { $_.Name -ne $prefix })
                if ($others.Count -gt 0) {
                    $names = ($others | ForEach-Object { $_.Name }) -join ", "
                    Write-Host "    Also configured (inactive): $names" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "    Model:    $($o.model)" -ForegroundColor Yellow
                Write-Host "    No provider matches model prefix '$prefix'." -ForegroundColor Yellow
            }
        } catch { Write-Host "    Could not parse config." -ForegroundColor Yellow }
    } else { Write-Host "    No config found." -ForegroundColor DarkGray }

    $codexDir = Join-Path $HOME ".codex"
    $codexAuth = Join-Path $codexDir "auth.json"
    $codexConfig = Join-Path $codexDir "config.toml"
    Write-Host ""
    Write-Host "  Codex: $codexDir" -ForegroundColor Gray
    if (Test-Path $codexAuth) {
        try {
            $ca = Get-Content $codexAuth -Raw | ConvertFrom-Json
            $key = $ca.OPENAI_API_KEY
            if (!$key -and $ca.tokens) { $key = $ca.tokens.access_token }
            Write-Host "    auth.json API Key: $(Mask-Key ([string]$key))"
        } catch { Write-Host "    Could not parse auth.json." -ForegroundColor Yellow }
    } else { Write-Host "    No auth.json found." -ForegroundColor DarkGray }
    if (Test-Path $codexConfig) {
        Write-Host "    config.toml: $codexConfig"
        $toml = Get-Content $codexConfig -Raw
        $modelLine = [regex]::Match($toml, '(?m)^\s*model\s*=\s*"([^"]+)"').Groups[1].Value
        $providerLine = [regex]::Match($toml, '(?m)^\s*model_provider\s*=\s*"([^"]+)"').Groups[1].Value
        if ($modelLine) { Write-Host "      Model: $modelLine" }
        if ($providerLine) { Write-Host "      Provider: $providerLine" }
    } else { Write-Host "    No config.toml found." -ForegroundColor DarkGray }

    $hermesCandidates = @(
        (Join-Path $HOME ".hermes/config.toml"),
        (Join-Path $HOME ".config/hermes/config.toml"),
        (Join-Path $HOME ".config/hermes/config.json")
    ) | Where-Object { Test-Path $_ }
    if ($hermesCandidates.Count -gt 0) {
        Write-Host "    Hermes config: $($hermesCandidates -join ', ')" -ForegroundColor DarkGray
    }
    Pause-Screen
}

# ---------- backup restore ----------

# Map a tool name to the config file path(s) the writers touch. Used by
# Restore-Backup to find which *.backup-* files belong to which tool.
function Get-ToolConfigPaths([string]$Tool) {
    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
    switch ($Tool) {
        "Claude Code"    { return ,(Join-Path $claudeDir "settings.json") }
        "OpenCode"       { return ,(Join-Path $HOME ".config/opencode/opencode.json") }
        "Codex"          { Write-Output (Join-Path $HOME ".codex/auth.json"); return (Join-Path $HOME ".codex/config.toml") }
        "Claude Desktop" {
            $dir = Get-ClaudeDesktopConfigDir
            $metaPath = Join-Path $dir "configLibrary/_meta.json"
            if (Test-Path $metaPath) {
                try {
                    $appliedId = [string]((Get-Content $metaPath -Raw | ConvertFrom-Json).appliedId)
                    if ($appliedId) { return ,(Join-Path $dir "configLibrary/$appliedId.json") }
                } catch { }
            }
            return @()
        }
        default { return @() }
    }
}

# Given a target config path, return the newest matching "*.backup-*" file.
function Get-LatestBackup([string]$TargetPath) {
    $pattern = "$TargetPath.backup-*"
    $backups = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^[^\\/]+\.backup-\d{8}-\d{6}-\d+$" } |
        Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) { return $null }
    return $backups[0]
}

function Restore-Backup {
    $toolIdx = Show-Menu -Title "Restore Last Backup" -Options @(
        "Claude Code",
        "OpenCode",
        "Codex",
        "Claude Desktop",
        "Back"
    )
    if ($toolIdx -eq -1 -or $toolIdx -eq 4) { return }
    $tool = @("Claude Code", "OpenCode", "Codex", "Claude Desktop")[$toolIdx]
    $paths = @(Get-ToolConfigPaths $tool)

    if ($paths.Count -eq 0) {
        Write-Host ""
        Write-Host "No config path known for $tool (Claude Desktop configLibrary not found)." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    # Collect the newest backup across all of this tool's config files.
    $latest = $null
    $latestTarget = $null
    foreach ($p in $paths) {
        $b = Get-LatestBackup $p
        if ($b -and ($null -eq $latest -or $b.LastWriteTime -gt $latest.LastWriteTime)) {
            $latest = $b
            $latestTarget = $p
        }
    }

    if ($null -eq $latest) {
        Write-Host ""
        Write-Host "No backups found for $tool." -ForegroundColor Yellow
        Write-Host "Configurations are backed up automatically before every write."
        Pause-Screen
        return
    }

    Clear-Host
    Write-Banner "Restore Backup - $tool"
    Write-Host "  Backup: $($latest.FullName)" -ForegroundColor Gray
    Write-Host "  Target: $latestTarget" -ForegroundColor Gray
    Write-Host "  Dated:  $($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray
    Write-Host ""

    $confirm = Show-Menu -Title "Confirm restore" -Options @(
        "Restore this backup",
        "Cancel"
    )
    if ($confirm -ne 0) { return }

    try {
        # Back up the current file first so the restore itself is reversible.
        $currentBackup = Backup-File $latestTarget
        Copy-Item $latest.FullName $latestTarget -Force
        Write-Host ""
        Write-Host "[OK] Restored $tool" -ForegroundColor Green
        Write-Host "     Target: $latestTarget"
        if ($currentBackup) { Write-Host "     Prior state backed up: $currentBackup" -ForegroundColor DarkGray }
        Write-Host ""
        Write-Host "Restart the tool for changes to take effect." -ForegroundColor Cyan
    } catch {
        Write-Host ""
        Write-Host "Restore failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause-Screen
}

# ---------- presets ----------

# Validate one preset's structure so a malformed entry fails with a useful
# message instead of null-dereferencing downstream. Returns nothing; throws on
# the first problem.
function Assert-PresetValid($Preset) {
    $label = if ($Preset.label) { [string]$Preset.label } else { "<untitled>" }
    $base = "Preset '$label' is invalid:"

    if (-not $Preset.id) { throw "$base missing 'id'." }
    foreach ($client in @("claude", "opencode")) {
        $block = $Preset.PSObject.Properties[$client]
        if ($null -eq $block -or $null -eq $block.Value) { throw "$base missing '$client' block." }
        if ([string]::IsNullOrWhiteSpace([string]$block.Value.baseUrl)) { throw "$base '$client.baseUrl' is empty." }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Preset.opencode.providerKey)) { throw "$base 'opencode.providerKey' is empty." }
    if ([string]::IsNullOrWhiteSpace([string]$Preset.opencode.npmPackage)) { throw "$base 'opencode.npmPackage' is empty." }
}

function Load-Presets {
    $path = Join-Path $PSScriptRoot "AI-Config-Presets.json"
    if (!(Test-Path $path)) {
        Write-Host "Preset file not found: $path" -ForegroundColor Red
        exit 1
    }
    try { $presets = @((Get-Content $path -Raw | ConvertFrom-Json).presets) }
    catch {
        Write-Host "Preset file is invalid JSON: $path" -ForegroundColor Red
        exit 1
    }
    foreach ($p in $presets) { Assert-PresetValid $p }
    return $presets
}

function New-CustomPreset([string]$Url) {
    [PSCustomObject]@{
        id = "custom"
        label = "Custom"
        dashboard = $null
        fetchModels = $true
        claude    = [PSCustomObject]@{ baseUrl = $Url; curatedModels = @() }
        opencode  = [PSCustomObject]@{ baseUrl = $Url; providerKey = "custom"; providerName = "Custom"; npmPackage = "@ai-sdk/openai-compatible"; curatedModels = @() }
    }
}

# ---------- self-test ----------
# Offline checks for the non-trivial helpers (scroll math, TOML/JSON writers,
# model merging, URL handling, backup, validation). Run without a TTY:
#   powershell -File .\AI-Config-Manager.ps1 -SelfTest
if ($SelfTest) {
    function Assert-Equal($a, $b, $msg) {
        if ($a -ne $b) { Write-Host "FAIL: $msg (expected '$b', got '$a')" -ForegroundColor Red; exit 1 }
        Write-Host "ok: $msg" -ForegroundColor DarkGray
    }
    function Assert-True($cond, $msg) {
        if (-not $cond) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }
        Write-Host "ok: $msg" -ForegroundColor DarkGray
    }

    # Scroll-window math
    Assert-Equal (Get-ScrollWindow 5 10 5 0) 1 "down: selection just past window"
    Assert-Equal (Get-ScrollWindow 9 10 5 0) 5 "down: selection near end"
    Assert-Equal (Get-ScrollWindow 0 10 5 3) 0 "up: selection above window"
    Assert-Equal (Get-ScrollWindow 0 3 5 0) 0 "count fits page"
    Assert-Equal (Get-ScrollWindow 2 100 5 50) 2 "up: from far window"
    Assert-Equal (Get-ScrollWindow 3 100 5 0) 0 "within window: no change"

    # URL / endpoint handling
    Assert-Equal (Get-ModelsEndpoint "https://x.com/v1") "https://x.com/v1/models" "models endpoint keeps existing /v1"
    Assert-Equal (Get-ModelsEndpoint "https://x.com") "https://x.com/v1/models" "models endpoint appends /v1"
    Assert-Equal (Get-ModelsEndpoint "https://x.com/") "https://x.com/v1/models" "models endpoint strips trailing slash"

    # Model merging
    Assert-Equal ((Merge-Models @("b","a","b") @("a","c")) -join ",") "a,b,c" "merge dedupes and sorts"
    Assert-Equal (Merge-Models $null $null).Count 0 "merge handles null inputs"

    # TOML root-vs-table placement (root keys must precede the first [table])
    $t1 = "[model_providers.custom]`r`nname = `"x`"`r`n"
    $t2 = Set-TomlValue $t1 "model" "gpt-5"
    Assert-True ($t2.StartsWith("model = `"gpt-5`"")) "TOML root key placed before table"
    $t3 = Set-TomlValue $t2 "model" "other"
    Assert-True (($t3 -match "(?m)^model = `"other`"\s*$") -and ($t3 -notmatch "other.*model")) "TOML root key replaced in place"
    $t4 = Set-TomlBareValue $t3 "disable_response_storage" "true"
    Assert-True ($t4 -match "(?m)^disable_response_storage = true\s*$") "TOML bare boolean written unquoted"

    # TOML env-policy table append + replace
    $t5 = Set-TomlEnvPolicyValue "model = `"x`"`r`n" "MY_API_KEY" "secret"
    Assert-True ($t5 -match "(?m)^\[shell_environment_policy\.set\]") "TOML env-policy table appended"
    $t6 = Set-TomlEnvPolicyValue $t5 "MY_API_KEY" "newsecret"
    Assert-True (($t6 -match "(?m)^MY_API_KEY = `"newsecret`"\s*$") -and ($t6 -notmatch "MY_API_KEY = `"secret`"")) "TOML env-policy key replaced"

    # JSON sanitizer (PS 5.1 rejects empty-string keys)
    $sanitized = Repair-JsonEmptyKeys '{"success":true,"data":[],"usable_group":{"":["x"]}}'
    Assert-True (($sanitized -match '"__empty__":\["x"\]') -and ($sanitized -notmatch '""\s*:')) "empty-string key renamed to placeholder"
    $null = $sanitized | ConvertFrom-Json
    Assert-True $true "sanitized JSON parses without error"

    # Error body truncation
    Assert-Equal (Truncate-Text "short") "short" "truncate leaves short text alone"
    Assert-True ((Truncate-Text ("a" * 1000)).Length -lt 1000) "truncate caps long text"

    # Backup: distinct names even within the same second
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("aimg-selftest-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    try {
        $f = Join-Path $tmpDir "cfg.json"
        Set-Content $f "{}"
        $b1 = Backup-File $f
        $b2 = Backup-File $f
        Assert-True (Test-Path $b1) "backup file created"
        Assert-True ($b1 -ne $b2) "backup names do not collide"

        # Save-Json must be BOM-less (the Claude Desktop app rejects a BOM)
        $jf = Join-Path $tmpDir "out.json"
        Save-Json ([PSCustomObject]@{ a = 1; b = @(1,2) }) $jf
        $bytes = [IO.File]::ReadAllBytes($jf)
        Assert-True ($bytes[0] -ne 0xEF -and $bytes[0] -ne 0xBB) "Save-Json writes BOM-less UTF-8"
    } finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

    # Preset validation
    $good = [PSCustomObject]@{
        id = "p"; label = "P"
        claude  = [PSCustomObject]@{ baseUrl = "https://a.com"; curatedModels = @() }
        opencode = [PSCustomObject]@{ baseUrl = "https://a.com/v1"; providerKey = "p"; providerName = "P"; npmPackage = "@ai-sdk/openai-compatible"; curatedModels = @() }
    }
    Assert-True ($null -eq (Assert-PresetValid $good)) "valid preset accepted"
    $bad = [PSCustomObject]@{ id = ""; label = "Bad"; claude = [PSCustomObject]@{ baseUrl = $null }; opencode = [PSCustomObject]@{ baseUrl = "x"; providerKey = ""; providerName = ""; npmPackage = "" } }
    $badThrew = $false
    try { Assert-PresetValid $bad } catch { $badThrew = $true }
    Assert-True $badThrew "invalid preset rejected"

    Write-Host "All self-test checks passed." -ForegroundColor Green
    exit 0
}

# ---------- main loop ----------

if ([Console]::IsInputRedirected) {
    Write-Host "This TUI requires an interactive terminal. Run it directly, not piped." -ForegroundColor Red
    exit 1
}

$presets = Load-Presets

while ($true) {
    $targetIdx = Show-Menu -Title "AI Config Manager" -Options @(
        "Configure Claude Code",
        "Configure OpenCode",
        "Configure Codex",
        "Configure Hermes Desktop",
        "Configure Claude Desktop",
        "Configure Both (Claude Code + OpenCode)",
        "Restore last backup",
        "View current configuration",
        "Exit"
    )
    if ($targetIdx -eq -1 -or $targetIdx -eq 8) { break }
    if ($targetIdx -eq 6) { Restore-Backup; continue }
    if ($targetIdx -eq 7) { Show-Current; continue }
    if ($targetIdx -eq 3) { Invoke-HermesModelSetup; continue }

    $doClaude = $targetIdx -in 0,5
    $doOpenCode = $targetIdx -in 1,5
    $doCodex = $targetIdx -eq 2
    $doClaudeDesktop = $targetIdx -eq 4

    $gwOpts = @($presets | ForEach-Object { $_.label }) + "[ Custom base URL ]"
    $gwIdx = Show-Menu -Title "Select Gateway" -Options $gwOpts
    if ($gwIdx -eq -1) { continue }

    if ($gwIdx -lt $presets.Count) {
        $preset = $presets[$gwIdx]
    } else {
        while ($true) {
            $u = Normalize-BaseUrl ((Read-Host "Enter custom Base URL").Trim())
            if ($u -match "^https?://") { $preset = New-CustomPreset $u; break }
            Write-Host "Enter a full http:// or https:// URL." -ForegroundColor Yellow
        }
    }

    # Never pass the reserved built-in ID "openai" as a provider key — Codex
    # rejects the whole config if a custom provider reuses a built-in ID.
    # Provider key/name come from the preset's opencode block (same value Codex
    # needs); fall back to a prompt only for presets that don't define one.
    $codexProviderKey = $preset.opencode.providerKey
    $codexProviderName = $preset.opencode.providerName
    if ($doCodex) {
        if ([string]::IsNullOrWhiteSpace($codexProviderKey)) {
            while ([string]::IsNullOrWhiteSpace($codexProviderKey)) {
                $codexProviderKey = (Read-Host "Codex provider key (for [model_providers.<key>])").Trim()
            }
        }
        if ([string]::IsNullOrWhiteSpace($codexProviderName)) {
            while ([string]::IsNullOrWhiteSpace($codexProviderName)) {
                $codexProviderName = (Read-Host "Codex provider display name").Trim()
            }
        }
    }

    Clear-Host
    Write-Banner "API Key - $($preset.label)"
    if ($preset.dashboard) {
        Write-Host "  Get a key at: $($preset.dashboard)" -ForegroundColor DarkGray
        Write-Host ""
    }
    $apiKey = Read-SecretPlain
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host "API key cannot be empty." -ForegroundColor Red
        Pause-Screen
        continue
    }

    $live = $null
    $fetchOk = $false
    if ($preset.fetchModels) {
        try {
            $live = Fetch-PresetModels $preset $apiKey
            $fetchOk = $true
        } catch {
            $hasCurated = ($preset.claude.curatedModels.Count -gt 0 -or $preset.opencode.curatedModels.Count -gt 0)
            if ($hasCurated) {
                Write-Host ""
                Write-Host "Live model list unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Showing known models instead." -ForegroundColor DarkGray
            } else {
                Write-Host ""
                Write-Host "Could not fetch models:" -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Tip: the script requests $(Get-ModelsEndpoint $preset.opencode.baseUrl). If that's wrong, choose Custom base URL." -ForegroundColor DarkGray
                Pause-Screen
                continue
            }
        }
    }
    $canRefresh = $fetchOk
    $liveClaude = if ($live) { $live.claude } else { $null }
    $liveOpenCode = if ($live) { $live.opencode } else { $null }

    while ($true) {
        $claudeModel = $null
        $opencodeModel = $null
        $codexModel = $null
        $claudeDesktopModel = $null

        if ($doClaude -or $doClaudeDesktop) {
            $cm = Merge-Models $liveClaude $preset.claude.curatedModels
            if ($doClaude) {
                $claudeModel = Choose-Model $cm $canRefresh $preset.label "Claude Code" $preset $apiKey "claude"
                if (!$claudeModel) { break }
            }
            if ($doClaudeDesktop) {
                $claudeDesktopModel = Choose-Model $cm $canRefresh $preset.label "Claude Desktop" $preset $apiKey "claude"
                if (!$claudeDesktopModel) { break }
            }
        }
        if ($doOpenCode -or $doCodex) {
            $om = Merge-Models $liveOpenCode $preset.opencode.curatedModels
            if ($doOpenCode) {
                $opencodeModel = Choose-Model $om $canRefresh $preset.label "OpenCode" $preset $apiKey "opencode"
                if (!$opencodeModel) { break }
            }
            if ($doCodex) {
                $codexModel = Choose-Model $om $canRefresh $preset.label "Codex" $preset $apiKey "opencode"
                if (!$codexModel) { break }
            }
        }

        $summary = @()
        $targetName = if ($doClaude -and $doOpenCode) { 'Claude Code + OpenCode' } elseif ($doClaude) { 'Claude Code' } elseif ($doClaudeDesktop) { 'Claude Desktop' } elseif ($doCodex) { 'Codex' } else { 'OpenCode' }
        $summary += "Target:  $targetName"
        $summary += "Gateway: $($preset.label)"
        if ($doClaude)          { $summary += "Claude model:        $claudeModel" }
        if ($doClaudeDesktop)   { $summary += "Claude Desktop model:$claudeDesktopModel" }
        if ($doOpenCode)        { $summary += "OpenCode model:      $opencodeModel" }
        if ($doCodex)           { $summary += "Codex model:         $codexModel" }
        $summary += "API Key: $(Mask-Key $apiKey)"

        $cIdx = Show-Menu -Title "Confirm" -Options @(
            "Apply configuration",
            "Choose another model",
            "Cancel"
        ) -Header $summary

        if ($cIdx -eq 1 -or $cIdx -eq -1) { continue }
        if ($cIdx -eq 2) { break }

        try {
            Write-Host ""
            if ($doClaude) {
                $r = Configure-Claude $preset.claude.baseUrl $apiKey $claudeModel
                Write-Host "[OK] Claude Code configured" -ForegroundColor Green
                Write-Host "     $($r.Path)"
                if ($r.Backup) { Write-Host "     Backup: $($r.Backup)" -ForegroundColor DarkGray }
            }
            if ($doClaudeDesktop) {
                $r = Configure-ClaudeDesktop $preset.claude.baseUrl $apiKey $claudeDesktopModel
                Write-Host "[OK] Claude Desktop configured (3P gateway config)" -ForegroundColor Green
                Write-Host "     $($r.Path)"
                if ($r.Backup) { Write-Host "     Backup: $($r.Backup)" -ForegroundColor DarkGray }
                Write-Host ""
                Write-Host "  Next steps in the Claude Desktop app:" -ForegroundColor Cyan
                Write-Host "  1. Fully quit and reopen the app (tray icon > Quit, not just close window)" -ForegroundColor Gray
                Write-Host "  2. If a setup/login screen appears, open the app menu (top-left) > Developer >" -ForegroundColor Gray
                Write-Host "     Configure Third-Party Inference to verify the gateway config loaded" -ForegroundColor Gray
                Write-Host "  3. The gateway base URL, API key, and model are pre-configured by this script" -ForegroundColor Gray
                Write-Host "  4. If the model list looks wrong, the model IDs must match what your gateway" -ForegroundColor Gray
                Write-Host "     expects (each gateway uses its own model ID format)" -ForegroundColor Gray
            }
            if ($doOpenCode) {
                $r = Configure-OpenCode $preset.opencode.baseUrl $apiKey $opencodeModel $preset.opencode.providerKey $preset.opencode.providerName $preset.opencode.npmPackage
                Write-Host "[OK] OpenCode configured" -ForegroundColor Green
                Write-Host "     $($r.Path)"
                if ($r.Backup) { Write-Host "     Backup: $($r.Backup)" -ForegroundColor DarkGray }
                if ($preset.id -eq "agentrouter") {
                    Write-Host "     If OpenCode rejects the key, run: opencode providers login --provider agentrouter" -ForegroundColor DarkGray
                }
            }
            if ($doCodex) {
                # Codex appends /responses to base_url, so AgentRouter needs the
                # root host (not /v1). Presets provide codex.baseUrl for this;
                # fall back to opencode.baseUrl for presets/custom without one.
                $codexBaseUrl = if ($preset.codex -and $preset.codex.baseUrl) { $preset.codex.baseUrl } else { $preset.opencode.baseUrl }
                $results = Configure-Codex $codexBaseUrl $apiKey $codexModel $codexProviderKey $codexProviderName
                Write-Host "[OK] Codex configured" -ForegroundColor Green
                foreach ($item in $results) {
                    Write-Host "     $($item.Path)"
                    if ($item.Backup) { Write-Host "     Backup: $($item.Backup)" -ForegroundColor DarkGray }
                }
            }
            Write-Host ""
            Write-Host "Configuration complete." -ForegroundColor Green
            Write-Host "Close existing Claude Code, OpenCode, or Codex sessions and start a new terminal session."
        } catch {
            Write-Host ""
            Write-Host "Configuration failed:" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
        Pause-Screen
        break
    }
}
