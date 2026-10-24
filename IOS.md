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
   - **iCloud Drive für Sicherungen** (bezahlter Account): `bash scripts/ios/mac-setup.sh --icloud`, siehe
     [Sicherung und iCloud Drive](#sicherung-und-icloud-drive).
   - **Kostenloses Apple-Konto** (Personal Team): `TRS_ENTITLEMENTS` auf
     `trs-launcher_iOS/trs-launcher_iOS-basic.entitlements` stellen (ohne Increased-Memory-Limit) und
     `TRS_WIDGET_ENTITLEMENTS` auf `Widgets/TRSWidgets-basic.entitlements` (ohne App-Gruppe).
   - Team und Bundle-ID gelten über die xcconfig auch für die **Widget-Erweiterung** (Target `TRSWidgets`, Bundle-ID
     der App + `.widgets`). Stellst du sie stattdessen in Xcode ein, dann bei beiden Targets.
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

Die App prüft beim Start, alle 4 Stunden und wenn sie nach einer Pause wieder nach vorn kommt das Release
**`ios-latest`** dieses Repos (`mobile.json`, signiert). Jeder Build hat die Version `<Version>.<Lauf-Nr.>`, also gilt
jeder neue Build auf `main` als Update – Änderungen hier genauso wie neue Versionen von theredstonee/TRS-Launcher, die
jeden Tag automatisch übernommen werden ([docs/upstream-sync.md](docs/upstream-sync.md)).

- **Mit Profil signiert** (einmalige Einrichtung unten): Die App **installiert das Update von selbst**, sobald gerade
  nichts läuft (kein Spiel, keine Downloads). iOS fragt nur noch einmal „Installieren?“ – ganz ohne Rückfrage lässt
  Apple keine App sich selbst ersetzen. Daten bleiben erhalten. Tippst du auf „Abbrechen“, bleibt oben ein Hinweis
  mit **Installieren**; beim nächsten Start fragt die App wieder.
- **Sonst** (AltStore/SideStore/Xcode): Der Hinweis sagt, wie du aktualisierst. Für SideStore/AltStore liegt im
  Release auch eine Quelle: `https://github.com/lencraft151-cloud/TRS-Client-IOS-App/releases/download/ios-latest/altstore.json`
  – einmal als Quelle hinzufügen, dann kommen Updates dort an.

### Einmalig einrichten: automatische Updates (Mac, bezahlter Apple-Developer-Account)

1. **Zertifikat exportieren:** Schlüsselbundverwaltung → *Meine Zertifikate* → „Apple Development: …“ →
   Rechtsklick → *Exportieren …* → `.p12` mit Passwort, z. B. auf den Schreibtisch.
2. Die beiden Dateien des Update-Kanals (`ios-update.key`, `ios-update.key.password`) nach `~/Downloads` legen.
3. Einmal ausführen (am besten mit GitHub-CLI: `brew install gh && gh auth login`):

   ```bash
   bash scripts/ios/ci-secrets.sh --p12 ~/Desktop/<datei>.p12
   ```

   Das Skript sucht das Profil, das Xcode beim ▶ Run angelegt hat (dein iPhone steht darin), setzt alle Secrets
   (`IOS_CERTIFICATE_*`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_UPDATE_SIGNING_KEY*`) und startet den ersten Build.
   Ohne GitHub-CLI legt es die Werte in `~/TRS-CI-Secrets` ab und sagt, wo sie eingetragen werden.
4. Ist der Build durch (Actions → iOS app), bietet die App auf dem iPhone das Update an – ab dann jedes neue.

Läuft das Profil ab (nach einem Jahr) oder kommt ein neues Gerät dazu: in Xcode einmal ▶ Run, dann Schritt 3 wiederholen.

### Beta-Versionen

Pushes auf den Branch **`beta`** landen im Release **`ios-beta`** (auch von Hand: *Run workflow* → *publish* →
Kanal `ios-beta`). In der App unter **Einstellungen → Verhalten → Beta-Versionen** einschalten: Sie prüft dann
beide Releases und bietet die neuere Version an – ist `main` weiter, wieder die normale.

### Einmalig einrichten: Signier-Schlüssel für den Update-Kanal

Damit niemand der App ein falsches Update unterschieben kann, ist `mobile.json` signiert. Der öffentliche
Schlüssel steckt in der App (`src-tauri/gen/apple/UpdateChannel.xcconfig`, `update-public-key.txt`); den privaten
legst du als Secret an – `scripts/ios/ci-secrets.sh` erledigt das mit, von Hand unter
**Settings → Secrets and variables → Actions**:

| Secret | Inhalt |
|---|---|
| `IOS_UPDATE_SIGNING_KEY` | Inhalt der Datei `ios-update.key` |
| `IOS_UPDATE_SIGNING_KEY_PASSWORD` | Inhalt der Datei `ios-update.key.password` |

Ohne diese Secrets baut alles weiter, nur meldet die App keine Updates. Eigenen Schlüssel statt des mitgelieferten:
`pnpm tauri signer generate -w ios-update.key`, dann den öffentlichen Schlüssel in `update-public-key.txt` **und**
`TRS_UPDATE_PUBKEY` (UpdateChannel.xcconfig) eintragen.

## Widget, Live-Aktivität, Kurzbefehle und Siri

- **Widget „Zuletzt gespielt“** (ab iOS 17; Home-Bildschirm lange drücken → **+** → TRS Launcher): zeigt die zuletzt
  gespielte Instanz, ein Tipp startet sie. Die Liste teilt die App über die App-Gruppe `group.<Team-ID>.trslauncher`
  (`TRS_APP_GROUP` in `Signing.xcconfig`); ohne App-Gruppe öffnet das Widget nur den Launcher.
- **Live-Aktivität** (ab iOS 16.2): Downloads, Installationen und Spielstarts, die länger als drei Sekunden dauern,
  zeigen ihren Fortschritt auf dem Sperrbildschirm und in der Dynamic Island. Abschalten: Einstellungen → TRS Launcher →
  Live-Aktivitäten.
- **Kurzbefehle und Siri** (ab iOS 17): „Starte TRS Launcher“ bzw. „Spiele Minecraft mit TRS Launcher“ startet die
  zuletzt gespielte Instanz, „Instanz starten“ (Kurzbefehle-App) eine gewählte. Kurzbefehle und Widget öffnen dafür
  `trs-launcher://play/<Instanz>` mit einem Schlüssel dieser Installation – Links von Websites zeigen nur die Instanz.

Signiert mit eigenem Profil (`sign-ipa.sh`, OTA-Updates): Ein **Wildcard-Profil** signiert das Widget mit; ein Profil
nur für die App-ID lässt die Erweiterung weg (die App läuft dann ohne Widget und Live-Aktivität).

## Sicherung und iCloud Drive

**Einstellungen → Sicherung** packt Einstellungen, alle Instanzen (Welten, Mods, Spieleinstellungen, Ressourcen- und
Shaderpakete, Screenshots), Skins, Presets und die Touch-Steuerung in eine Datei `TRS-Launcher_<Datum>.trsbackup`.
Anmeldungen bleiben draußen, sie sind an dieses Gerät gebunden. Spielversionen, Bibliotheken und Java fehlen ebenfalls,
die lädt der Launcher selbst neu. Mit **Täglich automatisch sichern** entsteht einmal am Tag eine Sicherung (beim Start
bzw. wenn die App wieder nach vorn kommt, nie während Minecraft läuft); die letzten drei bleiben.

- **Ohne weitere Einrichtung** liegen Sicherungen in der Dateien-App unter *Auf meinem iPhone › TRS Launcher ›
  Backups* und damit auch im iCloud-Backup des Geräts. **Teilen → In Dateien sichern** legt eine Sicherung zusätzlich
  in iCloud Drive ab.
- **Direkt in iCloud Drive** (*iCloud Drive › TRS Launcher › Backups*, auf jedem Gerät mit derselben Apple-ID) geht
  das nur mit bezahltem Apple-Developer-Account. Einmal `bash scripts/ios/mac-setup.sh --icloud` ausführen, dann
  ▶ Run. Xcode legt den iCloud-Container selbst an. Zurück geht es mit `--no-icloud`.
- **Wiederherstellen:** in der Liste auf **Wiederherstellen** tippen oder eine `.trsbackup`-Datei in der Dateien-App
  öffnen (**Öffnen in TRS Launcher**). Instanzen aus der Sicherung ersetzen die mit derselben ID, andere bleiben
  unberührt. Danach lädt der Launcher neu.

## Akku beim Spielen

**Einstellungen → Verhalten → Akku beim Spielen** legt fest, wie viel Strom Minecraft zieht:

| Stufe | Auflösung | FPS | Sichtweite |
| --- | --- | --- | --- |
| Volle Leistung | 100 % der Bildschirmpixel | wie im Spiel eingestellt | wie im Spiel eingestellt |
| **Ausgewogen** (ab Werk) | 75 % | höchstens 60 | wie im Spiel eingestellt |
| Akku sparen | 50 % | höchstens 30 | höchstens 6 Chunks (Simulation 5) |

Im **Stromsparmodus** von iOS spart „Ausgewogen“ wie „Akku sparen“ – die Auflösung wechselt sofort, auch mitten im
Spiel; FPS und Sichtweite gelten ab dem nächsten Start. FPS-Grenze und Sichtweite schreibt der Launcher beim Start in
die `options.txt` der Instanz und senkt sie dabei nur (höhere Werte stellst du im Spiel wieder ein, „Volle Leistung“
lässt sie in Ruhe). Die Kamera dreht sich bei jeder Auflösung gleich schnell.

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
