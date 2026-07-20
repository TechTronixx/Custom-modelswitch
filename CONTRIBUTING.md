# Contributing

Thanks for considering a contribution!

## Branch workflow

- `main` — stable, always runnable. Protected by review.
- `dev` — active development. Branch off `dev` for your work.

```powershell
git clone https://github.com/TechTronixx/Custom-modelswitch.git
cd Custom-modelswitch
git checkout dev
git checkout -b fix/your-topic
```

Make your changes, then open a pull request targeting `dev` (or `main` for small
fixes). Describe what changed and why.

## Before you submit

- The script must stay single-file and dependency-free (Windows PowerShell 5.1+).
- `AI-Config-Presets.json` must remain beside the script.
- Run the self-test — it must pass:

  ```powershell
  powershell -File .\AI-Config-Manager.ps1 -SelfTest
  ```

- Don't commit secrets or `*.backup-*` files (both are in `.gitignore`).
- Back up-before-write behavior must be preserved for every config writer.

## Adding a gateway preset

Edit `AI-Config-Presets.json` — no code changes needed. Copy an existing preset
block and fill in the per-tool base URLs, provider labels, and a curated model
fallback list. Note that base URLs can differ per tool (Codex appends `/responses`,
OpenCode uses `/v1`).

## Reporting issues

Use the issue templates (bug report or feature request). Include the tool,
gateway/preset, PowerShell version, and Windows version.
