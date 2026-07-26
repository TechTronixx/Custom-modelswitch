#!/usr/bin/env bash
set -e

REPO="TechTronixx/Custom-modelswitch"
BRANCH="main"
DIR="$HOME/AI-Config-Manager"

mkdir -p "$DIR"
cd "$DIR"

echo "Downloading AI Config Manager..."
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/AI-Config-Manager.ps1" -o AI-Config-Manager.ps1
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/AI-Config-Presets.json" -o AI-Config-Presets.json

if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell not found. Installing..."
  case "${OSTYPE:-}" in
    linux*)
      TMP=$(mktemp)
      curl -fsSL https://aka.ms/install-powershell.sh -o "$TMP"
      sudo bash "$TMP"
      rm -f "$TMP"
      ;;
    darwin*)
      if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required. Install it from https://brew.sh"
        exit 1
      fi
      brew install powershell
      ;;
    *)
      echo "Unsupported OS. Install PowerShell 7 manually: https://aka.ms/powershell"
      exit 1
      ;;
  esac
fi

echo "Launching AI Config Manager..."
pwsh -ExecutionPolicy Bypass -File ./AI-Config-Manager.ps1
