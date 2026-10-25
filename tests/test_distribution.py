"""Distribution preflight and final-artifact checks; no keys or uploads needed."""

import base64
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import distribute
from update_config import apply_config, load_config


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sidetable-distribution-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'config').mkdir()
        self.key = base64.b64encode(bytes(range(32))).decode()
        self.config_path = self.root / 'config/updates.json'
        self.config_path.write_text(json.dumps({'repository': 'vrypan/SideTable', 'public_key': self.key}))
        self.config = load_config(self.root, required=True)

    def test_configuration_requires_real_key_for_distribution(self):
        self.config_path.write_text('{"repository": "vrypan/SideTable", "public_key": ""}')
        self.assertIsNone(load_config(self.root))
        with self.assertRaises(ValueError):
            load_config(self.root, required=True)
        for repository, key in [('owner/repo/extra', self.key), ('owner/repo', 'bad!'), ('owner/repo', 'AAAA')]:
            self.config_path.write_text(json.dumps({'repository': repository, 'public_key': key}))
            with self.assertRaises(ValueError):
                load_config(self.root, required=True)

    def test_development_builds_disable_checks_and_distribution_enables_them(self):
        for distribution in (False, True):
            info = {}
            apply_config(info, self.root, distribution=distribution)
            self.assertEqual(info['SideTableDistribution'], distribution)
            self.assertEqual(info['SUEnableAutomaticChecks'], distribution)
            self.assertFalse(info['SUAutomaticallyUpdate'])
            self.assertFalse(info['SUAllowsAutomaticUpdates'])
            self.assertFalse(info['SUSendProfileInfo'])
            self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
            self.assertTrue(info['SUEnableInstallerLauncherService'])
            self.assertEqual(info['SUFeedURL'], 'https://github.com/vrypan/SideTable/releases/latest/download/appcast.xml')

    def test_notes_only_include_the_requested_release(self):
        notes = '# Changelog\n\n## Unreleased\n\n- Future.\n\n## 0.2.0 — 2026-10-25\n\n- Current.\n\n## 0.1.0\n\n- Old.\n'
        self.assertEqual(distribute.release_notes(notes, '0.2.0'), '## 0.2.0 — 2026-10-25\n\n- Current.\n')
        with self.assertRaises(ValueError):
            distribute.release_notes(notes, '0.2.1')

    def test_appcast_matches_final_dmg_and_embeds_notes(self):
        dmg = self.root / 'SideTable-0.2.0-universal.dmg'
        dmg.write_bytes(b'final stapled bytes')
        info = {'CFBundleVersion': '0.2.0', 'CFBundleShortVersionString': '0.2.0', 'LSMinimumSystemVersion': '14.0'}
        xml = '''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>0.2.0</sparkle:version><sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><description>Notes</description>
<enclosure url="https://github.com/vrypan/SideTable/releases/download/v0.2.0/SideTable-0.2.0-universal.dmg" length="19" sparkle:edSignature="signature"/>
</item></channel></rss>'''
        feed = self.root / 'appcast.xml'
        feed.write_text(xml)
        distribute.validate_appcast(feed, dmg, self.config, info)
        for mutated in [xml.replace('v0.2.0/', 'latest/'), xml.replace('length="19"', 'length="20"'),
                        xml.replace(' sparkle:edSignature="signature"', ''),
                        xml.replace('<sparkle:version>0.2.0', '<sparkle:version>0.1.0'),
                        xml.replace('14.0', '15.0'), xml.replace('</item>', '<sparkle:releaseNotesLink>https://elsewhere/notes</sparkle:releaseNotesLink></item>')]:
            feed.write_text(mutated)
            with self.assertRaises(ValueError):
                distribute.validate_appcast(feed, dmg, self.config, info)

    def test_modified_or_unnotarized_artifacts_cannot_advance(self):
        destination = self.root / 'build/distribution/0.2.0'
        destination.mkdir(parents=True)
        dmg = destination / 'SideTable-0.2.0-universal.dmg'
        dmg.write_bytes(b'original')
        receipt = {'version': '0.2.0', 'notarized': False, 'dmg_sha256': distribute.digest(dmg)}
        path = self.root / 'build/distribution/release.json'
        distribute.write_json(path, receipt)
        with patch.object(distribute, 'ROOT', self.root):
            distribute.artifact()
            with self.assertRaises(ValueError):
                distribute.artifact(require_notarized=True)
            receipt['notarized'] = True
            distribute.write_json(path, receipt)
            distribute.artifact(require_notarized=True)
            dmg.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                distribute.artifact()

    def test_rejected_notarization_does_not_staple_or_mark_accepted(self):
        destination = self.root / 'build/distribution/0.2.0'
        destination.mkdir(parents=True)
        dmg = destination / 'SideTable-0.2.0-universal.dmg'
        dmg.write_bytes(b'original')
        receipt = {'version': '0.2.0', 'notarized': False, 'dmg_sha256': distribute.digest(dmg)}
        path = self.root / 'build/distribution/release.json'
        distribute.write_json(path, receipt)
        def rejected(args, **kwargs):
            if 'submit' in args:
                json.dump({'status': 'Invalid', 'id': 'test-id'}, kwargs['stdout'])
            return type('Result', (), {'returncode': 0})()
        with patch.object(distribute, 'ROOT', self.root), patch.object(distribute.subprocess, 'run', side_effect=rejected), patch.object(distribute, 'run') as runner:
            with self.assertRaises(ValueError):
                distribute.notarize()
            runner.assert_not_called()
        self.assertFalse(json.loads(path.read_text())['notarized'])

    def test_distribution_rejects_wrong_feed_or_development_build(self):
        info = {'CFBundleIdentifier': 'chat.sidetable.mac', 'CFBundleVersion': '0.2.0',
                'CFBundleShortVersionString': '0.2.0', 'SideTableVersion': '0.2.0'}
        apply_config(info, self.root, distribution=True)
        distribute.validate_info(info, self.config, '0.2.0')
        for key, value in [('SideTableDistribution', False), ('SideTableVersion', '0.2.0-dirty'),
                           ('SUFeedURL', 'https://elsewhere/feed.xml'), ('SUPublicEDKey', 'other')]:
            with self.assertRaises(ValueError):
                distribute.validate_info(dict(info, **{key: value}), self.config, '0.2.0')
    def test_success_records_the_stapled_bytes(self):
        destination = self.root / 'build/distribution/0.2.0'
        destination.mkdir(parents=True)
        dmg = destination / 'SideTable-0.2.0-universal.dmg'
        dmg.write_bytes(b'original')
        receipt_path = self.root / 'build/distribution/release.json'
        distribute.write_json(receipt_path, {'version': '0.2.0', 'notarized': False, 'dmg_sha256': distribute.digest(dmg)})
        def accepted(args, **kwargs):
            json.dump({'status': 'Accepted', 'id': 'test-id'}, kwargs['stdout'])
            return type('Result', (), {'returncode': 0})()
        def command(*args, **kwargs):
            if args[:3] == ('xcrun', 'stapler', 'staple'):
                dmg.write_bytes(b'original with staple')
        with patch.object(distribute, 'ROOT', self.root), patch.object(distribute.subprocess, 'run', side_effect=accepted), patch.object(distribute, 'run', side_effect=command):
            distribute.notarize()
            receipt = json.loads(receipt_path.read_text())
            self.assertTrue(receipt['notarized'])
            self.assertEqual(receipt['dmg_sha256'], distribute.digest(dmg))
            distribute.artifact(require_notarized=True)


if __name__ == '__main__':
    unittest.main()
