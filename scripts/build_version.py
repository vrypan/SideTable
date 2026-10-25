"""Derive bundle versions from release tags without changing tracked files."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess

from update_config import apply_config


def version_parts(value):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError('expected a release version in X.Y.Z form')
    parts = tuple(map(int, value.split('.')))
    if max(parts) > 999:
        raise ValueError('version components must be between 0 and 999')
    return parts


def bundle_version(release):
    version_parts(release)
    return release


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True,
                                   stderr=subprocess.PIPE).strip()


def release_tags(root, *filters):
    result = {}
    for tag in git(root, 'tag', '--list', *filters).splitlines():
        if not tag.startswith('v'):
            continue
        try:
            result[tag] = version_parts(tag[1:])
        except ValueError:
            pass
    return result


def versions(root, fallback):
    version_parts(fallback)
    try:
        head = git(root, 'rev-parse', '--short', 'HEAD')
    except subprocess.CalledProcessError:
        return fallback, bundle_version(fallback), fallback
    tags = release_tags(root, '--merged', 'HEAD')
    tag = max(tags, key=tags.get) if tags else None
    release = tag[1:] if tag else fallback
    exact = tag is not None and git(root, 'rev-parse', f'{tag}^{{commit}}') == git(root, 'rev-parse', 'HEAD')
    dirty = bool(git(root, 'status', '--porcelain', '--untracked-files=no'))
    display = release
    if not exact or dirty:
        display += '-' + head
    if dirty:
        display += '-dirty'
    return release, bundle_version(release), display


def stamp(root, source, output):
    with source.open('rb') as stream:
        info = plistlib.load(stream)
    release, build, display = versions(root, info['CFBundleShortVersionString'])
    info.update(CFBundleShortVersionString=release, CFBundleVersion=build, SideTableVersion=display)
    apply_config(info, root, distribution=os.environ.get("SIDETABLE_DISTRIBUTION") == "YES")
    content = plistlib.dumps(info, sort_keys=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Avoid unnecessary plist processing when an incremental build has no changes.
    if not output.exists() or output.read_bytes() != content:
        output.write_bytes(content)
    print(f'SideTable {display} (build {build})')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        stamp(args.root, args.source, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Version stamping failed: {error}\n')
