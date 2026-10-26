#!/usr/bin/env bash
# TRS Launcher (iOS) – Änderungen aus theredstonee/TRS-Launcher (main) übernehmen. Ablauf und Konfliktregeln:
# docs/upstream-sync.md.
#
#   bash scripts/upstream/sync.sh --check     # nur prüfen: neue Upstream-Commits ausgeben (Exit 0 = aktuell, 10 = neu)
#   bash scripts/upstream/sync.sh             # neue Commits per `cherry-pick -x` auf den aktuellen Branch holen
#   bash scripts/upstream/sync.sh --continue  # nach einem von Hand gelösten Konflikt weitermachen
#
# Stand des letzten Abgleichs: .github/upstream-sync. Die Geschichte von upstream wird nicht übernommen (zu groß),
# nur die einzelnen Commits. Konflikte in CHANGELOG.md und den Lockfiles löst das Skript selbst (das Changelog wird
# am Ende neu zusammengesetzt, die Lockfiles neu erzeugt); bei anderen Konflikten endet es mit Exit 2 und einer
# Liste – von Hand lösen, `git add`, dann `--continue`. Zum Schluss ein Commit mit Changelog
# (scripts/upstream/changelog.py), Cargo.lock, Xcode-Projekt und neuem Stand.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/theredstonee/TRS-Launcher.git}"
UPSTREAM_REF=refs/remotes/upstream/main
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
STATE=.github/upstream-sync
GITDIR="$(git rev-parse --absolute-git-dir)"
TODO="$GITDIR/upstream-sync-todo"
START="$GITDIR/upstream-sync-start"
TARGET="$GITDIR/upstream-sync-target"
LOCKS="$GITDIR/upstream-sync-locks"

die() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*"; }

mode="${1:-sync}"
case "$mode" in --check | sync | --continue) ;; *) die "Unbekannte Option: $mode" ;; esac

marker="$(grep -v '^#' "$STATE" | tr -d '[:space:]')"
[[ "$marker" =~ ^[0-9a-f]{40}$ ]] || die "$STATE enthält keinen Commit"

fetch() {
  if git cat-file -e "$marker^{commit}" 2> /dev/null; then
    # Stand liegt schon da: nur Neues holen.
    git fetch --quiet --no-tags "$UPSTREAM_URL" "+main:$UPSTREAM_REF"
  else
    # Frischer Klon: flach holen und vertiefen, bis der Stand des letzten Abgleichs dabei ist.
    local depth=100
    git fetch --quiet --no-tags --depth="$depth" "$UPSTREAM_URL" "+main:$UPSTREAM_REF"
    until git cat-file -e "$marker^{commit}" 2> /dev/null; do
      [ "$depth" -lt 6400 ] || die "Stand $marker nicht in den letzten $depth Commits von upstream/main"
      git fetch --quiet --no-tags --deepen="$depth" "$UPSTREAM_URL" "+main:$UPSTREAM_REF"
      depth=$((depth * 2))
    done
  fi
  git merge-base --is-ancestor "$marker" "$UPSTREAM_REF" || die "$marker liegt nicht auf upstream/main (Geschichte umgeschrieben?)"
}

pending() {
  git rev-list --reverse --topo-order --no-merges "$marker..$UPSTREAM_REF"
}

pop() {
  tail -n +2 "$TODO" > "$TODO.tmp"
  mv "$TODO.tmp" "$TODO"
}

conflicts() {
  git diff --name-only --diff-filter=U
}

# Nach einem gescheiterten Pick: was sich von selbst lösen lässt, lösen. 0 = Pick abgeschlossen.
resolve() {
  local f manual=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      # Wird am Ende neu zusammengesetzt.
      CHANGELOG.md) git checkout --theirs -- "$f" ;;
      # Werden am Ende neu erzeugt (eigene Abhängigkeiten bleiben so erhalten).
      src-tauri/Cargo.lock | pnpm-lock.yaml)
        git checkout --ours -- "$f"
        echo "$f" >> "$LOCKS"
        ;;
      *)
        manual+=("$f")
        continue
        ;;
    esac
    git add -- "$f"
  done < <(conflicts)
  if [ ${#manual[@]} -gt 0 ]; then
    printf '\nKonflikt in %s:\n' "$(git log -1 --format='%h %s' CHERRY_PICK_HEAD)"
    printf '  %s\n' "${manual[@]}"
    printf '\nVon Hand lösen (docs/upstream-sync.md: beide Seiten behalten), „git add“, dann:\n'
    printf '  bash scripts/upstream/sync.sh --continue\n'
    exit 2
  fi
  finish_pick
}

# Laufenden Pick abschließen; leer (schon übernommen) → überspringen.
finish_pick() {
  if git diff --cached --quiet; then
    git cherry-pick --skip
  else
    GIT_EDITOR=true git cherry-pick --continue > /dev/null
  fi
}

pick_all() {
  local c
  while [ -s "$TODO" ]; do
    c="$(head -n 1 "$TODO")"
    say "$(git log -1 --format='%h %s' "$c")"
    if ! git cherry-pick -x "$c" > /dev/null 2>&1; then
      git rev-parse -q --verify CHERRY_PICK_HEAD > /dev/null || die "cherry-pick $c ging schief: $(git status --short | head -n 5)"
      resolve
    fi
    pop
  done
}

finish() {
  local target start version
  target="$(cat "$TARGET")"
  start="$(cat "$START")"
  say "Changelog: upstream $(git rev-parse --short "$target") + eigene Punkte"
  python3 -I scripts/upstream/changelog.py "$target" "$marker" "$start"
  if [ -f "$LOCKS" ] && grep -qx pnpm-lock.yaml "$LOCKS"; then
    say "pnpm-lock.yaml neu erzeugen"
    pnpm install --lockfile-only --ignore-scripts
  fi
  say "Cargo.lock nachziehen"
  (cd src-tauri && cargo metadata --format-version 1 > /dev/null)
  if ruby -e 'require "xcodeproj"' 2> /dev/null || gem install xcodeproj --no-document > /dev/null; then
    say "Xcode-Projekt neu erzeugen"
    ruby scripts/ios/generate-xcodeproj.rb > /dev/null
  else
    printf 'Warnung: Ruby-Gem xcodeproj fehlt – „ruby scripts/ios/generate-xcodeproj.rb“ von Hand ausführen (CI prüft es).\n' >&2
  fi
  { grep "^#" "$STATE" || true; echo "$target"; } > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  version="$(sed -nE 's/^ *"version": *"([^"]+)".*/\1/p' src-tauri/tauri.conf.json | head -n 1)"
  git add -- CHANGELOG.md src-tauri/Cargo.lock pnpm-lock.yaml src-tauri/gen/apple "$STATE"
  git commit -q -m "Upstream $version übernommen: Changelog, Lockfiles, Xcode-Projekt, Abgleich-Stand" \
    -m "Upstream theredstonee/TRS-Launcher bis $target."
  rm -f "$TODO" "$START" "$TARGET" "$LOCKS"
  say "Fertig: upstream $(git rev-parse --short "$target") (Version $version) – jetzt prüfen und PR (docs/upstream-sync.md)"
}

case "$mode" in
  --check)
    fetch
    new="$(pending)"
    if [ -z "$new" ]; then
      say "Aktuell: nichts Neues seit $(git rev-parse --short "$marker")"
      exit 0
    fi
    say "$(wc -l <<< "$new" | tr -d ' ') neue Commits auf upstream/main:"
    while IFS= read -r c; do git log -1 --format='  %h %s' "$c"; done <<< "$new"
    exit 10
    ;;
  sync)
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "Arbeitsverzeichnis nicht sauber"
    [ ! -s "$TODO" ] || die "Ein Abgleich läuft schon – weiter mit --continue (oder $TODO löschen)"
    fetch
    pending > "$TODO"
    if [ ! -s "$TODO" ]; then
      rm -f "$TODO"
      say "Aktuell: nichts Neues seit $(git rev-parse --short "$marker")"
      exit 0
    fi
    say "$(wc -l < "$TODO" | tr -d ' ') neue Commits übernehmen"
    git rev-parse HEAD > "$START"
    git rev-parse "$UPSTREAM_REF" > "$TARGET"
    rm -f "$LOCKS"
    pick_all
    finish
    ;;
  --continue)
    # Leere Liste, aber angefangen: alles übernommen, nur der Abschluss (Changelog, Lockfiles …) fehlt noch.
    [ -s "$TODO" ] || [ -s "$TARGET" ] || die "Kein Abgleich in Arbeit"
    c="$(head -n 1 "$TODO" 2> /dev/null || true)"
    if git rev-parse -q --verify CHERRY_PICK_HEAD > /dev/null; then
      [ -z "$(conflicts)" ] || die "Noch ungelöst: $(conflicts | tr '\n' ' ')"
      finish_pick
      pop
    elif [ -n "$c" ] && git log -1 --format=%B | grep -qF "cherry picked from commit $c"; then
      pop # schon von Hand abgeschlossen
    fi
    pick_all
    finish
    ;;
esac
