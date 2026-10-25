#!/bin/bash
# TRS Launcher – im Finder doppelklicken (öffnet das Terminal).
#
# Richtet einmal ein, dass dein Mac die App auf dem iPhone von selbst aktuell hält: Er baut neue Versionen mit Xcode,
# signiert sie mit deiner Apple-ID (kostenloses Konto reicht, die 7-Tage-Signatur erneuert er rechtzeitig) und
# installiert sie per WLAN. Führt durch alles, was dafür fehlt (Xcode, Werkzeuge, Apple-ID, iPhone).
# Ist schon alles eingerichtet, aktualisiert ein Doppelklick sofort.
#
# Dahinter steckt scripts/ios/auto-update-mac.sh (Abschalten: bash scripts/ios/auto-update-mac.sh --uninstall).
# shellcheck disable=SC1111 # „…“ in den Texten sind deutsche Anführungszeichen, keine Shell-Quotes.
cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"
AUTO="$ROOT/scripts/ios/auto-update-mac.sh"
LABEL=de.trs-launcher.ios-auto-update
LOCAL="$ROOT/src-tauri/gen/apple/Signing.local.xcconfig"
WORKSPACE="$ROOT/src-tauri/gen/apple/TRS-Launcher.xcworkspace"
LOG="$HOME/Library/Logs/TRS-Launcher-AutoUpdate.log"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/Library/pnpm:$PATH"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pause() {
  printf '\n%s\n\033[1mDanach hier Enter drücken …\033[0m ' "$*"
  read -r _
}
bye() {
  printf '\n%s\n\n(Du kannst das Fenster jetzt schließen.)\n' "$1"
  exit "${2:-0}"
}

[ "$(uname -s)" = Darwin ] || bye "Das geht nur auf dem Mac." 1

# --- Schon eingerichtet: sofort aktualisieren ---
if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then
  step "Automatische Updates laufen schon – ich aktualisiere jetzt"
  if bash "$AUTO" --now; then
    bash "$AUTO" --status
    bye "Fertig – die App auf dem iPhone ist aktuell."
  fi
  bye "Das hat nicht geklappt – der Grund steht oben (Log: $LOG). Behoben? Einfach erneut doppelklicken." 1
fi

printf '\033[1mTRS Launcher: automatische Updates fürs iPhone einrichten\033[0m\n'
printf 'Ich prüfe der Reihe nach, was fehlt, und sage dir, wenn du etwas tun musst.\n'

# --- 1. Xcode ---
step "1/5 Xcode"
if [[ "$(xcode-select -p 2> /dev/null)" != *.app/* ]]; then
  xcode="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2> /dev/null | head -n 1)"
  [ -n "$xcode" ] || [ ! -d /Applications/Xcode.app ] || xcode=/Applications/Xcode.app
  if [ -z "$xcode" ]; then
    open 'macappstore://apps.apple.com/app/xcode/id497799835'
    bye "Xcode fehlt – der App Store ist offen. Xcode installieren (kostenlos), einmal öffnen, dann hier erneut doppelklicken." 1
  fi
  echo "Xcode als Entwicklerwerkzeug auswählen – der Mac fragt nach deinem Passwort (Eingabe bleibt unsichtbar)."
  sudo xcode-select -s "$xcode/Contents/Developer" || bye "Ging nicht – bitte erneut doppelklicken." 1
fi
if ! xcodebuild -license check > /dev/null 2>&1 || ! xcodebuild -checkFirstLaunchStatus > /dev/null 2>&1; then
  echo "Xcode einmalig fertig einrichten (Lizenz, Komponenten) – der Mac fragt nach deinem Passwort."
  { sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch; } || bye "Ging nicht – Xcode einmal öffnen und den Fragen folgen, dann erneut doppelklicken." 1
fi
if ! xcodebuild -showsdks 2> /dev/null | grep -q iphoneos; then
  echo "iOS-Unterstützung für Xcode laden (einige GB, dauert etwas) …"
  xcodebuild -downloadPlatform iOS \
    || bye "Ging nicht – in Xcode → Settings → Components „iOS“ laden, dann erneut doppelklicken." 1
fi
git rev-parse --git-dir > /dev/null 2>&1 \
  || bye "Dieser Ordner ist kein git-Klon. Bitte das Repo mit git klonen (nicht als ZIP laden), dann hier erneut doppelklicken." 1
echo "Xcode ist bereit."

# --- 2. Werkzeuge für den App-Kern ---
step "2/5 Werkzeuge (Rust, Node.js, pnpm)"
if ! command -v rustup > /dev/null; then
  echo "Rust installieren (rustup.rs) …"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || bye "Rust ließ sich nicht installieren." 1
fi
if ! command -v node > /dev/null; then
  if command -v brew > /dev/null; then
    echo "Node.js installieren (Homebrew) …"
    brew install node || bye "Node.js ließ sich nicht installieren." 1
  else
    open 'https://nodejs.org/'
    bye "Node.js fehlt – auf nodejs.org die LTS-Version laden und installieren, dann hier erneut doppelklicken." 1
  fi
fi
if ! command -v pnpm > /dev/null; then
  echo "pnpm installieren …"
  npm install -g pnpm > /dev/null 2>&1 || corepack enable pnpm 2> /dev/null || sudo npm install -g pnpm \
    || bye "pnpm ließ sich nicht installieren." 1
fi
echo "Werkzeuge sind da."

# --- 3. Apple-ID und Team ---
step "3/5 Apple-ID"
bash "$ROOT/scripts/ios/mac-setup.sh" > /dev/null || bye "Die Grundeinrichtung (scripts/ios/mac-setup.sh) ging nicht – im Terminal: bash scripts/ios/mac-setup.sh" 1
tries=0
until grep -qsE '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' "$LOCAL"; do
  tries=$((tries + 1))
  if [ "$tries" -le 2 ]; then
    open -a Xcode
    pause "Xcode ist offen: oben im Menü Xcode → Settings … → Accounts → unten „+“ → Apple ID → mit deiner Apple-ID anmelden (kostenloses Konto reicht)."
  else
    open "$WORKSPACE"
    pause "Xcode zeigt das Projekt: links oben „trs-launcher“ anklicken → Target „trs-launcher_iOS“ → Signing & Capabilities → bei Team deine Apple-ID wählen. Dann oben dein iPhone als Ziel wählen und ▶ drücken (ein Mal)."
  fi
  bash "$ROOT/scripts/ios/mac-setup.sh" > /dev/null || true
done
echo "Apple-ID ist eingerichtet (Team $(sed -nE 's/^DEVELOPMENT_TEAM *= *//p' "$LOCAL" | head -n 1))."

# --- 4. iPhone ---
step "4/5 iPhone"
until device="$(bash "$AUTO" --find-device 2> /dev/null)" && [ -n "$device" ]; do
  pause "Kein iPhone gefunden. iPhone per Kabel an den Mac, entsperren und bei „Diesem Computer vertrauen?“ auf Vertrauen tippen."
done
echo "Gefunden: $(cut -f2 <<< "$device")."
printf '%s\n' "- Falls noch nicht an: iPhone → Einstellungen → Datenschutz & Sicherheit → Entwicklermodus → an (iPhone startet neu)." \
  "  Der Punkt erscheint erst, wenn das iPhone einmal mit Xcode verbunden war – das passiert gerade."
case "$ROOT" in
  "$HOME/Documents"/* | "$HOME/Desktop"/* | "$HOME/Downloads"/*)
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'
    pause "Das Repo liegt in $(basename "$(dirname "$ROOT")"). Damit der Mac im Hintergrund daran arbeiten darf: in den Systemeinstellungen (gerade offen) unter Festplattenvollzugriff auf „+“, ⇧⌘G drücken, /bin/bash eingeben, hinzufügen und einschalten. (Oder das Repo z. B. nach ~/Developer verschieben und dort doppelklicken.)"
    ;;
esac

# --- 5. Bauen, signieren, installieren, Hintergrunddienst ---
step "5/5 App bauen, signieren und aufs iPhone bringen (beim ersten Mal 10–30 Minuten)"
printf '%s\n' "Fragt der Mac nach dem Schlüsselbund: dein Mac-Passwort eingeben und „Immer erlauben“ – dann klappt es künftig auch im Hintergrund." \
  "iPhone dabei entsperrt und am Kabel oder im selben WLAN lassen."
if ! bash "$AUTO" --setup; then
  bye "Das hat nicht geklappt – der Grund steht oben (Log: $LOG). Behoben? Einfach erneut doppelklicken." 1
fi

step "Fertig!"
cat << 'EOF'
Noch einmal am iPhone (nur beim ersten Mal):
  Einstellungen → Allgemein → VPN & Geräteverwaltung → deine Apple-ID → „Vertrauen“.

Ab jetzt läuft alles von selbst: Der Mac schaut jede Stunde nach neuen Versionen (auch denen von theredstonee),
baut sie, erneuert die 7-Tage-Signatur und installiert per WLAN – Mac und iPhone im selben WLAN, der Mac darf
schlafen (er holt es nach). Eine Mitteilung auf dem Mac sagt Bescheid.
Sofort aktualisieren: diese Datei wieder doppelklicken.
Minecraft starten braucht weiter JIT: ▶ in Xcode oder StikDebug (IOS.md, Abschnitt JIT).
EOF
bye ""
