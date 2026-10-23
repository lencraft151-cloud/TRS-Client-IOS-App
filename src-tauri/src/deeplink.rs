//! Link-Protokoll `trs-launcher://` (Knöpfe auf der Website).
//!
//! Angenommen werden nur diese Formen, alle streng geprüft:
//! - `trs-launcher://pack/<Code>` ([`trs_core::pack_share::pack_code_from_link`]) → Dialog „Modpack per Code“ mit
//!   Vorschau – installiert wird erst nach einem Klick.
//! - `trs-launcher://web-login/<Token>` ([`trs_core::trs_api::web_login::web_login_token_from_link`]) → Dialog
//!   „Auf der Website anmelden“ – bestätigt wird erst nach einem Klick, nie automatisch.
//! - `trs-launcher://remote-pair/<Code>` ([`trs_core::trs_api::remote::pair_code_from_link`], QR-Code der
//!   PC-Fernbedienung) → am Handy die Seite „PC“ mit dem Code – gekoppelt wird erst nach einem Klick.
//! - `trs-launcher://notify/<Route>` (Tipp auf eine Push-Benachrichtigung, Route aus §33.5 wie `/chat/c…`) → die
//!   Oberfläche öffnet die passende Seite. Es passiert nichts außer Navigation.
//! - `trs-launcher://modpack/modrinth/<ID oder Slug>` bzw. `trs-launcher://modpack/curseforge/<Zahl>` (z. B. aus den
//!   empfohlenen Modpacks) → Projektseite im Launcher. Installiert wird erst nach einem Klick.
//!
//! - `trs-launcher://play/<Instanz-ID oder last>?k=<Schlüssel>` (iOS-Kurzbefehl, Siri, Widget) → Seite der Instanz;
//!   gestartet wird nur mit dem Schlüssel dieser Installation ([`crate::shortcuts`]), sonst erst nach einem Klick.
//! - `file://…/<name>.mrpack|.zip|.png|.trsbackup` (iOS „Öffnen in TRS Launcher“ aus der Dateien-App oder Safari) →
//!   Modpack: der Import-Dialog mit Vorschau; Skin: die Seite „Skins“ mit der Übernahme; Sicherung: der Dialog
//!   „Wiederherstellen“. Angelegt bzw. eingespielt wird erst nach einem Klick.
//!
//! Läuft der Launcher schon, reicht das Single-Instance-Plugin den Link an das offene Fenster weiter.
//! Android/iOS: Das Schema steht im App-Manifest bzw. in der Info.plist (`plugins.deep-link.mobile`), das System
//! reicht Links an die laufende App weiter.

use std::sync::Mutex;

use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_deep_link::DeepLinkExt;

/// Code aus einem Link beim Start, bis die Oberfläche bereit ist und ihn abholt.
#[derive(Default)]
pub struct PendingPackLink(Mutex<Option<String>>);

/// Link-Token einer Website-Anmeldung beim Start, bis die Oberfläche ihn abholt.
#[derive(Default)]
pub struct PendingWebLogin(Mutex<Option<String>>);

/// Kopplungs-Code der Fernbedienung beim Start, bis die Oberfläche ihn abholt.
#[derive(Default)]
pub struct PendingRemotePair(Mutex<Option<String>>);

/// Route einer angetippten Push-Benachrichtigung beim Start, bis die Oberfläche sie abholt.
#[derive(Default)]
pub struct PendingPushTarget(Mutex<Option<String>>);

/// Modpack-Projekt (`modrinth/<ID>` bzw. `curseforge/<Zahl>`) beim Start, bis die Oberfläche es abholt.
#[derive(Default)]
pub struct PendingModpackLink(Mutex<Option<String>>);

/// Instanz aus einem Kurzbefehl/Widget beim Start, bis die Oberfläche sie abholt.
#[derive(Default)]
pub struct PendingPlay(Mutex<Option<PlayRequest>>);

/// `trs-launcher://play/…`: welche Instanz (`last` = zuletzt gespielte) und ob der Schlüssel stimmte.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayRequest {
    pub instance: String,
    /// Mit Schlüssel (Kurzbefehl/Widget): gleich starten. Sonst nur die Instanz zeigen.
    pub start: bool,
}

/// `trs-launcher://play/survival?k=…` → Instanz-ID (oder `last`) und Schlüssel.
fn play_from_link(url: &str) -> Option<(String, String)> {
    let parsed = tauri::Url::parse(url).ok()?;
    if !parsed.scheme().eq_ignore_ascii_case(trs_core::pack_share::LINK_SCHEME) || url.len() > 300 || parsed.host_str() != Some("play") {
        return None;
    }
    let id = parsed.path().trim_matches('/');
    if id != "last" && trs_core::instance::validate_id(id).is_err() {
        return None;
    }
    let key = parsed.query_pairs().find(|(k, _)| k == "k").map(|(_, v)| v.into_owned()).unwrap_or_default();
    Some((id.to_owned(), key))
}

/// Geöffnete Modpack-Datei (gelesen und vorgemerkt), bis die Oberfläche sie abholt.
#[derive(Default)]
pub struct PendingOpenedPack(Mutex<Option<crate::commands::export::PickedPack>>);

/// Geöffnete Skin-Datei (Marke im [`crate::commands::system::DropState`]), bis die Seite „Skins“ sie abholt.
#[derive(Default)]
pub struct PendingOpenedSkins(Mutex<Option<u64>>);

/// Was eine geöffnete Datei ist – nach der Endung.
#[derive(Debug, PartialEq, Eq)]
enum OpenedKind {
    Pack,
    Skin,
    /// Sicherung des Launchers (`.trsbackup`, [`crate::backup`]).
    Backup,
}

fn opened_kind(name: &str) -> Option<OpenedKind> {
    let ext = name.rsplit_once('.')?.1.to_ascii_lowercase();
    match ext.as_str() {
        "mrpack" | "zip" => Some(OpenedKind::Pack),
        "png" => Some(OpenedKind::Skin),
        "trsbackup" => Some(OpenedKind::Backup),
        _ => None,
    }
}

/// `file://`-Link einer Datei, mit der der Launcher etwas anfangen kann.
fn opened_file_from_link(url: &str) -> Option<String> {
    let parsed = tauri::Url::parse(url).ok()?;
    if parsed.scheme() != "file" {
        return None;
    }
    let name = parsed.path_segments()?.next_back()?;
    opened_kind(name).map(|_| url.to_owned())
}

enum Link {
    Pack(String),
    WebLogin(String),
    RemotePair(String),
    PushTarget(String),
    /// `modrinth/<ID>` bzw. `curseforge/<Zahl>`.
    Modpack(String),
    /// `file://…` (Modpack oder Skin).
    File(String),
    Play(PlayRequest),
}

/// `trs-launcher://modpack/modrinth/AANobbMI` → `modrinth/AANobbMI`; `…/curseforge/925200` → `curseforge/925200`.
/// Modrinth: ID oder Slug (`[A-Za-z0-9_-]`, bis 64 Zeichen), CurseForge: Zahl. Sonst nichts.
fn modpack_from_link(url: &str) -> Option<String> {
    use trs_core::featured::{FeaturedSource, is_project_id};
    let (scheme, rest) = url.split_once("://")?;
    if !scheme.eq_ignore_ascii_case(trs_core::pack_share::LINK_SCHEME) || url.len() > 200 {
        return None;
    }
    let rest = rest.strip_prefix("modpack/")?;
    let rest = rest.split(['?', '#']).next()?.trim_end_matches('/');
    let (platform, id) = rest.split_once('/')?;
    let source = match platform {
        "modrinth" => FeaturedSource::Modrinth,
        "curseforge" => FeaturedSource::Curseforge,
        _ => return None,
    };
    is_project_id(source, id).then(|| format!("{platform}/{id}"))
}

/// `trs-launcher://notify/chat/c123` → `/chat/c123` (nur Routen nach §33.5).
fn push_target_from_link(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    if !scheme.eq_ignore_ascii_case(trs_core::pack_share::LINK_SCHEME) || url.len() > 300 {
        return None;
    }
    let rest = rest.strip_prefix("notify")?;
    let route = rest.split(['?', '#']).next()?.trim_end_matches('/');
    trs_core::trs_api::push::push_target(route).then(|| route.to_owned())
}

fn parse(url: &str) -> Option<Link> {
    if let Some(file) = opened_file_from_link(url) {
        return Some(Link::File(file));
    }
    if let Some((instance, key)) = play_from_link(url) {
        return Some(Link::Play(PlayRequest { instance, start: crate::shortcuts::key_matches(&key) }));
    }
    if let Some(code) = trs_core::pack_share::pack_code_from_link(url) {
        return Some(Link::Pack(code));
    }
    if let Some(code) = trs_core::trs_api::remote::pair_code_from_link(url) {
        return Some(Link::RemotePair(code));
    }
    if let Some(target) = push_target_from_link(url) {
        return Some(Link::PushTarget(target));
    }
    if let Some(project) = modpack_from_link(url) {
        return Some(Link::Modpack(project));
    }
    trs_core::trs_api::web_login::web_login_token_from_link(url).map(Link::WebLogin)
}

/// Links verarbeiten: gültigen Wert merken, ans Fenster schicken, Fenster nach vorne holen.
fn handle(app: &AppHandle, urls: impl IntoIterator<Item = String>) {
    let Some(link) = urls.into_iter().find_map(|u| parse(&u)) else { return };
    match link {
        Link::Pack(code) => {
            log::info!("Link geöffnet: Modpack {code}");
            if let Some(state) = app.try_state::<PendingPackLink>() {
                *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(code.clone());
            }
            let _ = app.emit("open-pack-link", code);
        }
        Link::WebLogin(token) => {
            // Den Token nicht ins Log schreiben.
            log::info!("Link geöffnet: Anmeldung auf der Website");
            if let Some(state) = app.try_state::<PendingWebLogin>() {
                *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(token.clone());
            }
            let _ = app.emit("open-web-login", token);
        }
        Link::RemotePair(code) => {
            log::info!("Link geöffnet: Fernbedienung koppeln");
            if let Some(state) = app.try_state::<PendingRemotePair>() {
                *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(code.clone());
            }
            let _ = app.emit("open-remote-pair", code);
        }
        Link::PushTarget(target) => {
            log::info!("Link geöffnet: Benachrichtigung");
            if let Some(state) = app.try_state::<PendingPushTarget>() {
                *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(target.clone());
            }
            let _ = app.emit("open-push-target", target);
        }
        Link::Modpack(project) => {
            log::info!("Link geöffnet: Modpack {project}");
            if let Some(state) = app.try_state::<PendingModpackLink>() {
                *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(project.clone());
            }
            let _ = app.emit("open-modpack-link", project);
        }
        Link::File(url) => {
            log::info!("Datei geöffnet");
            tauri::async_runtime::spawn(open_file(app.clone(), url));
        }
        Link::Play(request) => {
            log::info!("Link geöffnet: Instanz {} (starten: {})", request.instance, request.start);
            if let Some(state) = app.try_state::<PendingPlay>() {
                *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(request.clone());
            }
            let _ = app.emit("open-play", request);
        }
    }
    if let Some(window) = app.get_webview_window("main") {
        #[cfg(desktop)]
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Geöffnete Datei übernehmen: in den eigenen Ordner kopieren (iOS) und je nach Art vormerken.
async fn open_file(app: AppHandle, url: String) {
    let path = match local_copy(&app, &url).await {
        Ok(path) => path,
        Err(e) => {
            log::warn!("Geöffnete Datei nicht übernommen: {e}");
            return;
        }
    };
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned();
    match opened_kind(&name) {
        Some(OpenedKind::Pack) => {
            let (Some(launcher), Some(picks)) =
                (app.try_state::<crate::LauncherState>(), app.try_state::<crate::commands::export::PackPickState>())
            else {
                return;
            };
            match crate::commands::export::pick_path(&launcher, &picks, path).await {
                Ok(pack) => {
                    if let Some(state) = app.try_state::<PendingOpenedPack>() {
                        *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(pack);
                    }
                    let _ = app.emit("open-pack-file", ());
                }
                Err(e) => {
                    log::warn!("Geöffnete Datei ist kein lesbares Modpack: {e}");
                    let _ = app.emit("open-file-failed", e.to_user());
                }
            }
        }
        Some(OpenedKind::Skin) => {
            let Some(drops) = app.try_state::<crate::commands::system::DropState>() else { return };
            let crate::commands::system::DropEvent::Drop { token, .. } = drops.store(vec![path]) else { return };
            if let Some(state) = app.try_state::<PendingOpenedSkins>() {
                *state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(token);
            }
            let _ = app.emit("open-skin-files", ());
        }
        Some(OpenedKind::Backup) => crate::backup::opened(&app, path),
        None => {}
    }
}

/// iOS: Die Datei liegt an ihrem Ort (Dateien-App, iCloud Drive) – das Plugin kopiert sie mit Zugriffsrecht.
#[cfg(target_os = "ios")]
async fn local_copy(app: &AppHandle, url: &str) -> Result<std::path::PathBuf, String> {
    use tauri_plugin_trs_ios::TrsIosExt;
    let (app, url) = (app.clone(), url.to_owned());
    tauri::async_runtime::spawn_blocking(move || app.trs_ios().import_file(&url))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.to_string())
}

#[cfg(not(target_os = "ios"))]
async fn local_copy(_app: &AppHandle, url: &str) -> Result<std::path::PathBuf, String> {
    tauri::Url::parse(url).ok().and_then(|u| u.to_file_path().ok()).ok_or_else(|| "kein Dateipfad".to_owned())
}

/// Im `setup`: Protokoll anmelden (wo nötig), Start-Link und spätere Links annehmen.
pub fn setup(app: &tauri::App) {
    app.manage(PendingPackLink::default());
    app.manage(PendingWebLogin::default());
    app.manage(PendingRemotePair::default());
    app.manage(PendingPushTarget::default());
    app.manage(PendingModpackLink::default());
    app.manage(PendingOpenedPack::default());
    app.manage(PendingPlay::default());
    app.manage(PendingOpenedSkins::default());
    // Installer melden das Protokoll an; zusätzlich beim Start (nur für den eigenen Benutzer), damit es auch nach
    // Updates über ältere Installer, im AppImage und in Entwicklungs-Builds zum laufenden Programm zeigt.
    #[cfg(any(target_os = "linux", windows))]
    if let Err(e) = app.deep_link().register_all() {
        log::warn!("Link-Protokoll trs-launcher:// nicht angemeldet: {e}");
    }
    if let Ok(Some(urls)) = app.deep_link().get_current() {
        handle(app.handle(), urls.into_iter().map(|u| u.to_string()));
    }
    let handle_app = app.handle().clone();
    app.deep_link().on_open_url(move |event| {
        handle(&handle_app, event.urls().into_iter().map(|u| u.to_string()));
    });
}

/// Die Oberfläche holt einen beim Start mitgegebenen Link ab (einmalig).
#[tauri::command]
pub fn take_pending_pack_link(state: State<'_, PendingPackLink>) -> Option<String> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

/// Wie [`take_pending_pack_link`], für `trs-launcher://web-login/<Token>`.
#[tauri::command]
pub fn take_pending_web_login(state: State<'_, PendingWebLogin>) -> Option<String> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

/// Wie [`take_pending_pack_link`], für `trs-launcher://remote-pair/<Code>`.
#[tauri::command]
pub fn take_pending_remote_pair(state: State<'_, PendingRemotePair>) -> Option<String> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

/// Wie [`take_pending_pack_link`], für `trs-launcher://notify/<Route>`.
#[tauri::command]
pub fn take_pending_push_target(state: State<'_, PendingPushTarget>) -> Option<String> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

/// Wie [`take_pending_pack_link`], für `trs-launcher://modpack/<Plattform>/<ID>`.
#[tauri::command]
pub fn take_pending_modpack_link(state: State<'_, PendingModpackLink>) -> Option<String> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

/// Instanz aus einem Kurzbefehl/Widget (einmalig).
#[tauri::command]
pub fn take_pending_play(state: State<'_, PendingPlay>) -> Option<PlayRequest> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

/// Geöffnete Modpack-Datei (einmalig) – für den Import-Dialog.
#[tauri::command]
pub fn take_opened_pack(state: State<'_, PendingOpenedPack>) -> Option<crate::commands::export::PickedPack> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

/// Liegt eine geöffnete Skin-Datei bereit? (Die Seite „Skins“ holt sie mit [`take_opened_skins`].)
#[tauri::command]
pub fn opened_skins_pending(state: State<'_, PendingOpenedSkins>) -> bool {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
}

/// Marke der geöffneten Skin-Datei (einmalig) – weiter wie beim Hineinziehen (`stage_dropped_skins`).
#[tauri::command]
pub fn take_opened_skins(state: State<'_, PendingOpenedSkins>) -> Option<u64> {
    state.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_links_carry_only_known_routes() {
        assert_eq!(push_target_from_link("trs-launcher://notify/chat/c0123456789abcdef0123").as_deref(), Some("/chat/c0123456789abcdef0123"));
        assert_eq!(push_target_from_link("TRS-LAUNCHER://notify/friends/requests/").as_deref(), Some("/friends/requests"));
        assert_eq!(push_target_from_link("trs-launcher://notify/issues/42?x=1").as_deref(), Some("/issues/42"));
        assert!(push_target_from_link("trs-launcher://notify/").is_none());
        assert!(push_target_from_link("trs-launcher://notify/../etc").is_none());
        assert!(push_target_from_link("trs-launcher://notifyx/chat").is_none());
        assert!(push_target_from_link("https://notify/chat").is_none());
        assert!(matches!(parse("trs-launcher://notify/worlds/r1/requests"), Some(Link::PushTarget(t)) if t == "/worlds/r1/requests"));
    }

    #[test]
    fn play_links_need_a_valid_instance() {
        assert_eq!(play_from_link("trs-launcher://play/survival?k=abc"), Some(("survival".into(), "abc".into())));
        assert_eq!(play_from_link("trs-launcher://play/last"), Some(("last".into(), String::new())));
        // `..` löst die URL selbst auf; übrig bleiben nur gültige IDs.
        assert_eq!(play_from_link("trs-launcher://play/../etc").map(|(id, _)| id), Some("etc".into()));
        assert!(play_from_link("trs-launcher://play/a/b").is_none());
        assert!(play_from_link("trs-launcher://play/a%2F..%2Fb").is_none());
        assert!(play_from_link("trs-launcher://play/").is_none());
        assert!(play_from_link("trs-launcher://pack/ABCD").is_none());
        assert!(play_from_link("https://play/survival").is_none());
        // Ohne gespeicherten Schlüssel wird nie gleich gestartet.
        assert!(matches!(parse("trs-launcher://play/survival?k=x"), Some(Link::Play(PlayRequest { start: false, .. }))));
    }

    #[test]
    fn opened_files_by_extension() {
        assert!(matches!(parse("file:///private/var/mobile/Library/Mobile%20Documents/Pack.mrpack"), Some(Link::File(_))));
        assert!(matches!(parse("file:///tmp/Skin.PNG"), Some(Link::File(_))));
        assert!(matches!(parse("file:///tmp/Pack.zip"), Some(Link::File(_))));
        assert!(parse("file:///tmp/notes.txt").is_none());
        assert!(parse("file:///tmp/").is_none());
        assert!(opened_file_from_link("https://example.com/pack.mrpack").is_none());
        assert_eq!(opened_kind("a.MRPACK"), Some(OpenedKind::Pack));
        assert_eq!(opened_kind("skin.png"), Some(OpenedKind::Skin));
        assert_eq!(opened_kind("TRS-Launcher_2026-10-23.trsbackup"), Some(OpenedKind::Backup));
        assert_eq!(opened_kind("mod.jar"), None);
        assert_eq!(opened_kind("ohne-endung"), None);
    }

    #[test]
    fn modpack_links_open_only_valid_projects() {
        assert_eq!(modpack_from_link("trs-launcher://modpack/modrinth/AANobbMI").as_deref(), Some("modrinth/AANobbMI"));
        assert_eq!(modpack_from_link("TRS-LAUNCHER://modpack/modrinth/fabulously-optimized/?x=1").as_deref(), Some("modrinth/fabulously-optimized"));
        assert_eq!(modpack_from_link("trs-launcher://modpack/curseforge/925200").as_deref(), Some("curseforge/925200"));
        assert!(modpack_from_link("trs-launcher://modpack/curseforge/abc").is_none());
        assert!(modpack_from_link("trs-launcher://modpack/curseforge/0123").is_none());
        assert!(modpack_from_link("trs-launcher://modpack/modrinth/../etc").is_none());
        assert!(modpack_from_link("trs-launcher://modpack/modrinth/a/b").is_none());
        assert!(modpack_from_link("trs-launcher://modpack/modrinth/").is_none());
        assert!(modpack_from_link("trs-launcher://modpack/github/x").is_none());
        assert!(modpack_from_link(&format!("trs-launcher://modpack/modrinth/{}", "a".repeat(65))).is_none());
        assert!(modpack_from_link("https://modpack/modrinth/AANobbMI").is_none());
        assert!(matches!(parse("trs-launcher://modpack/curseforge/925200"), Some(Link::Modpack(p)) if p == "curseforge/925200"));
        // Codes geteilter Modpacks bleiben beim alten Weg.
        assert!(!matches!(parse("trs-launcher://pack/ABCD-EFGH"), Some(Link::Modpack(_))));
    }
}
