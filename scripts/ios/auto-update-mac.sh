#!/usr/bin/env bash
# TRS Launcher – der Mac hält die App auf dem iPhone aktuell, auch mit kostenlosem Apple-Konto.
#
#   bash scripts/ios/auto-update-mac.sh --setup [--device <Name oder UDID>]    # jetzt bauen + installieren, dann stündlich
#   bash scripts/ios/auto-update-mac.sh --install [--device <Name oder UDID>]  # nur einrichten, läuft dann stündlich
#   bash scripts/ios/auto-update-mac.sh --now                                 # sofort prüfen, bauen, installieren
#   bash scripts/ios/auto-update-mac.sh --status                              # Gerät, letzter Lauf, Log
#   bash scripts/ios/auto-update-mac.sh --uninstall                           # wieder abschalten
#
# Stündlich und nach dem Aufwachen: `git pull`. Gibt es eine neue Version – oder läuft die Signatur der App auf dem
# iPhone bald ab (kostenloses Konto: nach 7 Tagen) –, baut xcodebuild die App wie ▶ Run mit deinem Xcode-Konto und
# installiert sie per WLAN oder Kabel auf dem iPhone (`xcrun devicectl`). Eine Mitteilung auf dem Mac sagt Bescheid.
# Kostenloses Konto: Lehnt Xcode Capabilities ab, die ein Personal Team nicht hat, oder ist die Bundle-ID vergeben,
# stellt das Skript Signing.local.xcconfig selbst um und baut erneut.
#
# Am einfachsten per Doppelklick auf „iPhone-Updates einrichten.command“ im Repo (führt durch alles Nötige). Von Hand:
# `bash scripts/ios/mac-setup.sh`, iPhone einmal per Kabel verbinden (vertrauen, Entwicklermodus an), dann --setup.
# Mac und iPhone im selben WLAN, iPhone entsperrt reicht.
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
LOCAL_SIGNING="$ROOT/src-tauri/gen/apple/Signing.local.xcconfig"
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
# Erster Lauf: Statusdatei, Build-Ordner und Signing.local.xcconfig fehlen noch – unter pipefail darf das nicht abbrechen.
state_get() {
  [ -f "$STATE" ] || return 0
  sed -n "s/^$1=//p" "$STATE" | tail -n 1
}
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
  local dir="$DERIVED/Build/Products/$CONFIG-iphoneos"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.app' -type d | head -n 1 || true
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

# Zeile `KEY = Wert` in Signing.local.xcconfig setzen (von git ignoriert, überschreibt Signing.xcconfig).
set_local() {
  touch "$LOCAL_SIGNING"
  { grep -v "^$1 *=" "$LOCAL_SIGNING" || true; echo "$1 = $2"; } > "$LOCAL_SIGNING.tmp"
  mv "$LOCAL_SIGNING.tmp" "$LOCAL_SIGNING"
}
get_local() {
  [ -f "$LOCAL_SIGNING" ] || return 0
  sed -nE "s/^$1 *= *//p" "$LOCAL_SIGNING" | tr -d '[:space:]' | tail -n 1
}

# Kostenloses Apple-Konto: typische Signier-Fehler aus der Build-Ausgabe beheben. Erfolg = erneut bauen lohnt sich.
free_account_fix() {
  local out="$1" team fixed=1
  if grep -qiE 'personal development teams?|do(es)? not support the .*capabilit' "$out" \
    && [ "$(get_local TRS_ENTITLEMENTS)" != trs-launcher_iOS/trs-launcher_iOS-basic.entitlements ]; then
    set_local TRS_ENTITLEMENTS trs-launcher_iOS/trs-launcher_iOS-basic.entitlements
    set_local TRS_WIDGET_ENTITLEMENTS Widgets/TRSWidgets-basic.entitlements
    log "kostenloses Apple-Konto: App ohne Zusatz-Capabilities (basic-Entitlements in Signing.local.xcconfig)"
    fixed=0
  fi
  team="$(get_local DEVELOPMENT_TEAM)"
  if grep -qiE 'failed registering bundle identifier|cannot be registered to your development team' "$out" \
    && [ -z "$(get_local PRODUCT_BUNDLE_IDENTIFIER)" ] && [ -n "$team" ]; then
    set_local PRODUCT_BUNDLE_IDENTIFIER "dev.theredstonee.trslauncher.$(tr '[:upper:]' '[:lower:]' <<< "$team")"
    log "Bundle-ID vergeben – nehme eigene: $(get_local PRODUCT_BUNDLE_IDENTIFIER) (in Signing.local.xcconfig)"
    fixed=0
  fi
  return "$fixed"
}

# Was der Nutzer bei einem Build-Fehler tun kann (leer, wenn unbekannt). Liest $BUILD_OUT.
build_hint() {
  if grep -qiE 'requires a development team|no account for team|no accounts' "$BUILD_OUT" 2> /dev/null; then
    echo "In Xcode → Settings → Accounts mit deiner Apple-ID anmelden."
  elif grep -qiE 'no devices from which to generate|device .*not registered|is not registered' "$BUILD_OUT" 2> /dev/null; then
    echo "iPhone einmal per Kabel anschließen, entsperren und erneut versuchen (oder in Xcode ▶ Run)."
  elif grep -qiE 'maximum number of apps|limit .*app ?ids' "$BUILD_OUT" 2> /dev/null; then
    echo "Kostenloses Konto: höchstens 3 eigene Apps je iPhone – eine andere selbst signierte App löschen."
  fi
}

# Baut wie ▶ Run; Ausgabe auch in $BUILD_OUT. Beim ersten Mal mit dem iPhone als Ziel – dann registriert Xcode es selbst
# im Konto (sonst wäre ▶ Run in Xcode nötig). Danach reicht „irgendein iPhone“, das Gerät muss nicht erreichbar sein.
build_app() {
  local udid="$1" dest=(-destination 'generic/platform=iOS')
  BUILD_OUT="$(mktemp)"
  if [ -z "$(state_get installed_at)" ] && xcrun devicectl device info details --device "$udid" > /dev/null 2>&1; then
    dest=(-destination "id=$udid" -allowProvisioningDeviceRegistration)
  fi
  for _ in 1 2 3; do
    if xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIG" "${dest[@]}" \
      -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build 2>&1 | tee "$BUILD_OUT"; then
      return 0
    fi
    free_account_fix "$BUILD_OUT" && continue
    if [ "${dest[1]}" != generic/platform=iOS ]; then
      log "mit dem iPhone als Ziel ging es nicht – baue allgemein für iOS"
      dest=(-destination 'generic/platform=iOS')
      continue
    fi
    return 1
  done
  return 1
}

update() {
  local force="$1" udid head upstream reason="" app expiry new_expiry now failed version exe since hint waited=""
  mkdir -p "$SUPPORT"
  until mkdir "$LOCK" 2> /dev/null; do
    # Hängengebliebene Sperre (älter als 3 Stunden) aufräumen.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +180 2> /dev/null)" ]; then
      rmdir "$LOCK" 2> /dev/null || true
      continue
    fi
    # Von Hand gestartet (Doppelklick, --now): auf den laufenden Hintergrund-Lauf warten, statt nichts zu tun.
    if [ "$force" != yes ]; then
      log "läuft schon"
      return 0
    fi
    [ -n "$waited" ] || log "eine Aktualisierung läuft gerade im Hintergrund – ich warte darauf"
    waited=yes
    sleep 10
  done
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
  if ! build_app "$udid"; then
    state_set build_failed "$now"
    state_set failed_commit "$head"
    hint="$(build_hint)"
    rm -f "$BUILD_OUT"
    [ -z "$hint" ] || log "$hint"
    notify "TRS Launcher" "Die App ließ sich nicht bauen – ${hint:-Details: $LOG}"
    die "Build fehlgeschlagen"
  fi
  rm -f "$BUILD_OUT"
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

# iPhone wählen und merken (--device <Name oder UDID> in "$@").
pick_device() {
  local want=""
  if [ "${1:-}" = --device ]; then want="${2:?Name oder UDID fehlt}"; fi
  command -v xcodebuild > /dev/null || die "Xcode fehlt"
  device="$(find_device "$want")"
  [ -n "$device" ] || die "kein gepaartes iPhone gefunden – einmal per Kabel verbinden, entsperren, auf Vertrauen tippen, dann erneut${want:+ (gesucht: $want)}"
  mkdir -p "$SUPPORT" "$(dirname "$LOG")"
  printf '%s\n' "$device" > "$DEVICE_FILE"
}

# Hintergrunddienst (launchd, stündlich und nach dem Anmelden) einrichten.
install_agent() {
  mkdir -p "$(dirname "$PLIST")"
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
  printf '\n== Eingerichtet für %s (%s)\n' "$(cut -f2 "$DEVICE_FILE")" "$(cut -f1 "$DEVICE_FILE")"
  printf '   Läuft stündlich und gleich jetzt einmal. Log: %s\n' "$LOG"
  printf '   Stand ansehen: bash scripts/ios/auto-update-mac.sh --status\n'
}

case "$mode" in
  --install)
    pick_device "$@"
    install_agent
    ;;
  --setup)
    # Erstes Mal im Vordergrund: Fragen von Xcode/Schlüsselbund kommen jetzt, nicht unbemerkt im Hintergrund.
    pick_device "$@"
    update yes 2>&1 | tee -a "$LOG"
    install_agent
    ;;
  --find-device)
    device="$(find_device "${1:-}")"
    [ -n "$device" ] || exit 1
    printf '%s\n' "$device"
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
