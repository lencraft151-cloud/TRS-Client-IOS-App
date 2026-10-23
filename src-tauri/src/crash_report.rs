//! Absturzberichte (iOS): Rust-Panics, iOS-Abstürze und Hänger (MetricKit über das Plugin trs-ios), Ausfälle beim Start
//! und „Oberfläche lädt nicht“ landen als Textdatei in `Dokumente/Crash Reports`. Die Dateien-App zeigt den Ordner –
//! auch dann, wenn die Oberfläche nie erscheint. Beim nächsten Start zeigt die Oberfläche neue Berichte (Teilen,
//! Kopieren).
//!
//! Format (dasselbe schreibt `CrashReporter.swift`): Kopfzeilen `Art:`, `Zeit:`, `Titel:` …, eine Zeile `---`, Text.
//!
//! Startverlauf: `.running` im Ordner hält fest, wie weit der Start kam (`start` → `setup` → `ui`; `game`, solange das
//! Spiel läuft – dessen Ende beendet auf iOS die App). Im Hintergrund ist die Datei weg. Liegt sie beim nächsten Start
//! noch mit `start`/`setup` da, endete der letzte Start unterwegs – das wird ein Bericht der Art `unclean`.
//!
//! Desktop und Android: kein Ordner, die Befehle liefern nichts (die Logik ist dort nur in Tests im Einsatz).
#![cfg_attr(not(target_os = "ios"), allow(dead_code))]

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use tauri::AppHandle;

use crate::error::CommandResult;

pub const DIR_NAME: &str = "Crash Reports";
const MARKER: &str = ".running";
const SEEN: &str = ".seen.json";
/// So viele Berichte bleiben liegen; ältere löscht der nächste Start.
const KEEP: usize = 30;
/// Mehr Text eines Berichts geht nicht an die Oberfläche (die Datei bleibt ganz).
const MAX_TEXT: u64 = 64 * 1024;
/// Ende des App-Logs in Panic-Berichten.
const LOG_TAIL: u64 = 24 * 1024;

/// Wie weit der Start kam.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    /// Prozess läuft, Rust startet Tauri.
    Start,
    /// Rust-Kern eingerichtet, die Oberfläche lädt.
    Setup,
    /// Oberfläche hat sich gemeldet.
    Ui,
    /// Spiel läuft (sein Ende beendet die App – kein Absturz).
    Game,
}

impl Stage {
    fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Setup => "setup",
            Self::Ui => "ui",
            Self::Game => "game",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "start" => Some(Self::Start),
            "setup" => Some(Self::Setup),
            "ui" => Some(Self::Ui),
            "game" => Some(Self::Game),
            _ => None,
        }
    }
}

/// Ein Bericht für die Oberfläche.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CrashReport {
    /// Dateiname.
    pub id: String,
    /// `panic`, `ios`, `hang`, `unclean`, `boot`.
    pub kind: String,
    /// RFC 3339 (UTC).
    pub time: Option<String>,
    pub title: String,
    /// Ganzer Bericht (höchstens 64 KB).
    pub text: String,
    pub seen: bool,
}

static DIR: OnceLock<PathBuf> = OnceLock::new();
static STAGE: Mutex<Option<Stage>> = Mutex::new(None);

/// Ordner der Berichte – nur auf iOS gesetzt.
pub fn dir() -> Option<&'static Path> {
    DIR.get().map(PathBuf::as_path)
}

/// Ganz am Anfang von `run()`: letzten Start prüfen, Panic-Hook setzen, Startverlauf beginnen. Nur iOS.
pub fn init() {
    #[cfg(target_os = "ios")]
    if let Some(home) = std::env::var_os("HOME") {
        let dir = PathBuf::from(home).join("Documents").join(DIR_NAME);
        if DIR.set(dir.clone()).is_ok() {
            startup(&dir);
        }
    }
}

fn startup(dir: &Path) {
    if let Err(e) = std::fs::create_dir_all(dir) {
        eprintln!("Absturzberichte: Ordner nicht anlegbar: {e}");
        return;
    }
    check_previous(dir);
    prune(dir, KEEP);
    install_panic_hook();
    mark(Stage::Start);
}

/// Startverlauf weiterschreiben (`.running`).
pub fn mark(stage: Stage) {
    if let Ok(mut current) = STAGE.lock() {
        *current = Some(stage);
    }
    if let Some(dir) = dir() {
        write_marker(dir, stage);
    }
}

/// App im Hintergrund: Wird sie dort beendet, ist das kein Absturz.
pub fn suspended() {
    if let Some(dir) = dir() {
        let _ = std::fs::remove_file(dir.join(MARKER));
    }
}

/// Wieder vorn: letzten Stand zurückschreiben.
pub fn resumed() {
    let stage = STAGE.lock().ok().and_then(|s| *s);
    if let (Some(dir), Some(stage)) = (dir(), stage) {
        write_marker(dir, stage);
    }
}

fn write_marker(dir: &Path, stage: Stage) {
    let text = format!(
        "stage={}\nsince={}\npid={}\nversion={}\n",
        stage.as_str(),
        now(),
        std::process::id(),
        trs_core::mobile_update::installed_version()
    );
    let _ = std::fs::write(dir.join(MARKER), text);
}

/// Endete der letzte Start, bevor die Oberfläche da war? Dann ein Bericht `unclean`.
fn check_previous(dir: &Path) {
    let Ok(marker) = std::fs::read_to_string(dir.join(MARKER)) else { return };
    let _ = std::fs::remove_file(dir.join(MARKER));
    let stage = marker.lines().find_map(|l| l.strip_prefix("stage=")).and_then(Stage::parse);
    let title = match stage {
        Some(Stage::Start) => "Start abgebrochen, bevor der App-Kern bereit war",
        Some(Stage::Setup) => "Start abgebrochen, bevor die Oberfläche erschien",
        // Danach: echte Abstürze meldet iOS (MetricKit); ein Stopp aus Xcode ist kein Bericht wert.
        _ => return,
    };
    let body = format!(
        "Die App wurde beim letzten Start beendet, bevor die Oberfläche bereit war – abgestürzt, von iOS beendet \
         (z. B. Watchdog) oder aus Xcode gestoppt. Einen genaueren iOS-Bericht liefert iOS meist beim nächsten Start nach.\n\n\
         --- Startverlauf ---\n{marker}"
    );
    if let Err(e) = write_report(dir, "unclean", title, &body) {
        eprintln!("Absturzberichte: {e}");
    }
}

fn install_panic_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(dir) = dir() {
            let message = info
                .payload()
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| info.payload().downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "(keine Meldung)".into());
            let location = info.location().map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column())).unwrap_or_default();
            let thread = std::thread::current().name().unwrap_or("?").to_owned();
            let backtrace = std::backtrace::Backtrace::force_capture();
            let body = format!(
                "Rust-Panic im Thread „{thread}“\n{message}\nOrt: {location}\n\n--- Aufrufstapel ---\n{backtrace}\n\n--- App-Log (Ende) ---\n{}",
                log_tail()
            );
            let title: String = message.lines().next().unwrap_or_default().chars().take(200).collect();
            let _ = write_report(dir, "panic", &title, &body);
        }
        previous(info);
    }));
}

/// Ende der neuesten Log-Datei unter `~/Library/Logs` (Tauri-Log-Plugin).
fn log_tail() -> String {
    let Some(home) = std::env::var_os("HOME") else { return "(kein Log)".into() };
    let logs = PathBuf::from(home).join("Library").join("Logs");
    let newest = newest_log(&logs, 2);
    let Some(path) = newest else { return "(kein Log)".into() };
    tail(&path, LOG_TAIL).unwrap_or_else(|| "(Log nicht lesbar)".into())
}

fn newest_log(dir: &Path, depth: u8) -> Option<PathBuf> {
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        let candidate = if path.is_dir() {
            if depth == 0 {
                continue;
            }
            newest_log(&path, depth - 1)
        } else if path.extension().is_some_and(|e| e == "log") {
            Some(path)
        } else {
            None
        };
        let Some(candidate) = candidate else { continue };
        let modified = std::fs::metadata(&candidate).and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
        if best.as_ref().is_none_or(|(t, _)| modified > *t) {
            best = Some((modified, candidate));
        }
    }
    best.map(|(_, p)| p)
}

/// Letzte `max` Byte einer Datei (an einer Zeilengrenze begonnen).
fn tail(path: &Path, max: u64) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let start = len.saturating_sub(max);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    Some(if start > 0 { text.split_once('\n').map_or(text.clone(), |(_, rest)| rest.to_owned()) } else { text })
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Schreibt einen Bericht (Format wie `CrashReporter.swift`).
pub fn write_report(dir: &Path, kind: &str, title: &str, body: &str) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
    let mut path = dir.join(format!("{kind}-{stamp}.txt"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{kind}-{stamp}-{n}.txt"));
        n += 1;
    }
    let device = match (std::env::var("TRS_DEVICE_MODEL"), std::env::var("TRS_OS_VERSION")) {
        (Ok(model), Ok(os)) => format!("{model} · iOS {os}"),
        _ => "?".into(),
    };
    let text = format!(
        "TRS Launcher – Absturzbericht\nArt: {kind}\nZeit: {}\nTitel: {}\nVersion: {}\nGerät: {device}\n---\n{body}\n",
        now(),
        title.replace('\n', " "),
        trs_core::mobile_update::installed_version(),
    );
    std::fs::write(&path, text)?;
    Ok(path)
}

/// Kopfzeilen eines Berichts: Art, Zeit, Titel.
fn parse_header(text: &str) -> (Option<String>, Option<String>, Option<String>) {
    let (mut kind, mut time, mut title) = (None, None, None);
    for line in text.lines().take(20) {
        if line == "---" {
            break;
        }
        if let Some(v) = line.strip_prefix("Art: ") {
            kind = Some(v.trim().to_owned());
        } else if let Some(v) = line.strip_prefix("Zeit: ") {
            time = Some(v.trim().to_owned());
        } else if let Some(v) = line.strip_prefix("Titel: ") {
            title = Some(v.trim().to_owned());
        }
    }
    (kind, time, title)
}

fn read_seen(dir: &Path) -> Vec<String> {
    std::fs::read(dir.join(SEEN)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// Berichtsdateien, neueste zuerst (nach Dateiname: `<art>-<zeit>.txt` – also nach Zeit innerhalb der Art; über alle
/// Arten sortiert erst [`list`] nach der Zeit im Kopf).
fn report_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "txt") && p.is_file())
        .map(|p| (std::fs::metadata(&p).and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH), p))
        .collect();
    files.sort_by_key(|f| std::cmp::Reverse(f.0));
    files.into_iter().map(|(_, p)| p).collect()
}

/// Alle Berichte, neueste zuerst.
pub fn list(dir: &Path) -> Vec<CrashReport> {
    let seen = read_seen(dir);
    let mut reports: Vec<CrashReport> = report_files(dir)
        .into_iter()
        .filter_map(|path| {
            let id = path.file_name()?.to_str()?.to_owned();
            let mut bytes = Vec::new();
            std::fs::File::open(&path).ok()?.take(MAX_TEXT).read_to_end(&mut bytes).ok()?;
            // Verlustbehaftet: Der Schnitt bei 64 KB kann mitten in einem Zeichen liegen.
            let text = String::from_utf8_lossy(&bytes).into_owned();
            let (kind, time, title) = parse_header(&text);
            Some(CrashReport {
                seen: seen.contains(&id),
                kind: kind.unwrap_or_else(|| "unknown".into()),
                title: title.unwrap_or_else(|| id.clone()),
                id,
                time,
                text,
            })
        })
        .collect();
    reports.sort_by_key(|r| std::cmp::Reverse(r.time.clone()));
    reports
}

/// Diese Berichte nicht mehr als neu zeigen.
pub fn mark_seen(dir: &Path, ids: &[String]) -> std::io::Result<()> {
    let mut seen = read_seen(dir);
    for id in ids {
        if valid_id(id) && !seen.contains(id) {
            seen.push(id.clone());
        }
    }
    // Nur Namen behalten, die es noch gibt.
    seen.retain(|id| dir.join(id).is_file());
    std::fs::write(dir.join(SEEN), serde_json::to_vec(&seen).unwrap_or_default())
}

/// Nur die neuesten `keep` Berichte behalten.
fn prune(dir: &Path, keep: usize) {
    for old in report_files(dir).into_iter().skip(keep) {
        let _ = std::fs::remove_file(old);
    }
}

/// Ein Dateiname aus dem Ordner – keine Pfade.
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.ends_with(".txt") && !id.starts_with('.') && Path::new(id).file_name().and_then(|n| n.to_str()) == Some(id)
}

// --- Befehle ----------------------------------------------------------------------------------

/// Alle Berichte (leer, wo es keine gibt – Desktop, Android).
#[tauri::command]
pub fn crash_reports() -> Vec<CrashReport> {
    dir().map(list).unwrap_or_default()
}

#[tauri::command]
pub fn crash_reports_seen(ids: Vec<String>) -> CommandResult<()> {
    if let Some(dir) = dir() {
        mark_seen(dir, &ids).map_err(|e| trs_core::Error::Internal(format!("Absturzberichte: {e}")))?;
    }
    Ok(())
}

/// Teilen-Menü (iOS) für einen Bericht.
#[tauri::command]
pub async fn crash_report_share(app: AppHandle, id: String) -> CommandResult<()> {
    let path = dir().filter(|_| valid_id(&id)).map(|d| d.join(&id)).filter(|p| p.is_file());
    let Some(path) = path else {
        return Err(trs_core::Error::validation(trs_core::msg!("crashReport.notFound", "Den Bericht gibt es nicht mehr.")).into());
    };
    share(&app, path).await
}

#[cfg(target_os = "ios")]
async fn share(app: &AppHandle, path: PathBuf) -> CommandResult<()> {
    use tauri_plugin_trs_ios::TrsIosExt;
    let app = app.clone();
    let paths = vec![path.display().to_string()];
    tauri::async_runtime::spawn_blocking(move || app.trs_ios().share(&paths))
        .await
        .map_err(|e| trs_core::Error::Internal(e.to_string()))?
        .map_err(|e| trs_core::Error::Internal(format!("Teilen: {e}")))?;
    Ok(())
}

#[cfg(not(target_os = "ios"))]
async fn share(_app: &AppHandle, _path: PathBuf) -> CommandResult<()> {
    Err(trs_core::Error::validation(trs_core::msg!("crashReport.shareUnsupported", "Teilen gibt es hier nicht – kopiere den Bericht.")).into())
}

/// Die Oberfläche ist geladen: Startverlauf `ui`, Start-Wächter aus.
#[tauri::command]
pub async fn ui_ready(app: AppHandle) {
    mark(Stage::Ui);
    #[cfg(target_os = "ios")]
    {
        use tauri_plugin_trs_ios::TrsIosExt;
        let result = tauri::async_runtime::spawn_blocking(move || app.trs_ios().ui_ready()).await;
        if let Ok(Err(e)) = result {
            log::warn!("Start-Wächter nicht erreichbar: {e}");
        }
    }
    #[cfg(not(target_os = "ios"))]
    let _ = app;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("trs-crash-{}-{}", std::process::id(), uuid_like()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn uuid_like() -> u128 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    }

    #[test]
    fn writes_and_lists_reports_newest_first() {
        let dir = temp();
        write_report(&dir, "panic", "Index außerhalb", "Text 1").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        write_report(&dir, "ios", "EXC_BREAKPOINT / SIGTRAP", "Text 2").unwrap();
        let reports = list(&dir);
        assert_eq!(reports.len(), 2);
        assert_eq!(reports[0].kind, "ios");
        assert_eq!(reports[0].title, "EXC_BREAKPOINT / SIGTRAP");
        assert!(reports[0].text.contains("Text 2"));
        assert!(reports[0].time.as_deref().is_some_and(|t| t.ends_with('Z')));
        assert_eq!(reports[1].kind, "panic");
        assert!(!reports[0].seen);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn reads_reports_written_by_swift() {
        let dir = temp();
        let text = "TRS Launcher – Absturzbericht\nArt: hang\nZeit: 2026-10-23T08:00:00Z\nTitel: Hänger 3.2 s\nVersion: 0.27.1 (5)\n\
                    Gerät: iPhone14,4 · iOS 27.2\n---\nDie App reagierte 3.2 s lang nicht.\n";
        std::fs::write(dir.join("hang-20261023-080000.txt"), text).unwrap();
        let reports = list(&dir);
        assert_eq!(reports[0].kind, "hang");
        assert_eq!(reports[0].time.as_deref(), Some("2026-10-23T08:00:00Z"));
        assert_eq!(reports[0].title, "Hänger 3.2 s");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn marks_reports_as_seen_and_forgets_deleted_ones() {
        let dir = temp();
        let path = write_report(&dir, "panic", "x", "y").unwrap();
        let id = path.file_name().unwrap().to_str().unwrap().to_owned();
        mark_seen(&dir, &[id.clone(), "../etc/passwd".into(), "gibt-es-nicht.txt".into()]).unwrap();
        assert!(list(&dir)[0].seen);
        assert_eq!(read_seen(&dir), vec![id]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn unclean_start_becomes_a_report_but_not_after_the_ui_or_during_the_game() {
        let dir = temp();
        std::fs::write(dir.join(MARKER), "stage=setup\nsince=2026-10-23T08:00:00Z\n").unwrap();
        check_previous(&dir);
        let reports = list(&dir);
        assert_eq!(reports.len(), 1);
        assert_eq!(reports[0].kind, "unclean");
        assert!(reports[0].text.contains("stage=setup"));
        assert!(!dir.join(MARKER).exists());

        for stage in ["ui", "game"] {
            std::fs::write(dir.join(MARKER), format!("stage={stage}\n")).unwrap();
            check_previous(&dir);
            assert_eq!(list(&dir).len(), 1, "kein Bericht für {stage}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn keeps_only_the_newest_reports() {
        let dir = temp();
        for i in 0..5 {
            write_report(&dir, &format!("k{i}"), "t", "b").unwrap();
        }
        prune(&dir, 3);
        assert_eq!(report_files(&dir).len(), 3);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn ids_are_plain_report_names() {
        assert!(valid_id("panic-20261023-080000.txt"));
        assert!(!valid_id("../x.txt"));
        assert!(!valid_id("a/b.txt"));
        assert!(!valid_id(".seen.json"));
        assert!(!valid_id(".running"));
        assert!(!valid_id(""));
    }

    #[test]
    fn tail_starts_at_a_line() {
        let dir = temp();
        let file = dir.join("app.log");
        std::fs::write(&file, "erste Zeile\nzweite Zeile\ndritte Zeile\n").unwrap();
        assert_eq!(tail(&file, 1024).unwrap(), "erste Zeile\nzweite Zeile\ndritte Zeile\n");
        assert_eq!(tail(&file, 15).unwrap(), "dritte Zeile\n");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
