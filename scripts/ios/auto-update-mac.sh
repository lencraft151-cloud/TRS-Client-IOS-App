#!/usr/bin/env bash
# TRS Launcher – der Mac hält die App auf dem iPhone aktuell, auch mit kostenlosem Apple-Konto.
#
#   bash scripts/ios/auto-update-mac.sh --install [--device <Name oder UDID>]  # einrichten, läuft dann stündlich
#   bash scripts/ios/auto-update-mac.sh --now                                 # sofort prüfen, bauen, installieren
#   bash scripts/ios/auto-update-mac.sh --status                              # Gerät, letzter Lauf, Log
#   bash scripts/ios/auto-update-mac.sh --uninstall                           # wieder abschalten
#
# Stündlich und nach dem Aufwachen: `git pull`. Gibt es eine neue Version – oder läuft die Signatur der App auf dem
# iPhone bald ab (kostenloses Konto: nach 7 Tagen) –, baut xcodebuild die App wie ▶ Run mit deinem Xcode-Konto und
# installiert sie per WLAN oder Kabel auf dem iPhone (`xcrun devicectl`). Eine Mitteilung auf dem Mac sagt Bescheid.
#
# Vorher einmal: `bash scripts/ios/mac-setup.sh`, in Xcode ▶ Run auf dem iPhone, und in Xcode → Window → Devices and
# Simulators beim iPhone „Connect via network“ anhaken. Mac und iPhone im selben WLAN, iPhone entsperrt reicht.
# Für Minecraft braucht es weiter JIT: ▶ Run in Xcode oder StikDebug (IOS.md).
set -euo pipefail

LABEL=de.trs-launcher.ios-auto-update
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ios/auto-update-mac.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/TRS-Launcher-AutoUpdate"
DEVICE_FILE="$SUPPORT/device"
STATE="$SUPPORT/state"
LOCK="$SUPPORT/lock"
DERIVED="$SUPPORT/DerivedData"
LOG="$HOME/Library/Logs/TRS-Launcher-AutoUpdate.log"
WORKSPACE="$ROOT/src-tauri/gen/apple/TRS-Launcher.xcworkspace"
SCHEME=trs-launcher_iOS
CONFIG=debug
# Nach einem fehlgeschlagenen Build erst so spät wieder bauen (außer die Signatur läuft ab).
RETRY_AFTER=$((3 * 3600))
# So lange vor dem Ablauf der Signatur neu bauen (Xcode stellt dann ein neues Profil aus).
RENEW_BEFORE=$((12 * 3600))
# Ist die App auf dem iPhone offen, so lange mit dem Installieren warten (danach trotzdem).
POSTPONE_MAX=$((6 * 3600))

die() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*"; }
notify() {
  osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\"" 2> /dev/null || true
}
state_get() { sed -n "s/^$1=//p" "$STATE" 2> /dev/null | tail -n 1; }
state_set() {
  mkdir -p "$SUPPORT"
  { grep -v "^$1=" "$STATE" 2> /dev/null || true; echo "$1=$2"; } > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

[ "$(uname -s)" = Darwin ] || die "nur auf dem Mac"
mode="${1:-}"
shift || true

# Gepaartes iPhone/iPad: erste passende Zeile „UDID<TAB>Name“.
find_device() {
  local want="${1:-}" json
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" > /dev/null 2>&1 || { rm -f "$json"; return 1; }
  /usr/bin/python3 -I - "$json" "$want" << 'PY' || true
import json, sys
devices = json.load(open(sys.argv[1])).get('result', {}).get('devices', [])
want = sys.argv[2]
for d in devices:
    hw, cp, dp = d.get('hardwareProperties', {}), d.get('connectionProperties', {}), d.get('deviceProperties', {})
    udid = hw.get('udid') or d.get('identifier', '')
    if hw.get('platform') != 'iOS' or hw.get('reality', 'physical') != 'physical':
        continue
    if want and want not in (udid, d.get('identifier'), dp.get('name')):
        continue
    if cp.get('pairingState') != 'paired':
        continue
    print(f"{udid}\t{dp.get('name', '')}")
    break
PY
  rm -f "$json"
}

# Läuft die App gerade auf dem iPhone (offen oder im Hintergrund)? Unbekannt zählt als nein.
app_running() {
  local udid="$1" exe="$2" json result=1
  json="$(mktemp)"
  if xcrun devicectl device info processes --device "$udid" --json-output "$json" > /dev/null 2>&1; then
    /usr/bin/python3 -I - "$json" "$exe" << 'PY' && result=0
import json, sys
procs = json.load(open(sys.argv[1])).get('result', {}).get('runningProcesses', [])
exe = '/' + sys.argv[2]
sys.exit(0 if any((p.get('executable') or '').rstrip('/').endswith(exe) for p in procs) else 1)
PY
  fi
  rm -f "$json"
  return "$result"
}

built_app() {
  find "$DERIVED/Build/Products/$CONFIG-iphoneos" -maxdepth 1 -name '*.app' -type d 2> /dev/null | head -n 1
}

# Ablauf der Signatur (Unix-Zeit) der zuletzt gebauten App; leer, wenn unbekannt.
signature_expiry() {
  local app="$1" plist iso
  [ -f "$app/embedded.mobileprovision" ] || return 0
  plist="$(mktemp)"
  if security cms -D -i "$app/embedded.mobileprovision" > "$plist" 2> /dev/null; then
    iso="$(plutil -extract ExpirationDate raw -o - "$plist" 2> /dev/null || true)"
    [ -z "$iso" ] || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2> /dev/null || true
  fi
  rm -f "$plist"
}

update() {
  local force="$1" udid head upstream reason="" app expiry new_expiry now failed version exe since
  mkdir -p "$SUPPORT"
  if ! mkdir "$LOCK" 2> /dev/null; then
    # Hängengebliebene Sperre (älter als 3 Stunden) aufräumen.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +180 2> /dev/null)" ]; then rmdir "$LOCK" && mkdir "$LOCK"; else log "läuft schon"; return 0; fi
  fi
  trap 'rmdir "$LOCK" 2> /dev/null || true' EXIT
  udid="$(cut -f1 "$DEVICE_FILE" 2> /dev/null || true)"
  [ -n "$udid" ] || die "kein iPhone eingerichtet – erst: bash scripts/ios/auto-update-mac.sh --install"
  cd "$ROOT"

  # --- neue Version holen ---
  if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2> /dev/null)"; then
    if git fetch --quiet 2> /dev/null; then
      if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
        log "neue Version auf $upstream – git pull"
        git pull --ff-only --quiet || { notify "TRS Launcher" "git pull ging nicht – bitte im Terminal nachsehen."; die "git pull fehlgeschlagen"; }
      fi
    else
      log "offline – baue nur, wenn nötig"
    fi
  fi
  head="$(git rev-parse HEAD)"
  now="$(date +%s)"

  # --- muss gebaut werden? ---
  [ "$force" = yes ] && reason="von Hand gestartet"
  [ -n "$reason" ] || [ "$(state_get installed_commit)" = "$head" ] || reason="neue Version ${head:0:7}"
  app="$(built_app)"
  expiry=""
  [ -z "$app" ] || expiry="$(signature_expiry "$app")"
  if [ -z "$reason" ] && [ -n "$expiry" ] && [ $((expiry - now)) -lt "$RENEW_BEFORE" ]; then
    reason="Signatur läuft ab"
  fi
  if [ -z "$reason" ]; then
    log "aktuell (${head:0:7})"
    return 0
  fi
  failed="$(state_get build_failed)"
  if [ "$force" != yes ] && [ "$reason" != "Signatur läuft ab" ] && [ -n "$failed" ] && [ $((now - failed)) -lt "$RETRY_AFTER" ] \
    && [ "$(state_get failed_commit)" = "$head" ]; then
    log "Build schlug vor Kurzem fehl – nächster Versuch später"
    return 0
  fi

  # --- bauen (wie ▶ Run; das iPhone muss dafür nicht erreichbar sein) ---
  log "$reason – baue die App"
  if ! xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIG" -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build; then
    state_set build_failed "$now"
    state_set failed_commit "$head"
    notify "TRS Launcher" "Die App ließ sich nicht bauen – Details: $LOG"
    die "Build fehlgeschlagen"
  fi
  state_set build_failed ""
  app="$(built_app)"
  [ -n "$app" ] || die "gebaute App nicht gefunden"
  new_expiry="$(signature_expiry "$app")"
  if [ "$reason" = "Signatur läuft ab" ] && [ -n "$new_expiry" ] && [ "$new_expiry" = "$(state_get installed_expiry)" ]; then
    log "Xcode hat die Signatur noch nicht erneuert – nächster Versuch in einer Stunde"
    return 0
  fi

  # --- installieren (nicht mitten im Spiel: eine Installation beendet die laufende App) ---
  exe="$(plutil -extract CFBundleExecutable raw -o - "$app/Info.plist" 2> /dev/null || true)"
  if [ -n "$exe" ] && [ "$force" != yes ] && app_running "$udid" "$exe"; then
    since="$(state_get postponed_since)"
    [ -n "$since" ] || { since="$now"; state_set postponed_since "$now"; }
    if [ $((now - since)) -lt "$POSTPONE_MAX" ]; then
      log "TRS Launcher ist auf dem iPhone offen – Installation beim nächsten Lauf"
      return 0
    fi
  fi
  log "installiere auf dem iPhone"
  if ! xcrun devicectl device install app --device "$udid" "$app"; then
    # Meist: iPhone nicht im WLAN/gesperrt – beim nächsten Lauf (stündlich) erneut, der Build ist dann schnell.
    notify "TRS Launcher" "iPhone nicht erreichbar – neuer Versuch in einer Stunde (gleiches WLAN, entsperrt?)."
    die "Installation fehlgeschlagen"
  fi
  state_set installed_commit "$head"
  state_set installed_at "$now"
  state_set installed_expiry "$new_expiry"
  state_set postponed_since ""
  version="$(sed -nE 's/^ *"version": *"([^"]+)".*/\1/p' "$ROOT/src-tauri/tauri.conf.json" | head -n 1)"
  log "fertig: TRS Launcher $version (${head:0:7}) ist auf dem iPhone"
  notify "TRS Launcher aktualisiert" "Version $version ist auf dem iPhone."
}

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"; }

case "$mode" in
  --install)
    want=""
    if [ "${1:-}" = --device ]; then want="${2:?Name oder UDID fehlt}"; fi
    command -v xcodebuild > /dev/null || die "Xcode fehlt"
    device="$(find_device "$want")"
    [ -n "$device" ] || die "kein gepaartes iPhone gefunden – einmal per Kabel verbinden und in Xcode ▶ Run, dann erneut${want:+ (gesucht: $want)}"
    mkdir -p "$SUPPORT" "$(dirname "$PLIST")" "$(dirname "$LOG")"
    printf '%s\n' "$device" > "$DEVICE_FILE"
    case "$ROOT" in
      "$HOME/Documents"/* | "$HOME/Desktop"/* | "$HOME/Downloads"/*)
        printf '\nHinweis: Das Repo liegt in %s. macOS lässt Hintergrund-Aufgaben dort nur mit Erlaubnis zu:\n' "$ROOT"
        printf 'Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff → /bin/bash hinzufügen –\n'
        printf 'oder das Repo z. B. nach ~/Developer verschieben und dieses Skript dort erneut ausführen.\n'
        ;;
    esac
    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$(xml "$SCRIPT")</string><string>--run</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$(xml "$PATH")</string></dict>
  <key>StandardOutPath</key><string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" > /dev/null
    launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    printf '\n== Eingerichtet für %s (%s)\n' "$(cut -f2 <<< "$device")" "$(cut -f1 <<< "$device")"
    printf '   Läuft stündlich und gleich jetzt einmal. Log: %s\n' "$LOG"
    printf '   Stand ansehen: bash scripts/ios/auto-update-mac.sh --status\n'
    ;;
  --run)
    update no
    ;;
  --now)
    update yes 2>&1 | tee -a "$LOG"
    ;;
  --status)
    if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then echo "Automatische Updates: an (stündlich)"; else echo "Automatische Updates: aus"; fi
    [ -f "$DEVICE_FILE" ] && echo "iPhone: $(cut -f2 "$DEVICE_FILE") ($(cut -f1 "$DEVICE_FILE"))"
    at="$(state_get installed_at)"
    [ -z "$at" ] || echo "Zuletzt installiert: $(date -r "$at" '+%Y-%m-%d %H:%M') (Commit $(state_get installed_commit | cut -c1-7))"
    app="$(built_app)"
    if [ -n "$app" ]; then
      expiry="$(signature_expiry "$app")"
      [ -z "$expiry" ] || echo "Signatur gültig bis: $(date -r "$expiry" '+%Y-%m-%d %H:%M')"
    fi
    if [ -f "$LOG" ]; then echo "--- Log (Ende) ---"; tail -n 15 "$LOG"; fi
    ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
    rm -f "$PLIST"
    rm -rf "$DERIVED"
    echo "Automatische Updates aus. (Log bleibt: $LOG)"
    ;;
  *)
    sed -n '2,17p' "$SCRIPT"
    [ -z "$mode" ] || exit 2
    ;;
esac
