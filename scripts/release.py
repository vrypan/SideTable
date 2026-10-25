"""Finalize committed release notes and create a local release tag."""

from datetime import date
import os
from pathlib import Path
import re
import subprocess
import sys

from build_version import git, release_tags, version_parts


def release(root, version):
    parts = version_parts(version)
    if git(root, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Commit or stash pending changes before preparing a release.')
    if not git(root, 'branch', '--show-current'):
        raise ValueError('Check out a branch before preparing a release.')
    tags = release_tags(root)
    tag = 'v' + version
    if tag in tags:
        raise ValueError(f'Tag {tag} already exists.')
    if tags and parts <= max(tags.values()):
        raise ValueError('Choose a version greater than the existing release tags.')

    path = root / 'Changelog.md'
    original = path.read_text()
    headings = list(re.finditer(r'^## (.+)$', original, re.MULTILINE))
    if not headings or headings[0].group(1) != 'Unreleased':
        raise ValueError('Changelog.md must start with an Unreleased section.')
    if sum(h.group(1) == 'Unreleased' for h in headings) != 1:
        raise ValueError('Changelog.md must have exactly one Unreleased section.')
    end = headings[1].start() if len(headings) > 1 else len(original)
    if not re.search(r'^- \S', original[headings[0].end():end], re.MULTILINE):
        raise ValueError('The Unreleased section must contain release notes.')
    if any(h.group(1).split(' ')[0] == version for h in headings):
        raise ValueError(f'Changelog.md already contains version {version}.')

    heading = headings[0]
    path.write_text(original[:heading.start()] + f'## {version} — {date.today().isoformat()}'
                    + original[heading.end():])
    # Leave failed commit changes for review; never reset the user's work.
    git(root, 'diff', '--check')
    git(root, 'add', '--', 'Changelog.md')
    git(root, 'commit', '-m', f'Prepare release {version}')
    try:
        git(root, 'tag', tag)
    except subprocess.CalledProcessError as error:
        raise ValueError(f'Release notes committed, but tagging failed. Resolve the error, then run git tag {tag}.') from error
    print(f'Created {tag}. Run make build to build this release. Nothing was pushed or published.')


if __name__ == '__main__':
    try:
        release(Path(__file__).resolve().parent.parent, os.environ.get('VERSION', ''))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        sys.exit(f'Release failed: {detail}\nUsage: make release VERSION=X.Y.Z')
