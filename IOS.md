# TRS Launcher für iPhone und iPad

Diese Kopie von [TRS Launcher](https://github.com/theredstonee/TRS-Launcher) (GPL-3.0, © Theredstonee – siehe
[LICENSE](LICENSE) und [NOTICE](NOTICE)) enthält die iOS-App als **fertiges, signierbares Xcode-Projekt** und baut
IPAs, die sich mit einem eigenen Zertifikat + Provisioning-Profil direkt installieren lassen.

Die App ist dieselbe wie im Original: Microsoft-Anmeldung (Gerätecode), Instanzen, Modrinth-Inhalte, Modpacks,
Skins & Umhänge, Freunde und Chat, News, Benachrichtigungen, PC-Fernbedienung per QR-Code – und Minecraft Java selbst
über die eingebaute Spiel-Engine (Amethyst-iOS-Teile, JIT nötig, siehe unten).

| Was | Wo |
|---|---|
| Xcode-Projekt | `src-tauri/gen/apple/trs-launcher.xcodeproj` (Target/Schema `trs-launcher_iOS`) |
| Signatur-Einstellungen | `src-tauri/gen/apple/Signing.xcconfig` |
| IPA bauen (Mac) | `scripts/ios/build-ipa.sh` |
| IPA mit .p12 + .mobileprovision signieren | `scripts/ios/sign-ipa.sh` |
| OTA-Link (manifest.plist) | `scripts/ios/ota-manifest.sh` |
| CI (GitHub Actions, macOS) | `.github/workflows/ios-app.yml` |
| Projekt neu erzeugen | `ruby scripts/ios/generate-xcodeproj.rb` |

## Weg 1: Fertige IPA aus GitHub Actions (ohne Mac)

1. **Actions → iOS app → Run workflow** (Häkchen „publish“ setzen, um ein Release `ios-latest` anzulegen).
   Der Lauf baut Engine + App (ca. 45–90 Minuten).
2. Ergebnis (Artefakt `trs-launcher-ios-app` bzw. Release):
   - **`TRS-Launcher-unsigned.ipa`** – installierbar mit **Feather, ESign, Scarlet, KSign, Sideloadly,
     AltStore/SideStore** oder **TrollStore**. Diese Apps signieren beim Installieren mit deinem Zertifikat (.p12)
     und Profil (.mobileprovision) bzw. deiner Apple-ID.
   - **`TRS-Launcher.ipa`** – schon mit *deinem* Zertifikat + Profil signiert (nur wenn die Secrets unten gesetzt
     sind). Installieren per OTA-Link, Apple Configurator, Finder/iTunes oder Xcode → *Devices and Simulators*.

### Eigenes Zertifikat + Profil hinterlegen

Repository → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Inhalt |
|---|---|
| `IOS_CERTIFICATE_P12_BASE64` | `base64 -i zertifikat.p12` (Zertifikat **mit** privatem Schlüssel) |
| `IOS_CERTIFICATE_PASSWORD` | Passwort der .p12 |
| `IOS_PROVISIONING_PROFILE_BASE64` | `base64 -i profil.mobileprovision` |
| `IOS_BUNDLE_ID` | optional: Bundle-ID erzwingen (sonst aus dem Profil) |

Unter Windows: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("zertifikat.p12"))`.

Die Entitlements kommen aus dem Profil. Bei einem Wildcard-Profil (`TEAMID.*`) bleibt die Bundle-ID
`dev.theredstonee.trslauncher`, bei `TEAMID.com.beispiel.*` wird sie `com.beispiel.trslauncher`, sonst die des Profils.

### Installation über den OTA-Link

Mit „publish“ (oder einem Tag `ios-v…`) legt der Workflow `manifest.plist` und `install.html` ins Release und
schreibt den Link `itms-services://?action=download-manifest&url=…` in die Release-Notizen. Den Link in **Safari auf
dem iPhone** öffnen (oder `install.html` auf einer eigenen HTTPS-Seite ablegen) → *Installieren*.

Danach: **Einstellungen → Allgemein → VPN und Geräteverwaltung → Entwickler-App vertrauen** und ab iOS 16
**Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** einschalten.
Bei Development/Ad-Hoc-Profilen muss die **UDID des Geräts im Profil** stehen.

## Weg 2: Selbst in Xcode signieren (Mac)

Voraussetzungen: macOS mit Xcode 16+, [Rust](https://rustup.rs) (`rustup target add aarch64-apple-ios`),
Node.js 22 + pnpm (`npm i -g pnpm`).

```sh
pnpm install
pnpm generate                      # Oberfläche (sonst baut Xcode sie beim ersten Build selbst)
open src-tauri/gen/apple/trs-launcher.xcodeproj
```

1. In `src-tauri/gen/apple/Signing.xcconfig` (oder einer neuen `Signing.local.xcconfig`, nicht eingecheckt)
   `DEVELOPMENT_TEAM` und ggf. `PRODUCT_BUNDLE_IDENTIFIER` eintragen – oder in Xcode unter
   *Target trs-launcher_iOS → Signing & Capabilities* Team wählen.
   - **Automatic**: Xcode legt Zertifikat und Profil selbst an.
   - **Manual** (eigene .p12 + .mobileprovision): .p12 per Doppelklick in den Schlüsselbund, Profil per Doppelklick
     installieren, dann `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY` und `PROVISIONING_PROFILE_SPECIFIER` setzen.
   - **Kostenloses Apple-Konto** (Personal Team): `TRS_ENTITLEMENTS` auf
     `trs-launcher_iOS/trs-launcher_iOS-basic.entitlements` stellen (ohne Increased-Memory-Limit).
2. iPhone anschließen, Ziel wählen, **▶ Run** – oder **Product → Archive → Distribute App**
   (Development / Ad Hoc / Enterprise; passende `ExportOptions-*.plist` liegen für `xcodebuild -exportArchive` bei).

Die Build-Phase **Build Rust Code** (`scripts/build-rust.sh`) baut Oberfläche und Rust-Kern automatisch;
**Embed Game Engine** (`scripts/embed-engine.sh`) legt die Spiel-Engine aus `src-tauri/gen/apple/Engine/` in die App
und signiert sie mit. Die Engine bekommst du so:

```sh
# Variante A: selbst bauen (braucht cmake und ein JDK 8)
JAVA8_HOME=$(/usr/libexec/java_home -v 1.8) scripts/ios/build-engine.sh src-tauri/gen/apple/Engine
# Variante B: Artefakt „engine-ios“ eines Actions-Laufs herunterladen und nach src-tauri/gen/apple/Engine entpacken
```

Ohne Engine läuft der Launcher vollständig, nur der Spielstart meldet „Engine fehlt“.

### Komplett per Kommandozeile

```sh
brew install ldid
export IOS_P12_PATH=~/zertifikat.p12 IOS_P12_PASSWORD=… IOS_PROFILE_PATH=~/profil.mobileprovision
scripts/ios/build-ipa.sh build/ios src-tauri/gen/apple/Engine
# → build/ios/TRS-Launcher.ipa (signiert) und build/ios/TRS-Launcher-unsigned.ipa

# Eine vorhandene IPA neu signieren:
P12_PASSWORD=… scripts/ios/sign-ipa.sh TRS-Launcher-unsigned.ipa zertifikat.p12 profil.mobileprovision TRS-Launcher.ipa
```

## Minecraft starten: JIT

Minecraft Java läuft in einer JVM und braucht auf iOS **JIT**. Das geht nur, wenn die App `get-task-allow` hat –
also mit einem **Development-Profil** (oder AltStore/SideStore-/TrollStore-Installation) – und JIT aktiviert wird:
StikDebug (iOS 17+; ab iOS 26 mit dem mitgelieferten `UniversalJIT26.js`), SideStore, AltServer oder TrollStore.
Die App zeigt beim Spielstart eine Anleitung und wartet, bis JIT aktiv ist.

| Profil | Launcher | Minecraft-Start |
|---|---|---|
| Development (Gerät im Profil) | ✅ | ✅ mit JIT |
| Ad Hoc | ✅ | ❌ (kein get-task-allow) |
| Enterprise / Fremdzertifikat | ✅ | ❌ (kein get-task-allow) |
| AltStore / SideStore / Sideloadly (Apple-ID) | ✅ | ✅ mit JIT |
| TrollStore (unsignierte IPA) | ✅ | ✅ |

Mehr Arbeitsspeicher: Mit bezahltem Account die Capabilities *Increased Memory Limit* und *Extended Virtual
Addressing* in der App-ID einschalten (Xcode macht das bei „Automatic“ selbst). Fehlen sie, wählt die App den
Java-Heap kleiner.

## Projekt nach Änderungen neu erzeugen

Das Xcode-Projekt entsteht aus `scripts/ios/generate-xcodeproj.rb` (Ruby-Gem `xcodeproj`, läuft auch unter
Linux/Windows). Nach einem Versionssprung in `src-tauri/tauri.conf.json` oder neuen App-Symbolen:

```sh
gem install xcodeproj
ruby scripts/ios/generate-xcodeproj.rb
```

Der Workflow prüft, dass das eingecheckte Projekt aktuell ist.
