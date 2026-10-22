#!/usr/bin/env bash
# TRS Launcher – OTA-Installation („über Profil“ direkt aus Safari): manifest.plist + install.html.
#
#   scripts/ios/ota-manifest.sh <signiert.ipa> <ipa-url> <manifest-url> <ausgabe-ordner>
#
# iOS installiert über itms-services://?action=download-manifest&url=<manifest-url> – die IPA muss mit einem
# Profil signiert sein, das das Gerät enthält (Development/Ad Hoc: UDID im Profil) oder Enterprise ist.
# Beide Adressen müssen HTTPS sein (GitHub-Releases gehen).
set -euo pipefail

IPA="${1:?Aufruf: ota-manifest.sh <signiert.ipa> <ipa-url> <manifest-url> <ausgabe-ordner>}"
IPA_URL="${2:?ipa-url fehlt}"
MANIFEST_URL="${3:?manifest-url fehlt}"
OUT="${4:?ausgabe-ordner fehlt}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$IPA" 'Payload/*.app/Info.plist' -d "$TMP"
plist="$(find "$TMP/Payload" -maxdepth 2 -name Info.plist | head -n 1)"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2> /dev/null || plutil -extract "$1" raw "$plist"; }
bundle="$(read_key CFBundleIdentifier)"
version="$(read_key CFBundleShortVersionString)"
title="$(read_key CFBundleDisplayName)"

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
mkdir -p "$OUT"
cat > "$OUT/manifest.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>items</key>
	<array>
		<dict>
			<key>assets</key>
			<array>
				<dict>
					<key>kind</key>
					<string>software-package</string>
					<key>url</key>
					<string>$(printf '%s' "$IPA_URL" | xml_escape)</string>
				</dict>
			</array>
			<key>metadata</key>
			<dict>
				<key>bundle-identifier</key>
				<string>$(printf '%s' "$bundle" | xml_escape)</string>
				<key>bundle-version</key>
				<string>$(printf '%s' "$version" | xml_escape)</string>
				<key>kind</key>
				<string>software</string>
				<key>title</key>
				<string>$(printf '%s' "$title" | xml_escape)</string>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF

encoded="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$MANIFEST_URL")"
link="itms-services://?action=download-manifest&url=$encoded"
cat > "$OUT/install.html" << EOF
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(printf '%s' "$title" | xml_escape) installieren</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0b0c0f; color: #eee;
         font: 17px/1.5 -apple-system, system-ui, sans-serif; }
  main { max-width: 26rem; padding: 2rem 1rem; text-align: center; }
  a.button { display: inline-block; margin: 1.5rem 0; padding: .9rem 1.6rem; border-radius: .8rem;
             background: #e0281e; color: #fff; font-weight: 600; text-decoration: none; }
  small { color: #aaa; }
</style>
</head>
<body>
<main>
  <h1>$(printf '%s' "$title" | xml_escape) $(printf '%s' "$version" | xml_escape)</h1>
  <p>In Safari auf dem iPhone/iPad öffnen und tippen:</p>
  <a class="button" href="$(printf '%s' "$link" | xml_escape)">Installieren</a>
  <p><small>Danach Einstellungen → Allgemein → VPN und Geräteverwaltung → Entwickler-App vertrauen.
  Ab iOS 16 zusätzlich Einstellungen → Datenschutz &amp; Sicherheit → Entwicklermodus einschalten.</small></p>
</main>
</body>
</html>
EOF
echo "OTA: $OUT/manifest.plist, $OUT/install.html"
echo "Link: $link"
