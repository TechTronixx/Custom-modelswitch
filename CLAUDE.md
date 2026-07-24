# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file Windows PowerShell TUI (`AI-Config-Manager.ps1`) that points Claude Code, Claude Desktop, OpenCode, and Codex at a custom OpenAI/Anthropic-compatible gateway, and launches Hermes Desktop's own model setup. Gateway definitions live in `AI-Config-Presets.json`. No build step, no dependencies beyond `curl.exe` (bundled with Windows).

## Commands

```powershell
# Run the TUI
powershell -ExecutionPolicy Bypass -File .\AI-Config-Manager.ps1

# Self-test (scroll-window math, no terminal needed) - must pass before any commit
powershell -File .\AI-Config-Manager.ps1 -SelfTest

# One-click install for end users (downloads both files to ~/AI-Config-Manager and launches)
irm https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main/bootstrap.ps1 | iex
```

Git workflow: `dev` is active development, `main` is stable. Branch off `dev`, PR to `dev`, merge to `main` when stable. Keep both in sync (after committing to `main`, `git checkout dev && git merge main && git push`).

## Architecture

One file, top to bottom: scroll-window math + self-test, UI helpers, input helpers, live model fetch (generic `/v1/models` plus the AgentRouter public `/api/pricing` endpoint), config writers (one per tool), model picker, current-config viewer, preset loader, then the main menu loop.

`AI-Config-Presets.json` is the data layer. Each preset holds per-tool base URLs, provider labels, a curated model fallback list, and an optional `modelsApiUrl` for AgentRouter's public model list. Adding a gateway is a JSON edit, never a code change. The script reads it from `$PSScriptRoot` at startup and exits if it is missing, so it must ship beside the script.

`Fetch-PresetModels` splits models by `supported_endpoint_types`: `anthropic` for Claude, `openai` for OpenCode/Codex. `Merge-Models` unions the live list with the preset's curated fallback so a failed fetch degrades gracefully.

## Invariants - do not break these

- **Single file, no dependencies.** The script must stay one `.ps1` that runs on PowerShell 5.1 with only `curl.exe`. Do not add module imports or package dependencies.
- **Backup before write.** Every config writer calls `Backup-File` first. New writers must too.
- **Presets beside the script.** `Load-Presets` reads `$PSScriptRoot\AI-Config-Presets.json`. Do not move to a config dir without updating this and the bootstrap.

## Codex config gotchas (learned the hard way, do not regress)

The Codex desktop app is picky and silently ignores the whole `config.toml` on any invalid value, falling back to ChatGPT defaults. `Configure-Codex` encodes workarounds for all of these:

- **`auth_mode` gate.** While `~/.codex/auth.json` says `"auth_mode": "chatgpt"`, the app uses its built-in ChatGPT provider and ignores `model_provider` entirely. The writer sets `auth_mode = "apikey"` and writes both `OPEN_API_KEY` and `OPENAI_API_KEY`.
- **All-or-nothing validation.** One unsupported key makes Codex discard the entire file. Do not write `wire_api` (the `"chat"` value was removed in newer Codex, and `"responses"` is the default so it is unnecessary). Never use the reserved built-in provider id `openai` as a custom provider key; the writer remaps it to `custom`.
- **`env_key` resolves against the real process environment**, not the `[shell_environment_policy.set]` block in config.toml (that block only feeds shells Codex spawns for tools). The writer sets a persistent User environment variable via `[Environment]::SetEnvironmentVariable(..., "User")` so the provider can actually find the key.
- **Base URL differs per tool.** Codex appends `/responses` to `base_url`, so AgentRouter's Codex base URL is the root `https://agentrouter.org` (not `/v1`). OpenCode uses `/v1`. Presets carry a separate `codex.baseUrl` for this; the call site uses it with a fallback to `opencode.baseUrl`.

## Claude Desktop config gotchas

The Claude Desktop Electron app runs in "3P" (third-party) mode and reads its gateway settings from a managed config file in `%LOCALAPPDATA%\Claude-3p\configLibrary\<appliedId>.json`, where `appliedId` comes from `configLibrary\_meta.json`. `Configure-ClaudeDesktop` finds that entry, backs it up, and writes:

- `inferenceProvider` = `"gateway"`
- `inferenceGatewayBaseUrl` = the gateway base URL
- `inferenceGatewayApiKey` = the API key
- `inferenceGatewayAuthScheme` = `"x-api-key"` (the app also supports `"bearer"` and `"sso"`)
- `inferenceModels` = `[selected model]`

**BOM is fatal.** The app's `JSON.parse` rejects files that start with a UTF-8 BOM (`EF BB BF`). PowerShell 5.1's `Set-Content -Encoding UTF8` adds one. `Save-Json` must use `[IO.File]::WriteAllText` with `Text.UTF8Encoding($false)` (BOM-less) for ALL JSON writers, not just Claude Desktop. If the app log says `Unexpected token` on a config file, check for a BOM.

**Model ID format is per-gateway.** Each gateway uses its own model ID format (e.g. EuroModels uses `accounts/euromodels/claude-opus-4.7`, AgentRouter uses `claude-opus-4-8`). The model picker fetches the live list from the gateway, so the IDs in `inferenceModels` match what that gateway expects. Do not hardcode model IDs.

**The app needs a full restart** to pick up config changes. If a setup/login screen appears, the config did not load (check the app log at `%APPDATA%\Claude\logs\main.log` or `%LOCALAPPDATA%\Claude-3p\logs\main.log` for parse errors).

## TOML writer gotchas

`Set-TomlValue` and `Set-TomlBareValue` place root keys before the first `[table]` header, because TOML parses any key after a table header as a member of that table (a root `model =` line placed after `[windows]` becomes `windows.model` and is silently ignored). They also strip any stray copy of the key from inside the tables, which self-heals configs an older version of this script mis-wrote. If you add a new root TOML key, use these helpers, not a naive append.

`Set-TomlEnvPolicyValue` is the opposite: it writes a key inside the `[shell_environment_policy.set]` table specifically, appending the table if missing.
