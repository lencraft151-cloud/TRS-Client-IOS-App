//! Sicherung des ganzen Launchers als eine Datei (`<name>.trsbackup`, ein ZIP) – für ein neues Gerät, nach einer
//! Neuinstallation oder als Rückweg. Drin sind Einstellungen, alle Instanzen (Welten, Mods, Spieleinstellungen,
//! Ressourcen- und Shaderpakete, Screenshots), gemeinsame Dateien und Ordner, Skins, Presets und die Touch-Steuerung.
//!
//! Nicht drin:
//! - Anmeldungen: Die Tokens sind mit dem Schlüssel dieses Geräts verschlüsselt und anderswo nutzlos.
//! - Was der Launcher selbst wieder lädt: Spielversionen, Bibliotheken, Assets, Java, Caches.
//! - Logs, Absturzberichte, Welt- und Datei-Sicherungen, Sync-Sicherungen.
//! - Links auf gemeinsame Ordner (die Ordner selbst sind drin; der nächste Spielstart verlinkt neu).
//!
//! Wiederherstellen ersetzt Instanzen aus der Sicherung (gleiche ID) komplett, legt fehlende an und lässt alle
//! anderen in Ruhe. Gemeinsame Dateien, Skins, Presets und Steuerung werden überschrieben bzw. ergänzt, nichts
//! wird gelöscht. Die Einstellungen liefert [`restore`] zurück – übernehmen muss sie der Aufrufer
//! ([`crate::Launcher::update_settings`]), damit auch der Zustand im Speicher stimmt.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::instance::{Instance, validate_id};
use crate::paths::Paths;
use crate::settings::Settings;
use crate::{Error, Result, msg};

/// Dateiendung (eigener Dokumenttyp in iOS: „Öffnen in TRS Launcher“).
pub const EXTENSION: &str = "trsbackup";
/// Beschreibung im ZIP (erster Eintrag).
const MANIFEST: &str = "trs-backup.json";
/// Höchste Format-Version, die dieser Launcher lesen kann.
const FORMAT: u32 = 1;
const SETTINGS: &str = "settings.json";
const INSTANCES: &str = "instances";
/// Einzelne Dateien im Datenordner.
const ROOT_FILES: [&str; 1] = ["presets.json"];
/// Ordner im Datenordner, die mitkommen.
const ROOT_DIRS: [&str; 4] = ["shared", "shared-folders", "skins", "controls"];
/// Pfade (relativ zum Instanz- bzw. Datenordner), die draußen bleiben.
const SKIP: [&str; 8] = [
    "minecraft/logs",
    "minecraft/crash-reports",
    "minecraft/backups",
    "minecraft/.cache",
    "minecraft/debug",
    "sync-backup",
    "file-backups",
    "shared/.backup",
];
/// Dateiname-Anfang automatischer Sicherungen (nur die räumt [`prune_automatic`] auf).
const AUTO_PREFIX: &str = "TRS-Launcher_auto_";
const MANUAL_PREFIX: &str = "TRS-Launcher_";
/// Nicht fertig geschriebene Sicherung (wird beim nächsten Mal weggeräumt).
const PART_SUFFIX: &str = ".part";
/// Arbeitsordner beim Wiederherstellen (im Datenordner, damit Umbenennen statt Kopieren reicht).
const STAGING: &str = ".restore";

/// Beschreibung einer Sicherung (`trs-backup.json` im ZIP).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub format: u32,
    /// Launcher-Version, die sie geschrieben hat.
    pub app_version: String,
    pub created: DateTime<Utc>,
    /// Gerät (z. B. „iPhone14,4“), nur zur Anzeige.
    #[serde(default)]
    pub device: String,
    /// Automatisch angelegt (wird nach [`prune_automatic`] aufgeräumt).
    #[serde(default)]
    pub automatic: bool,
    #[serde(default)]
    pub instances: Vec<ManifestInstance>,
    /// Größe aller Dateien vor dem Packen.
    #[serde(default)]
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestInstance {
    pub id: String,
    pub name: String,
    pub game_version: String,
}

/// Eine Sicherung in einem Ordner (lokal oder iCloud).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupFile {
    pub path: PathBuf,
    pub file_name: String,
    /// Größe der Datei (0, solange sie nur in iCloud liegt).
    pub size: u64,
    pub modified: Option<DateTime<Utc>>,
    /// `None`, wenn noch nicht geladen (iCloud) oder unlesbar.
    pub manifest: Option<Manifest>,
    /// `false`: nur ein iCloud-Platzhalter, erst herunterladen.
    pub downloaded: bool,
}

/// Was beim Erstellen mit in die Beschreibung kommt.
#[derive(Debug, Clone, Default)]
pub struct CreateOptions {
    pub app_version: String,
    pub device: String,
    pub automatic: bool,
}

/// Ergebnis von [`restore`].
#[derive(Debug, Clone)]
pub struct Restored {
    /// Einstellungen aus der Sicherung (übernimmt der Aufrufer).
    pub settings: Option<Settings>,
    /// Wiederhergestellte Instanzen (IDs).
    pub instances: Vec<String>,
}

/// Dateiname für eine neue Sicherung.
pub fn file_name(now: DateTime<chrono::Local>, automatic: bool) -> String {
    let prefix = if automatic { AUTO_PREFIX } else { MANUAL_PREFIX };
    format!("{prefix}{}.{EXTENSION}", now.format("%Y-%m-%d_%H-%M-%S"))
}

fn skipped(rel: &str) -> bool {
    SKIP.iter().any(|s| rel == *s || rel.starts_with(&format!("{s}/")))
}

/// Dateien unter `dir` (ohne Links), als (Pfad, ZIP-Name, Größe). `rel` = Pfad relativ zum Daten-/Instanzordner
/// für [`SKIP`], `zip_prefix` = Ort im ZIP.
fn collect(dir: &Path, rel: &str, zip_prefix: &str, out: &mut Vec<(PathBuf, String, u64)>) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    for entry in read.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else { continue };
        let child_rel = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
        if skipped(&child_rel) || name.ends_with(".tmp") || name == "session.lock" {
            continue;
        }
        let zip_name = format!("{zip_prefix}/{name}");
        if kind.is_dir() {
            collect(&entry.path(), &child_rel, &zip_name, out);
        } else if kind.is_file() {
            let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
            out.push((entry.path(), zip_name, size));
        }
    }
}

/// Alles, was in die Sicherung kommt.
fn files(paths: &Paths, instances: &[Instance]) -> Vec<(PathBuf, String, u64)> {
    let mut out = Vec::new();
    let root = paths.root();
    for name in std::iter::once(SETTINGS).chain(ROOT_FILES) {
        if let Ok(meta) = std::fs::metadata(root.join(name))
            && meta.is_file()
        {
            out.push((root.join(name), name.to_owned(), meta.len()));
        }
    }
    for dir in ROOT_DIRS {
        // `skipped` sieht hier den Pfad relativ zum Datenordner (z. B. `shared/.backup`).
        let mut found = Vec::new();
        collect(&root.join(dir), dir, dir, &mut found);
        out.extend(found);
    }
    for instance in instances {
        if validate_id(&instance.id).is_err() {
            continue;
        }
        collect(&paths.instance_dir(&instance.id), "", &format!("{INSTANCES}/{}", instance.id), &mut out);
    }
    out
}

/// Ungefähre Größe einer Sicherung vor dem Packen (Bytes).
pub async fn estimate(paths: &Paths, instances: &[Instance]) -> u64 {
    let paths = paths.clone();
    let instances = instances.to_vec();
    tokio::task::spawn_blocking(move || files(&paths, &instances).iter().map(|(_, _, size)| size).sum())
        .await
        .unwrap_or(0)
}

/// Schreibt eine Sicherung nach `dest_dir` und liefert ihren Pfad. Erst als `.part`, dann umbenannt – so sieht
/// iCloud nie eine halbe Datei.
pub async fn create(
    paths: &Paths,
    instances: &[Instance],
    dest_dir: &Path,
    options: CreateOptions,
    on_progress: impl Fn(u8) + Send + 'static,
) -> Result<PathBuf> {
    let paths = paths.clone();
    let instances = instances.to_vec();
    let dest_dir = dest_dir.to_owned();
    let control = crate::task::current();
    tokio::task::spawn_blocking(move || {
        std::fs::create_dir_all(&dest_dir).map_err(|e| Error::io(&dest_dir, e))?;
        let name = crate::instance_files::free_name(&dest_dir, &file_name(chrono::Local::now(), options.automatic));
        let dest = dest_dir.join(&name);
        let part = dest_dir.join(format!(".{name}{PART_SUFFIX}"));
        let cancelled = || control.as_ref().is_some_and(crate::task::TaskControl::is_cancelled);
        let result = write(&paths, &instances, &part, &options, &on_progress, &cancelled)
            .and_then(|()| std::fs::rename(&part, &dest).map_err(|e| Error::io(&dest, e)));
        if result.is_err() {
            let _ = std::fs::remove_file(&part);
        }
        result.map(|()| dest)
    })
    .await
    .map_err(|e| Error::Internal(e.to_string()))?
}

fn write(
    paths: &Paths,
    instances: &[Instance],
    dest: &Path,
    options: &CreateOptions,
    on_progress: &dyn Fn(u8),
    cancelled: &dyn Fn() -> bool,
) -> Result<()> {
    let files = files(paths, instances);
    let bytes: u64 = files.iter().map(|(_, _, size)| size).sum();
    let manifest = Manifest {
        format: FORMAT,
        app_version: options.app_version.clone(),
        created: Utc::now(),
        device: options.device.clone(),
        automatic: options.automatic,
        instances: instances
            .iter()
            .filter(|i| validate_id(&i.id).is_ok())
            .map(|i| ManifestInstance { id: i.id.clone(), name: i.name.clone(), game_version: i.game_version.clone() })
            .collect(),
        bytes,
    };

    let file = std::fs::File::create(dest).map_err(|e| Error::io(dest, e))?;
    let mut zip = zip::ZipWriter::new(std::io::BufWriter::new(file));
    let deflated = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated).large_file(true);
    // Schon gepackte Formate nur ablegen – spart auf dem Handy viel Zeit.
    let stored = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored).large_file(true);
    let zip_err = |e: zip::result::ZipError| Error::Internal(e.to_string());

    zip.start_file(MANIFEST, deflated).map_err(zip_err)?;
    let json = serde_json::to_vec_pretty(&manifest).map_err(|e| Error::json(MANIFEST, e))?;
    zip.write_all(&json).map_err(|e| Error::io(dest, e))?;

    let total = bytes.max(1);
    let mut done = 0u64;
    let mut last = 0u8;
    let mut buf = vec![0u8; 256 * 1024];
    for (path, name, _) in files {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        // Datei gerade gesperrt oder verschwunden: überspringen statt abbrechen.
        let Ok(mut input) = std::fs::File::open(&path) else { continue };
        let packed = matches!(
            Path::new(&name).extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref(),
            Some("jar" | "zip" | "png" | "jpg" | "jpeg" | "ogg" | "mp4" | "mrpack" | "gz")
        );
        zip.start_file(name.as_str(), if packed { stored } else { deflated }).map_err(zip_err)?;
        loop {
            let read = input.read(&mut buf).map_err(|e| Error::io(&path, e))?;
            if read == 0 {
                break;
            }
            zip.write_all(&buf[..read]).map_err(|e| Error::io(dest, e))?;
            done += read as u64;
        }
        let percent = ((done * 100) / total).min(99) as u8;
        if percent != last {
            last = percent;
            on_progress(percent);
        }
    }
    zip.finish().map_err(zip_err)?.into_inner().map_err(|e| Error::io(dest, e.into_error()))?.sync_all().map_err(|e| Error::io(dest, e))?;
    on_progress(100);
    Ok(())
}

fn read_manifest_from<R: Read + std::io::Seek>(archive: &mut zip::ZipArchive<R>) -> Result<Manifest> {
    let invalid = || Error::validation(msg!("backup.invalid", "Das ist keine Sicherung des TRS Launchers."));
    let mut entry = archive.by_name(MANIFEST).map_err(|_| invalid())?;
    if entry.size() > 1024 * 1024 {
        return Err(invalid());
    }
    let mut text = String::new();
    entry.read_to_string(&mut text).map_err(|_| invalid())?;
    let manifest: Manifest = serde_json::from_str(&text).map_err(|_| invalid())?;
    if manifest.format > FORMAT {
        return Err(Error::validation(msg!(
            "backup.tooNew",
            "Diese Sicherung stammt aus einer neueren Version ({version}) – bitte erst den Launcher aktualisieren.",
            version = &manifest.app_version
        )));
    }
    Ok(manifest)
}

/// Beschreibung einer Sicherungsdatei lesen.
pub fn read_manifest(file: &Path) -> Result<Manifest> {
    let input = std::fs::File::open(file).map_err(|e| Error::io(file, e))?;
    let mut archive = zip::ZipArchive::new(std::io::BufReader::new(input))
        .map_err(|_| Error::validation(msg!("backup.invalid", "Das ist keine Sicherung des TRS Launchers.")))?;
    read_manifest_from(&mut archive)
}

/// iCloud-Platzhalter `.<name>.trsbackup.icloud` → `<name>.trsbackup`.
fn placeholder_target(name: &str) -> Option<&str> {
    let inner = name.strip_prefix('.')?.strip_suffix(".icloud")?;
    inner.ends_with(&format!(".{EXTENSION}")).then_some(inner)
}

/// Sicherungen in `dir`, neueste zuerst. Liest nur die Beschreibung, nicht den Inhalt.
pub fn list(dir: &Path) -> Vec<BackupFile> {
    let Ok(read) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut out = Vec::new();
    for entry in read.flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else { continue };
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let modified = meta.modified().ok().map(DateTime::<Utc>::from);
        if let Some(target) = placeholder_target(&name) {
            out.push(BackupFile {
                path: dir.join(target),
                file_name: target.to_owned(),
                size: 0,
                modified,
                manifest: None,
                downloaded: false,
            });
        } else if !name.starts_with('.') && name.ends_with(&format!(".{EXTENSION}")) {
            let path = entry.path();
            out.push(BackupFile {
                manifest: read_manifest(&path).ok(),
                path,
                file_name: name,
                size: meta.len(),
                modified,
                downloaded: true,
            });
        }
    }
    let created = |b: &BackupFile| b.manifest.as_ref().map(|m| m.created).or(b.modified);
    out.sort_by_key(|b| std::cmp::Reverse(created(b)));
    out
}

/// Ältere automatische Sicherungen löschen, die neuesten `keep` bleiben. Halbe Dateien (`.part`) älter als ein Tag
/// fliegen auch raus. Liefert die Zahl der gelöschten Dateien.
pub fn prune_automatic(dir: &Path, keep: usize) -> usize {
    let mut removed = 0;
    let mut automatic: Vec<BackupFile> =
        list(dir).into_iter().filter(|b| b.downloaded && b.file_name.starts_with(AUTO_PREFIX)).collect();
    // `list` sortiert schon neueste zuerst.
    for old in automatic.drain(keep.min(automatic.len())..) {
        if std::fs::remove_file(&old.path).is_ok() {
            removed += 1;
        }
    }
    if let Ok(read) = std::fs::read_dir(dir) {
        let day_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(24 * 3600);
        for entry in read.flatten() {
            let name = entry.file_name();
            let stale = entry.metadata().and_then(|m| m.modified()).is_ok_and(|t| t < day_ago);
            if name.to_str().is_some_and(|n| n.starts_with('.') && n.ends_with(PART_SUFFIX)) && stale && std::fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
    }
    removed
}

/// Neueste automatische Sicherung in `dir` (für „einmal am Tag“).
pub fn last_automatic(dir: &Path) -> Option<DateTime<Utc>> {
    list(dir)
        .into_iter()
        .filter(|b| b.file_name.starts_with(AUTO_PREFIX))
        .filter_map(|b| b.manifest.map(|m| m.created).or(b.modified))
        .max()
}

/// Wohin ein ZIP-Eintrag beim Wiederherstellen darf (relativ zum Arbeitsordner) – `None` = ignorieren.
fn allowed(name: &Path) -> Option<PathBuf> {
    let parts: Vec<&str> = name.components().map(|c| c.as_os_str().to_str()).collect::<Option<_>>()?;
    let first = *parts.first()?;
    let ok = match first {
        SETTINGS => parts.len() == 1,
        INSTANCES => parts.len() >= 3 && validate_id(parts[1]).is_ok(),
        _ if ROOT_FILES.contains(&first) => parts.len() == 1,
        _ if ROOT_DIRS.contains(&first) => parts.len() >= 2,
        _ => false,
    };
    (ok && !skipped(&parts.join("/"))).then(|| parts.iter().collect())
}

/// Spielt eine Sicherung ein (siehe Modulbeschreibung). Läuft eine Instanz, muss der Aufrufer vorher abbrechen.
pub async fn restore(paths: &Paths, file: &Path, on_progress: impl Fn(u8) + Send + 'static) -> Result<Restored> {
    let paths = paths.clone();
    let file = file.to_owned();
    let control = crate::task::current();
    let staging = paths.root().join(STAGING);
    let restored = tokio::task::spawn_blocking(move || {
        let cancelled = || control.as_ref().is_some_and(crate::task::TaskControl::is_cancelled);
        let _ = std::fs::remove_dir_all(&staging);
        let result = extract(&file, &staging, &on_progress, &cancelled).and_then(|()| apply(&paths, &staging));
        let _ = std::fs::remove_dir_all(&staging);
        result
    })
    .await
    .map_err(|e| Error::Internal(e.to_string()))??;
    // Kaputte Einstellungen in der Sicherung: Instanzen sind schon da – dann eben die bisherigen Einstellungen behalten.
    let settings = restored.1.and_then(|text| {
        Settings::from_json(&text).map_err(|e| tracing::warn!("Einstellungen aus der Sicherung unlesbar: {e}")).ok()
    });
    Ok(Restored { settings, instances: restored.0 })
}

fn extract(file: &Path, staging: &Path, on_progress: &dyn Fn(u8), cancelled: &dyn Fn() -> bool) -> Result<()> {
    let input = std::fs::File::open(file).map_err(|e| Error::io(file, e))?;
    let mut archive = zip::ZipArchive::new(std::io::BufReader::new(input))
        .map_err(|_| Error::validation(msg!("backup.invalid", "Das ist keine Sicherung des TRS Launchers.")))?;
    let manifest = read_manifest_from(&mut archive)?;
    let total = manifest.bytes.max(1);
    let mut done = 0u64;
    let mut last = 0u8;
    let mut buf = vec![0u8; 256 * 1024];
    for index in 0..archive.len() {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        let mut entry = archive.by_index(index).map_err(|e| Error::Internal(e.to_string()))?;
        if entry.is_dir() {
            continue;
        }
        // `enclosed_name` verhindert Zip-Slip, `allowed` alles außerhalb der bekannten Orte.
        let Some(rel) = entry.enclosed_name().as_deref().and_then(allowed) else { continue };
        let dest = staging.join(&rel);
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
        }
        let mut out = std::fs::File::create(&dest).map_err(|e| Error::io(&dest, e))?;
        loop {
            let read = entry.read(&mut buf).map_err(|e| Error::io(file, e))?;
            if read == 0 {
                break;
            }
            out.write_all(&buf[..read]).map_err(|e| Error::io(&dest, e))?;
            done += read as u64;
        }
        let percent = ((done * 100) / total).min(99) as u8;
        if percent != last {
            last = percent;
            on_progress(percent);
        }
    }
    on_progress(100);
    Ok(())
}

/// Verschiebt den entpackten Stand an seinen Platz. Liefert die Instanz-IDs und den Text der Einstellungen.
fn apply(paths: &Paths, staging: &Path) -> Result<(Vec<String>, Option<String>)> {
    let root = paths.root();
    let mut instances = Vec::new();
    let staged_instances = staging.join(INSTANCES);
    if let Ok(read) = std::fs::read_dir(&staged_instances) {
        let previous = staging.join("previous");
        for entry in read.flatten() {
            let Some(id) = entry.file_name().to_str().map(str::to_owned) else { continue };
            if validate_id(&id).is_err() || !entry.path().join("instance.json").is_file() {
                continue;
            }
            // Eigener Speicherort: die Sicherung kommt an den Standardort, der alte Ordner bleibt, wo er ist.
            if paths.instance_location(&id).is_some() {
                paths.set_instance_location(&id, None)?;
            }
            let target = paths.default_instance_dir(&id);
            let moved_away = previous.join(&id);
            let had_old = target.exists();
            if had_old {
                std::fs::create_dir_all(&previous).map_err(|e| Error::io(&previous, e))?;
                std::fs::rename(&target, &moved_away).map_err(|e| Error::io(&target, e))?;
            }
            std::fs::create_dir_all(paths.instances_dir()).map_err(|e| Error::io(paths.instances_dir(), e))?;
            if let Err(e) = std::fs::rename(entry.path(), &target) {
                // Alten Stand zurück, damit nichts verloren geht.
                if had_old {
                    let _ = std::fs::rename(&moved_away, &target);
                }
                return Err(Error::io(&target, e));
            }
            instances.push(id);
        }
    }
    for name in ROOT_DIRS.iter().chain(ROOT_FILES.iter()) {
        merge(&staging.join(name), &root.join(name))?;
    }
    let settings = std::fs::read_to_string(staging.join(SETTINGS)).ok();
    Ok((instances, settings))
}

/// Datei bzw. Ordnerinhalt von `from` nach `to` verschieben (vorhandene Dateien werden ersetzt, nichts gelöscht).
fn merge(from: &Path, to: &Path) -> Result<()> {
    let Ok(meta) = std::fs::metadata(from) else { return Ok(()) };
    if meta.is_file() {
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
        }
        // Ein Link (z. B. gemeinsamer Ordner) wird nicht durchschrieben, sondern ersetzt.
        if let Ok(existing) = std::fs::symlink_metadata(to) {
            let removed = if existing.file_type().is_symlink() {
                std::fs::remove_file(to).or_else(|_| crate::platform::remove_dir_link(to))
            } else if existing.is_dir() {
                std::fs::remove_dir_all(to)
            } else {
                Ok(())
            };
            removed.map_err(|e| Error::io(to, e))?;
        }
        return std::fs::rename(from, to).map_err(|e| Error::io(to, e));
    }
    let read = std::fs::read_dir(from).map_err(|e| Error::io(from, e))?;
    for entry in read.flatten() {
        merge(&entry.path(), &to.join(entry.file_name()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_file(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn instance(id: &str, name: &str) -> Instance {
        serde_json::from_value(serde_json::json!({
            "id": id, "name": name, "gameVersion": "1.21.1",
            "loader": { "kind": "fabric", "version": "0.16.0" },
            "createdAt": "2026-10-01T10:00:00Z"
        }))
        .unwrap()
    }

    fn setup(root: &Path) -> (Paths, Vec<Instance>) {
        let paths = Paths::new(root);
        let survival = instance("survival", "Survival");
        write_file(&paths.instance_file("survival"), &serde_json::to_string(&survival).unwrap());
        write_file(&paths.instance_game_dir("survival").join("saves/Welt/level.dat"), "welt");
        write_file(&paths.instance_game_dir("survival").join("mods/sodium.jar"), "jar");
        write_file(&paths.instance_game_dir("survival").join("options.txt"), "fov:90");
        write_file(&paths.instance_game_dir("survival").join("logs/latest.log"), "log");
        write_file(&paths.instance_game_dir("survival").join("backups/Welt_2026.zip"), "zip");
        write_file(&paths.instance_dir("survival").join("sync-backup/options.txt"), "alt");
        write_file(&root.join("settings.json"), r#"{"mobileBeta": true}"#);
        write_file(&root.join("accounts.json"), "geheim");
        write_file(&root.join("skins/skin-1.png"), "png");
        write_file(&root.join("shared/servers.dat"), "servers");
        write_file(&root.join("shared/.backup/servers.dat"), "alt");
        write_file(&root.join("controls/layout.json"), "{}");
        write_file(&root.join("versions/1.21.1/1.21.1.jar"), "client");
        (paths, vec![survival])
    }

    fn names(file: &Path) -> Vec<String> {
        let mut archive = zip::ZipArchive::new(std::fs::File::open(file).unwrap()).unwrap();
        let mut out: Vec<String> = (0..archive.len()).map(|i| archive.by_index(i).unwrap().name().to_owned()).collect();
        out.sort();
        out
    }

    #[tokio::test]
    async fn backup_keeps_player_data_and_leaves_out_secrets_and_downloads() {
        let dir = tempfile::tempdir().unwrap();
        let (paths, instances) = setup(&dir.path().join("data"));
        let out = dir.path().join("out");
        let options = CreateOptions { app_version: "0.27.1".into(), device: "iPhone14,4".into(), automatic: false };
        let file = create(&paths, &instances, &out, options, |_| {}).await.unwrap();
        assert!(file.file_name().unwrap().to_str().unwrap().ends_with(".trsbackup"));
        assert_eq!(
            names(&file),
            [
                "controls/layout.json",
                "instances/survival/instance.json",
                "instances/survival/minecraft/mods/sodium.jar",
                "instances/survival/minecraft/options.txt",
                "instances/survival/minecraft/saves/Welt/level.dat",
                "settings.json",
                "shared/servers.dat",
                "skins/skin-1.png",
                "trs-backup.json",
            ]
        );
        let manifest = read_manifest(&file).unwrap();
        assert_eq!(manifest.instances[0].name, "Survival");
        assert_eq!(manifest.device, "iPhone14,4");
        assert!(manifest.bytes > 0);
        // Keine halbe Datei bleibt liegen.
        assert_eq!(std::fs::read_dir(&out).unwrap().count(), 1);
    }

    #[tokio::test]
    async fn restore_replaces_backed_up_instances_and_keeps_others() {
        let dir = tempfile::tempdir().unwrap();
        let (paths, instances) = setup(&dir.path().join("data"));
        let file = create(&paths, &instances, &dir.path().join("out"), CreateOptions::default(), |_| {}).await.unwrap();

        // Danach: Welt geändert, Mod dazu, neue Instanz, neuer Skin.
        let game = paths.instance_game_dir("survival");
        write_file(&game.join("saves/Welt/level.dat"), "kaputt");
        write_file(&game.join("mods/extra.jar"), "jar");
        write_file(&paths.instance_file("creative"), &serde_json::to_string(&instance("creative", "Creative")).unwrap());
        write_file(&paths.root().join("skins/skin-2.png"), "png");
        write_file(&paths.root().join("settings.json"), r#"{"mobileBeta": false}"#);

        let restored = restore(&paths, &file, |_| {}).await.unwrap();
        assert_eq!(restored.instances, ["survival"]);
        assert!(restored.settings.unwrap().mobile_beta);
        assert_eq!(std::fs::read_to_string(game.join("saves/Welt/level.dat")).unwrap(), "welt");
        assert!(!game.join("mods/extra.jar").exists(), "Instanz wird ersetzt, nicht gemischt");
        assert!(paths.instance_file("creative").exists(), "andere Instanzen bleiben");
        assert!(paths.root().join("skins/skin-2.png").exists(), "Skins werden ergänzt");
        assert!(paths.root().join("skins/skin-1.png").exists());
        assert_eq!(std::fs::read_to_string(paths.root().join("accounts.json")).unwrap(), "geheim");
        assert!(!paths.root().join(STAGING).exists());
    }

    #[test]
    fn restore_only_writes_known_places() {
        assert_eq!(allowed(Path::new("settings.json")), Some(PathBuf::from("settings.json")));
        assert!(allowed(Path::new("instances/survival/minecraft/saves/a/level.dat")).is_some());
        assert!(allowed(Path::new("accounts.json")).is_none());
        assert!(allowed(Path::new(".token-key")).is_none());
        assert!(allowed(Path::new("versions/1.21.1/1.21.1.jar")).is_none());
        assert!(allowed(Path::new("instances/../../x/instance.json")).is_none());
        assert!(allowed(Path::new("instances/survival")).is_none());
        assert!(allowed(Path::new("skins")).is_none());
        assert!(allowed(Path::new("shared/.backup/servers.dat")).is_none());
        assert!(allowed(Path::new("settings.json/x")).is_none());
    }

    #[tokio::test]
    async fn rejects_other_zips_and_newer_formats() {
        let dir = tempfile::tempdir().unwrap();
        let plain = dir.path().join("pack.trsbackup");
        {
            let mut zip = zip::ZipWriter::new(std::fs::File::create(&plain).unwrap());
            zip.start_file("modrinth.index.json", zip::write::SimpleFileOptions::default()).unwrap();
            zip.write_all(b"{}").unwrap();
            zip.finish().unwrap();
        }
        assert_eq!(read_manifest(&plain).unwrap_err().message_code(), "backup.invalid");

        let newer = dir.path().join("newer.trsbackup");
        {
            let mut zip = zip::ZipWriter::new(std::fs::File::create(&newer).unwrap());
            zip.start_file(MANIFEST, zip::write::SimpleFileOptions::default()).unwrap();
            zip.write_all(br#"{"format": 99, "appVersion": "9.0.0", "created": "2030-01-01T00:00:00Z"}"#).unwrap();
            zip.finish().unwrap();
        }
        assert_eq!(read_manifest(&newer).unwrap_err().message_code(), "backup.tooNew");
        let paths = Paths::new(dir.path().join("data"));
        assert!(restore(&paths, &newer, |_| {}).await.is_err());
    }

    #[test]
    fn lists_newest_first_and_prunes_only_automatic_backups() {
        let dir = tempfile::tempdir().unwrap();
        let write_backup = |name: &str, created: &str| {
            let mut zip = zip::ZipWriter::new(std::fs::File::create(dir.path().join(name)).unwrap());
            zip.start_file(MANIFEST, zip::write::SimpleFileOptions::default()).unwrap();
            zip.write_all(format!(r#"{{"format": 1, "appVersion": "1", "created": "{created}"}}"#).as_bytes()).unwrap();
            zip.finish().unwrap();
        };
        write_backup("TRS-Launcher_auto_1.trsbackup", "2026-10-01T00:00:00Z");
        write_backup("TRS-Launcher_auto_2.trsbackup", "2026-10-02T00:00:00Z");
        write_backup("TRS-Launcher_auto_3.trsbackup", "2026-10-03T00:00:00Z");
        write_backup("TRS-Launcher_2026.trsbackup", "2026-09-01T00:00:00Z");
        std::fs::write(dir.path().join(".TRS-Launcher_cloud.trsbackup.icloud"), "plist").unwrap();
        std::fs::write(dir.path().join("notiz.txt"), "x").unwrap();

        let all = list(dir.path());
        assert_eq!(all.len(), 5);
        assert_eq!(all.iter().filter(|b| !b.downloaded).count(), 1);
        let cloud = all.iter().find(|b| !b.downloaded).unwrap();
        assert_eq!(cloud.file_name, "TRS-Launcher_cloud.trsbackup");
        assert_eq!(last_automatic(dir.path()).unwrap().to_rfc3339(), "2026-10-03T00:00:00+00:00");

        assert_eq!(prune_automatic(dir.path(), 2), 1);
        assert!(!dir.path().join("TRS-Launcher_auto_1.trsbackup").exists());
        assert!(dir.path().join("TRS-Launcher_2026.trsbackup").exists(), "eigene Sicherungen bleiben");
    }
}
