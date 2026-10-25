//! Bilder wählen für Skins, Instanz-Symbol/-Banner, Symbol-Editor, Chat und Umhänge.
//!
//! iOS: Die Oberfläche fragt vorher „Fotos“ oder „Dateien“ ([`ImageSource`]); gewählt wird mit dem eigenen Picker des
//! iOS-Plugins (Fotos der Kamera kommen als HEIC und werden dort umgewandelt). Der Dateidialog von Tauri zeigt bei
//! reinen Bildfiltern nur die Mediathek – Skins aus Safari-Downloads lägen dann unerreichbar in „Dateien“.
//! Andere Systeme: der gewohnte Dateidialog mit Filter.

use std::path::PathBuf;

use serde::Deserialize;
use tauri::AppHandle;
use tauri_plugin_dialog::DialogExt;

/// Woher Bilder kommen (iOS): Mediathek („Fotos“) oder Dateien-App. Andere Systeme ignorieren es.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ImageSource {
    Photos,
    Files,
}

/// Bildformate, die Symbol, Banner und Chat lesen.
pub const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "webp"];

/// Was gewählt wird.
pub struct ImagePick<'a> {
    pub title: &'a str,
    /// Name des Filters im Dateidialog.
    pub filter: &'a str,
    /// Erlaubte Endungen (klein).
    pub extensions: &'a [&'a str],
    pub multiple: bool,
}

/// Blockiert bis zur Auswahl – nur in `spawn_blocking`. `None` = abgebrochen (oder nichts Lesbares gewählt).
pub fn pick_blocking(app: &AppHandle, pick: &ImagePick<'_>, source: Option<ImageSource>) -> Option<Vec<PathBuf>> {
    #[cfg(target_os = "ios")]
    if let Some(source) = source {
        use tauri_plugin_trs_ios::TrsIosExt;
        let source = match source {
            ImageSource::Photos => tauri_plugin_trs_ios::ImageSource::Photos,
            ImageSource::Files => tauri_plugin_trs_ios::ImageSource::Files,
        };
        return match app.trs_ios().pick_images(source, pick.multiple, pick.extensions) {
            Ok(paths) => paths.filter(|p| !p.is_empty()),
            Err(e) => {
                log::warn!("Bilder nicht gewählt: {e}");
                None
            }
        };
    }
    #[cfg(not(target_os = "ios"))]
    let _ = source;
    let dialog = app.dialog().file().set_title(pick.title).add_filter(pick.filter, pick.extensions);
    let picked = if pick.multiple {
        dialog.blocking_pick_files()
    } else {
        dialog.blocking_pick_file().map(|p| vec![p])
    }?;
    let files: Vec<PathBuf> = picked.into_iter().filter_map(|p| p.into_path().ok()).collect();
    (!files.is_empty()).then_some(files)
}

/// Wie [`pick_blocking`], aus async-Code.
pub async fn pick(app: &AppHandle, pick: ImagePick<'static>, source: Option<ImageSource>) -> Option<Vec<PathBuf>> {
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || pick_blocking(&app, &pick, source)).await.ok().flatten()
}
