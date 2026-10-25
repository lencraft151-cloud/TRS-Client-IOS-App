//! Android/iOS: Update-Kanal `mobile` und die APK-Installation.
//!
//! Die Commands gibt es auf allen Plattformen (eine Liste im Handler);
//! installieren kann nur Android. Die APK lädt der Kern geprüft (signiertes
//! Manifest, SHA-256, Größe) nach `<daten>/mobile-update/`, danach übergibt
//! ein kleines Kotlin-Plugin (`TrsMobilePlugin`) sie dem PackageInstaller –
//! das System fragt den Nutzer, bevor etwas installiert wird.

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, State};
use trs_core::mobile_update::{MobileUpdater, Target, UpdateStatus};

use crate::LauncherState;
use crate::commands::tasks::tracked;
use crate::error::CommandResult;

/// Kanal-Prüfung und Download (ein Updater pro App).
pub struct UpdateState(MobileUpdater);

impl UpdateState {
    pub fn new(launcher: &LauncherState) -> trs_core::Result<Self> {
        Ok(Self(MobileUpdater::new(launcher.paths())?))
    }
}

/// Was nach „Installieren“ passiert ist.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InstallOutcome {
    /// `started`: Das System zeigt den Installationsdialog.
    /// iOS: `started` heißt, die Rückfrage „Installieren?“ von iOS ist offen.
    /// `permissionRequired`: Erst „Unbekannte Apps installieren“ für den Launcher erlauben
    /// (die Einstellungsseite ist schon offen), dann erneut versuchen.
    /// iOS ohne Profil: `storeStarted` = SideStore/AltStore ist offen, `noStore` = keiner installiert.
    pub status: String,
}

/// Prüft den Kanal `mobile` (Signatur wie beim TRS-Client-Kanal) – mit „Beta-Versionen“ auch den Beta-Kanal.
#[tauri::command]
pub async fn mobile_update_check(state: State<'_, UpdateState>, launcher: State<'_, LauncherState>) -> CommandResult<UpdateStatus> {
    let beta = launcher.settings().await.mobile_beta;
    Ok(state.0.check(Target::current(), beta).await?)
}

/// Android: lädt die neue APK (Aufgabe mit Fortschritt, abbrechbar) und
/// startet die Installation. iOS: öffnet den `itms-services`-Link der mit Profil
/// signierten IPA – iOS fragt nach und installiert über die laufende App.
/// Andere Plattformen: Fehler.
#[tauri::command]
pub async fn mobile_update_install(
    app: AppHandle,
    state: State<'_, UpdateState>,
    task_id: Option<String>,
) -> CommandResult<InstallOutcome> {
    if cfg!(target_os = "ios") {
        if let Some(link) = state.0.ios_install_url().await {
            crate::open::url(&app, &link).map_err(|e| {
                log::error!("iOS-Update konnte nicht geöffnet werden: {e}");
                trs_core::Error::validation(trs_core::msg!("mobileUpdate.installFailed", "Die Installation konnte nicht gestartet werden."))
            })?;
            return Ok(InstallOutcome { status: "started".into() });
        }
        // Ohne mit Profil signierte IPA (kostenloses Apple-Konto): SideStore installiert und signiert auf dem Gerät.
        let Some(ipa) = state.0.ios_sideload_url().await else {
            return Err(trs_core::Error::validation(trs_core::msg!("mobileUpdate.noUpdate", "Es gibt keine neuere Version.")).into());
        };
        return store_install(&app, ipa).await;
    }
    if !cfg!(target_os = "android") {
        return Err(trs_core::Error::validation(trs_core::msg!(
            "mobileUpdate.androidOnly",
            "Updates installiert die App nur unter Android selbst."
        ))
        .into());
    }
    let path = tracked(&app, task_id, state.0.download_apk()).await?;
    if !state.0.owns(&path) {
        return Err(trs_core::Error::Internal("APK liegt nicht im Update-Ordner".into()).into());
    }
    install(&app, path).await
}

/// iOS: IPA in SideStore/AltStore öffnen. `storeStarted` = der Store ist offen, `noStore` = keiner installiert.
#[cfg(target_os = "ios")]
async fn store_install(app: &AppHandle, ipa: String) -> CommandResult<InstallOutcome> {
    use tauri_plugin_trs_ios::TrsIosExt;
    let handle = app.clone();
    let opened = tauri::async_runtime::spawn_blocking(move || handle.trs_ios().open_store_install(&ipa))
        .await
        .map_err(|e| trs_core::Error::Internal(e.to_string()))?
        .map_err(|e| {
            log::error!("SideStore konnte nicht geöffnet werden: {e}");
            trs_core::Error::validation(trs_core::msg!("mobileUpdate.installFailed", "Die Installation konnte nicht gestartet werden."))
        })?;
    let status = if opened.is_some() { "storeStarted" } else { "noStore" };
    Ok(InstallOutcome { status: status.into() })
}

#[cfg(not(target_os = "ios"))]
async fn store_install(_app: &AppHandle, _ipa: String) -> CommandResult<InstallOutcome> {
    Err(trs_core::Error::UnsupportedOnMobile.into())
}

#[cfg(target_os = "android")]
async fn install(app: &AppHandle, path: std::path::PathBuf) -> CommandResult<InstallOutcome> {
    use tauri::Manager;

    #[derive(Serialize)]
    struct Args {
        path: String,
    }
    let Some(installer) = app.try_state::<android::Installer>() else {
        return Err(trs_core::Error::Internal("Installer-Plugin fehlt".into()).into());
    };
    let handle = installer.0.clone();
    let args = Args { path: path.display().to_string() };
    let outcome = tauri::async_runtime::spawn_blocking(move || handle.run_mobile_plugin::<InstallOutcome>("installApk", args))
        .await
        .map_err(|e| trs_core::Error::Internal(e.to_string()))?
        .map_err(|e| {
            log::error!("APK-Installation fehlgeschlagen: {e}");
            trs_core::Error::validation(trs_core::msg!("mobileUpdate.installFailed", "Die Installation konnte nicht gestartet werden."))
        })?;
    if !matches!(outcome.status.as_str(), "started" | "permissionRequired") {
        return Err(trs_core::Error::Internal(format!("Unbekannter Installer-Status: {}", outcome.status)).into());
    }
    Ok(outcome)
}

/// Android-Zurück-Taste auf der Startseite: App schließen (Activity beenden). Sonst nichts.
#[tauri::command]
pub fn mobile_exit_app(app: AppHandle) {
    #[cfg(target_os = "android")]
    {
        use tauri::Manager;
        if let Some(installer) = app.try_state::<android::Installer>()
            && let Err(e) = installer.0.run_mobile_plugin::<serde_json::Value>("exitApp", ())
        {
            log::warn!("App konnte nicht geschlossen werden: {e}");
        }
    }
    #[cfg(not(target_os = "android"))]
    let _ = app;
}

/// Android: Abholen der Push-Hinweise im Hintergrund (WorkManager, etwa alle 15 min) planen oder abbestellen.
#[cfg(target_os = "android")]
pub async fn schedule_push_poll(app: &AppHandle, enabled: bool, root: &str) -> Result<(), String> {
    use tauri::Manager;

    #[derive(Serialize)]
    struct Args {
        enabled: bool,
        root: String,
    }
    let Some(plugin) = app.try_state::<android::Installer>() else { return Err("Plugin fehlt".into()) };
    let handle = plugin.0.clone();
    let args = Args { enabled, root: root.to_owned() };
    tauri::async_runtime::spawn_blocking(move || handle.run_mobile_plugin::<serde_json::Value>("pushPoll", args))
        .await
        .map_err(|e| e.to_string())?
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Android: Startsymbol (activity-alias) auf `icon` stellen (`"default"`, `"halloween"`); `true`, wenn gewechselt.
#[cfg(target_os = "android")]
pub async fn set_launcher_icon(app: &AppHandle, icon: &str) -> Result<bool, String> {
    use tauri::Manager;

    #[derive(Serialize)]
    struct Args {
        icon: String,
    }
    #[derive(Deserialize)]
    struct Changed {
        #[serde(default)]
        changed: bool,
    }
    let Some(plugin) = app.try_state::<android::Installer>() else { return Err("Plugin fehlt".into()) };
    let handle = plugin.0.clone();
    let args = Args { icon: icon.to_owned() };
    tauri::async_runtime::spawn_blocking(move || handle.run_mobile_plugin::<Changed>("setLauncherIcon", args))
        .await
        .map_err(|e| e.to_string())?
        .map(|r| r.changed)
        .map_err(|e| e.to_string())
}

#[cfg(not(target_os = "android"))]
async fn install(_app: &AppHandle, _path: std::path::PathBuf) -> CommandResult<InstallOutcome> {
    Err(trs_core::Error::UnsupportedOnMobile.into())
}

#[cfg(target_os = "android")]
mod android {
    /// Zugriff auf das Kotlin-Plugin `dev.theredstonee.trslauncher.TrsMobilePlugin`.
    pub struct Installer(pub tauri::plugin::PluginHandle<tauri::Wry>);
}

/// Plugin `trs-mobile`: meldet unter Android das Kotlin-Plugin an. Das
/// Webview darf es nicht direkt aufrufen (keine Rechte in den Capabilities) –
/// nur Rust über [`mobile_update_install`].
#[cfg(mobile)]
pub fn init() -> tauri::plugin::TauriPlugin<tauri::Wry> {
    tauri::plugin::Builder::new("trs-mobile")
        .setup(|app, api| {
            #[cfg(target_os = "android")]
            {
                use tauri::Manager;
                let handle = api.register_android_plugin("dev.theredstonee.trslauncher", "TrsMobilePlugin")?;
                app.manage(android::Installer(handle));
            }
            #[cfg(not(target_os = "android"))]
            let _ = (app, api);
            Ok(())
        })
        .build()
}
