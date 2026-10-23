//! Sicherung und Wiederherstellung (Einstellungen → Sicherung, `.trsbackup` aus der Dateien-App). Was in einer
//! Sicherung steckt, regelt [`trs_core::backup`]; hier geht es darum, wohin sie kommt, um die tägliche automatische
//! Sicherung und darum, die Einstellungen nach dem Wiederherstellen zu übernehmen.
//!
//! Orte (iOS, vom Plugin trs-ios): `iCloud Drive › TRS Launcher › Backups`, wenn die App das iCloud-Entitlement hat
//! und iCloud angemeldet ist, sonst `Auf meinem iPhone › TRS Launcher › Backups` (Dateien-App; liegt mit im
//! iCloud-Backup des Geräts). Andere Systeme: `<daten>/launcher-backups` (die Oberfläche zeigt den Bereich dort nicht).
#![cfg_attr(not(target_os = "ios"), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::Serialize;
use tauri::ipc::Channel;
use tauri::{AppHandle, Emitter, Manager, State};
use trs_core::Launcher;
use trs_core::backup::{self, BackupFile, CreateOptions};

use crate::LauncherState;
use crate::commands::tasks::tracked;
use crate::error::CommandResult;

/// So viele automatische Sicherungen bleiben je Ort.
const KEEP_AUTOMATIC: usize = 3;
/// Automatisch höchstens so oft.
const AUTO_INTERVAL: chrono::Duration = chrono::Duration::hours(24);
/// Nach dem Start erst warten – der Start soll nicht langsamer werden.
const AUTO_DELAY: Duration = Duration::from_secs(90);
/// So lange darf das Laden einer Sicherung aus iCloud dauern.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(15 * 60);

static AUTO_RUNNING: AtomicBool = AtomicBool::new(false);

/// Über „Öffnen in TRS Launcher“ geöffnete Sicherung: wartet auf die Oberfläche; danach darf genau diese Datei
/// wiederhergestellt werden (sie liegt im temporären Ordner, nicht an einem der Sicherungsorte).
#[derive(Default)]
pub struct OpenedBackups {
    pending: Mutex<Option<PathBuf>>,
    allowed: Mutex<Vec<PathBuf>>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Places {
    pub local: Option<PathBuf>,
    pub icloud: Option<PathBuf>,
}

impl Places {
    /// Hierhin kommen neue Sicherungen.
    fn target(&self) -> Option<&Path> {
        self.icloud.as_deref().or(self.local.as_deref())
    }

    fn dirs(&self) -> impl Iterator<Item = (&Path, bool)> {
        self.icloud.iter().map(|d| (d.as_path(), true)).chain(self.local.iter().map(|d| (d.as_path(), false)))
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    #[serde(flatten)]
    pub file: BackupFile,
    /// Liegt in iCloud Drive.
    pub icloud: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    pub places: Places,
    pub backups: Vec<Entry>,
    /// Ungefähre Größe einer neuen Sicherung (vor dem Packen).
    pub estimate: u64,
    pub last_automatic: Option<DateTime<Utc>>,
}

#[cfg(target_os = "ios")]
async fn places(app: &AppHandle, _launcher: &Launcher) -> Places {
    use tauri_plugin_trs_ios::TrsIosExt;
    let handle = app.clone();
    match tauri::async_runtime::spawn_blocking(move || handle.trs_ios().backup_dirs()).await {
        Ok(Ok(dirs)) => Places { local: dirs.local, icloud: dirs.icloud },
        Ok(Err(e)) => {
            log::warn!("Sicherungsordner unbekannt: {e}");
            Places::default()
        }
        Err(e) => {
            log::warn!("Sicherungsordner unbekannt: {e}");
            Places::default()
        }
    }
}

#[cfg(not(target_os = "ios"))]
async fn places(_app: &AppHandle, launcher: &Launcher) -> Places {
    Places { local: Some(launcher.paths().root().join("launcher-backups")), icloud: None }
}

fn device() -> String {
    std::env::var("TRS_DEVICE_MODEL").unwrap_or_else(|_| std::env::consts::OS.to_owned())
}

fn not_found() -> trs_core::Error {
    trs_core::Error::validation(trs_core::msg!("backup.notFound", "Diese Sicherung gibt es nicht mehr."))
}

/// Pfad aus der Oberfläche prüfen: nur Sicherungen an einem der Orte oder eine gerade geöffnete Datei.
fn checked(places: &Places, opened: Option<&OpenedBackups>, path: &str) -> trs_core::Result<(PathBuf, bool)> {
    let path = PathBuf::from(path);
    let name_ok = path.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
        !n.starts_with('.') && n.ends_with(&format!(".{}", backup::EXTENSION)) && !n.contains(['/', '\\'])
    });
    if !name_ok {
        return Err(not_found());
    }
    if let Some((_, icloud)) = places.dirs().find(|(dir, _)| path.parent() == Some(*dir)) {
        return Ok((path, icloud));
    }
    let opened_ok = opened.is_some_and(|o| o.allowed.lock().unwrap_or_else(std::sync::PoisonError::into_inner).contains(&path));
    if opened_ok { Ok((path, false)) } else { Err(not_found()) }
}

/// iCloud-Platzhalter neben `path` (`.<name>.icloud`).
fn placeholder(path: &Path) -> Option<PathBuf> {
    let name = path.file_name()?.to_str()?;
    Some(path.with_file_name(format!(".{name}.icloud")))
}

fn entry(file: BackupFile, icloud: bool) -> Entry {
    Entry { file, icloud }
}

/// Liste, Orte, Größe einer neuen Sicherung.
#[tauri::command]
pub async fn backup_overview(app: AppHandle, launcher: State<'_, LauncherState>) -> CommandResult<Overview> {
    let places = places(&app, &launcher).await;
    let instances = launcher.instances().list().await?;
    let estimate = backup::estimate(launcher.paths(), &instances).await;
    let scan = places.clone();
    let (backups, last_automatic) = tauri::async_runtime::spawn_blocking(move || {
        let mut all = Vec::new();
        let mut last = None;
        for (dir, icloud) in scan.dirs() {
            all.extend(backup::list(dir).into_iter().map(|f| entry(f, icloud)));
            last = last.max(backup::last_automatic(dir));
        }
        let created = |e: &Entry| e.file.manifest.as_ref().map(|m| m.created).or(e.file.modified);
        all.sort_by_key(|e| std::cmp::Reverse(created(e)));
        (all, last)
    })
    .await
    .map_err(|e| trs_core::Error::Internal(e.to_string()))?;
    Ok(Overview { places, backups, estimate, last_automatic })
}

async fn create(app: &AppHandle, launcher: &Launcher, automatic: bool, on_progress: impl Fn(u8) + Send + 'static) -> trs_core::Result<Entry> {
    let places = places(app, launcher).await;
    let Some(target) = places.target().map(Path::to_path_buf) else {
        return Err(trs_core::Error::validation(trs_core::msg!("backup.noPlace", "Kein Ort für Sicherungen gefunden.")));
    };
    let icloud = places.icloud.as_deref() == Some(target.as_path());
    let instances = launcher.instances().list().await?;
    let options = CreateOptions { app_version: trs_core::LAUNCHER_VERSION.to_owned(), device: device(), automatic };
    let path = backup::create(launcher.paths(), &instances, &target, options, on_progress).await?;
    if automatic {
        let dirs: Vec<PathBuf> = places.dirs().map(|(d, _)| d.to_owned()).collect();
        let _ = tauri::async_runtime::spawn_blocking(move || {
            for dir in dirs {
                backup::prune_automatic(&dir, KEEP_AUTOMATIC);
            }
        })
        .await;
    }
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    let file = BackupFile {
        file_name: path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned(),
        manifest: backup::read_manifest(&path).ok(),
        modified: Some(Utc::now()),
        size,
        downloaded: true,
        path,
    };
    let _ = app.emit("backup-changed", ());
    Ok(entry(file, icloud))
}

/// Jetzt sichern (an den bevorzugten Ort).
#[tauri::command]
pub async fn backup_create(
    app: AppHandle,
    launcher: State<'_, LauncherState>,
    on_progress: Channel<u8>,
    task_id: Option<String>,
) -> CommandResult<Entry> {
    let work = create(&app, &launcher, false, move |p| {
        let _ = on_progress.send(p);
    });
    Ok(tracked(&app, task_id, work).await?)
}

/// Liegt die Sicherung nur in iCloud, erst laden (abbrechbar).
async fn ensure_local(app: &AppHandle, path: &Path) -> trs_core::Result<()> {
    if backup::read_manifest(path).is_ok() {
        return Ok(());
    }
    #[cfg(target_os = "ios")]
    {
        use tauri_plugin_trs_ios::TrsIosExt;
        let (handle, file) = (app.clone(), path.to_owned());
        tauri::async_runtime::spawn_blocking(move || handle.trs_ios().icloud_download(&file))
            .await
            .map_err(|e| trs_core::Error::Internal(e.to_string()))?
            .map_err(|e| {
                log::warn!("iCloud-Download nicht gestartet: {e}");
                trs_core::Error::validation(trs_core::msg!("backup.downloadFailed", "Die Sicherung ließ sich nicht aus iCloud laden."))
            })?;
    }
    #[cfg(not(target_os = "ios"))]
    let _ = app;
    let started = std::time::Instant::now();
    loop {
        trs_core::task::sleep(Duration::from_secs(1)).await?;
        if backup::read_manifest(path).is_ok() {
            return Ok(());
        }
        if started.elapsed() > DOWNLOAD_TIMEOUT {
            return Err(trs_core::Error::validation(trs_core::msg!(
                "backup.downloadFailed",
                "Die Sicherung ließ sich nicht aus iCloud laden."
            )));
        }
    }
}

/// Sicherung einspielen. Danach lädt die Oberfläche neu.
#[tauri::command]
pub async fn backup_restore(
    app: AppHandle,
    launcher: State<'_, LauncherState>,
    opened: State<'_, OpenedBackups>,
    path: String,
    on_progress: Channel<u8>,
    task_id: Option<String>,
) -> CommandResult<Vec<String>> {
    if !launcher.games().running().is_empty() {
        return Err(trs_core::Error::validation(trs_core::msg!(
            "backup.gameRunning",
            "Minecraft läuft gerade – bitte erst beenden, dann wiederherstellen."
        ))
        .into());
    }
    let places = places(&app, &launcher).await;
    let (path, _) = checked(&places, Some(&opened), &path)?;
    let paths = launcher.paths().clone();
    let handle = app.clone();
    let work = async move {
        ensure_local(&handle, &path).await?;
        backup::restore(&paths, &path, move |p| {
            let _ = on_progress.send(p);
        })
        .await
    };
    let restored = tracked(&app, task_id, work).await?;
    if let Some(settings) = restored.settings {
        // Wie „Speichern“ in den Einstellungen – so stimmt auch der Zustand im Speicher (Sprache, Discord …).
        launcher.update_settings(settings).await?;
    }
    log::info!("Sicherung wiederhergestellt: {} Instanz(en)", restored.instances.len());
    let _ = app.emit("backup-changed", ());
    Ok(restored.instances)
}

/// Sicherung löschen (lokal oder in iCloud – dort auch, wenn sie noch nicht geladen ist).
#[tauri::command]
pub async fn backup_delete(app: AppHandle, launcher: State<'_, LauncherState>, path: String) -> CommandResult<()> {
    let places = places(&app, &launcher).await;
    let (path, _) = checked(&places, None, &path)?;
    let target = if path.is_file() { Some(path.clone()) } else { placeholder(&path).filter(|p| p.is_file()) };
    let Some(target) = target else { return Err(not_found().into()) };
    std::fs::remove_file(&target).map_err(|e| trs_core::Error::io(&target, e))?;
    let _ = app.emit("backup-changed", ());
    Ok(())
}

/// Teilen-Menü (AirDrop, „In Dateien sichern“ …).
#[tauri::command]
pub async fn backup_share(app: AppHandle, launcher: State<'_, LauncherState>, path: String) -> CommandResult<()> {
    let places = places(&app, &launcher).await;
    let (path, _) = checked(&places, None, &path)?;
    tracked(&app, None, ensure_local(&app, &path)).await?;
    crate::crash_report::share(&app, path).await
}

/// Über „Öffnen in TRS Launcher“ geöffnete Sicherung (einmalig), mit Beschreibung.
#[tauri::command]
pub fn take_opened_backup(opened: State<'_, OpenedBackups>) -> Option<Entry> {
    let path = opened.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()?;
    let meta = std::fs::metadata(&path).ok()?;
    let file = BackupFile {
        file_name: path.file_name()?.to_str()?.to_owned(),
        manifest: backup::read_manifest(&path).ok(),
        modified: meta.modified().ok().map(DateTime::<Utc>::from),
        size: meta.len(),
        downloaded: true,
        path,
    };
    Some(entry(file, false))
}

/// Von [`crate::deeplink`]: eine `.trsbackup`-Datei wurde geöffnet (schon in den eigenen Ordner kopiert).
pub fn opened(app: &AppHandle, path: PathBuf) {
    let Some(state) = app.try_state::<OpenedBackups>() else { return };
    state.allowed.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(path.clone());
    *state.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(path);
    let _ = app.emit("open-backup-file", ());
}

/// Einmal am Tag automatisch sichern (Einstellung „Täglich automatisch sichern“) – kurz nach dem Start und wenn die
/// App wieder nach vorn kommt. Nicht, solange Minecraft läuft.
pub fn automatic_soon(app: &AppHandle, delay: Duration) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        // Eigene Wartezeit (kein Aufgaben-Abbruch nötig).
        let _ = trs_core::task::sleep(delay).await;
        if AUTO_RUNNING.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Err(e) = automatic(&app).await {
            log::warn!("Automatische Sicherung fehlgeschlagen: {e}");
        }
        AUTO_RUNNING.store(false, Ordering::SeqCst);
    });
}

/// Beim Start (nach [`AUTO_DELAY`]).
pub fn start(app: &AppHandle) {
    automatic_soon(app, AUTO_DELAY);
}

async fn automatic(app: &AppHandle) -> trs_core::Result<()> {
    let Some(launcher) = app.try_state::<LauncherState>().map(|s| s.inner().clone()) else { return Ok(()) };
    if !launcher.settings().await.auto_backup || !launcher.games().running().is_empty() {
        return Ok(());
    }
    let places = places(app, &launcher).await;
    let dirs: Vec<PathBuf> = places.dirs().map(|(d, _)| d.to_owned()).collect();
    let last = tauri::async_runtime::spawn_blocking(move || dirs.iter().filter_map(|d| backup::last_automatic(d)).max())
        .await
        .unwrap_or(None);
    if last.is_some_and(|t| Utc::now() - t < AUTO_INTERVAL) {
        return Ok(());
    }
    log::info!("Automatische Sicherung startet");
    let made = create(app, &launcher, true, |_| {}).await?;
    log::info!("Automatische Sicherung: {} ({} Bytes)", made.file.file_name, made.file.size);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_backups_in_known_places_are_accepted() {
        let places = Places { local: Some("/data/Backups".into()), icloud: Some("/cloud/Documents/Backups".into()) };
        assert_eq!(places.target(), Some(Path::new("/cloud/Documents/Backups")));
        let (path, icloud) = checked(&places, None, "/cloud/Documents/Backups/TRS-Launcher_1.trsbackup").unwrap();
        assert!(icloud);
        assert_eq!(path, PathBuf::from("/cloud/Documents/Backups/TRS-Launcher_1.trsbackup"));
        assert!(!checked(&places, None, "/data/Backups/a.trsbackup").unwrap().1);
        assert!(checked(&places, None, "/data/Backups/../secret/a.trsbackup").is_err());
        assert!(checked(&places, None, "/data/Backups/a.zip").is_err());
        assert!(checked(&places, None, "/data/Backups/.a.trsbackup").is_err());
        assert!(checked(&places, None, "/elsewhere/a.trsbackup").is_err());

        let opened = OpenedBackups::default();
        opened.allowed.lock().unwrap().push("/tmp/Opened/x/b.trsbackup".into());
        assert!(checked(&places, Some(&opened), "/tmp/Opened/x/b.trsbackup").is_ok());
        assert!(checked(&places, Some(&opened), "/tmp/Opened/y/b.trsbackup").is_err());
        // Löschen und Teilen nur an den festen Orten.
        assert!(checked(&places, None, "/tmp/Opened/x/b.trsbackup").is_err());
    }

    #[test]
    fn placeholders_sit_next_to_the_file() {
        assert_eq!(placeholder(Path::new("/c/B/a.trsbackup")), Some(PathBuf::from("/c/B/.a.trsbackup.icloud")));
    }
}
