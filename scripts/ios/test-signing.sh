#!/usr/bin/env bash
# Test für sign-ipa.sh und ota-manifest.sh ohne echtes Apple-Zertifikat: erzeugt ein selbst signiertes
# Code-Signing-Zertifikat (.p12) und ein damit signiertes Wegwerf-Profil (.mobileprovision, Wildcard-App-ID,
# get-task-allow), signiert die IPA und prüft Signatur, Entitlements, Bundle-ID und OTA-Manifest.
# Die Test-IPA ist auf keinem Gerät installierbar – es geht nur um die Skripte.
#
#   scripts/ios/test-signing.sh <unsigned.ipa>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IPA="${1:?Aufruf: test-signing.sh <unsigned.ipa>}"
[ -f "$IPA" ] || { echo "Test fehlgeschlagen: $IPA fehlt" >&2; exit 1; }
IPA="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
TEAM=TRSTEST001
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

die() { printf 'Test fehlgeschlagen: %s\n' "$*" >&2; exit 1; }

# --- Selbst signiertes Code-Signing-Zertifikat (LibreSSL: altes .p12-Format, wie der Schlüsselbund es mag) ---
cat > cert.cnf << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = TRS Test Signing ($TEAM)
OU = $TEAM
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 2 -config cert.cnf 2> /dev/null
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out test.p12 -passout pass:trs-test

# --- Wegwerf-Profil (gleiche Struktur wie von Apple, nur mit unserem Zertifikat signiert) ---
cat > profile.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Name</key><string>TRS Test Profile</string>
	<key>TeamIdentifier</key><array><string>$TEAM</string></array>
	<key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
	<key>Entitlements</key>
	<dict>
		<key>application-identifier</key><string>$TEAM.*</string>
		<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
		<key>get-task-allow</key><true/>
		<key>keychain-access-groups</key><array><string>$TEAM.*</string></array>
	</dict>
</dict>
</plist>
EOF
/usr/bin/openssl smime -sign -binary -nodetach -outform der -signer cert.pem -inkey key.pem -in profile.plist -out test.mobileprovision

# --- Signieren ---
P12_PASSWORD=trs-test bash "$ROOT/scripts/ios/sign-ipa.sh" "$IPA" test.p12 test.mobileprovision signed.ipa
[ -f signed.ipa ] || die "keine signierte IPA"

# --- Prüfen ---
unzip -q signed.ipa -d x
app="$(find x/Payload -maxdepth 1 -name '*.app' -type d | head -n 1)"
[ -f "$app/embedded.mobileprovision" ] || die "embedded.mobileprovision fehlt"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
[ "$bundle" = dev.theredstonee.trslauncher ] || die "Bundle-ID $bundle (Wildcard-Profil soll sie behalten)"
codesign --verify --deep --strict "$app" || die "Signatur ungültig"
codesign -dvv "$app" 2>&1 | grep -q "Authority=TRS Test Signing" || die "falsche Signatur-Identität"
codesign -d --entitlements :- "$app" > ent.plist 2> /dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' ent.plist)" = "$TEAM.$bundle" ] || die "application-identifier falsch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' ent.plist)" = true ] || die "get-task-allow fehlt (JIT)"
# Jede eingebettete Bibliothek muss mit derselben Identität signiert sein (sonst lädt iOS sie nicht).
while IFS= read -r -d '' lib; do
  codesign -dvv "$lib" 2>&1 | grep -q "Authority=TRS Test Signing" || die "nicht signiert: ${lib#"$app"/}"
done < <(find "$app/Frameworks" -name '*.dylib' -print0 2> /dev/null)

# --- OTA-Manifest ---
bash "$ROOT/scripts/ios/ota-manifest.sh" signed.ipa https://example.com/TRS.ipa https://example.com/manifest.plist ota > /dev/null
plutil -lint ota/manifest.plist
[ "$(/usr/libexec/PlistBuddy -c 'Print :items:0:metadata:bundle-identifier' ota/manifest.plist)" = "$bundle" ] || die "Manifest: Bundle-ID"
grep -q 'itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fexample.com%2Fmanifest.plist' ota/install.html \
  || die "install.html: Link falsch"
echo "Signier-Test bestanden ($bundle, Team $TEAM)"
