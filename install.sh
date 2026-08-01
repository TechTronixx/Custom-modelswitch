#!/usr/bin/env bash
# One-line installer for AI Config Manager (Linux/macOS).
# Usage: curl -fsSL https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main/install.sh | bash
set -e

REPO="TechTronixx/Custom-modelswitch"
BRANCH="main"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
DIR="$HOME/AI-Config-Manager"

mkdir -p "$DIR"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell (pwsh) is required but not installed."
  echo "Linux:   sudo snap install powershell --classic   (or see https://aka.ms/powershell)"
  echo "macOS:   brew install powershell"
  exit 1
fi

echo "Downloading AI Config Manager into $DIR ..."
curl -fsSL "$BASE/AI-Config-Manager.ps1" -o "$DIR/AI-Config-Manager.ps1"
curl -fsSL "$BASE/AI-Config-Presets.json" -o "$DIR/AI-Config-Presets.json"

echo "Launching AI Config Manager ..."
pwsh -File "$DIR/AI-Config-Manager.ps1"
