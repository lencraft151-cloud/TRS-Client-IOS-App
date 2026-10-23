//! Klick-Test im CI (`scripts/ios/simulator-smoke-test.sh`): Mit `TRS_UI_TOUR=1` geht die Oberfläche selbst durch die
//! Einrichtung und die Hauptseiten (`app/utils/uiTour.ts`) und meldet jeden Schritt hier – das Skript liest die Zeilen
//! `ui-tour: <schritt> ok|FEHLER` aus dem System-Log und macht dazu einen Screenshot. Ohne die Variable passiert nichts.

/// Läuft der Klick-Test?
#[tauri::command]
pub fn ui_tour() -> bool {
    std::env::var("TRS_UI_TOUR").is_ok_and(|v| v == "1")
}

/// Ein Schritt ist zu sehen (`ok`: mit Inhalt).
#[tauri::command]
pub fn ui_tour_step(name: String, ok: bool) {
    if !ui_tour() {
        return;
    }
    log::info!("ui-tour: {} {}", step_name(&name), if ok { "ok" } else { "FEHLER" });
}

/// Nur `[a-z0-9-]`, höchstens 48 Zeichen – der Name landet in einem Dateinamen des Skripts.
fn step_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .take(48)
        .collect();
    let trimmed = cleaned.trim_matches('-');
    if trimmed.is_empty() { "schritt".into() } else { trimmed.to_owned() }
}

#[cfg(test)]
mod tests {
    use super::step_name;

    #[test]
    fn step_names_are_safe_file_names() {
        assert_eq!(step_name("page-/settings"), "page--settings");
        assert_eq!(step_name("onboarding-Login"), "onboarding-login");
        assert_eq!(step_name("../../etc"), "etc");
        assert_eq!(step_name("???"), "schritt");
        assert_eq!(step_name(&"x".repeat(100)).len(), 48);
    }
}
