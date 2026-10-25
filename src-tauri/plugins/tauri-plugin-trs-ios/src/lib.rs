//! iOS-Systemfunktionen des TRS Launchers (Swift `TrsIosPlugin`):
//!
//! - **Start-Wächter:** Meldet die Oberfläche nicht binnen 25 s [`TrsIos::ui_ready`], zeigt die App ein natives Fenster
//!   mit „Neu laden“ und „Bericht teilen“ – statt eines schwarzen Bildschirms.
//! - **Absturzberichte:** iOS-Abstürze und Hänger (MetricKit, beim nächsten Start) und Objective-C-Ausnahmen landen als
//!   Text in `Dokumente/Crash Reports` (siehe `src/crash_report.rs` der App). Eingerichtet wird das in `main.mm`.
//! - **Anmeldefenster:** [`TrsIos::auth_start`] öffnet die Microsoft-Anmeldung in einem Fenster über der App
//!   (`ASWebAuthenticationSession`). Die App bleibt dabei vorn – der Loopback-Server bekommt die Weiterleitung.
//!   In Safari würde iOS die App anhalten, und die Anmeldung liefe ins Leere.
//! - **Teilen:** [`TrsIos::share`] öffnet das Teilen-Menü für Dateien (Berichte).
//! - **Sicherungen:** [`TrsIos::backup_dirs`] (Dateien-App bzw. iCloud Drive), [`TrsIos::icloud_download`].
//! - **Kurzbefehle, Widget, Live-Aktivität:** [`TrsIos::shared_dirs`], [`TrsIos::shared_changed`] und
//!   [`TrsIos::live_activity`] (Widget-Erweiterung in `gen/apple/Widgets`).
//! - **Öffnen in …:** [`TrsIos::import_file`] kopiert eine aus der Dateien-App oder Safari geöffnete Datei (an ihrem
//!   Ort, mit Sicherheitsbereich) in den eigenen temporären Ordner.
//!
//! Auf anderen Plattformen meldet jede Funktion „nicht unterstützt“.

use serde::{Deserialize, Serialize};
use tauri::plugin::{Builder, TauriPlugin};
use tauri::{Manager, Runtime};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_trs_ios);

/// Fehler des nativen Teils (Code wie `unsupported`).
#[derive(Debug)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// Wie das Anmeldefenster zu ging.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AuthOutcome {
    /// Vom Nutzer geschlossen – oder von [`TrsIos::auth_close`] nach der Weiterleitung.
    Cancelled,
    /// iOS hat das Fenster nicht geöffnet (z. B. kein Fenster da).
    Failed,
}

#[derive(Debug, Deserialize)]
struct AuthResult {
    status: AuthOutcome,
}

/// Gerät und Ausstattung (Leistungsprofil, Berichte).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DeviceInfo {
    /// Modellkennung, z. B. `iPhone14,4`.
    pub model: String,
    /// iOS-Version, z. B. `27.2`.
    pub system_version: String,
    /// Arbeitsspeicher in Byte.
    pub memory_bytes: u64,
    /// Rechenkerne.
    pub processor_count: u32,
    /// Stromsparmodus an.
    pub low_power: bool,
}

#[derive(Serialize)]
struct UrlArgs<'a> {
    url: &'a str,
}

#[derive(Serialize)]
struct ShareArgs<'a> {
    paths: &'a [String],
}

#[derive(Debug, Deserialize)]
struct ImportedFile {
    path: String,
}

#[derive(Debug, Deserialize)]
struct StoreOpened {
    store: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SharedDirs {
    dirs: Vec<String>,
}

/// Stand einer Aufgabe für die Live-Aktivität.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityUpdate<'a> {
    /// Aufgaben-ID (eine Aktivität je Aufgabe).
    pub id: &'a str,
    /// `download`, `install`, `modpack` … (Symbol).
    pub kind: &'a str,
    pub title: &'a str,
    pub detail: &'a str,
    /// 0…1, negativ = unbestimmt.
    pub progress: f64,
    /// Fertig (oder abgebrochen): die Aktivität endet kurz danach.
    pub done: bool,
}

/// Ordner für Sicherungen (siehe [`TrsIos::backup_dirs`]).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct BackupDirs {
    /// `Dokumente/Backups` – in der Dateien-App unter „Auf meinem iPhone › TRS Launcher“.
    pub local: Option<std::path::PathBuf>,
    /// `iCloud Drive › TRS Launcher › Backups` – nur mit iCloud-Entitlement und angemeldetem iCloud.
    pub icloud: Option<std::path::PathBuf>,
}

#[derive(Serialize)]
struct PathArg<'a> {
    path: &'a str,
}

/// Zugriff auf den nativen Teil.
pub struct TrsIos<R: Runtime> {
    #[cfg(target_os = "ios")]
    handle: tauri::plugin::PluginHandle<R>,
    #[cfg(not(target_os = "ios"))]
    _marker: std::marker::PhantomData<fn() -> R>,
}

impl<R: Runtime> TrsIos<R> {
    /// Blockiert bis zur Antwort – aus Rust nur außerhalb der Async-Runtime aufrufen (`spawn_blocking`).
    #[cfg(target_os = "ios")]
    fn call<T: serde::de::DeserializeOwned, A: Serialize>(&self, command: &str, args: A) -> Result<T> {
        self.handle.run_mobile_plugin(command, args).map_err(|e| match e {
            tauri::plugin::mobile::PluginInvokeError::InvokeRejected(r) => Error(r.code.or(r.message).unwrap_or_else(|| "rejected".into())),
            other => Error(other.to_string()),
        })
    }

    #[cfg(not(target_os = "ios"))]
    fn call<T: serde::de::DeserializeOwned, A: Serialize>(&self, _command: &str, _args: A) -> Result<T> {
        Err(Error("unsupported".into()))
    }

    /// Die Oberfläche ist da: Start-Wächter aus (ein offenes Wächter-Fenster schließt sich).
    pub fn ui_ready(&self) -> Result<()> {
        self.call::<serde_json::Value, _>("uiReady", ()).map(|_| ())
    }

    /// Öffnet `url` im Anmeldefenster und wartet, bis es zu ist (blockiert – nur aus einem eigenen Thread).
    pub fn auth_start(&self, url: &str) -> Result<AuthOutcome> {
        self.call::<AuthResult, _>("authStart", UrlArgs { url }).map(|r| r.status)
    }

    /// Schließt ein offenes Anmeldefenster (nach der Weiterleitung oder beim Abbruch).
    pub fn auth_close(&self) -> Result<()> {
        self.call::<serde_json::Value, _>("authClose", ()).map(|_| ())
    }

    /// Teilen-Menü für diese Dateien (absolute Pfade).
    pub fn share(&self, paths: &[String]) -> Result<()> {
        self.call::<serde_json::Value, _>("share", ShareArgs { paths }).map(|_| ())
    }

    /// Kopiert eine geöffnete Datei (`file://…`, evtl. in iCloud Drive) in den temporären Ordner der App.
    pub fn import_file(&self, url: &str) -> Result<std::path::PathBuf> {
        self.call::<ImportedFile, _>("importFile", UrlArgs { url }).map(|f| std::path::PathBuf::from(f.path))
    }

    /// Ordner für `shared.json` (App-Gruppe zuerst, dann Application Support der App).
    pub fn shared_dirs(&self) -> Result<Vec<std::path::PathBuf>> {
        self.call::<SharedDirs, _>("sharedDirs", ()).map(|d| d.dirs.into_iter().map(std::path::PathBuf::from).collect())
    }

    /// `shared.json` geändert: Widget neu laden, Kurzbefehle aktualisieren.
    pub fn shared_changed(&self) -> Result<()> {
        self.call::<serde_json::Value, _>("sharedChanged", ()).map(|_| ())
    }

    /// Live-Aktivität starten, aktualisieren oder beenden.
    pub fn live_activity(&self, update: &ActivityUpdate<'_>) -> Result<()> {
        self.call::<serde_json::Value, _>("liveActivity", update).map(|_| ())
    }

    /// Ordner für Sicherungen (lokal, iCloud).
    pub fn backup_dirs(&self) -> Result<BackupDirs> {
        self.call("backupDirs", ())
    }

    /// Sicherung aus iCloud aufs Gerät holen (startet nur den Download).
    pub fn icloud_download(&self, path: &std::path::Path) -> Result<()> {
        self.call::<serde_json::Value, _>("icloudDownload", PathArg { path: &path.to_string_lossy() }).map(|_| ())
    }

    /// Modell, iOS-Version, Arbeitsspeicher.
    pub fn device_info(&self) -> Result<DeviceInfo> {
        self.call("deviceInfo", ())
    }

    /// IPA in SideStore (sonst AltStore) zum Installieren öffnen. Liefert den geöffneten Store, `None` = keiner da.
    pub fn open_store_install(&self, ipa_url: &str) -> Result<Option<String>> {
        self.call::<StoreOpened, _>("openStoreInstall", UrlArgs { url: ipa_url }).map(|r| r.store)
    }

    /// Bilder aus „Fotos“ oder „Dateien“ wählen (blockiert bis zur Auswahl). Kopien im temporären Ordner der App;
    /// Formate außerhalb von `extensions` (HEIC …) als PNG bzw. JPEG. `None` = abgebrochen.
    pub fn pick_images(&self, source: ImageSource, multiple: bool, extensions: &[&str]) -> Result<Option<Vec<std::path::PathBuf>>> {
        self.call::<PickedImages, _>("pickImages", PickImagesArgs { source, multiple, extensions })
            .map(|p| p.paths.map(|paths| paths.into_iter().map(std::path::PathBuf::from).collect()))
    }
}

/// Woher Bilder kommen: Mediathek („Fotos“) oder Dateien-App.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ImageSource {
    Photos,
    Files,
}

#[derive(Serialize)]
struct PickImagesArgs<'a> {
    source: ImageSource,
    multiple: bool,
    extensions: &'a [&'a str],
}

#[derive(Debug, Deserialize)]
struct PickedImages {
    paths: Option<Vec<String>>,
}

/// Zugriff über `app.trs_ios()`.
pub trait TrsIosExt<R: Runtime> {
    fn trs_ios(&self) -> &TrsIos<R>;
}

impl<R: Runtime, T: Manager<R>> TrsIosExt<R> for T {
    fn trs_ios(&self) -> &TrsIos<R> {
        self.state::<TrsIos<R>>().inner()
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("trs-ios")
        .setup(|app, api| {
            #[cfg(target_os = "ios")]
            let state = TrsIos { handle: api.register_ios_plugin(init_plugin_trs_ios)? };
            #[cfg(not(target_os = "ios"))]
            let state = {
                let _ = api;
                TrsIos::<R> { _marker: std::marker::PhantomData }
            };
            app.manage(state);
            Ok(())
        })
        .build()
}
