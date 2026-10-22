#!/usr/bin/env bash
# Xcode-Build-Phase „Build Rust Code“: baut Oberfläche (Nuxt) und Rust-Kern für iOS und legt die
# Bibliothek als Externals/<arch>/<konfiguration>/libapp.a ab, wo das Target sie linkt.
#
# Ersetzt `tauri ios xcode-script` der Tauri-Vorlage: Das Projekt lässt sich so direkt in Xcode bauen,
# signieren und archivieren – ohne laufenden `tauri ios build`.
#
# Schalter (Umgebung oder Signing.local.xcconfig):
#   TRS_SKIP_RUST_BUILD=1     Bibliothek liegt schon in Externals (z. B. von scripts/ios/build-ipa.sh)
#   TRS_SKIP_FRONTEND=1       .output/public nicht neu bauen, auch wenn es fehlt
#   TRS_REBUILD_FRONTEND=1    Oberfläche immer neu bauen (pnpm generate)
set -euo pipefail

# Xcode startet Skripte mit kleinem PATH – übliche Orte für cargo, pnpm und node ergänzen.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/Library/pnpm:$HOME/.local/share/pnpm:$PATH"
for nvm_node in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$nvm_node" ] && PATH="$nvm_node:$PATH"
done

PROJECT_DIR="${PROJECT_DIR:?nur aus Xcode aufrufen}"
CONFIGURATION="${CONFIGURATION:?}"

die() { echo "error: $*" >&2; exit 1; }

if [ "${TRS_SKIP_RUST_BUILD:-}" = 1 ]; then
  echo "Rust-Bibliothek vorab gebaut (TRS_SKIP_RUST_BUILD=1)"
  exit 0
fi

# Xcode-Paket (scripts/ios/package-xcode.sh): kein Quellcode daneben, der Kern liegt fertig in Externals/.
if [ ! -f "$PROJECT_DIR/../../Cargo.toml" ]; then
  lib="$PROJECT_DIR/Externals/arm64/$CONFIGURATION/libapp.a"
  [ -f "$lib" ] || die "Vorgebauter App-Kern fehlt ($lib) – das Xcode-Paket ist unvollständig, bitte neu herunterladen"
  [ "${PLATFORM_NAME:-iphoneos}" = iphoneos ] \
    || die "Das Xcode-Paket enthält den App-Kern nur für echte Geräte – oben in Xcode ein iPhone/iPad als Ziel wählen, keinen Simulator"
  echo "Vorgebauter App-Kern: $lib"
  exit 0
fi

ROOT="$(cd "$PROJECT_DIR/../../.." && pwd)"
TAURI_DIR="$ROOT/src-tauri"

case "$CONFIGURATION" in
  debug | Debug) profile=debug ;;
  *) profile=release ;;
esac

# Ziel-Triple und Externals-Ordner wie bei `tauri ios xcode-script`.
simulator=0
if [ "${PLATFORM_NAME:-iphoneos}" = iphonesimulator ]; then simulator=1; fi
triples=()
arch_dirs=()
for arch in ${ARCHS:-arm64}; do
  case "$arch:$simulator" in
    arm64:0) triples+=(aarch64-apple-ios); arch_dirs+=(arm64) ;;
    arm64:1) triples+=(aarch64-apple-ios-sim); arch_dirs+=(arm64) ;;
    x86_64:1) triples+=(x86_64-apple-ios); arch_dirs+=(x86_64) ;;
    *) die "Architektur $arch wird nicht unterstützt" ;;
  esac
done

command -v cargo > /dev/null || die "cargo fehlt – Rust installieren: https://rustup.rs"

# --- Oberfläche (wird beim Rust-Build ins Binary eingebettet) ---
frontend="$ROOT/.output/public/index.html"
if [ "${TRS_SKIP_FRONTEND:-}" != 1 ] && { [ ! -f "$frontend" ] || [ "${TRS_REBUILD_FRONTEND:-}" = 1 ]; }; then
  command -v pnpm > /dev/null || die "pnpm fehlt (npm i -g pnpm) – oder vorher im Projektordner 'pnpm install && pnpm generate' ausführen"
  echo "Oberfläche bauen (pnpm generate)"
  if [ ! -d "$ROOT/node_modules" ]; then
    (cd "$ROOT" && pnpm install --frozen-lockfile)
  fi
  (cd "$ROOT" && pnpm generate)
fi
[ -f "$frontend" ] || die "Oberfläche fehlt ($frontend) – 'pnpm install && pnpm generate' im Projektordner ausführen"

# --- Rust ---
# Saubere Umgebung wie im CI: Xcodes SDKROOT/Flags (iphoneos) würden sonst auch die Build-Skripte für den Mac treffen.
keep_env=(HOME USER LOGNAME TMPDIR LANG PATH DEVELOPER_DIR CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN CARGO_TARGET_DIR
  CURSEFORGE_API_KEY RUSTC_WRAPPER SCCACHE_DIR CARGO_INCREMENTAL CARGO_BUILD_JOBS)
clean_env=()
for name in "${keep_env[@]}"; do
  if [ -n "${!name:-}" ]; then clean_env+=("$name=${!name}"); fi
done
# iOS-Überlagerung der Tauri-Konfiguration (sonst mischt sie der Tauri-Befehl ein).
clean_env+=("TAURI_CONFIG=$(cat "$TAURI_DIR/tauri.ios.conf.json")")
clean_env+=("IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-15.0}")
# Update-Kanal (UpdateChannel.xcconfig) und Buildnummer (CURRENT_PROJECT_VERSION, nur ganze Zahlen) für den Kern.
for name in TRS_UPDATE_REPO TRS_UPDATE_TAG TRS_UPDATE_PUBKEY; do
  if [ -n "${!name:-}" ]; then clean_env+=("$name=${!name}"); fi
done
if [[ "${CURRENT_PROJECT_VERSION:-}" =~ ^[0-9]+$ ]]; then clean_env+=("TRS_BUILD_NUMBER=$CURRENT_PROJECT_VERSION"); fi

cargo_flags=(--manifest-path "$TAURI_DIR/Cargo.toml" --lib --features tauri/custom-protocol)
if [ "$profile" = release ]; then cargo_flags+=(--release); fi

# Xcode 27: SwiftPM macht die @_cdecl-Exporte der Plugin-Pakete (Tauri-Plugins: init_plugin_…) intern; swift-rs
# macht sie mit llvm-objcopy aus rustups llvm-tools wieder sichtbar. Fehlt es, startet die App nicht.
# Schon gebaute Swift-Archive hat swift-rs dann ohne objcopy verarbeitet – einmal neu bauen (Marker im target-Ordner).
fresh_llvm_tools=0
if command -v rustup > /dev/null && ! rustup component list --installed 2> /dev/null | grep -q '^llvm-tools'; then
  echo "rustup-Komponente llvm-tools installieren (für swift-rs unter Xcode 27)"
  rustup component add llvm-tools
  fresh_llvm_tools=1
fi

target_dir="${CARGO_TARGET_DIR:-$TAURI_DIR/target}"
for i in "${!triples[@]}"; do
  triple="${triples[$i]}"
  if command -v rustup > /dev/null && ! rustup target list --installed | grep -qx "$triple"; then
    echo "Rust-Ziel $triple installieren"
    rustup target add "$triple"
  fi
  marker="$target_dir/$triple/.trs-llvm-tools"
  # Nicht im CI (dort kommt llvm-tools mit der Toolchain, der Cache bleibt nutzbar).
  if [ -z "${CI:-}" ] && { [ "$fresh_llvm_tools" = 1 ] || { [ -d "$target_dir/$triple" ] && [ ! -f "$marker" ]; }; }; then
    echo "iOS-Build-Ordner $triple einmal leeren (Swift-Exporte mit llvm-objcopy neu erzeugen)"
    env -i "${clean_env[@]}" cargo clean --manifest-path "$TAURI_DIR/Cargo.toml" --target "$triple"
  fi
  echo "cargo build --target $triple ($profile)"
  env -i "${clean_env[@]}" cargo build "${cargo_flags[@]}" --target "$triple"
  mkdir -p "$target_dir/$triple" && touch "$marker"
  lib="$target_dir/$triple/$profile/libtrs_launcher_lib.a"
  [ -f "$lib" ] || die "Rust-Bibliothek fehlt: $lib"
  out="$PROJECT_DIR/Externals/${arch_dirs[$i]}/$CONFIGURATION"
  mkdir -p "$out"
  cp "$lib" "$out/libapp.a"
done
