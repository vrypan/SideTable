"""Exercise version stamping and release preparation in disposable repositories."""

from datetime import date
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE / 'scripts'))
from build_version import bundle_version, stamp, versions

NOTES = '# Changelog\n\n## Unreleased\n\n### Added\n\n- A new feature.\n'


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sidetable-release-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Release Test', GIT_AUTHOR_EMAIL='test@example.com',
                        GIT_COMMITTER_NAME='Release Test', GIT_COMMITTER_EMAIL='test@example.com',
                        PYTHONDONTWRITEBYTECODE='1')
        # Do not inherit repository selectors from a caller's Git hook.
        for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
            self.env.pop(name, None)
        shutil.copytree(SOURCE / 'scripts', self.root / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy(SOURCE / 'Makefile', self.root / 'Makefile')
        (self.root / '.gitignore').write_text('__pycache__/\nbuild/\n')
        (self.root / 'Changelog.md').write_text(NOTES)
        self.info = self.root / 'Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
                                             'CFBundleExecutable': '$(EXECUTABLE_NAME)'}))
        self.run_command('git', 'init', '-b', 'main')
        self.commit('Initial fixture')

    def run_command(self, *args, success=True):
        result = subprocess.run(args, cwd=self.root, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout.strip()

    def commit(self, message):
        self.run_command('git', 'add', '.')
        self.run_command('git', 'commit', '-m', message)

    def reject(self, version):
        head = self.run_command('git', 'rev-parse', 'HEAD')
        status = self.run_command('git', 'status', '--porcelain')
        notes = (self.root / 'Changelog.md').read_bytes()
        tags = self.run_command('git', 'tag', '--list')
        self.run_command('make', 'release', 'VERSION=' + version, success=False)
        self.assertEqual(self.run_command('git', 'rev-parse', 'HEAD'), head)
        self.assertEqual(self.run_command('git', 'status', '--porcelain'), status)
        self.assertEqual((self.root / 'Changelog.md').read_bytes(), notes)
        self.assertEqual(self.run_command('git', 'tag', '--list'), tags)

    def test_release_dates_notes_commits_and_tags(self):
        self.run_command('git', 'tag', 'v0.1.0')
        self.run_command('make', 'release', 'VERSION=0.1.1')
        self.assertEqual(self.run_command('git', 'rev-parse', 'v0.1.1'), self.run_command('git', 'rev-parse', 'HEAD'))
        self.assertEqual(self.run_command('git', 'log', '-1', '--format=%s'), 'Prepare release 0.1.1')
        self.assertEqual((self.root / 'Changelog.md').read_text(), NOTES.replace('Unreleased', f'0.1.1 — {date.today().isoformat()}'))
        self.assertEqual(self.run_command('git', 'status', '--porcelain'), '')
        self.assertEqual(versions(self.root, '0.1.0'), ('0.1.1', '0.1.1', '0.1.1'))
        self.assertFalse((self.root / 'build').exists())
        self.reject('0.1.2')  # Next release needs new Unreleased notes.

    def test_first_release_needs_no_prior_tag(self):
        self.run_command('make', 'release', 'VERSION=0.1.0')
        self.assertEqual(versions(self.root, '0.1.0'), ('0.1.0', '0.1.0', '0.1.0'))

    def test_invalid_duplicate_and_older_versions_are_rejected(self):
        self.run_command('git', 'tag', 'v0.2.10')
        for value in ('', 'bad', '01.2.3', '0.2.10', '0.2.9', '0.1.99', '0.1000.0', '1.0', '1.0.0-beta'):
            with self.subTest(value=value):
                self.reject(value)

    def test_dirty_and_detached_releases_are_rejected(self):
        pending = self.root / 'pending.txt'
        pending.write_text('Untracked work')
        self.reject('0.2.0')
        pending.unlink()
        (self.root / 'Changelog.md').write_text(NOTES + '- More.\n')
        self.reject('0.2.0')
        self.run_command('git', 'add', 'Changelog.md')
        self.reject('0.2.0')
        self.commit('Notes')
        self.run_command('git', 'checkout', '--detach')
        self.reject('0.2.0')

    def test_notes_are_required_and_unique(self):
        for notes in ('# Changelog\n', '# Changelog\n\n## Unreleased\n\n### Added\n',
                      NOTES + '\n## Unreleased\n\n- Duplicate.\n',
                      NOTES + '\n## 0.2.0 — 2026-01-01\n\n- Already released.\n'):
            (self.root / 'Changelog.md').write_text(notes)
            self.commit('Invalid notes fixture')
            self.reject('0.2.0')

    def test_builds_distinguish_tagged_commits_and_dirty_work(self):
        head = self.run_command('git', 'rev-parse', '--short', 'HEAD')
        self.assertEqual(versions(self.root, '0.1.0')[2], '0.1.0-' + head)
        self.run_command('git', 'tag', '-a', 'v0.2.0', '-m', 'Release')
        self.assertEqual(versions(self.root, '0.1.0'), ('0.2.0', '0.2.0', '0.2.0'))
        (self.root / 'Changelog.md').write_text(NOTES + '- Change.\n')
        self.assertEqual(versions(self.root, '0.1.0')[2], '0.2.0-' + head + '-dirty')
        self.commit('Change')
        head = self.run_command('git', 'rev-parse', '--short', 'HEAD')
        self.assertEqual(versions(self.root, '0.1.0')[2], '0.2.0-' + head)
        (self.root / 'scratch.txt').write_text('Untracked files do not change build labels')
        self.assertEqual(versions(self.root, '0.1.0')[2], '0.2.0-' + head)

    def test_only_valid_reachable_tags_control_builds(self):
        self.run_command('git', 'tag', 'v0.1.0')
        self.run_command('git', 'tag', 'vnot-a-release')
        self.run_command('git', 'checkout', '-b', 'future')
        (self.root / 'future.txt').write_text('Future release')
        self.commit('Future')
        self.run_command('git', 'tag', 'v9.0.0')
        self.run_command('git', 'checkout', 'main')
        self.assertEqual(versions(self.root, '0.1.0')[0], '0.1.0')
        self.reject('0.2.0')  # Release ordering checks all branches' release tags.

    def test_plist_stamping_preserves_source_and_incremental_output(self):
        self.run_command('git', 'tag', 'v0.3.1')
        original = self.info.read_bytes()
        output = self.root / 'build' / 'Info.plist'
        stamp(self.root, self.info, output)
        info = plistlib.loads(output.read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '0.3.1')
        self.assertEqual(info['CFBundleVersion'], '0.3.1')
        self.assertEqual(info['SideTableVersion'], '0.3.1')
        self.assertEqual(info['CFBundleExecutable'], '$(EXECUTABLE_NAME)')
        modified = output.stat().st_mtime_ns
        stamp(self.root, self.info, output)
        self.assertEqual(output.stat().st_mtime_ns, modified)
        self.assertEqual(self.info.read_bytes(), original)
        self.assertEqual(self.run_command('git', 'status', '--porcelain'), '')

    def test_source_archive_falls_back_to_plist_version(self):
        # An actual source archive has no enclosing repository.
        with tempfile.TemporaryDirectory(prefix='sidetable-archive-') as directory:
            self.assertEqual(versions(Path(directory), '0.1.0'), ('0.1.0', '0.1.0', '0.1.0'))

    def test_failed_commit_keeps_notes_for_review_without_tagging(self):
        hook = self.root / '.git' / 'hooks' / 'pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        head = self.run_command('git', 'rev-parse', 'HEAD')
        self.run_command('make', 'release', 'VERSION=0.2.0', success=False)
        self.assertEqual(self.run_command('git', 'rev-parse', 'HEAD'), head)
        self.assertEqual(self.run_command('git', 'tag', '--list', 'v0.2.0'), '')
        self.assertIn('## 0.2.0', (self.root / 'Changelog.md').read_text())
        self.assertIn('Changelog.md', self.run_command('git', 'diff', '--cached', '--name-only'))

    def test_build_numbers_preserve_release_order(self):
        releases = ['0.1.0', '0.1.9', '0.1.10', '0.2.0', '1.0.0']
        builds = [tuple(map(int, bundle_version(value).split('.'))) for value in releases]
        self.assertEqual(sorted(builds), builds)


if __name__ == '__main__':
    unittest.main()
