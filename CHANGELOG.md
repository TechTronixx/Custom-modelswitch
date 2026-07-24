# Changelog

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
