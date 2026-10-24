# Abgleich mit theredstonee/TRS-Launcher

Dieses Repo ist die iOS-Fassung von [theredstonee/TRS-Launcher](https://github.com/theredstonee/TRS-Launcher). Neue
Versionen von dort kommen **automatisch** herein: Eine geplante Claude-Routine prüft jeden Tag, ob `main` von upstream
weiter ist, übernimmt die neuen Commits, prüft alles, öffnet einen Pull Request und führt ihn zusammen, sobald der CI
grün ist. Der Push auf `main` baut dann die iOS-App (Release `ios-latest`); aufs iPhone kommt sie von selbst – mit
bezahltem Apple-Account über die App, mit kostenlosem über den Mac (`scripts/ios/auto-update-mac.sh`, IOS.md →
Automatische Updates).

Von Hand geht derselbe Ablauf genauso (Abschnitt „Ablauf“).

## Wie übernommen wird

- **Einzelne Commits, nicht die Geschichte:** Die Geschichte von upstream ist zu groß für dieses Repo. Übernommen wird
  per `git cherry-pick -x` (die Herkunft steht in jeder Commit-Nachricht), Merge-Commits von upstream werden
  übersprungen.
- **Stand:** `.github/upstream-sync` nennt den letzten übernommenen Upstream-Commit. Nur `scripts/upstream/sync.sh`
  schreibt die Datei.
- **Changelog:** `CHANGELOG.md` ist immer die Fassung von upstream plus die eigenen iOS-Punkte oben unter
  „## Unreleased“ (`scripts/upstream/changelog.py`). Die Release-Abschnitte müssen exakt upstream entsprechen.
- **Lockfiles und Xcode-Projekt** erzeugt das Skript neu (`cargo metadata`, bei Bedarf `pnpm install --lockfile-only`,
  `ruby scripts/ios/generate-xcodeproj.rb` – die Version steckt im Projekt).

## Ablauf

```bash
git fetch origin main && git checkout -B claude/upstream-sync origin/main
bash scripts/upstream/sync.sh --check     # Exit 0 = nichts Neues, 10 = neue Commits (Liste)
bash scripts/upstream/sync.sh             # übernehmen; Exit 2 = Konflikt (siehe unten)
```

Danach prüfen (wie ein Beitrag, siehe CONTRIBUTING.md):

```bash
cd src-tauri && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace && cd ..
pnpm install --frozen-lockfile && pnpm test && pnpm typecheck
```

Dann pushen und einen Pull Request gegen `main` öffnen (Titel „Upstream <Version> übernehmen“, im Text die
übernommenen Commits). Merge-Methode **Merge-Commit** (nicht Squash – die einzelnen `cherry picked from`-Zeilen
bleiben so sichtbar). Nach dem Merge den Branch `claude/ios-xcode-signierbar` auf `main` vorspulen
(`git push origin origin/main:claude/ios-xcode-signierbar`).

## Konflikte

`CHANGELOG.md`, `src-tauri/Cargo.lock` und `pnpm-lock.yaml` löst das Skript selbst. Bei allen anderen Dateien hält es
an (Exit 2) und nennt sie. Regel: **beide Seiten behalten** – die Änderung von upstream übernehmen und die iOS-Anpassung
dieses Repos darin erhalten. Danach `git add <dateien>` und `bash scripts/upstream/sync.sh --continue`.

Wo dieses Repo von upstream abweicht (dort sind Konflikte zu erwarten):

| Bereich | Was hier anders ist |
| --- | --- |
| `src-tauri/gen/apple/`, `scripts/ios/`, `IOS.md` | Xcode-Projekt, Widget, Signieren, Engine-Einbindung – gibt es nur hier |
| `src-tauri/plugins/tauri-plugin-trs-ios/`, `src-tauri/src/{backup,shortcuts,crash_report,deeplink,mobile_game,mobile}.rs` | iOS-Funktionen (Sicherung, Kurzbefehle, Absturzberichte, Öffnen-in, Akku-Plan, Updates) |
| `src-tauri/crates/core/` (`backup.rs`, `mobile_profile.rs`, `mobile_launch.rs`, `settings.rs`, `mobile_update.rs`) | Sicherung, Leistungs-/Akku-Profil, eigener Update-Kanal |
| `src-tauri/plugins/tauri-plugin-trs-game/` | Auflösung/FPS-Grenze der iOS-Engine (`renderPercent`, `maxFps`) |
| `app/` (Einstellungen, `MobileUpdateBanner.vue`, `BackupPanel.vue`, Locales en/de/es) | Oberfläche der iOS-Funktionen |
| `.github/workflows/ios-*.yml` | iOS-Builds und Releases `ios-latest`/`ios-beta`/`ios-engine` |
| `client-mod/common/…/ShareTest.java` | Test robuster (`not_allowed` oder `closed` beim Abweisen) |

Ganz genau zeigt es `git diff <Stand aus .github/upstream-sync> origin/main -- <datei>`: Das ist die eigene Änderung,
die nach dem Konflikt wieder drin sein muss. Steckt in einem Konflikt eine echte Entscheidung (beide Seiten ändern
dieselbe Logik verschieden), den Pull Request als Entwurf lassen und im Text beschreiben, was zu entscheiden ist.

Wird ein Test durch upstream rot, gilt: Ursache finden und beheben (in der eigenen Anpassung oder, wenn upstream selbst
rot ist, mit einem kleinen Fix, der im PR-Text erklärt wird) – nie einen Test abschalten.

## Die Routine

Die tägliche Claude-Routine („TRS Upstream-Abgleich“) arbeitet genau diese Datei ab. Ändern, pausieren oder löschen:
claude.ai → Routinen. Ohne neue Upstream-Commits endet sie sofort.
