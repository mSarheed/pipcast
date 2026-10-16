#!/usr/bin/env python3
"""Print CHANGELOG.md's notes for one version, or fail if it has none.

The release workflow runs this before building anything, so a release cannot ship without
notes, and publishes its output as the GitHub release body. Mirrors `Changelog.swift`.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Matches `versionHeading` in Changelog.swift: `## 0.4.0`, optionally followed by a date.
HEADING = re.compile(r'^## (\d+\.\d+\.\d+)(?:\s.*)?$')


def notes(changelog: str, version: str) -> str | None:
    current = None
    sections: dict[str, list[str]] = {}
    for line in changelog.splitlines():
        match = HEADING.match(line)
        if match:
            current = match.group(1)
            if current in sections:
                raise ValueError(f'CHANGELOG.md has two "## {current}" sections; merge them.')
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    body = '\n'.join(sections.get(version, [])).strip()
    return body or None


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r'\d+\.\d+\.\d+', sys.argv[1]):
        print('usage: changelog-notes.py MAJOR.MINOR.PATCH', file=sys.stderr)
        return 2
    version = sys.argv[1]
    path = Path(__file__).resolve().parent.parent / 'CHANGELOG.md'
    try:
        body = notes(path.read_text(encoding='utf-8'), version)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    if body is None:
        print(
            f'CHANGELOG.md has no notes for {version}. Add a "## {version}" section with the '
            'release\'s big-picture changes before releasing (see docs/release.md).',
            file=sys.stderr)
        return 1
    print(body)
    return 0


if __name__ == '__main__':
    sys.exit(main())
