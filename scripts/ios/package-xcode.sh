#!/usr/bin/env bash
# TRS Launcher – „Xcode-Paket“: das iOS-Projekt als eigenständiger Ordner mit fertig gebautem App-Kern
# (Rust + Oberfläche als libapp.a) und Spiel-Engine. Herunterladen, entpacken, TRS-Launcher.xcworkspace öffnen,
# Team wählen, ▶ – kein Rust, Node oder Terminal nötig.
#
#   scripts/ios/package-xcode.sh <ausgabe.zip> [engine-ordner]
#
# Vorher muss der Kern gebaut sein: src-tauri/gen/apple/Externals/arm64/release/libapp.a
# (entsteht bei scripts/ios/build-ipa.sh oder einem release-Build in Xcode).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:?Aufruf: package-xcode.sh <ausgabe.zip> [engine-ordner]}"
ENGINE="${2:-}"
APPLE="$ROOT/src-tauri/gen/apple"
LIB="$APPLE/Externals/arm64/release/libapp.a"
NAME=TRS-Launcher-Xcode

die() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
[ -f "$LIB" ] || die "App-Kern fehlt ($LIB) – erst scripts/ios/build-ipa.sh ausführen"
if [ -n "$ENGINE" ]; then [ -f "$ENGINE/engine.json" ] || die "$ENGINE ist kein Engine-Ordner"; fi
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/$NAME"
mkdir -p "$PKG"

# Eingecheckte Projektdateien (keine Build-Reste), Pfade relativ zu src-tauri/gen/apple.
(cd "$APPLE" && git ls-files -z . | tar --null -T - -cf - | tar -xf - -C "$PKG")
rm -f "$PKG/.gitignore"

# Fertiger App-Kern: release für beide Konfigurationen (debug zeigt auf dieselbe Datei).
mkdir -p "$PKG/Externals/arm64/release"
cp "$LIB" "$PKG/Externals/arm64/release/libapp.a"
ln -s release "$PKG/Externals/arm64/debug"

if [ -n "$ENGINE" ]; then
  mkdir -p "$PKG/Engine"
  cp -R "$ENGINE/." "$PKG/Engine/"
fi

cp "$ROOT/LICENSE" "$PKG/LICENSE.txt"
cp "$ROOT/NOTICE" "$PKG/NOTICE.txt"
commit="$(git -C "$ROOT" rev-parse HEAD)"
remote="$(git -C "$ROOT" config --get remote.origin.url 2> /dev/null | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##' || true)"
version="$(node -e 'process.stdout.write(require(process.argv[1]).version)' "$ROOT/src-tauri/tauri.conf.json")"
engine_note="Die Spiel-Engine liegt in Engine/ – Minecraft lässt sich starten."
[ -n "$ENGINE" ] || engine_note="Dieses Paket enthält KEINE Spiel-Engine: Der Launcher läuft, der Minecraft-Start meldet \"Engine fehlt\"."

cat > "$PKG/LIESMICH.md" << EOF
# TRS Launcher $version – Xcode-Paket

1. **TRS-Launcher.xcworkspace** doppelklicken (Xcode 16 oder neuer).
2. Links das Projekt **trs-launcher** → Target **trs-launcher_iOS** → **Signing & Capabilities**:
   bei **Team** dein Apple-Konto wählen (Xcode → Settings → Accounts, falls noch keins angemeldet ist).
   Meldet Xcode, die Bundle-ID sei vergeben: unter *Bundle Identifier* eine eigene eintragen,
   z. B. \`de.deinname.trslauncher\`.
3. iPhone/iPad per Kabel anschließen und oben als Ziel wählen (kein Simulator), dann **▶ Run**.
   Auf dem Gerät: Einstellungen → Allgemein → VPN und Geräteverwaltung → Entwickler vertrauen;
   ab iOS 16 zusätzlich Datenschutz & Sicherheit → Entwicklermodus einschalten.

**Eigenes Zertifikat + Profil statt Automatik:** .p12 per Doppelklick in den Schlüsselbund, .mobileprovision
per Doppelklick installieren, dann in *Signing & Capabilities* "Automatically manage signing" ausschalten und das
Profil wählen – oder alles in \`Signing.xcconfig\` eintragen.
**IPA zum Verteilen:** Product → Archive → Distribute App (Development, Ad Hoc oder Enterprise).

**Kostenloses Apple-Konto (Personal Team):** Meldet Xcode, *Increased Memory Limit* werde nicht unterstützt,
in \`Signing.xcconfig\` die Zeile mit \`trs-launcher_iOS-basic.entitlements\` aktivieren
(die andere \`TRS_ENTITLEMENTS\`-Zeile mit \`//\` auskommentieren).

$engine_note
**JIT (Just-in-Time) für Minecraft Java ist eingebaut:** Mit **▶ Run** aus Xcode gestartet, ist JIT automatisch an –
auch auf iOS 26 (der Helfer in \`lldb/\` beantwortet die JIT-Anfragen der Engine im Debugger). Xcode bleibt dabei
verbunden (Kabel oder WLAN). Ohne Mac: In der App beim Spielstart auf "JIT mit StikDebug aktivieren" tippen
(StikDebug muss eingerichtet sein) – oder SideStore/AltServer nutzen.

**Ohne Kabel spielen:** iPhone einmal per Kabel anschließen, Xcode → Window → Devices and Simulators → dein iPhone →
"Connect via network" anhaken, Kabel abziehen, ▶ Run. Mac und iPhone im selben WLAN, Mac wach halten
(\`caffeinate -d\`), während Minecraft läuft nicht auf Stop drücken.

Der App-Kern (Externals/arm64/…/libapp.a) ist vorgebaut, daher nur echte Geräte (arm64).
Quellcode: ${remote:-dieses Repository} (Commit $commit), Original: https://github.com/theredstonee/TRS-Launcher
– GPL-3.0, siehe LICENSE.txt und NOTICE.txt.
EOF

rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" "$NAME")
echo "Xcode-Paket: $OUT ($(du -h "$OUT" | cut -f1))"
