#!/usr/bin/env python3
"""Pick the next version and write its CHANGELOG.md section and release body from git history.

Every commit on the release branch's first-parent line since the last stable tag lands in
CHANGELOG.md, grouped by its Conventional Commits type. See docs/release.md#changelog.
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Pipcast's own history starts after this Tinycast commit; nothing older is ours to list.
FORK_POINT = '8d0d6b68'
GROUPS = [
    ('New', 'new feature', ('feat',)),
    ('Improved', 'improvement', ('perf', 'refactor', 'style')),
    ('Fixed', 'fix', ('fix', 'revert')),
    ('Other', 'other change', ()),
]
# Matches `versionHeading` in Changelog.swift: `## 0.4.0`, optionally followed by a date.
HEADING = re.compile(r'^## (\d+\.\d+\.\d+)(?:\s.*)?$')
CONVENTIONAL = re.compile(r'^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<breaking>!)?: (?P<text>.+)$')
TRAILING_PR = re.compile(r'\s*\(#(\d+)\)$')
MERGE_PR = re.compile(r'^Merge pull request #(\d+) from \S+$')
# The workflow's own changelog commits; listing them would grow every release by one line.
RELEASE_COMMIT = 'chore(release): '


def parse_version(text: str) -> tuple[int, int, int] | None:
    match = re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', text)
    return tuple(map(int, match.groups())) if match else None


def format_version(version: tuple[int, int, int]) -> str:
    return '.'.join(map(str, version))


@dataclass
class Commit:
    sha: str
    group: str
    text: str
    breaking: bool
    pr: str | None
    author: str | None = None

    def bullet(self) -> str:
        line = f'- {self.text}'
        if self.author:
            line += f' by @{self.author}'
        if self.pr:
            line += f' in #{self.pr}'
        return line


def parse_commit(sha: str, subject: str, body: str) -> Commit:
    pr = None
    merge = MERGE_PR.match(subject)
    if merge:
        pr = merge.group(1)
        # A merge commit's subject names the branch; the PR title is the first body line.
        subject = next((line.strip() for line in body.splitlines() if line.strip()), subject)
    trailing = TRAILING_PR.search(subject)
    if trailing:
        pr = pr or trailing.group(1)
        subject = subject[:trailing.start()]
    match = CONVENTIONAL.match(subject)
    if not match:
        return Commit(sha, 'Other', subject[:1].upper() + subject[1:], False, pr)
    kind = match['type']
    group = next((name for name, _, kinds in GROUPS if kind in kinds), 'Other')
    text = match['text'][:1].upper() + match['text'][1:]
    if match['scope']:
        text = f'**{match["scope"]}** — {text}'
    breaking = bool(match['breaking']) or 'BREAKING CHANGE:' in body or 'BREAKING-CHANGE:' in body
    return Commit(sha, group, text, breaking, pr)


def git(*args: str) -> str:
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True)


def commits(since: str | None) -> list[Commit]:
    span = f'{since}..HEAD' if since else 'HEAD'
    log = git('log', '--first-parent', '--format=%H%x1f%s%x1f%b%x1e', span)
    entries = [entry.strip('\n').split('\x1f') for entry in log.split('\x1e') if entry.strip()]
    return [
        parse_commit(sha, subject, body) for sha, subject, body in entries
        if not subject.startswith(RELEASE_COMMIT)]


def tags() -> dict[str, tuple[tuple[int, int, int], int | None]]:
    found = {}
    # Tinycast's tags sit on its own history and upstream merges; only ours count.
    line = set(git('rev-list', '--first-parent', f'{FORK_POINT}..HEAD').split())
    for tag in git('tag', '--list', 'v*', '--merged', 'HEAD').split():
        if git('rev-list', '-n1', tag).strip() not in line:
            continue
        match = re.fullmatch(r'v(\d+\.\d+\.\d+)(?:-beta\.(\d+))?', tag)
        if match and parse_version(match.group(1)):
            beta = int(match.group(2)) if match.group(2) else None
            found[tag] = (parse_version(match.group(1)), beta)
    return found


def latest(found: dict, beta: bool) -> str | None:
    candidates = [tag for tag, (_, number) in found.items() if (number is not None) == beta]
    return max(candidates, key=lambda tag: found[tag], default=None)


def next_version(base: tuple[int, int, int], changes: list[Commit]) -> tuple[int, int, int]:
    major, minor, patch = base
    # Before 1.0, a breaking change moves the minor version, as semver allows.
    if any(commit.breaking for commit in changes):
        return (major + 1, 0, 0) if major > 0 else (0, minor + 1, 0)
    if any(commit.group == 'New' for commit in changes):
        return (major, minor + 1, 0)
    return (major, minor, patch + 1)


def headline(changes: list[Commit]) -> str:
    parts = []
    for name, noun, _ in GROUPS:
        count = sum(commit.group == name for commit in changes)
        if count:
            plural = noun.replace('fix', 'fixe') + 's' if count > 1 else noun
            parts.append(f'{count} {plural}')
    if len(parts) > 1:
        parts[-2:] = [f'{parts[-2]} and {parts[-1]}']
    return ', '.join(parts) + '.'


def is_generated_headline(text: str) -> bool:
    nouns = '|'.join(f'{noun}s?|{noun}es' for _, noun, _ in GROUPS)
    item = rf'\d+ (?:{nouns})'
    return re.fullmatch(rf'{item}(?:, {item})*(?: and {item})?\.', text) is not None


def grouped(changes: list[Commit]) -> str:
    blocks = []
    for name, _, _ in GROUPS:
        bullets = [commit.bullet() for commit in changes if commit.group == name]
        if bullets:
            blocks.append(f'### {name}\n\n' + '\n'.join(bullets))
    return '\n\n'.join(blocks)


def section_bodies(changelog: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current = None
    for line in changelog.splitlines():
        match = HEADING.match(line)
        if match:
            current = match.group(1)
            sections.setdefault(current, [])
        elif current is not None:
            sections[current].append(line)
    return sections


def intro(lines: list[str]) -> str:
    """Hand-written prose above the first `###` survives regeneration; a generated count does not."""
    head = []
    for line in lines:
        if line.startswith('### '):
            break
        head.append(line)
    text = '\n'.join(head).strip()
    return '' if is_generated_headline(' '.join(text.split())) else text


def write_section(changelog: str, version: str, date: str | None, changes: list[Commit]) -> str:
    kept = intro(section_bodies(changelog).get(version, []))
    heading = f'## {version}' + (f' — {date}' if date else '')
    section = f'{heading}\n\n{kept or headline(changes)}\n\n{grouped(changes)}\n'
    lines = changelog.splitlines()
    starts = [index for index, line in enumerate(lines) if HEADING.match(line)]
    existing = next((index for index in starts if HEADING.match(lines[index]).group(1) == version), None)
    if existing is not None:
        end = next((index for index in starts if index > existing), len(lines))
        lines[existing:end] = section.splitlines() + ([''] if end < len(lines) else [])
    else:
        at = starts[0] if starts else len(lines)
        lines[at:at] = section.splitlines() + ['']
    return '\n'.join(lines).rstrip('\n') + '\n'


def set_marketing_version(version: str) -> None:
    project = ROOT / 'project.yml'
    project.write_text(re.sub(
        r'(MARKETING_VERSION: )"[^"]*"', rf'\g<1>"{version}"', project.read_text()))
    pbxproj = ROOT / 'Pipcast.xcodeproj/project.pbxproj'
    pbxproj.write_text(re.sub(
        r'(MARKETING_VERSION = )[^;]*;', rf'\g<1>{version};', pbxproj.read_text()))


def resolve_authors(changes: list[Commit], repo: str) -> None:
    for commit in changes:
        result = subprocess.run(
            ['gh', 'api', f'repos/{repo}/commits/{commit.sha}', '--jq', '.author.login // empty'],
            capture_output=True, text=True)
        login = result.stdout.strip()
        if result.returncode == 0 and login and not login.endswith('[bot]'):
            commit.author = login


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--channel', choices=['beta', 'stable'], required=True)
    parser.add_argument('--version', default='', help='Base version; derived from commits when empty')
    parser.add_argument('--repo', help='owner/name, to credit authors through the GitHub API')
    parser.add_argument('--notes', type=Path, required=True, help='Where to write the release body')
    args = parser.parse_args()

    found = tags()
    stable = latest(found, beta=False)
    since_stable = commits(stable or FORK_POINT)
    beta = latest(found, beta=True)
    # A beta of the version that went stable is older than that stable tag.
    newer_beta = beta and (not stable or found[beta][0] > found[stable][0])
    previous = beta if args.channel == 'beta' and newer_beta else stable
    since_previous = commits(previous or FORK_POINT)
    if not since_previous:
        print(f'Nothing has been merged since {previous}.', file=sys.stderr)
        return 1

    if args.version:
        version = parse_version(args.version)
        if not version:
            print(f'{args.version} is not MAJOR.MINOR.PATCH.', file=sys.stderr)
            return 2
    elif stable:
        version = next_version(found[stable][0], since_stable)
    else:
        marketing = re.search(r'MARKETING_VERSION: "([^"]+)"', (ROOT / 'project.yml').read_text())
        version = parse_version(marketing.group(1))
    if stable and version <= found[stable][0]:
        print(f'{format_version(version)} is not above {stable}.', file=sys.stderr)
        return 2
    base = format_version(version)

    if args.repo:
        resolve_authors(since_stable, args.repo)
    date = datetime.date.today().isoformat() if args.channel == 'stable' else None
    changelog = ROOT / 'CHANGELOG.md'
    changelog.write_text(write_section(changelog.read_text(), base, date, since_stable))
    set_marketing_version(base)

    # A beta's update window lists what changed since the previous beta, as Tinycast's does.
    shas = {commit.sha for commit in since_previous}
    body = grouped([commit for commit in since_stable if commit.sha in shas])
    if args.channel == 'stable':
        body = f'{intro(section_bodies(changelog.read_text())[base]) or headline(since_stable)}\n\n{body}'
    args.notes.write_text(body + '\n')

    if output := os.environ.get('GITHUB_OUTPUT'):
        with open(output, 'a') as handle:
            handle.write(f'version={base}\n')
    print(f'{base}: {len(since_previous)} changes since {previous or FORK_POINT}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
