#!/usr/bin/env bash
# Xcode-Build-Phase „Embed Game Engine“: legt die iOS-Spiel-Engine (Amethyst-iOS-Teile + TRS-Anbindung)
# in die App und signiert ihre Bibliotheken mit derselben Identität wie die App.
#
# Engine-Ordner = Ergebnis von scripts/ios/build-engine.sh bzw. CI-Artefakt „engine-ios“
# (Frameworks/, libs/, libs_caciocavallo*/, resources/, LICENSES/, engine.json).
# Pfad: TRS_ENGINE_DIR (Signing.xcconfig, Standard: src-tauri/gen/apple/Engine).
# Fehlt der Ordner, baut Xcode die App ohne Engine: der Launcher läuft, nur der Spielstart meldet „Engine fehlt“.
set -euo pipefail

ENGINE="${TRS_ENGINE_DIR:-$PROJECT_DIR/Engine}"
APP="${TARGET_BUILD_DIR:?nur aus Xcode aufrufen}/${WRAPPER_NAME:?}"

if [ ! -f "$ENGINE/engine.json" ]; then
  echo "warning: Spiel-Engine nicht gefunden ($ENGINE) – App ohne Minecraft-Start. Siehe IOS.md (Engine bauen oder Artefakt engine-ios laden)."
  exit 0
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
