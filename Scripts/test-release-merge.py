#!/usr/bin/env python3
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
MERGE = ROOT / 'Scripts/release-merge.sh'


class ReleaseMergeTests(unittest.TestCase):
    def setUp(self):
        previous_umask = os.umask(0o077)
        self.addCleanup(os.umask, previous_umask)
        self.scratch = tempfile.TemporaryDirectory(prefix='pipcast-release-test-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.name = 'Pipcast Beta'
        self.binaries = [
            f'Contents/MacOS/{self.name}',
            'Contents/Helpers/ClipboardTextHelper',
            'Contents/Helpers/FileIndexHelper',
            'Contents/Helpers/Pipcast Dictation.app/Contents/MacOS/Pipcast Dictation',
        ]
        self.apps = {}
        for arch in ('arm64', 'x86_64'):
            app = self.root / arch / f'{self.name}.app'
            self.apps[arch] = app
            binary = self.root / arch / 'fixture'
            binary.parent.mkdir(parents=True)
            subprocess.run(['xcrun', 'clang', '-arch', arch, '-x', 'c', '-', '-o', str(binary)],
                           input=b'int main(void) { return 0; }', check=True, capture_output=True)
            for relative in self.binaries:
                target = app / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(binary.read_bytes())
                target.chmod(0o755)
            for bundle, executable, identifier in (
                (app, self.name, 'io.github.msarheed.pipcast.app.beta'),
                (app / 'Contents/Helpers/Pipcast Dictation.app', 'Pipcast Dictation',
                 'io.github.msarheed.pipcast.app.beta.dictation'),
            ):
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleExecutable': executable, 'CFBundleIdentifier': identifier,
                    'CFBundleShortVersionString': '0.1.0-beta.10', 'CFBundleVersion': '10',
                    'CFBundlePackageType': 'APPL', 'DTXcodeBuild': '26A123',
                    'DTSDKBuild': '26A123', 'PipcastUpdateTeamID': 'ABCDEFGHIJ',
                }))
            resources = app / 'Contents/Resources'
            resources.mkdir()
            (resources / 'fixture.txt').write_text('unchanged resource')
            (resources / 'link').symlink_to('fixture.txt')
            for path in app.rglob('*'):
                if path.is_symlink():
                    continue
                if path.is_dir():
                    path.chmod(0o755)
                elif str(path.relative_to(app)) not in self.binaries:
                    path.chmod(0o644)
            app.chmod(0o755)

    def merge(self):
        return subprocess.run([str(MERGE), str(self.apps['arm64']), str(self.apps['x86_64'])],
                              capture_output=True, text=True)

    def test_merges_all_executables_and_preserves_bundle(self):
        for arch, app in self.apps.items():
            archive = self.root / f'{arch}.tar'
            subprocess.run(['tar', '-cf', str(archive), '-C', str(app.parent), app.name], check=True)
            restored = self.root / f'extracted-{arch}'
            restored.mkdir()
            subprocess.run(['tar', '-xpf', str(archive), '-C', str(restored)], check=True)
            self.apps[arch] = restored / app.name
        result = self.merge()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.apps['arm64']
        for relative in self.binaries:
            binary = app / relative
            arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
            self.assertEqual(set(arches), {'arm64', 'x86_64'})
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
        self.assertEqual(app.stat().st_mode & 0o777, 0o755)
        self.assertEqual((app / 'Contents/Resources').stat().st_mode & 0o777, 0o755)
        self.assertEqual((app / 'Contents/Resources/fixture.txt').stat().st_mode & 0o777, 0o644)
        self.assertTrue((app / 'Contents/Resources/link').is_symlink())
        self.assertEqual((app / 'Contents/Resources/link').read_text(), 'unchanged resource')
        for helper in ('ClipboardTextHelper', 'FileIndexHelper', 'Pipcast Dictation.app'):
            subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
                            str(app / 'Contents/Helpers' / helper)], check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
                        '--entitlements', str(ROOT / 'Pipcast/Pipcast.entitlements'), str(app)],
                       check=True, capture_output=True)
        subprocess.run([str(ROOT / 'Scripts/verify-signature.sh'), str(app)],
                       check=True, capture_output=True)
        archive = self.root / 'app.tar'
        subprocess.run(['tar', '-cf', str(archive), '-C', str(app.parent), app.name], check=True)
        restored = self.root / 'restored'
        restored.mkdir()
        subprocess.run(['tar', '-xpf', str(archive), '-C', str(restored)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(restored / app.name)],
                       check=True, capture_output=True)
        self.assertTrue((restored / app.name / 'Contents/Resources/link').is_symlink())

    def test_rejects_mismatched_bundle_metadata_before_merging(self):
        for relative in ('Contents/Info.plist',
                         'Contents/Helpers/Pipcast Dictation.app/Contents/Info.plist'):
            plist = self.apps['x86_64'] / relative
            original = plist.read_bytes()
            for key in ('CFBundleIdentifier', 'CFBundleExecutable',
                        'CFBundleShortVersionString', 'CFBundleVersion', 'DTXcodeBuild', 'DTSDKBuild'):
                with self.subTest(plist=relative, key=key):
                    info = plistlib.loads(original)
                    info[key] = 'wrong'
                    plist.write_bytes(plistlib.dumps(info))
                    self.assertNotEqual(self.merge().returncode, 0)
                    for binary in self.binaries:
                        self.assertEqual(subprocess.check_output(
                            ['lipo', '-archs', str(self.apps['arm64'] / binary)], text=True).strip(),
                            'arm64')
            plist.write_bytes(original)

    def test_rejects_different_updater_team(self):
        plist = self.apps['x86_64'] / 'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info['PipcastUpdateTeamID'] = 'OTHERTEAM1'
        plist.write_bytes(plistlib.dumps(info))
        self.assertNotEqual(self.merge().returncode, 0)

    def test_rejects_wrong_slice_before_merging(self):
        target = self.apps['x86_64'] / self.binaries[-1]
        target.write_bytes((self.apps['arm64'] / self.binaries[-1]).read_bytes())
        self.assertNotEqual(self.merge().returncode, 0)
        self.assertEqual(subprocess.check_output(
            ['lipo', '-archs', str(self.apps['arm64'] / self.binaries[0])], text=True).strip(), 'arm64')

    def test_rejects_missing_helper(self):
        (self.apps['x86_64'] / self.binaries[-1]).unlink()
        self.assertNotEqual(self.merge().returncode, 0)


if __name__ == '__main__':
    unittest.main()
