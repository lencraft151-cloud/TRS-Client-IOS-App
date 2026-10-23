# TRS Launcher für iPhone und iPad

Diese Kopie von [TRS Launcher](https://github.com/theredstonee/TRS-Launcher) (GPL-3.0, © Theredstonee – siehe
[LICENSE](LICENSE) und [NOTICE](NOTICE)) enthält die iOS-App als **fertiges, signierbares Xcode-Projekt** und baut
IPAs, die sich mit einem eigenen Zertifikat + Provisioning-Profil direkt installieren lassen.

Die App ist dieselbe wie im Original: Microsoft-Anmeldung (Gerätecode), Instanzen, Modrinth-Inhalte, Modpacks,
Skins & Umhänge, Freunde und Chat, News, Benachrichtigungen, PC-Fernbedienung per QR-Code – und Minecraft Java selbst
über die eingebaute Spiel-Engine (Amethyst-iOS-Teile, JIT nötig, siehe unten).

| Was | Wo |
|---|---|
| **Xcode-Paket zum Herunterladen** | Release `ios-latest` → **`TRS-Launcher-Xcode.zip`** (siehe unten) |
| Xcode-Workspace | `src-tauri/gen/apple/TRS-Launcher.xcworkspace` (Projekt `trs-launcher.xcodeproj`, Schema `trs-launcher_iOS`) |
| Signatur-Einstellungen | `src-tauri/gen/apple/Signing.xcconfig` |
| IPA bauen (Mac) | `scripts/ios/build-ipa.sh` |
| IPA mit .p12 + .mobileprovision signieren | `scripts/ios/sign-ipa.sh` |
| OTA-Link (manifest.plist) | `scripts/ios/ota-manifest.sh` |
| CI (GitHub Actions, macOS) | `.github/workflows/ios-app.yml` |
| Projekt neu erzeugen | `ruby scripts/ios/generate-xcodeproj.rb` |
| Xcode-Paket bauen | `scripts/ios/package-xcode.sh` |

## Am einfachsten: Xcode-Paket herunterladen und öffnen

1. **`TRS-Launcher-Xcode.zip`** herunterladen – aus dem Release
   [`ios-latest`](../../releases/tag/ios-latest) (wird bei jedem Push auf `main` neu gebaut) oder als Artefakt
   `TRS-Launcher-Xcode` eines Laufs unter **Actions → iOS app**.
2. Entpacken und **`TRS-Launcher.xcworkspace`** doppelklicken (Xcode 16+).
3. Target **trs-launcher_iOS → Signing & Capabilities → Team** wählen (ggf. eigene Bundle-ID eintragen).
4. iPhone/iPad anschließen, als Ziel wählen, **▶ Run** – JIT für Minecraft ist dabei automatisch an
   (siehe [JIT](#minecraft-starten-jit)). **Product → Archive** baut eine IPA.

App-Kern (Rust + Oberfläche) und Spiel-Engine sind im Paket schon fertig gebaut: kein Rust, kein Node, kein
Terminal. Einschränkung: nur echte Geräte (arm64), kein Simulator. Details stehen in `LIESMICH.md` im Paket.

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

## Weg 2: Aus dem Quellcode in Xcode bauen (Mac)

Voraussetzungen: macOS mit Xcode 16+, [Rust](https://rustup.rs) (`rustup target add aarch64-apple-ios`),
Node.js 22 + pnpm (`npm i -g pnpm`).

```sh
bash scripts/ios/mac-setup.sh      # einmal: Team, git und Rust einrichten (siehe unten)
open src-tauri/gen/apple/TRS-Launcher.xcworkspace
```

**Einmal `scripts/ios/mac-setup.sh`, danach nur noch `git pull` + ▶ Run.** Das Skript legt Änderungen, die Xcode an
eingecheckten Projektdateien gemacht hat, beiseite (`git stash`), trägt Team und Bundle-ID in die von git ignorierte
`Signing.local.xcconfig` ein (aus diesen Änderungen, deinen Xcode-Konten oder deinem Zertifikat), stellt git so ein,
dass `git pull` lokale Änderungen künftig selbst beiseitelegt (`merge.autoStash`), und richtet Rust für iOS ein. Bricht
`git pull` mit „Please commit your changes or stash them“ ab: einmal `git stash && git pull && bash scripts/ios/mac-setup.sh`.

Nach jedem `git pull` erledigt ▶ Run den Rest: Abhängigkeiten (`pnpm install`), Oberfläche (`pnpm generate`) und
Rust-Kern werden neu gebaut, wenn sich etwas geändert hat; die Spiel-Engine lädt Xcode beim ersten Build selbst.

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
und signiert sie mit.

#### Spiel-Engine

**Automatisch:** Fehlt `src-tauri/gen/apple/Engine`, lädt die Build-Phase die fertige Engine aus dem Release
[`ios-engine`](../../releases/tag/ios-engine) dieses Repos (vom CI gebaut, SHA-256 geprüft) und legt sie dort ab.
In der Build-Ausgabe steht dann „Spiel-Engine laden: …“. Neue Engine holen: den Ordner `Engine` löschen und neu bauen.
Abschalten: `TRS_ENGINE_DOWNLOAD = NO` in `Signing.local.xcconfig`.

Von Hand geht es auch:

```sh
# selbst bauen (braucht cmake und ein JDK 8)
JAVA8_HOME=$(/usr/libexec/java_home -v 1.8) scripts/ios/build-engine.sh src-tauri/gen/apple/Engine
# oder: Artefakt „engine-ios“ eines Actions-Laufs herunterladen und nach src-tauri/gen/apple/Engine entpacken
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

## Automatische Updates

Die App prüft beim Start und alle 4 Stunden das Release **`ios-latest`** dieses Repos (`mobile.json`, signiert).
Jeder Build hat die Version `0.27.1.<Lauf-Nr.>`, also gilt jeder neue Build auf `main` als Update. Gibt es eins,
erscheint oben ein Hinweis:

- **Mit Profil signiert** (Secrets aus „Eigenes Zertifikat + Profil“ gesetzt): **Installieren** antippen →
  iOS fragt einmal nach → die App wird ersetzt, Daten bleiben erhalten. Das Gerät muss im Profil stehen
  (Development/Ad Hoc) bzw. das Profil ist Enterprise.
- **Sonst** (AltStore/SideStore/Xcode): Der Hinweis sagt, wie du aktualisierst. Für SideStore/AltStore liegt im
  Release auch eine Quelle: `https://github.com/lencraft151-cloud/TRS-Client-IOS-App/releases/download/ios-latest/altstore.json`
  – einmal als Quelle hinzufügen, dann kommen Updates dort an.

### Beta-Versionen

Pushes auf den Branch **`beta`** landen im Release **`ios-beta`** (auch von Hand: *Run workflow* → *publish* →
Kanal `ios-beta`). In der App unter **Einstellungen → Verhalten → Beta-Versionen** einschalten: Sie prüft dann
beide Releases und bietet die neuere Version an – ist `main` weiter, wieder die normale.

### Einmalig einrichten: Signier-Schlüssel für den Update-Kanal

Damit niemand der App ein falsches Update unterschieben kann, ist `mobile.json` signiert. Der öffentliche
Schlüssel steckt in der App (`src-tauri/gen/apple/UpdateChannel.xcconfig`, `update-public-key.txt`); den privaten
legst du als Secret an – **Settings → Secrets and variables → Actions**:

| Secret | Inhalt |
|---|---|
| `IOS_UPDATE_SIGNING_KEY` | Inhalt der Datei `ios-update.key` |
| `IOS_UPDATE_SIGNING_KEY_PASSWORD` | Inhalt der Datei `ios-update.key.password` |

Ohne diese Secrets baut alles weiter, nur meldet die App keine Updates. Eigenen Schlüssel statt des mitgelieferten:
`pnpm tauri signer generate -w ios-update.key`, dann den öffentlichen Schlüssel in `update-public-key.txt` **und**
`TRS_UPDATE_PUBKEY` (UpdateChannel.xcconfig) eintragen.

## Minecraft starten: JIT

Minecraft Java läuft in einer JVM und braucht auf iOS **JIT** (Just-in-Time-Kompilierung).

### JIT ist eingebaut: einfach aus Xcode starten

Das Xcode-Projekt bringt einen JIT-Helfer mit (`src-tauri/gen/apple/lldb/`). Startest du die App mit **▶ Run**
aus Xcode, ist JIT automatisch an – ohne StikDebug, SideStore oder Zusatz-Apps:

- Xcodes Debugger hängt sich an die App; damit darf sie ausführbaren Speicher anlegen (iOS 15–18 und iOS 26 ohne TXM).
- **iOS 26 mit TXM** (neuere iPhones): Der Helfer `trs_jit.py` beantwortet die JIT-Anfragen der Engine im Debugger –
  dasselbe, was StikDebug mit `UniversalJIT26.js` macht.
- `trs-jit.lldbinit` lässt die Signale der JVM durch, damit Xcode nicht bei jeder Java-Null-Prüfung anhält.
- Eingestellt im Schema: *Product → Scheme → Edit Scheme → Run → Info → LLDB Init File* und Umgebungsvariable
  `TRS_JIT_ALWAYS_ATTACHED=1`.

Solange Minecraft läuft, bleibt Xcode verbunden (Kabel oder WLAN-Debugging). In der Xcode-Konsole stehen dabei
Zeilen wie `[TRS-JIT] JIT-Region …`.

### Ohne Kabel spielen (WLAN-Debugging)

Einmal einrichten, danach startet ▶ Run die App über WLAN – das iPhone muss nicht am Mac hängen:

1. iPhone **einmal per Kabel** anschließen und entsperren („Diesem Computer vertrauen“).
2. Xcode → **Window → Devices and Simulators** → links dein iPhone → Haken bei **Connect via network**.
3. Kabel abziehen. Neben dem Gerät erscheint ein Netzwerk-Symbol; oben in Xcode bleibt es als Ziel wählbar.
4. **▶ Run** – App und JIT laufen wie mit Kabel.

Damit es stabil bleibt:

- Mac und iPhone im **selben WLAN**; Gast-Netze und „Client-Isolation“ (Schul-/Firmen-WLAN, manche Router)
  blockieren das. Notfalls den persönlichen Hotspot des iPhones nutzen und den Mac damit verbinden.
- Den Mac **wach halten**, solange du spielst (Deckel offen oder im Terminal `caffeinate -d`); schläft er ein,
  trennt Xcode und – auf iOS 26 mit TXM – endet JIT.
- iPhone vor dem Start entsperren; findet Xcode es nicht, einmal kurz das Kabel anstecken.
- Nicht auf *Stop* oder *Debug → Detach* drücken, solange Minecraft läuft. Auf iOS 15–18 bleibt JIT nach einem
  Detach zwar an, auf iOS 26 mit TXM aber nicht.

### JIT ohne Mac: ein Tipp mit StikDebug

Ist [StikDebug](https://github.com/StephenDev0/StikDebug) einmal eingerichtet (Pairing-Datei, LocalDevVPN), reicht
in der App beim Spielstart **„JIT mit StikDebug aktivieren“**: TRS öffnet StikDebug mit seiner eigenen Prozess-ID,
StikDebug hängt sich an die laufende App und springt zurück – Minecraft startet. Auf iOS 26 (TXM) wird das Skript
`UniversalJIT26.js` automatisch mitgegeben, nichts muss von Hand zugewiesen werden.

Allgemein braucht die App ohne Xcode `get-task-allow` – also ein **Development-Profil** (oder AltStore/SideStore-/
TrollStore-Installation) – und ein Werkzeug, das JIT einschaltet: StikDebug (iOS 17+; ab iOS 26 mit dem
mitgelieferten `UniversalJIT26.js`), SideStore, AltServer oder TrollStore. Die App zeigt beim Spielstart eine
Anleitung und wartet, bis JIT aktiv ist.

| Profil | Launcher | Minecraft-Start |
|---|---|---|
| ▶ Run aus Xcode | ✅ | ✅ JIT automatisch |
| Development (Gerät im Profil) | ✅ | ✅ mit JIT-Werkzeug |
| Ad Hoc | ✅ | ❌ (kein get-task-allow) |
| Enterprise / Fremdzertifikat | ✅ | ❌ (kein get-task-allow) |
| AltStore / SideStore / Sideloadly (Apple-ID) | ✅ | ✅ mit JIT |
| TrollStore (unsignierte IPA) | ✅ | ✅ |

Mehr Arbeitsspeicher: Mit bezahltem Account die Capabilities *Increased Memory Limit* und *Extended Virtual
Addressing* in der App-ID einschalten (Xcode macht das bei „Automatic“ selbst). Fehlen sie, wählt die App den
Java-Heap kleiner.

## Fehlerbehebung

**App stürzt direkt beim Start ab (Xcode 27):**

1. Neuesten Stand holen (`git pull`).
2. In Xcode **Product → Clean Build Folder** (⇧⌘K), dann erneut ▶ Run.

Der erste Build danach dauert länger: Die Build-Phase installiert `llvm-tools` (rustup) und baut den Rust-Kern
einmal komplett neu. Hintergrund:

- Mit dem iOS-27-SDK starten UIKit-Apps nur noch mit Scene-Lebenszyklus (`UIApplicationSceneManifest` in der
  Info.plist).
- Den Hintergrundabruf (BGTaskScheduler) meldet die App jetzt vor dem Start an (`main.mm`); später beendet iOS
  sie sofort.
- Unter Xcode 27 braucht `swift-rs` `llvm-objcopy`, sonst fehlen die Einstiegspunkte der Plugins.

Stürzt sie weiter ab, in Xcode unten die Konsole öffnen (⇧⌘C) und die letzte rote Zeile bzw. den
„Terminating app due to …“-Text schicken. Auf dem iPhone selbst liegen Absturzberichte unter
Einstellungen → Datenschutz & Sicherheit → Analyse & Verbesserungen → Analysedaten („TRS Launcher-…“).

**Absturzberichte der App:** Die App schreibt eigene Berichte nach **Dateien → Auf meinem iPhone → TRS Launcher →
Crash Reports** – Abstürze und Hänger (von iOS beim nächsten Start nachgeliefert), Fehler im Rust-Kern und Starts,
die vor der Oberfläche abbrachen. Der nächste Start zeigt neue Berichte mit **Teilen**. Lädt die Oberfläche nach
25 Sekunden nicht, erscheint ein Fenster mit **Neu laden** und **Bericht teilen**.

## Projekt nach Änderungen neu erzeugen

Das Xcode-Projekt entsteht aus `scripts/ios/generate-xcodeproj.rb` (Ruby-Gem `xcodeproj`, läuft auch unter
Linux/Windows). Nach einem Versionssprung in `src-tauri/tauri.conf.json` oder neuen App-Symbolen:

```sh
gem install xcodeproj
ruby scripts/ios/generate-xcodeproj.rb
```

Der Workflow prüft, dass das eingecheckte Projekt aktuell ist.
