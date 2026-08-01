# Changelog

## v1.2.1

- New: **Update check on startup**. The script compares its version against the
  latest GitHub release and shows a notice in the menu header when an update is
  available. Offline-safe (fails silently). Disable with `-SkipVersionCheck`.

## v1.2.0

- New: **Restore last backup** menu option. Re-applies the newest `*.backup-*`
  file for the chosen tool, backing up the current state first.
- New: **OpenRouter** preset ships alongside AgentRouter and EuroModels.
- New: AgentRouter curated model list refreshed (adds `deepseek-v4-flash-0731`).
- New: Linux and macOS support. Script detects the platform and uses `curl` /
  `curl.exe` accordingly; Claude Desktop configLibrary is located per platform;
  Codex's API key is persisted via a User env var (Windows) or the shell rc
  (Linux/macOS). One-line installer: `curl .../install.sh | bash`.
- New: built-in `-SelfTest` now covers the TOML/JSON writers, model merging,
  URL handling, backup, and validation (25 checks, was 6).
- New: box-drawing menu borders, banner highlight bar, and a bottom status bar
  showing scroll position and the version. Model fetches show a spinner.
- Fix: preset validation rejects empty provider keys / npm packages / base URLs
  with a clear message instead of writing broken config.
- Fix: empty-string JSON keys from the AgentRouter pricing API are renamed to a
  safe placeholder (PS 5.1's `ConvertFrom-Json` rejects them).
- Fix: backup names never collide even when two backups happen in the same
  second (tick counter appended).
- Fix: error bodies are truncated before display so a huge response can't flood
  the terminal.
- Fix: `Configure-OpenCode` refuses empty `npmPackage` / `providerKey`.

## v1.1.0

- New: Configure Claude Desktop app support via the 3P gateway config
  (configLibrary entry with inferenceProvider, base URL, API key, auth scheme,
  and model list).
- Fix: all JSON writers now write BOM-less UTF-8. The Claude Desktop app's
  JSON parser rejects files with a BOM, which caused the 3P config to be
  silently ignored and the app to show a login/setup screen.
- Fix: Codex config writer no longer writes `wire_api` (removed in newer Codex,
  caused the entire config.toml to be discarded).
- Fix: Codex config writer sets `auth_mode = "apikey"` in auth.json (the desktop
  app ignores custom providers while auth_mode is "chatgpt").
- Fix: Codex `env_key` resolved against the real process env, not the config's
  shell policy block. The writer now sets a persistent User env var.
- Fix: Codex base URL uses the root host (no `/v1`) since Codex appends
  `/responses` to the base URL.
- Fix: TOML root keys are now placed before the first `[table]` header to
  avoid being absorbed into table sections.
- Fix: removed dead `$cancelled` variable and `$args` automatic-variable
  shadowing in the model-fetch function.

## v1.0.0

First public release.

- Terminal UI to configure Claude Code, OpenCode, and Codex against any
  OpenAI/Anthropic-compatible gateway.
- Preset system (`AI-Config-Presets.json`) with live model fetching and curated
  fallbacks; ships AgentRouter and EuroModels, plus a runtime Custom base URL.
- Hermes Desktop launcher (detects `hermes`, runs `hermes model`).
- One-click bootstrap: `irm | iex` downloads both files and launches.
- Backs up every config file before writing; sets a persistent User env var for
  Codex provider keys.
- Issue templates, CONTRIBUTING, MIT license.
