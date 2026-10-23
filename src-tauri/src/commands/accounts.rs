use tauri::ipc::Channel;
use tauri::{AppHandle, State};
use trs_core::auth::{Account, DeviceCode};

use crate::LauncherState;
use crate::error::CommandResult;

#[tauri::command]
pub async fn list_accounts(launcher: State<'_, LauncherState>) -> CommandResult<Vec<Account>> {
    Ok(launcher.accounts().list().await?)
}

/// Öffnet die Microsoft-Anmeldung im Standardbrowser und wartet auf den Redirect.
/// iOS: im Anmeldefenster über der App – in Safari hielte iOS die App an, und die Weiterleitung käme nie an.
#[tauri::command]
pub async fn login_browser(app: AppHandle, launcher: State<'_, LauncherState>) -> CommandResult<Account> {
    #[cfg(target_os = "ios")]
    let account = ios_login_browser(&app, &launcher).await?;
    #[cfg(not(target_os = "ios"))]
    let account = {
        let open = move |url: &str| {
            if let Err(e) = crate::open::url(&app, url) {
                log::error!("Browser konnte nicht geöffnet werden: {e}");
            }
        };
        launcher.accounts().login_browser(&open).await?
    };
    // Neuer (aktiver) Account: gleich mit seinem TRS-Konto abgleichen (nur mit Einwilligung).
    launcher.trs_sync_kick();
    // Laufende Spiele mit TRS Client laden ihre Kontenliste neu.
    launcher.link_accounts_changed();
    Ok(account)
}

/// iOS: Anmeldung im Anmeldefenster (`ASWebAuthenticationSession`). Schließt der Nutzer das Fenster, bricht die
/// Anmeldung ab; nach der Weiterleitung schließt der Launcher es selbst.
#[cfg(target_os = "ios")]
async fn ios_login_browser(app: &AppHandle, launcher: &LauncherState) -> trs_core::Result<Account> {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tauri_plugin_trs_ios::{AuthOutcome, TrsIosExt};

    // Gesetzt, sobald die Anmeldung vorbei ist: Dann schließt der Launcher das Fenster – kein Abbruch.
    let finished = Arc::new(AtomicBool::new(false));
    let open = {
        let (app, launcher, finished) = (app.clone(), Arc::clone(launcher), Arc::clone(&finished));
        move |url: &str| {
            let (app, launcher, finished, url) = (app.clone(), Arc::clone(&launcher), Arc::clone(&finished), url.to_owned());
            // Blockiert, bis das Fenster zu ist – eigener Thread.
            std::thread::spawn(move || {
                let outcome = app.trs_ios().auth_start(&url);
                if finished.load(Ordering::SeqCst) {
                    return;
                }
                match outcome {
                    Ok(AuthOutcome::Cancelled) => {}
                    Ok(AuthOutcome::Failed) => log::error!("Anmeldefenster ließ sich nicht öffnen"),
                    Err(e) => log::error!("Anmeldefenster: {e}"),
                }
                tauri::async_runtime::block_on(launcher.accounts().cancel_login());
            });
        }
    };
    let result = launcher.accounts().login_browser(&open).await;
    finished.store(true, Ordering::SeqCst);
    let app = app.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || app.trs_ios().auth_close()).await;
    result
}

/// Device-Code-Login: Der Code geht über den Channel ans Frontend, die
/// Microsoft-Seite zum Eingeben wird gleich mit geöffnet.
#[tauri::command]
pub async fn login_device_code(
    app: AppHandle,
    launcher: State<'_, LauncherState>,
    on_code: Channel<DeviceCode>,
) -> CommandResult<Account> {
    let show = move |code: &DeviceCode| {
        let _ = on_code.send(code.clone());
        // Die URL kommt von Microsoft; trotzdem nur bekannte Hosts öffnen.
        let trusted = ["https://www.microsoft.com/", "https://microsoft.com/", "https://login.microsoftonline.com/", "https://login.live.com/"]
            .iter()
            .any(|prefix| code.verification_uri.starts_with(prefix));
        if trusted && let Err(e) = crate::open::url(&app, &code.verification_uri) {
            log::error!("Browser konnte nicht geöffnet werden: {e}");
        }
    };
    let account = launcher.accounts().login_device_code(&show).await?;
    launcher.trs_sync_kick();
    launcher.link_accounts_changed();
    Ok(account)
}

#[tauri::command]
pub async fn cancel_login(launcher: State<'_, LauncherState>) -> CommandResult<()> {
    launcher.accounts().cancel_login().await;
    Ok(())
}

#[tauri::command]
pub async fn set_active_account(launcher: State<'_, LauncherState>, id: String) -> CommandResult<()> {
    launcher.accounts().set_active(&id).await?;
    // Präsenz sofort auf den neuen Account umstellen, Sammlung mit dessen TRS-Konto abgleichen.
    launcher.trs().presence_kick();
    launcher.trs_sync_kick();
    launcher.link_accounts_changed();
    Ok(())
}

#[tauri::command]
pub async fn remove_account(launcher: State<'_, LauncherState>, id: String) -> CommandResult<()> {
    // Vorher bei der TRS API abmelden (Präsenz zurück, Token widerrufen).
    launcher.trs_forget_account(&id).await;
    launcher.accounts().remove(&id).await?;
    launcher.link_accounts_changed();
    Ok(())
}
