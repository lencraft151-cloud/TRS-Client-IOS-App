#!/usr/bin/env bash
# TRS Launcher – baut die iOS-App aus dem eingecheckten Xcode-Projekt (src-tauri/gen/apple) und packt sie als IPA.
#
#   scripts/ios/build-ipa.sh <ausgabe-ordner> [engine-ordner]
#
# Ergebnis in <ausgabe-ordner>:
#   TRS-Launcher-unsigned.ipa   ldid-Pseudosignatur mit Entitlements – für AltStore/SideStore, Feather, ESign,
#                               Scarlet, Sideloadly, TrollStore (die signieren mit deinem Profil/Apple-ID neu)
#   TRS-Launcher.ipa            nur mit Signier-Daten (s. u.): mit deinem Zertifikat + Profil signiert,
#                               direkt installierbar (OTA-Link, Apple Configurator, Xcode, Finder)
#
# Signier-Daten (optional, Umgebung):
#   IOS_P12_PATH, IOS_P12_PASSWORD, IOS_PROFILE_PATH, [IOS_BUNDLE_ID]
#
# Engine-Ordner (scripts/ios/build-engine.sh / CI-Artefakt „engine-ios“) macht den Minecraft-Start möglich;
# ohne ihn läuft der Launcher, nur der Spielstart meldet „Engine fehlt“.
# Braucht macOS mit Xcode, Rust (Ziel aarch64-apple-ios), Node 22 + pnpm, ldid (brew install ldid).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:?Aufruf: build-ipa.sh <ausgabe-ordner> [engine-ordner]}"
ENGINE="${2:-}"
APPLE="$ROOT/src-tauri/gen/apple"
ENTITLEMENTS="$ROOT/src-tauri/plugins/tauri-plugin-trs-game/ios/trs-game.entitlements"

die() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || die "nur auf macOS (Xcode)"
command -v ldid > /dev/null || die "ldid fehlt (brew install ldid)"
if [ -n "$ENGINE" ]; then
  [ -f "$ENGINE/engine.json" ] || die "$ENGINE ist kein Engine-Ordner (engine.json fehlt)"
  ENGINE="$(cd "$ENGINE" && pwd)"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Archiv ohne Signatur (Oberfläche + Rust baut die Phase „Build Rust Code“ des Projekts) ---
alt_icons="$(find "$APPLE/Assets.xcassets" -maxdepth 1 -type d -name 'AppIcon-*.appiconset' -exec basename {} .appiconset \; | sort | tr '\n' ' ' | sed 's/ $//')"
xcodebuild -project "$APPLE/trs-launcher.xcodeproj" -scheme trs-launcher_iOS -configuration release \
  -sdk iphoneos -destination 'generic/platform=iOS' -archivePath "$WORK/TRS.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  TRS_ENGINE_DIR="${ENGINE:-$WORK/no-engine}" \
  ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES="$alt_icons" \
  archive

APP="$(find "$WORK/TRS.xcarchive/Products/Applications" -maxdepth 1 -name '*.app' -type d | head -n 1)"
[ -n "$APP" ] || die "keine .app im Archiv"
for name in $alt_icons; do
  /usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundleAlternateIcons:$name" "$APP/Info.plist" > /dev/null \
    || echo "::warning::Alternatives App-Symbol $name fehlt in der Info.plist."
done

# --- Unsignierte IPA (Pseudosignatur mit Entitlements) ---
if [ -n "$ENGINE" ]; then
  # Gleicher Weg wie im Original-Release: Engine (noch einmal) einlegen, Info.plist-Schlüssel, ldid.
  bash "$ROOT/scripts/ios/package-ipa.sh" "$APP" "$ENGINE" "$OUT/TRS-Launcher-unsigned.ipa"
else
  mkdir -p "$WORK/u/Payload"
  cp -R "$APP" "$WORK/u/Payload/"
  app="$(find "$WORK/u/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
  while IFS= read -r -d '' file; do
    [ "$file" = "$app/$exe" ] && continue
    if file "$file" | grep -q 'Mach-O'; then ldid -S "$file"; fi
  done < <(find "$app" -type f -print0)
  ldid -S"$ENTITLEMENTS" "$app/$exe"
  rm -f "$OUT/TRS-Launcher-unsigned.ipa"
  (cd "$WORK/u" && zip -qry "$OUT/TRS-Launcher-unsigned.ipa" Payload)
  echo "IPA: $OUT/TRS-Launcher-unsigned.ipa (ohne Spiel-Engine)"
fi

# --- Signierte IPA (eigenes Zertifikat + Profil) ---
if [ -n "${IOS_P12_PATH:-}" ] && [ -n "${IOS_PROFILE_PATH:-}" ]; then
  P12_PASSWORD="${IOS_P12_PASSWORD:-}" BUNDLE_ID="${IOS_BUNDLE_ID:-}" \
    bash "$ROOT/scripts/ios/sign-ipa.sh" "$OUT/TRS-Launcher-unsigned.ipa" "$IOS_P12_PATH" "$IOS_PROFILE_PATH" "$OUT/TRS-Launcher.ipa"
else
  echo "Keine Signier-Daten (IOS_P12_PATH/IOS_PROFILE_PATH) – nur die unsignierte IPA gebaut."
fi
ls -la "$OUT"
