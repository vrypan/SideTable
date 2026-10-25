"""Build a signed universal DMG, notarize it, and stage a GitHub/Sparkle release."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from build_version import git, version_parts, versions
from update_config import KEY_ACCOUNT, load_config

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def tools():
    return Path(run('bash', 'scripts/prepare-sparkle.sh', capture=True)) / 'bin'


def matching_key(binaries, config):
    key = run(binaries / 'generate_keys', '--account', KEY_ACCOUNT, '-p', capture=True)
    if key != config['public_key']:
        raise ValueError('The sidetable-ed25519 Keychain key does not match config/updates.json.')


def update_key():
    binaries = tools()
    path = ROOT / 'config/updates.json'
    config = json.loads(path.read_text())
    if config.get('public_key'):
        matching_key(binaries, load_config(ROOT, required=True))
        print('The existing SideTable public key matches the Keychain. No changes made.')
        return
    run(binaries / 'generate_keys', '--account', KEY_ACCOUNT)
    config['public_key'] = run(binaries / 'generate_keys', '--account', KEY_ACCOUNT, '-p', capture=True)
    write_json(path, config)
    load_config(ROOT, required=True)
    print('Public key saved in config/updates.json. Commit it before making a release.')
    print('Private key remains in the login Keychain under account sidetable-ed25519.')


def release_version(root):
    if git(root, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Commit all changes before packaging a release.')
    release, _, display = versions(root, '0.1.0')
    if display != release or git(root, 'rev-parse', f'v{release}^{{commit}}') != git(root, 'rev-parse', 'HEAD'):
        raise ValueError('Package a clean release tag; first run make release VERSION=X.Y.Z.')
    return release


def signing_identity():
    output = run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True)
    identities = re.findall(r'([0-9A-Fa-f]{40}) "(Developer ID Application:[^\n]+ \(([A-Z0-9]+)\))"', output)
    requested = os.environ.get('SIDETABLE_SIGN_IDENTITY', '')
    matches = [item for item in identities if not requested or requested in item[:2]]
    if len(matches) != 1:
        raise ValueError('Set SIDETABLE_SIGN_IDENTITY to one Developer ID Application identity (name or SHA-1).')
    identity, _, team = matches[0]
    return identity, team


def release_notes(text, version):
    match = re.search(r'^## ' + re.escape(version) + r'(?=[ \t]|$)[^\n]*(?:\n|$)', text, re.M)
    if not match:
        raise ValueError(f'Changelog.md has no notes for {version}.')
    next_heading = re.search(r'^## ', text[match.end():], re.M)
    end = match.end() + next_heading.start() if next_heading else len(text)
    return text[match.start():end].strip() + '\n'


def validate_info(info, config, version):
    expected = {'CFBundleIdentifier': 'chat.sidetable.mac', 'CFBundleShortVersionString': version,
                'CFBundleVersion': version, 'SideTableVersion': version, 'SideTableDistribution': True,
                'SUFeedURL': config['feed_url'], 'SUPublicEDKey': config['public_key'],
                'SUEnableInstallerLauncherService': True, 'SUVerifyUpdateBeforeExtraction': True,
                'SUEnableAutomaticChecks': True, 'SUAllowsAutomaticUpdates': False,
                'SUAutomaticallyUpdate': False, 'SUSendProfileInfo': False}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'Distribution app has an unexpected {key}.')


def inspect_app(app, config, version, team):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    validate_info(info, config, version)
    archs = set(run('lipo', '-archs', app / 'Contents/MacOS/SideTable', capture=True).split())
    if archs != {'arm64', 'x86_64'}:
        raise ValueError(f'Expected a universal app; found {sorted(archs)}.')
    run('codesign', '--verify', '--deep', '--strict', app)
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    # Archive/export must sign each helper, not just the enclosing framework.
    for binary in [app, framework, framework / 'Versions/B/Autoupdate',
                   framework / 'Versions/B/Updater.app', framework / 'Versions/B/XPCServices/Installer.xpc',
                   framework / 'Versions/B/XPCServices/Downloader.xpc']:
        details = subprocess.check_output(['codesign', '-d', '--verbose=4', str(binary)], text=True, stderr=subprocess.STDOUT)
        if f'TeamIdentifier={team}\n' not in details or 'Authority=Developer ID Application:' not in details or 'runtime' not in details:
            raise ValueError(f'{binary.name} lacks the expected Developer ID/hardened-runtime signature.')
    entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', app, capture=True).encode())
    if entitlements.get('com.apple.security.app-sandbox') is not True:
        raise ValueError('The distributed app must remain sandboxed.')
    if entitlements.get('com.apple.security.get-task-allow') or entitlements.get('com.apple.security.cs.disable-library-validation'):
        raise ValueError('Development-only signing entitlements cannot ship.')
    required = {'chat.sidetable.mac-spks', 'chat.sidetable.mac-spki'}
    if set(entitlements.get('com.apple.security.temporary-exception.mach-lookup.global-name', [])) != required:
        raise ValueError('Sparkle sandbox communication entitlements are missing.')
    return info


def package():
    version = release_version(ROOT)
    config = load_config(ROOT, required=True)
    binaries = tools()
    matching_key(binaries, config)
    identity, team = signing_identity()
    destination = ROOT / 'build/distribution' / version
    if destination.exists():
        raise ValueError(f'{destination} already exists. Inspect it before removing a failed build; never replace a published version.')
    destination.mkdir(parents=True)
    archive = destination / 'SideTable.xcarchive'
    run('xcodebuild', '-project', 'Sidetable.xcodeproj', '-scheme', 'Sidetable', '-configuration', 'Release',
        '-destination', 'generic/platform=macOS', '-derivedDataPath', 'build', '-archivePath', archive,
        'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identity}',
        f'DEVELOPMENT_TEAM={team}', 'OTHER_CODE_SIGN_FLAGS=--timestamp', 'SIDETABLE_DISTRIBUTION=YES', 'archive')
    options = destination / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps({'method': 'developer-id', 'signingStyle': 'manual',
                                       'signingCertificate': identity, 'teamID': team, 'destination': 'export'}))
    exported = destination / 'export'
    run('xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', exported, '-exportOptionsPlist', options)
    app = exported / 'SideTable.app'
    info = inspect_app(app, config, version, team)
    dmg = destination / f'SideTable-{version}-universal.dmg'
    with tempfile.TemporaryDirectory(prefix='dmg-stage-', dir=destination) as directory:
        stage = Path(directory)
        run('ditto', app, stage / 'SideTable.app')
        (stage / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', 'SideTable', '-srcfolder', stage, '-format', 'UDZO', '-fs', 'APFS', dmg)
    run('codesign', '--sign', identity, '--timestamp', dmg)
    run('codesign', '--verify', '--strict', dmg)
    run('hdiutil', 'verify', dmg)
    (destination / 'Info.plist').write_bytes(plistlib.dumps(info))
    notes = release_notes(git(ROOT, 'show', f'v{version}:Changelog.md'), version)
    (destination / 'release-notes.md').write_text(notes)
    receipt = dict(version=version, commit=git(ROOT, 'rev-parse', 'HEAD'), config=config, team=team,
                   dmg_sha256=digest(dmg), notarized=False)
    write_json(ROOT / 'build/distribution/release.json', receipt)
    print(f'Signed universal DMG: {dmg}\nNext: make notarize')


def artifact(require_notarized=False):
    receipt = json.loads((ROOT / 'build/distribution/release.json').read_text())
    version_parts(receipt['version'])
    destination = ROOT / 'build/distribution' / receipt['version']
    dmg = destination / f'SideTable-{receipt["version"]}-universal.dmg'
    if digest(dmg) != receipt['dmg_sha256']:
        raise ValueError('The DMG changed after packaging/notarization. Refusing to use mismatched artifacts.')
    if require_notarized and not receipt['notarized']:
        raise ValueError('Run make notarize before generating or uploading the appcast.')
    return receipt, destination, dmg


def notarize():
    receipt, destination, dmg = artifact()
    if receipt['notarized']:
        run('xcrun', 'stapler', 'validate', dmg)
        print('This DMG is already notarized and stapled. Next: make appcast')
        return
    profile = os.environ.get('SIDETABLE_NOTARY_PROFILE', 'sidetable-notary')
    result_path = destination / 'notarization.json'
    with result_path.open('w') as stream:
        result = subprocess.run(['xcrun', 'notarytool', 'submit', str(dmg), '--keychain-profile', profile,
                                 '--wait', '--timeout', '20m', '--output-format', 'json'], stdout=stream)
    try:
        status = json.loads(result_path.read_text())
    except ValueError:
        raise ValueError(f'Notarization did not return a result; inspect {result_path}.')
    if result.returncode or status.get('status') != 'Accepted':
        if status.get('id'):
            subprocess.run(['xcrun', 'notarytool', 'log', status['id'], '--keychain-profile', profile,
                            str(destination / 'notarization-log.json')])
        raise ValueError(f'Notarization was not accepted; inspect {result_path}.')
    run('xcrun', 'stapler', 'staple', dmg)
    run('xcrun', 'stapler', 'validate', dmg)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
    receipt.update(notarized=True, dmg_sha256=digest(dmg), notarization_id=status['id'])
    write_json(ROOT / 'build/distribution/release.json', receipt)
    print('Notarized and stapled. Next: make appcast')


def validate_appcast(path, dmg, config, info):
    items = ET.parse(path).getroot().findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one release in the staged appcast.')
    item = items[0]
    version = info['CFBundleVersion']
    for key, expected in [('version', version), ('shortVersionString', info['CFBundleShortVersionString']),
                          ('minimumSystemVersion', info['LSMinimumSystemVersion'])]:
        if item.findtext(SPARKLE_NS + key) != expected:
            raise ValueError(f'Appcast {key} does not match the packaged app.')
    enclosure = item.find('enclosure')
    expected_url = f'https://github.com/{config["repository"]}/releases/download/v{version}/{dmg.name}'
    if enclosure is None or enclosure.get('url') != expected_url or enclosure.get('length') != str(dmg.stat().st_size):
        raise ValueError('Appcast download URL or size does not match the final DMG.')
    if not enclosure.get(SPARKLE_NS + 'edSignature'):
        raise ValueError('Appcast has no Sparkle signature.')
    if item.find(SPARKLE_NS + 'releaseNotesLink') is not None:
        raise ValueError('Release notes must be embedded in the appcast.')
    return enclosure.get(SPARKLE_NS + 'edSignature')


def appcast():
    receipt, destination, dmg = artifact(require_notarized=True)
    run('xcrun', 'stapler', 'validate', dmg)
    config = receipt['config']
    binaries = tools()
    matching_key(binaries, config)
    info = plistlib.loads((destination / 'Info.plist').read_bytes())
    validate_info(info, config, receipt['version'])
    # Sign only the final stapled bytes; generation never modifies the original.
    with tempfile.TemporaryDirectory(prefix='appcast-stage-', dir=destination) as directory:
        stage = Path(directory)
        run('ditto', dmg, stage / dmg.name)
        (stage / (dmg.stem + '.md')).write_text((destination / 'release-notes.md').read_text())
        prefix = f'https://github.com/{config["repository"]}/releases/download/v{receipt["version"]}/'
        run(binaries / 'generate_appcast', '--account', KEY_ACCOUNT, '--download-url-prefix', prefix,
            '--embed-release-notes', '--maximum-deltas', '0', '--maximum-versions', '1', '-o', stage / 'appcast.xml', stage)
        signature = validate_appcast(stage / 'appcast.xml', dmg, config, info)
        run(binaries / 'sign_update', '--account', KEY_ACCOUNT, '--verify', dmg, signature)
        (destination / 'appcast.xml').write_bytes((stage / 'appcast.xml').read_bytes())
    receipt['appcast_sha256'] = digest(destination / 'appcast.xml')
    write_json(ROOT / 'build/distribution/release.json', receipt)
    print(f'Appcast ready: {destination / "appcast.xml"}\nNext: push the release tag, then make github-draft')


def github_draft():
    receipt, destination, dmg = artifact(require_notarized=True)
    feed = destination / 'appcast.xml'
    if digest(feed) != receipt.get('appcast_sha256'):
        raise ValueError('The appcast changed after generation. Run make appcast again.')
    run('xcrun', 'stapler', 'validate', dmg)
    version = receipt['version']
    repository = receipt['config']['repository']
    tag = 'v' + version
    # --verify-tag refuses to create a release against an unpushed/missing tag.
    remote = json.loads(run('gh', 'api', f'repos/{repository}/commits/{tag}', capture=True))
    if remote.get('sha') != receipt['commit']:
        raise ValueError('The GitHub tag does not point to the packaged commit.')
    run('gh', 'release', 'create', tag, dmg, feed, '--repo', repository, '--verify-tag', '--draft',
        '--title', f'SideTable {version}', '--notes-file', destination / 'release-notes.md')
    print('Draft uploaded. Review it on GitHub, then publish it as the latest full release (not a prerelease).')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['update-key', 'dmg', 'notarize', 'appcast', 'github-draft'])
    args = parser.parse_args()
    try:
        {'update-key': update_key, 'dmg': package, 'notarize': notarize,
         'appcast': appcast, 'github-draft': github_draft}[args.command]()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, ET.ParseError) as error:
        sys.exit(f'Distribution failed: {error}')
