"""Public update configuration shared by builds and distribution tools."""

import base64
import json
import re

KEY_ACCOUNT = 'sidetable-ed25519'


def load_config(root, required=False):
    path = root / 'config' / 'updates.json'
    if not path.exists() and not required:
        return None
    config = json.loads(path.read_text())
    repository = config.get('repository', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('config/updates.json needs a GitHub owner/repository.')
    key = config.get('public_key', '')
    if not key and not required:
        return None
    try:
        valid = isinstance(key, str) and len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid = False
    if not valid:
        raise ValueError('Configure the Sparkle public key with make update-key before distributing.')
    return {'repository': repository, 'public_key': key,
            'feed_url': f'https://github.com/{repository}/releases/latest/download/appcast.xml'}


def apply_config(info, root, distribution=False):
    config = load_config(root, required=distribution)
    info.update(SideTableDistribution=distribution, SUEnableAutomaticChecks=distribution,
                SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False, SUSendProfileInfo=False,
                SUVerifyUpdateBeforeExtraction=True, SUEnableInstallerLauncherService=True)
    if config:
        info.update(SUFeedURL=config['feed_url'], SUPublicEDKey=config['public_key'])
