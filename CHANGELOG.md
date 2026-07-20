# Changelog

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
