#!/usr/bin/env python3
"""CHANGELOG.md nach einem Upstream-Abgleich neu zusammensetzen.

Ergebnis = Fassung von theredstonee/TRS-Launcher am Commit <neu> + die eigenen Punkte dieses Repos oben unter
„## Unreleased“ (je Sprache). Eigene Punkte = Punkte unter „## Unreleased“ in <eigene> (Standard: HEAD), die es in der
Upstream-Fassung des letzten Abgleichs (<alt>) und in <neu> nicht gibt. Die Release-Abschnitte stimmen so immer mit
upstream überein (die Release-Prüfung verlangt das).

  python3 -I scripts/upstream/changelog.py <neu> <alt> [<eigene>]
"""
import subprocess
import sys

MARK = '\n## Unreleased\n'


def show(ref):
    return subprocess.run(['git', 'show', f'{ref}:CHANGELOG.md'], capture_output=True, text=True, check=True).stdout


def split(text):
    """Kopf, Inhalt von „## Unreleased“, Rest ab dem nächsten „## “."""
    if MARK not in text:
        raise SystemExit('CHANGELOG.md ohne „## Unreleased“')
    head, rest = text.split(MARK, 1)
    if '\n## ' in rest:
        body, tail = rest.split('\n## ', 1)
        return head, body, '\n## ' + tail
    return head, rest, ''


def own_points(ours, *upstream):
    _, body, _ = split(ours)
    if '### Deutsch' not in body:
        return [], []
    en, de = body.split('### Deutsch', 1)
    known = set()
    for text in upstream:
        known.update(line for line in text.splitlines() if line.startswith('- '))
    pick = lambda section: [line for line in section.splitlines() if line.startswith('- ') and line not in known]
    return pick(en), pick(de)


def insert(section, points):
    lines = section.splitlines()
    idx = next((i for i, line in enumerate(lines) if line.startswith('- ')), None)
    if idx is None:  # Überschrift ohne Punkte
        idx = next((i for i, line in enumerate(lines) if line.startswith('### ')), -1) + 1
    return '\n'.join(lines[:idx] + points + lines[idx:])


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    new_ref, old_ref = sys.argv[1], sys.argv[2]
    ours_ref = sys.argv[3] if len(sys.argv) == 4 else 'HEAD'
    new, old = show(new_ref), show(old_ref)
    own_en, own_de = own_points(show(ours_ref), old, new)
    if len(own_en) != len(own_de):
        print(f'Warnung: {len(own_en)} englische, aber {len(own_de)} deutsche eigene Punkte', file=sys.stderr)
    head, body, tail = split(new)
    if '### Deutsch' in body:
        en, de = body.split('### Deutsch', 1)
        body = insert(en, own_en) + '\n### Deutsch' + insert(de, own_de)
        if not body.endswith('\n'):
            body += '\n'
    elif own_en or own_de:  # leerer Abschnitt direkt nach einem Release
        body = '\n### English\n' + '\n'.join(own_en) + '\n\n### Deutsch\n' + '\n'.join(own_de) + '\n' + body
    with open('CHANGELOG.md', 'w', encoding='utf-8') as out:
        out.write(head + MARK + body + tail)
    print(f'CHANGELOG.md: upstream {new_ref[:10]} + {len(own_en)}/{len(own_de)} eigene Punkte (EN/DE)')


if __name__ == '__main__':
    main()
