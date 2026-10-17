#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location(
    'release_notes', Path(__file__).resolve().parent / 'release-notes.py')
notes = importlib.util.module_from_spec(spec)
sys.modules['release_notes'] = notes
spec.loader.exec_module(notes)


def commit(subject, body=''):
    return notes.parse_commit('0' * 40, subject, body)


class ReleaseNotesTests(unittest.TestCase):
    def test_groups_by_conventional_type(self):
        self.assertEqual(commit('feat(clipboard): create snippets (#14)').group, 'New')
        self.assertEqual(commit('perf: speed up launch').group, 'Improved')
        self.assertEqual(commit('fix(launcher): activate results').group, 'Fixed')
        self.assertEqual(commit('docs: explain releases').group, 'Other')
        self.assertEqual(commit('Rewrite the README').group, 'Other')

    def test_writes_scope_author_and_pull_request(self):
        change = commit('feat(clipboard): create snippets (#14)')
        change.author = 'someone'
        self.assertEqual(change.bullet(), '- **clipboard** — Create snippets by @someone in #14')
        self.assertEqual(commit('fix: restore redirects').bullet(), '- Restore redirects')

    def test_reads_a_merge_commit_title_from_its_body(self):
        change = commit('Merge pull request #3 from me/branch', 'build(release): compile once\n\nMore.')
        self.assertEqual(change.bullet(), '- **release** — Compile once in #3')

    def test_keeps_other_release_chores(self):
        self.assertFalse(
            'chore(release): rotate signing credentials'.startswith(notes.RELEASE_COMMIT))
        self.assertTrue('chore(release): update the changelog for 0.2.0'.startswith(notes.RELEASE_COMMIT))

    def test_reads_a_breaking_footer_only_at_a_line_start(self):
        self.assertTrue(commit('fix: a', 'Body.\n\nBREAKING CHANGE: gone').breaking)
        self.assertTrue(commit('fix: a', 'BREAKING-CHANGE: gone').breaking)
        self.assertFalse(commit('docs: a', 'Explain how a BREAKING CHANGE: footer works.').breaking)

    def test_bumps_by_the_strongest_change(self):
        self.assertEqual(notes.next_version((0, 1, 0), [commit('fix: a')]), (0, 1, 1))
        self.assertEqual(notes.next_version((0, 1, 2), [commit('fix: a'), commit('feat: b')]), (0, 2, 0))
        self.assertEqual(notes.next_version((0, 1, 2), [commit('feat!: b')]), (0, 2, 0))
        self.assertEqual(notes.next_version((1, 4, 2), [commit('fix: a', 'BREAKING CHANGE: x')]), (2, 0, 0))

    def test_counts_changes_in_the_headline(self):
        changes = [commit('feat: a'), commit('feat: b'), commit('fix: c'), commit('chore: d')]
        line = notes.headline(changes)
        self.assertEqual(line, '2 new features, 1 fix and 1 other change.')
        self.assertTrue(notes.is_generated_headline(line))
        self.assertTrue(notes.is_generated_headline('3 fixes.'))
        self.assertFalse(notes.is_generated_headline('The first release of Pipcast.'))

    def test_inserts_a_new_section_above_older_ones(self):
        changelog = '# Changelog\n\nPreamble.\n\n## 0.1.0\n\n- Old.\n'
        written = notes.write_section(
            changelog, '0.2.0', None, [commit('feat: new thing')], released=(0, 1, 0))
        self.assertEqual(
            written,
            '# Changelog\n\nPreamble.\n\n## 0.2.0\n\n1 new feature.\n\n### New\n\n- New thing\n\n'
            '## 0.1.0\n\n- Old.\n')

    def test_regenerates_a_section_keeping_its_written_headline(self):
        changelog = '## 0.2.0\n\nA headline.\n\n### New\n\n- Stale.\n\n## 0.1.0\n\n- Old.\n'
        written = notes.write_section(
            changelog, '0.2.0', '2026-10-17', [commit('fix: thing')], released=(0, 1, 0))
        self.assertEqual(
            written,
            '## 0.2.0 — 2026-10-17\n\nA headline.\n\n### Fixed\n\n- Thing\n\n## 0.1.0\n\n- Old.\n')

    def test_replaces_a_generated_headline(self):
        changelog = '## 0.2.0\n\n1 fix.\n\n### Fixed\n\n- Thing\n'
        written = notes.write_section(changelog, '0.2.0', None, [commit('fix: thing'), commit('feat: more')])
        self.assertTrue(written.startswith('## 0.2.0\n\n1 new feature and 1 fix.\n'))

    def test_folds_a_superseded_unreleased_section_into_the_new_one(self):
        changelog = (
            '# Changelog\n\n## 0.1.1\n\nWritten.\n\n### Fixed\n\n- Old fix\n\n'
            '## 0.1.0 — 2026-10-17\n\n### New\n\n- First\n')
        written = notes.write_section(
            changelog, '0.2.0', None, [commit('feat: more'), commit('fix: old fix')], released=(0, 1, 0))
        self.assertEqual(
            written,
            '# Changelog\n\n## 0.2.0\n\nWritten.\n\n### New\n\n- More\n\n### Fixed\n\n- Old fix\n\n'
            '## 0.1.0 — 2026-10-17\n\n### New\n\n- First\n')


if __name__ == '__main__':
    unittest.main()
