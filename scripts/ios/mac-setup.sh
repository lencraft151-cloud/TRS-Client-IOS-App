#!/usr/bin/env bash
# TRS Launcher – einmal auf dem Mac ausführen; danach reichen `git pull` und ▶ Run in Xcode.
#
#   bash scripts/ios/mac-setup.sh
#
# - legt Änderungen, die Xcode an eingecheckten Projektdateien gemacht hat (Team, Bundle-ID …), per git stash beiseite
# - trägt Team und Bundle-ID in src-tauri/gen/apple/Signing.local.xcconfig ein (von git ignoriert): aus diesen
#   Änderungen, sonst aus Xcodes Konten, sonst aus dem „Apple Development“-Zertifikat im Schlüsselbund
# - stellt git so ein, dass `git pull` Xcode-Änderungen künftig selbst beiseitelegt und wieder anwendet
# - installiert die Rust-Teile für iOS (Ziel aarch64-apple-ios, llvm-tools)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
APPLE=src-tauri/gen/apple
PBXPROJ="$APPLE/trs-launcher.xcodeproj/project.pbxproj"
LOCAL="$APPLE/Signing.local.xcconfig"

say() { printf '\n== %s\n' "$*"; }

# --- 1. Xcode-Änderungen beiseitelegen ---
if ! git diff --quiet -- "$APPLE" || ! git diff --cached --quiet -- "$APPLE"; then
  say "Xcode-Änderungen an $APPLE beiseitelegen (git stash)"
  git stash push -m "Xcode-Änderungen (mac-setup)" -- "$APPLE"
fi

# --- 2. Team und Bundle-ID finden ---
setting_from_stashes() {
  local key="$1" ref value
  while IFS= read -r ref; do
    value="$(git diff "$ref^1" "$ref" -- "$PBXPROJ" 2> /dev/null \
      | sed -nE "s/^\+[[:space:]]*$key = \"?([^\";]+)\"?;.*/\1/p" | head -n 1)"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
  done < <(git stash list --format=%gd)
}

team="$(grep -s '^DEVELOPMENT_TEAM' "$LOCAL" | sed -E 's/.*= *//' | tr -d '[:space:]' || true)"
bundle="$(grep -s '^PRODUCT_BUNDLE_IDENTIFIER' "$LOCAL" | sed -E 's/.*= *//' | tr -d '[:space:]' || true)"
[ -n "$team" ] || team="$(setting_from_stashes DEVELOPMENT_TEAM)"
[ -n "$bundle" ] || bundle="$(setting_from_stashes PRODUCT_BUNDLE_IDENTIFIER)"
if [ -z "$team" ]; then
  # Xcode → Settings → Accounts
  team="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2> /dev/null \
    | sed -nE 's/.*teamID = "?([A-Z0-9]{10})"?;.*/\1/p' | head -n 1 || true)"
fi
if [ -z "$team" ]; then
  # Zertifikat „Apple Development: … (TEAMID)“ – die Team-ID steht im Feld OU.
  team="$(security find-certificate -a -c "Apple Development" -p 2> /dev/null \
    | openssl x509 -noout -subject 2> /dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -n 1 || true)"
fi

if [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  if ! grep -qs '^DEVELOPMENT_TEAM' "$LOCAL"; then
    echo "DEVELOPMENT_TEAM = $team" >> "$LOCAL"
  fi
  say "Team: $team (in $LOCAL)"
else
  say "Kein Team gefunden – in Xcode unter Settings → Accounts mit deiner Apple-ID anmelden, dann erneut ausführen."
fi
if [ -n "$bundle" ] && [ "$bundle" != dev.theredstonee.trslauncher ] && ! grep -qs '^PRODUCT_BUNDLE_IDENTIFIER' "$LOCAL"; then
  echo "PRODUCT_BUNDLE_IDENTIFIER = $bundle" >> "$LOCAL"
  say "Bundle-ID: $bundle (in $LOCAL)"
fi

# --- 3. git pull legt Xcode-Änderungen künftig selbst beiseite ---
git config merge.autoStash true
git config rebase.autoStash true
say "git pull legt lokale Änderungen künftig automatisch beiseite"

# --- 4. Rust für iOS ---
if command -v rustup > /dev/null; then
  say "Rust für iOS einrichten"
  rustup target add aarch64-apple-ios
  rustup component add llvm-tools
else
  say "rustup fehlt – Rust installieren: https://rustup.rs (danach dieses Skript erneut ausführen)"
fi
command -v pnpm > /dev/null || say "pnpm fehlt – installieren mit: npm install -g pnpm"

say "Fertig. Jetzt in Xcode: Product → Clean Build Folder (⇧⌘K), dann ▶ Run. Künftig reicht git pull."
