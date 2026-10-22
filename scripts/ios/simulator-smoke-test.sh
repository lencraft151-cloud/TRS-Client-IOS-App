#!/usr/bin/env bash
# Starttest der iOS-App im Simulator: bauen (debug, arm64-Simulator), installieren, starten, 45 s beobachten.
# Schlägt fehl, wenn die App nicht mehr läuft oder die Oberfläche nicht lädt. Absturzbericht, Konsole, System-Log und
# Screenshots landen in <ausgabe-ordner> (im CI als Artefakt „ios-simulator-smoke-test“).
#
#   scripts/ios/simulator-smoke-test.sh <ausgabe-ordner>
#
# Die Spiel-Engine läuft im Simulator nicht (JIT, Metal-Treiber) – getestet wird der Launcher bis zur Oberfläche.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/src-tauri/gen/apple"
OUT="${1:?Aufruf: simulator-smoke-test.sh <ausgabe-ordner>}"
WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-45}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
DD="$OUT/derived-data"

die() { printf 'Starttest fehlgeschlagen: %s\n' "$*" >&2; exit 1; }

xcodebuild -project "$APPLE/trs-launcher.xcodeproj" -scheme trs-launcher_iOS -configuration debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO TRS_ENGINE_DIR="$OUT/no-engine" build \
  > "$OUT/xcodebuild.log" 2>&1 || { tail -n 80 "$OUT/xcodebuild.log"; die "Simulator-Build"; }
APP="$(find "$DD/Build/Products" -maxdepth 2 -name '*.app' -type d | head -n 1)"
[ -n "$APP" ] || die "keine .app gebaut"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
echo "App: $APP ($BUNDLE)"

# Neuestes iPhone auf der neuesten Simulator-Laufzeit.
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
def key(rt):
    v = rt.rsplit(".", 1)[-1].split("-")[1:]
    return [int(x) for x in v if x.isdigit()]
for runtime in sorted((r for r in data if "iOS" in r), key=key, reverse=True):
    phones = [d for d in data[runtime] if d.get("isAvailable") and d["name"].startswith("iPhone")]
    if phones:
        print(phones[-1]["udid"]); break
')"
[ -n "$UDID" ] || die "kein iPhone-Simulator verfügbar"
xcrun simctl list devices | grep "$UDID" || true
xcrun simctl boot "$UDID" 2> /dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl install "$UDID" "$APP"

reports="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$reports"
marker="$OUT/.start"
touch "$marker"

xcrun simctl spawn "$UDID" log stream --level debug --style compact --predicate "process == \"$EXE\"" \
  > "$OUT/system-log.txt" 2>&1 &
log_pid=$!
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE" > "$OUT/console.txt" 2>&1 &
console_pid=$!

# Läuft die App? `simctl launch` schreibt „<bundle-id>: <pid>“ in die Konsole, sobald der Prozess steht; Simulator-Apps
# sind normale Prozesse auf dem Mac, also reicht danach kill -0. (Der Start dauert ein paar Sekunden – vorher prüfen
# hieße „beendet“.)
pid=""
for _ in $(seq 1 60); do
  pid="$(sed -nE "s/^$BUNDLE: ([0-9]+).*/\1/p" "$OUT/console.txt" 2> /dev/null | head -n 1)"
  [ -n "$pid" ] && break
  kill -0 "$console_pid" 2> /dev/null || break
  sleep 1
done
echo "App-Prozess: ${pid:-nicht gestartet}"

alive=0
seconds=0
if [ -n "$pid" ]; then
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    sleep 1
    seconds=$((seconds + 1))
    if kill -0 "$pid" 2> /dev/null; then alive=1; else alive=0; break; fi
    if [ "$seconds" = 10 ]; then
      xcrun simctl io "$UDID" screenshot "$OUT/screenshot-10s.png" > /dev/null 2>&1 || true
    fi
  done
fi
echo "App lief ${seconds}s (läuft am Ende: $([ "$alive" = 1 ] && echo ja || echo nein))"
xcrun simctl io "$UDID" screenshot "$OUT/screenshot.png" > /dev/null 2>&1 || true
# Absturzberichte schreibt ReportCrash mit etwas Verzögerung.
[ "$alive" = 1 ] || sleep 15
kill "$log_pid" "$console_pid" 2> /dev/null || true
xcrun simctl spawn "$UDID" log show --last 5m --style compact \
  --predicate "process == \"$EXE\" OR eventMessage CONTAINS[c] \"trslauncher\"" > "$OUT/log-show.txt" 2>&1 || true

# Absturzberichte dieses Laufs (macOS legt Simulator-Abstürze beim Host ab).
found=0
while IFS= read -r -d '' report; do
  cp "$report" "$OUT/"
  found=1
  echo "===== Absturzbericht: $(basename "$report")"
  head -n 150 "$report"
done < <(find "$reports" -newer "$marker" \( -name "*${EXE}*" -o -name "*trs*" -o -name "*TRS*" \) -type f -print0 2> /dev/null)

echo "===== Konsole (letzte 80 Zeilen)"
tail -n 80 "$OUT/console.txt" || true
echo "===== System-Log der App (letzte 80 Zeilen)"
tail -n 80 "$OUT/log-show.txt" || true

xcrun simctl terminate "$UDID" "$BUNDLE" 2> /dev/null || true
rm -rf "$DD"
if [ "$alive" != 1 ]; then
  [ "$found" = 1 ] || echo "(kein Absturzbericht gefunden – siehe Konsole/System-Log)"
  die "die App läuft nach ${seconds}s nicht mehr"
fi
# Oberfläche geladen? WebKit meldet das Ende des Hauptdokuments im Log der App.
grep -q 'didFinishLoadForFrame: .*isMainFrame=1' "$OUT/system-log.txt" \
  || die "die App läuft, aber die Oberfläche wurde nicht geladen (schwarzer Bildschirm) – siehe system-log.txt"
echo "Starttest bestanden: App läuft nach ${WAIT_SECONDS}s mit geladener Oberfläche, Screenshot: $OUT/screenshot.png"
