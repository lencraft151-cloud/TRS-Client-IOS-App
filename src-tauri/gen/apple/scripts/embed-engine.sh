#!/usr/bin/env bash
# Xcode-Build-Phase „Embed Game Engine“: legt die iOS-Spiel-Engine (Amethyst-iOS-Teile + TRS-Anbindung)
# in die App und signiert ihre Bibliotheken mit derselben Identität wie die App.
#
# Engine-Ordner = Ergebnis von scripts/ios/build-engine.sh bzw. CI-Artefakt „engine-ios“
# (Frameworks/, libs/, libs_caciocavallo*/, resources/, LICENSES/, engine.json).
# Pfad: TRS_ENGINE_DIR (Signing.xcconfig, Standard: src-tauri/gen/apple/Engine).
# Fehlt der Ordner, lädt die Phase die fertige Engine aus dem Release TRS_ENGINE_TAG (UpdateChannel.xcconfig,
# Standard ios-engine) von TRS_UPDATE_REPO – vom CI gebaut, mit SHA-256 geprüft. Neu laden: Ordner löschen.
# Klappt das nicht (offline, Release fehlt), baut Xcode die App ohne Engine: der Launcher läuft, nur der
# Spielstart meldet „Engine fehlt“.
set -euo pipefail

ENGINE="${TRS_ENGINE_DIR:-$PROJECT_DIR/Engine}"
APP="${TARGET_BUILD_DIR:?nur aus Xcode aufrufen}/${WRAPPER_NAME:?}"

download_engine() {
  local repo="${TRS_UPDATE_REPO:-}" tag="${TRS_ENGINE_TAG:-ios-engine}"
  [ -n "$repo" ] || return 1
  local base="https://github.com/$repo/releases/download/$tag" tmp
  tmp="$(mktemp -d)"
  echo "Spiel-Engine laden: $base/engine-ios.zip"
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/engine-ios.zip" "$base/engine-ios.zip" \
    || ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/engine-ios.zip.sha256" "$base/engine-ios.zip.sha256"; then
    rm -rf "$tmp"
    return 1
  fi
  local expected actual
  expected="$(tr -d '[:space:]' < "$tmp/engine-ios.zip.sha256")"
  actual="$(shasum -a 256 "$tmp/engine-ios.zip" | cut -d' ' -f1)"
  if [ "$expected" != "$actual" ]; then
    echo "warning: Spiel-Engine: Prüfsumme stimmt nicht – nicht verwendet."
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$tmp/engine"
  unzip -q "$tmp/engine-ios.zip" -d "$tmp/engine"
  if [ ! -f "$tmp/engine/engine.json" ]; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$ENGINE"
  mkdir -p "$(dirname "$ENGINE")"
  mv "$tmp/engine" "$ENGINE"
  rm -rf "$tmp"
}

if [ ! -f "$ENGINE/engine.json" ]; then
  # Nicht im CI: dort kommt die Engine aus dem eigenen Job (oder der Build ist bewusst ohne).
  if [ -n "${CI:-}" ] || [ "${TRS_ENGINE_DOWNLOAD:-YES}" = NO ] || ! download_engine; then
    echo "warning: Spiel-Engine nicht gefunden ($ENGINE) – App ohne Minecraft-Start. Siehe IOS.md (Spiel-Engine)."
    exit 0
  fi
fi

echo "Engine aus $ENGINE einbetten"
mkdir -p "$APP/Frameworks"
cp -R "$ENGINE/Frameworks/." "$APP/Frameworks/"
for dir in libs libs_caciocavallo libs_caciocavallo17; do
  rm -rf "${APP:?}/$dir"
  cp -R "$ENGINE/$dir" "$APP/$dir"
done
cp "$ENGINE"/resources/* "$APP/"
mkdir -p "$APP/licenses/engine"
cp -R "$ENGINE/LICENSES/." "$APP/licenses/engine/"

# Signieren: Xcode signiert danach nur die App selbst, eingebettete dylibs/Frameworks müssen vorher signiert sein.
if [ "${CODE_SIGNING_ALLOWED:-NO}" != YES ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  echo "Ohne Signatur gebaut – Engine-Bibliotheken bleiben unsigniert (werden beim Signieren der IPA signiert)."
  exit 0
fi
sign() { codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none --preserve-metadata=identifier "$1"; }
for item in "$APP"/Frameworks/*; do
  case "$item" in
    *.framework) sign "$item" ;;
    *) if file "$item" | grep -q 'Mach-O'; then sign "$item"; fi ;;
  esac
done
# Mach-O-Dateien außerhalb von Frameworks/ (sollte es nicht geben, aber sicher ist sicher).
while IFS= read -r -d '' file; do
  if file "$file" | grep -q 'Mach-O'; then sign "$file"; fi
done < <(find "$APP/libs" "$APP/libs_caciocavallo" "$APP/libs_caciocavallo17" -type f -print0)
