#!/usr/bin/env bash
# TRS Launcher – einmal auf dem Mac: GitHub-Secrets für automatische App-Updates setzen. Danach baut jeder Push auf
# main eine mit deinem Profil signierte App (Release ios-latest), und die App auf dem iPhone installiert sie von selbst
# (iOS fragt einmal „Installieren?“). Braucht einen bezahlten Apple-Developer-Account.
#
#   bash scripts/ios/ci-secrets.sh --p12 ~/Desktop/TRS.p12 [--profile X.mobileprovision] \
#        [--update-key ~/Downloads/ios-update.key] [--update-key-password ~/Downloads/ios-update.key.password]
#
# --p12      Zertifikat mit privatem Schlüssel: Schlüsselbundverwaltung → Meine Zertifikate → „Apple Development: …“
#            → Rechtsklick → Exportieren … → Format .p12, Passwort vergeben (fragt das Skript ab).
# --profile  Provisioning-Profil (Development oder Ad Hoc, dein iPhone muss drinstehen). Ohne: das passende Profil,
#            das Xcode beim ▶ Run angelegt hat (Wildcard bevorzugt – dann ist das Widget mit dabei).
# --update-key / --update-key-password
#            Schlüssel des Update-Kanals (mobile.json wird damit signiert; der öffentliche Teil steckt in der App).
#            Standard: ~/Downloads/ios-update.key und ~/Downloads/ios-update.key.password.
#
# Mit der GitHub-CLI (`brew install gh`, `gh auth login`) setzt das Skript die Secrets selbst und startet einen Build;
# sonst legt es die Werte in ~/TRS-CI-Secrets ab und sagt, wo sie hinkommen.
set -euo pipefail

p12=""
profile=""
update_key="$HOME/Downloads/ios-update.key"
update_key_password="$HOME/Downloads/ios-update.key.password"
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) p12="${2:?}"; shift 2 ;;
    --profile) profile="${2:?}"; shift 2 ;;
    --update-key) update_key="${2:?}"; shift 2 ;;
    --update-key-password) update_key_password="${2:?}"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'Unbekannte Option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

die() { printf '\nFehler: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || die "nur auf dem Mac"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE="$ROOT/src-tauri/gen/apple"
LOCAL="$APPLE/Signing.local.xcconfig"
repo="$(sed -nE 's/^TRS_UPDATE_REPO *= *([^ ]+).*/\1/p' "$APPLE/UpdateChannel.xcconfig" | head -n 1)"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "TRS_UPDATE_REPO in UpdateChannel.xcconfig fehlt"

# --- Zertifikat ---
[ -n "$p12" ] || die "--p12 fehlt (Zertifikat aus der Schlüsselbundverwaltung exportieren, siehe oben)"
[ -f "$p12" ] || die "$p12 gibt es nicht"
read -r -s -p "Passwort der .p12: " p12_password
echo
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
openssl pkcs12 -in "$p12" -passin "pass:$p12_password" -nokeys -clcerts -out "$TMP/cert.pem" 2> /dev/null \
  || openssl pkcs12 -legacy -in "$p12" -passin "pass:$p12_password" -nokeys -clcerts -out "$TMP/cert.pem" 2> /dev/null \
  || die "Die .p12 lässt sich nicht öffnen – Passwort falsch?"
subject="$(openssl x509 -in "$TMP/cert.pem" -noout -subject)"
team="$(sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' <<< "$subject" | head -n 1)"
[ -n "$team" ] || die "Kein Team im Zertifikat ($subject)"
say "Zertifikat: $(sed -nE 's/.*CN ?= ?([^,/]+).*/\1/p' <<< "$subject") (Team $team)"

bundle="$(grep -s '^PRODUCT_BUNDLE_IDENTIFIER' "$LOCAL" | sed -E 's/.*= *//' | tr -d '[:space:]' || true)"
[ -n "$bundle" ] || bundle=dev.theredstonee.trslauncher

# --- Profil ---
profile_value() { plutil -extract "$2" raw -o - "$1" 2> /dev/null || true; }
if [ -z "$profile" ]; then
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  best="" best_rank="" best_expiry=""
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    for f in "$dir"/*.mobileprovision; do
      [ -f "$f" ] || continue
      security cms -D -i "$f" > "$TMP/p.plist" 2> /dev/null || continue
      [ "$(profile_value "$TMP/p.plist" TeamIdentifier.0)" = "$team" ] || continue
      expiry="$(profile_value "$TMP/p.plist" ExpirationDate)"
      [[ "$expiry" > "$now" ]] || continue
      [ -n "$(profile_value "$TMP/p.plist" ProvisionedDevices.0)" ] || continue # Development/Ad Hoc mit Geräten
      app_id="$(profile_value "$TMP/p.plist" Entitlements.application-identifier)"
      case "$app_id" in
        "$team.*") rank=2 ;;
        "$team.$bundle") rank=1 ;;
        *) continue ;;
      esac
      if [ -z "$best" ] || [ "$rank" -gt "$best_rank" ] || { [ "$rank" = "$best_rank" ] && [[ "$expiry" > "$best_expiry" ]]; }; then
        best="$f" best_rank="$rank" best_expiry="$expiry"
      fi
    done
  done
  [ -n "$best" ] || die "Kein passendes Profil gefunden (Team $team, App $bundle). Einmal in Xcode ▶ Run auf dem iPhone, dann erneut – oder --profile angeben."
  profile="$best"
fi
[ -f "$profile" ] || die "$profile gibt es nicht"
security cms -D -i "$profile" > "$TMP/p.plist" 2> /dev/null || die "$profile ist kein Provisioning-Profil"
say "Profil: $(profile_value "$TMP/p.plist" Name) (gültig bis $(profile_value "$TMP/p.plist" ExpirationDate))"
case "$(profile_value "$TMP/p.plist" Entitlements.application-identifier)" in
  "$team.*") echo "   Wildcard – App und Widget werden signiert" ;;
  *) echo "   nur für die App – das Widget fällt in der signierten IPA weg" ;;
esac

# --- Update-Kanal ---
[ -f "$update_key" ] || die "$update_key fehlt (Schlüssel des Update-Kanals, siehe IOS.md)"
[ -f "$update_key_password" ] || die "$update_key_password fehlt"

# --- Secrets ---
secret_files=(
  "IOS_CERTIFICATE_P12_BASE64:$TMP/p12.b64"
  "IOS_CERTIFICATE_PASSWORD:$TMP/p12.pw"
  "IOS_PROVISIONING_PROFILE_BASE64:$TMP/profile.b64"
  "IOS_UPDATE_SIGNING_KEY:$update_key"
  "IOS_UPDATE_SIGNING_KEY_PASSWORD:$update_key_password"
)
base64 -i "$p12" | tr -d '\n' > "$TMP/p12.b64"
printf '%s' "$p12_password" > "$TMP/p12.pw"
base64 -i "$profile" | tr -d '\n' > "$TMP/profile.b64"
if [ "$bundle" != dev.theredstonee.trslauncher ]; then
  printf '%s' "$bundle" > "$TMP/bundle"
  secret_files+=("IOS_BUNDLE_ID:$TMP/bundle")
fi

if command -v gh > /dev/null && gh auth status > /dev/null 2>&1; then
  say "Secrets in $repo setzen"
  for entry in "${secret_files[@]}"; do
    name="${entry%%:*}"
    gh secret set "$name" --repo "$repo" < "${entry#*:}"
    echo "   $name"
  done
  say "Build starten (Release ios-latest, dauert etwa 1–2 Stunden)"
  gh workflow run ios-app.yml --repo "$repo" -f publish=true -f channel=ios-latest -f engine=true
  say "Fertig. Ist der Build durch, bietet die App das Update von selbst an – ab dann jedes neue."
else
  out="$HOME/TRS-CI-Secrets"
  mkdir -p "$out"
  chmod 700 "$out"
  for entry in "${secret_files[@]}"; do
    cp "${entry#*:}" "$out/${entry%%:*}.txt"
  done
  chmod 600 "$out"/*.txt
  say "Ohne GitHub-CLI: Werte liegen in $out (je Datei ein Secret)"
  echo "   https://github.com/$repo/settings/secrets/actions → New repository secret"
  echo "   Name = Dateiname ohne .txt, Wert = Inhalt der Datei. Danach $out löschen."
  echo "   Dann: Actions → iOS app → Run workflow (publish an)."
fi
