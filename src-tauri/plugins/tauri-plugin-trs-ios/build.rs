// Keine Befehle für das Webview: Nur der Rust-Kern ruft das Plugin auf.
const COMMANDS: &[&str] = &[];

fn main() {
    tauri_plugin::Builder::new(COMMANDS).ios_path("ios").build();
}
