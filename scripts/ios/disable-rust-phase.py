"""Ersetzt im Xcode-Projekt die Build-Phase „Build Rust Code“ durch einen Hinweis.

Die Phase der Tauri-Vorlage (`tauri ios xcode-script`) verlangt einen laufenden `tauri ios build`;
die des eingecheckten Projekts (scripts/build-rust.sh) würde die Bibliothek ein zweites Mal bauen.
Im unsignierten CI-Build legt scripts/ios-unsigned-ipa.sh die Rust-Bibliothek vorher selbst ab.

    python3 scripts/ios/disable-rust-phase.py <project.pbxproj>
"""
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()

# shellScript = "…";  – der Inhalt kann maskierte Anführungszeichen (\") enthalten.
pattern = re.compile(r'shellScript = "(?:[^"\\]|\\.)*(?:tauri ios xcode-script|scripts/build-rust\.sh)(?:[^"\\]|\\.)*";')
text, count = pattern.subn('shellScript = "echo Rust-Bibliothek vorab gebaut";', text)
if count == 0:
    sys.exit("Build-Phase „Build Rust Code“ nicht gefunden")

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print(f"{count} Build-Phase(n) ersetzt")
