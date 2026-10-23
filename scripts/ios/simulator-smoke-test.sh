#!/usr/bin/env bash
# Starttest der iOS-App im Simulator: bauen (debug, arm64-Simulator), installieren, starten, mindestens 45 s beobachten.
# Dabei läuft der Klick-Test (TRS_UI_TOUR=1, app/utils/uiTour.ts): Die App geht selbst durch die Einrichtung und die
# Hauptseiten und meldet jeden Schritt im Log – dazu entsteht je ein Screenshot tour-<nr>-<schritt>.png.
# Schlägt fehl, wenn die App nicht mehr läuft, die Oberfläche nicht lädt, eine Seite leer bleibt oder der Klick-Test
# nicht fertig wird. Absturzbericht, Konsole, System-Log und Screenshots landen in <ausgabe-ordner> (im CI als Artefakt
# „ios-simulator-smoke-test“ und Release „ios-diagnostics“).
#
#   scripts/ios/simulator-smoke-test.sh <ausgabe-ordner>
#
# Die Spiel-Engine läuft im Simulator nicht (JIT, Metal-Treiber) – getestet wird der Launcher bis zur Oberfläche.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/src-tauri/gen/apple"
OUT="${1:?Aufruf: simulator-smoke-test.sh <ausgabe-ordner>}"
WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-45}"
TOUR_SECONDS="${SMOKE_TOUR_SECONDS:-180}"
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
[ -d "$APP/PlugIns/TRSWidgets.appex" ] || die "Widget-Erweiterung fehlt (PlugIns/TRSWidgets.appex)"
# Kurzbefehle/Siri: Xcode legt die App-Intents-Metadaten in die App, wenn es Shortcuts.swift erkannt hat.
if [ -d "$APP/Metadata.appintents" ]; then
  echo "App Intents: $(find "$APP/Metadata.appintents" -type f | wc -l | tr -d ' ') Datei(en)"
else
  echo "::warning::Keine App-Intents-Metadaten in der App – Kurzbefehle und Siri fehlen."
fi

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
# Starten: `simctl launch` kehrt zurück, sobald der Prozess steht, und meldet „<bundle-id>: <pid>“. Simulator-Apps sind
# normale Prozesse auf dem Mac – danach reicht kill -0. (Mit --console-pty im Hintergrund kam die PID-Zeile erst beim
# Beenden aus dem Puffer.) stdout/stderr der App landen in Dateien.
# SIMCTL_CHILD_… gibt simctl als Umgebungsvariable an die App weiter (Klick-Test an).
launched="$(SIMCTL_CHILD_TRS_UI_TOUR=1 xcrun simctl launch --terminate-running-process --stdout="$OUT/stdout.txt" \
  --stderr="$OUT/stderr.txt" "$UDID" "$BUNDLE" 2>&1)" || { echo "$launched"; die "simctl launch"; }
pid=""
if [[ "$launched" =~ :\ ([0-9]+) ]]; then pid="${BASH_REMATCH[1]}"; fi
echo "App-Prozess: ${pid:-nicht gestartet} ($launched)"

alive=0
ticks=0
seconds=0
seen=0
shots=0
tour_done=0
tour_failed=()
if [ -n "$pid" ]; then
  while :; do
    sleep 0.5
    ticks=$((ticks + 1))
    seconds=$((ticks / 2))
    if kill -0 "$pid" 2> /dev/null; then alive=1; else alive=0; break; fi
    if [ "$ticks" = 20 ]; then
      xcrun simctl io "$UDID" screenshot "$OUT/screenshot-10s.png" > /dev/null 2>&1 || true
    fi
    # Neue Schritte des Klick-Tests: Screenshot, solange der Schritt zu sehen ist (die App wartet je 2 s).
    steps="$(grep -oE 'ui-tour: [a-z0-9-]+ (ok|FEHLER)' "$OUT/system-log.txt" 2> /dev/null || true)"
    count="$(printf '%s\n' "$steps" | grep -c . || true)"
    while [ "$seen" -lt "$count" ]; do
      seen=$((seen + 1))
      line="$(printf '%s\n' "$steps" | sed -n "${seen}p")"
      name="$(printf '%s' "$line" | awk '{print $2}')"
      result="$(printf '%s' "$line" | awk '{print $3}')"
      shots=$((shots + 1))
      xcrun simctl io "$UDID" screenshot "$OUT/tour-$(printf '%02d' "$shots")-$name.png" > /dev/null 2>&1 || true
      echo "Klick-Test: $name $result"
      if [ "$result" = FEHLER ]; then tour_failed+=("$name"); fi
      if [ "$name" = fertig ]; then tour_done=1; fi
    done
    if [ "$seconds" -ge "$WAIT_SECONDS" ] && { [ "$tour_done" = 1 ] || [ "$seconds" -ge "$TOUR_SECONDS" ]; }; then break; fi
  done
fi
echo "App lief ${seconds}s (läuft am Ende: $([ "$alive" = 1 ] && echo ja || echo nein))"
xcrun simctl io "$UDID" screenshot "$OUT/screenshot.png" > /dev/null 2>&1 || true
# Absturzberichte schreibt ReportCrash mit etwas Verzögerung.
[ "$alive" = 1 ] || sleep 15
kill "$log_pid" 2> /dev/null || true
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

echo "===== Konsole: stderr (letzte 80 Zeilen)"
tail -n 80 "$OUT/stderr.txt" || true
echo "===== Konsole: stdout (letzte 40 Zeilen)"
tail -n 40 "$OUT/stdout.txt" || true
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
[ "$tour_done" = 1 ] || die "Klick-Test nicht fertig geworden (${shots} Schritte in ${seconds}s) – siehe tour-*.png und system-log.txt"
[ "${#tour_failed[@]}" = 0 ] || die "Klick-Test: ohne Inhalt: ${tour_failed[*]} – siehe tour-*.png"
echo "Starttest bestanden: App läuft ${seconds}s mit geladener Oberfläche, Klick-Test mit ${shots} Schritten, Screenshots in $OUT"
