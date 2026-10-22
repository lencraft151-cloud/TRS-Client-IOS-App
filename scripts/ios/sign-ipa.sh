#!/usr/bin/env bash
# TRS Launcher – signiert eine IPA mit eigenem Zertifikat (.p12) und Provisioning-Profil (.mobileprovision),
# damit sie sich direkt (Profil auf dem Gerät, OTA-Link, Apple Configurator, Xcode „Devices“) installieren lässt.
#
#   scripts/ios/sign-ipa.sh <eingabe.ipa> <zertifikat.p12> <profil.mobileprovision> <ausgabe.ipa>
#
# Umgebung:
#   P12_PASSWORD   Passwort der .p12 (leer, wenn keins)
#   BUNDLE_ID      Bundle-ID erzwingen (Standard: aus dem Profil; bei Wildcard-Profil bleibt die der App)
#
# Profil-Arten: Development (mit get-task-allow → JIT für den Minecraft-Start möglich), Ad Hoc und Enterprise
# (Launcher läuft, Minecraft startet ohne JIT nicht). Die Entitlements kommen aus dem Profil – was das Profil
# nicht erlaubt (z. B. increased-memory-limit), fällt weg; die App passt den Speicher zur Laufzeit an.
# Braucht macOS (security, codesign, PlistBuddy).
set -euo pipefail

IN="${1:?Aufruf: sign-ipa.sh <eingabe.ipa> <zertifikat.p12> <profil.mobileprovision> <ausgabe.ipa>}"
P12="${2:?zertifikat.p12 fehlt}"
PROFILE="${3:?profil.mobileprovision fehlt}"
OUT="${4:?ausgabe.ipa fehlt}"
PB=/usr/libexec/PlistBuddy

die() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || die "nur auf macOS"
for f in "$IN" "$P12" "$PROFILE"; do [ -f "$f" ] || die "$f fehlt"; done
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

TMP="$(mktemp -d)"
KEYCHAIN="$TMP/sign.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
old_keychains=()
cleanup() {
  if [ ${#old_keychains[@]} -gt 0 ]; then security list-keychains -d user -s "${old_keychains[@]}" || true; fi
  security delete-keychain "$KEYCHAIN" 2> /dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- Zertifikat in einen temporären Schlüsselbund ---
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
if ! security import "$P12" -k "$KEYCHAIN" -P "${P12_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security > /dev/null 2>&1; then
  # .p12 von OpenSSL 3 (AES/PBKDF2) kennt der Schlüsselbund nicht – ins alte Format umpacken und erneut versuchen.
  command -v openssl > /dev/null || die "Zertifikat nicht importierbar (Passwort falsch?) und openssl fehlt zum Umwandeln"
  openssl pkcs12 -in "$P12" -passin "pass:${P12_PASSWORD:-}" -nodes -out "$TMP/cert.pem" -legacy 2> /dev/null \
    || openssl pkcs12 -in "$P12" -passin "pass:${P12_PASSWORD:-}" -nodes -out "$TMP/cert.pem" \
    || die "Zertifikat nicht lesbar – Passwort falsch?"
  /usr/bin/openssl pkcs12 -export -in "$TMP/cert.pem" -out "$TMP/legacy.p12" -passout "pass:$KEYCHAIN_PASSWORD"
  security import "$TMP/legacy.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
fi
# Apple-Zwischenzertifikate (WWDR): ohne sie kann codesign die Kette nicht bauen (frischer Mac). Fehlen darf es –
# dann gilt, was im System-Schlüsselbund liegt.
for ca in AppleWWDRCAG3 AppleWWDRCAG6; do
  if curl -fsSL --max-time 20 -o "$TMP/$ca.cer" "https://www.apple.com/certificateauthority/$ca.cer"; then
    security import "$TMP/$ca.cer" -k "$KEYCHAIN" > /dev/null 2>&1 || true
  fi
done
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
while IFS= read -r kc; do old_keychains+=("$kc"); done < <(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
security list-keychains -d user -s "$KEYCHAIN" "${old_keychains[@]}"
# Ohne -v: auch Identitäten, deren Kette macOS (noch) nicht prüfen kann – codesign signiert trotzdem.
identity_line="$(security find-identity -p codesigning "$KEYCHAIN" | awk '$2 ~ /^[0-9A-F]{40}$/ {print; exit}')"
IDENTITY="$(awk '{print $2}' <<< "$identity_line")"
[ -n "$IDENTITY" ] || die "kein Signier-Zertifikat in $P12 (Passwort richtig? Zertifikat mit privatem Schlüssel exportiert?)"
echo "Zertifikat: $(cut -d'"' -f2 <<< "$identity_line")"

# --- Profil lesen ---
security cms -D -i "$PROFILE" > "$TMP/profile.plist" 2> /dev/null \
  || openssl smime -verify -noverify -inform der -in "$PROFILE" -out "$TMP/profile.plist" 2> /dev/null \
  || die "$PROFILE ist kein Provisioning-Profil"
APP_ID="$($PB -c 'Print :Entitlements:application-identifier' "$TMP/profile.plist")"
TEAM="$($PB -c 'Print :TeamIdentifier:0' "$TMP/profile.plist")"
EXPIRES="$($PB -c 'Print :ExpirationDate' "$TMP/profile.plist")"
$PB -x -c 'Print :Entitlements' "$TMP/profile.plist" > "$TMP/entitlements.plist"
echo "Profil: $($PB -c 'Print :Name' "$TMP/profile.plist") (Team $TEAM, App-ID $APP_ID, gültig bis $EXPIRES)"

# --- IPA auspacken ---
unzip -q "$IN" -d "$TMP/x"
APP="$(find "$TMP/x/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
[ -n "$APP" ] || die "keine .app in $IN"
PLIST="$APP/Info.plist"
EXE="$($PB -c 'Print :CFBundleExecutable' "$PLIST")"

# Bundle-ID: explizit > aus dem Profil > (Wildcard) die der App.
profile_bundle="${APP_ID#"$TEAM".}"
current_bundle="$($PB -c 'Print :CFBundleIdentifier' "$PLIST")"
if [ -n "${BUNDLE_ID:-}" ]; then
  bundle="$BUNDLE_ID"
elif [ "$profile_bundle" = '*' ]; then
  bundle="$current_bundle"
elif [[ "$profile_bundle" == *'.*' ]]; then
  bundle="${profile_bundle%\*}trslauncher"
else
  bundle="$profile_bundle"
fi
case "$profile_bundle" in
  '*') ;;
  *'.*') [[ "$bundle" == "${profile_bundle%\*}"* ]] || die "Bundle-ID $bundle passt nicht zum Profil ($profile_bundle)" ;;
  *) [ "$bundle" = "$profile_bundle" ] || die "Bundle-ID $bundle passt nicht zum Profil ($profile_bundle)" ;;
esac
$PB -c "Set :CFBundleIdentifier $bundle" "$PLIST"
$PB -c "Set :CFBundleURLTypes:0:CFBundleURLName $bundle" "$PLIST" 2> /dev/null || true
$PB -c "Set :application-identifier $TEAM.$bundle" "$TMP/entitlements.plist"
echo "Bundle-ID: $bundle"
for key in get-task-allow com.apple.developer.kernel.increased-memory-limit com.apple.developer.kernel.extended-virtual-addressing; do
  if [ "$($PB -c "Print :$key" "$TMP/entitlements.plist" 2> /dev/null)" = true ]; then
    echo "  $key: ja"
  else
    echo "  $key: nein"
  fi
done

# --- Signieren: erst eingebettete Bibliotheken/Frameworks, zuletzt die App mit Profil + Entitlements ---
rm -rf "$APP/_CodeSignature"
cp "$PROFILE" "$APP/embedded.mobileprovision"
sign() { codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$@"; }
if [ -d "$APP/Frameworks" ]; then
  # Frameworks als Bündel, lose dylibs einzeln (tiefste zuerst).
  while IFS= read -r -d '' fw; do sign "$fw"; done < <(find "$APP/Frameworks" -depth -name '*.framework' -type d -print0)
fi
while IFS= read -r -d '' file; do
  [ "$file" = "$APP/$EXE" ] && continue
  case "$file" in *.framework/*) continue ;; esac
  if file "$file" | grep -q 'Mach-O'; then sign "$file"; fi
done < <(find "$APP" -type f -print0)
sign --entitlements "$TMP/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2> /dev/null | grep -q "$TEAM.$bundle" || die "Entitlements fehlen in der Signatur"

rm -f "$OUT"
(cd "$TMP/x" && zip -qry "$OUT" Payload)
echo "Signierte IPA: $OUT ($(du -h "$OUT" | cut -f1))"
