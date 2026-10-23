//! iOS-Kurzbefehle, Siri und Widget: Der Launcher legt die Instanzliste als `shared.json` ab (App-Gruppe, falls
//! erlaubt, und Application Support der App) – gelesen von `gen/apple/Shared/TrsShared.swift`. Kurzbefehl und Widget
//! starten eine Instanz über `trs-launcher://play/<id>?k=<schlüssel>` ([`crate::deeplink`]); nur mit dem Schlüssel aus
//! dieser Datei startet der Launcher ohne Rückfrage – Links von Websites öffnen bloß die Instanz.
//!
//! Live-Aktivität: [`live_activity`] reicht den Stand einer Aufgabe (Download, Installation) an das Plugin weiter.
//!
//! Desktop und Android: nichts davon (die Logik ist dort nur in Tests im Einsatz).
#![cfg_attr(not(target_os = "ios"), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde::Serialize;
use tauri::AppHandle;
use trs_core::instance::Instance;

const KEY_FILE: &str = "shortcut-key";
/// So viele Instanzen bekommen Siri und das Widget (zuletzt gespielte zuerst).
const MAX_INSTANCES: usize = 50;

static KEY: OnceLock<String> = OnceLock::new();

/// Schlüssel dieser Installation (liegt im Datenordner, entsteht beim ersten Mal).
pub fn key(root: &Path) -> &'static str {
    KEY.get_or_init(|| {
        let file = root.join(KEY_FILE);
        if let Ok(existing) = std::fs::read_to_string(&file) {
            let existing = existing.trim().to_owned();
            if existing.len() == 64 && existing.bytes().all(|b| b.is_ascii_hexdigit()) {
                return existing;
            }
        }
        let fresh = trs_core::link::new_token();
        if let Err(e) = std::fs::write(&file, &fresh) {
            log::warn!("Kurzbefehl-Schlüssel nicht gespeichert: {e}");
        }
        fresh
    })
}

/// Stimmt der Schlüssel aus einem Link? (Ohne gespeicherten Schlüssel: nie.)
pub fn key_matches(given: &str) -> bool {
    KEY.get().is_some_and(|k| !given.is_empty() && k.as_bytes() == given.as_bytes())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SharedInstance<'a> {
    id: &'a str,
    name: &'a str,
    version: &'a str,
    loader: String,
    /// ISO 8601 ohne Sekundenbruchteile (so liest Swift `.iso8601`).
    #[serde(skip_serializing_if = "Option::is_none")]
    last_played: Option<String>,
}

#[derive(Serialize)]
struct SharedData<'a> {
    key: &'a str,
    instances: Vec<SharedInstance<'a>>,
}

/// Inhalt von `shared.json` (Liste kommt schon „zuletzt gespielt zuerst“ aus dem Kern).
fn shared_json(key: &str, instances: &[Instance]) -> Vec<u8> {
    let data = SharedData {
        key,
        instances: instances
            .iter()
            .take(MAX_INSTANCES)
            .map(|i| SharedInstance {
                id: &i.id,
                name: &i.name,
                version: &i.game_version,
                loader: serde_json::to_value(i.loader.kind).ok().and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default(),
                last_played: i.last_played.map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
            })
            .collect(),
    };
    serde_json::to_vec(&data).unwrap_or_default()
}

fn write_all(dirs: &[PathBuf], bytes: &[u8]) {
    for dir in dirs {
        let result = std::fs::create_dir_all(dir).and_then(|()| {
            let tmp = dir.join("shared.json.tmp");
            std::fs::write(&tmp, bytes)?;
            std::fs::rename(&tmp, dir.join("shared.json"))
        });
        if let Err(e) = result {
            log::warn!("shared.json nicht geschrieben ({}): {e}", dir.display());
        }
    }
}

/// Nach jeder Instanzliste (`list_instances`): neu ablegen – nur, wenn sich etwas geändert hat.
#[cfg(target_os = "ios")]
pub fn publish(app: &AppHandle, root: &Path, instances: &[Instance]) {
    use std::sync::Mutex;
    use tauri_plugin_trs_ios::TrsIosExt;
    static LAST: Mutex<Vec<u8>> = Mutex::new(Vec::new());

    let bytes = shared_json(key(root), instances);
    {
        let mut last = LAST.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if *last == bytes {
            return;
        }
        last.clone_from(&bytes);
    }
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let dirs = match app.trs_ios().shared_dirs() {
            Ok(dirs) => dirs,
            Err(e) => {
                log::warn!("Ordner für Kurzbefehle unbekannt: {e}");
                return;
            }
        };
        write_all(&dirs, &bytes);
        if let Err(e) = app.trs_ios().shared_changed() {
            log::warn!("Widget/Kurzbefehle nicht aktualisiert: {e}");
        }
    });
}

#[cfg(not(target_os = "ios"))]
pub fn publish(_app: &AppHandle, _root: &Path, _instances: &[Instance]) {}

/// Stand einer Aufgabe für die Live-Aktivität (iOS 16.2+; sonst nichts).
#[tauri::command]
pub async fn live_activity(app: AppHandle, id: String, kind: String, title: String, detail: String, progress: f64, done: bool) {
    #[cfg(target_os = "ios")]
    {
        use tauri_plugin_trs_ios::{ActivityUpdate, TrsIosExt};
        let progress = if progress.is_finite() { progress.min(1.0) } else { -1.0 };
        let result = tauri::async_runtime::spawn_blocking(move || {
            app.trs_ios().live_activity(&ActivityUpdate {
                id: &id,
                kind: &kind,
                title: &title,
                detail: &detail,
                progress,
                done,
            })
        })
        .await;
        if let Ok(Err(e)) = result {
            log::debug!("Live-Aktivität: {e}");
        }
    }
    #[cfg(not(target_os = "ios"))]
    let _ = (app, id, kind, title, detail, progress, done);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_json_lists_instances_with_swift_dates() {
        let mut instance: Instance = serde_json::from_value(serde_json::json!({
            "id": "survival", "name": "Survival", "gameVersion": "1.21.1",
            "loader": { "kind": "fabric", "version": "0.16.0" },
            "createdAt": "2026-10-01T10:00:00Z"
        }))
        .unwrap();
        instance.last_played = Some(chrono::DateTime::parse_from_rfc3339("2026-10-23T08:00:00.123+00:00").unwrap().into());
        let json: serde_json::Value = serde_json::from_slice(&shared_json(&"a".repeat(64), &[instance])).unwrap();
        assert_eq!(json["key"], "a".repeat(64));
        assert_eq!(json["instances"][0]["id"], "survival");
        assert_eq!(json["instances"][0]["version"], "1.21.1");
        assert_eq!(json["instances"][0]["loader"], "fabric");
        assert_eq!(json["instances"][0]["lastPlayed"], "2026-10-23T08:00:00Z");
    }

    #[test]
    fn keys_only_match_exactly() {
        let dir = std::env::temp_dir().join(format!("trs-shortcut-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let k = key(&dir).to_owned();
        assert_eq!(k.len(), 64);
        assert!(key_matches(&k));
        assert!(!key_matches(""));
        assert!(!key_matches(&k[..63]));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
