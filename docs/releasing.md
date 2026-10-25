# Binary releases and updates

[Documentation](README.md) · [SideTable](../README.md)

SideTable uses [Sparkle 2.10.1](https://sparkle-project.org/documentation/) for in-app updates. **SideTable > Check for Updates…** opens Sparkle’s update UI; **Settings > General > Updates** controls automatic checks. Distributed builds check automatically and ask before downloading/installing. Development, preview, and test builds never start the updater. No system profile is sent. Updates use signed archives verified before extraction; the app remains sandboxed using [Sparkle’s installer service](https://sparkle-project.org/documentation/sandboxing/).

Releases are universal macOS 14+ DMGs containing Apple silicon and Intel code. Downloads and `appcast.xml` are assets of the public [GitHub Releases](https://github.com/vrypan/SideTable/releases):

- Stable feed: `https://github.com/vrypan/SideTable/releases/latest/download/appcast.xml`
- Versioned download: `https://github.com/vrypan/SideTable/releases/download/vX.Y.Z/SideTable-X.Y.Z-universal.dmg`

GitHub’s [latest-release asset links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) require a published full release. Drafts and prereleases do not become the production update feed. Publish the DMG and its matching feed together; retain old release assets, since already-downloaded feeds may reference them.

## One-time setup

A Developer ID Application certificate with its private key must be available in the login Keychain. Packaging selects it automatically when exactly one is installed; otherwise set `SIDETABLE_SIGN_IDENTITY` to its name or SHA-1 from `security find-identity -v -p codesigning`. Xcode’s Archive/Export workflow signs the application and Sparkle’s nested helpers with the same team.

Create a dedicated Sparkle key:

```sh
make update-key
```

This downloads checksum-pinned Sparkle tools, creates or reuses the Keychain account `sidetable-ed25519`, and writes **only the public key** to `config/updates.json`. Commit that file before releasing. The private key stays in Keychain; back it up offline using Sparkle’s `generate_keys --account sidetable-ed25519 -x /secure/path/key` and keep the exported file out of this repository. The command refuses to replace a previously configured key. Follow Sparkle’s key-rotation guidance for a future rotation.

Store Apple notarization credentials once (the tool prompts for an app-specific password):

```sh
xcrun notarytool store-credentials sidetable-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Alternatively, reuse an existing notarytool Keychain profile by setting `SIDETABLE_NOTARY_PROFILE`, for example `scotty-notary`. Credentials are never stored in the repository. Install and authenticate GitHub CLI (`gh`) for draft uploads.

## Prepare and upload a release

Run commands from the repository root. After committing the code, public key, and Unreleased notes, replace `X.Y.Z` below with the next release version. See [build versions](versions.md) for how tags and changelog notes are prepared.

If using the existing `scotty-notary` Keychain profile, select it in this shell before running the workflow:

```sh
export SIDETABLE_NOTARY_PROFILE=scotty-notary
```

If the variable is unset, the script uses `sidetable-notary`; it does not create that profile automatically.

Then run:

```sh
make check
make test-app
make release VERSION=X.Y.Z
make dmg
make notarize
make appcast
git push origin main vX.Y.Z
make github-draft
```

- `make dmg` requires a clean release tag and the matching Sparkle signing key. It archives and exports an optimized universal app, checks its identity, architecture, sandbox entitlements, and nested signatures, and creates a signed DMG with an Applications shortcut.
- `make notarize` submits that exact DMG to Apple, waits for acceptance, staples the ticket, and checks Gatekeeper. Apple’s result and diagnostic logs stay alongside the artifact.
- `make appcast` signs the final **stapled** bytes, embeds the version’s changelog notes, verifies the Sparkle signature, and checks feed URLs, versions, minimum macOS, and archive size. It does not upload anything.
- `make github-draft` verifies that GitHub’s tag matches the packaged commit, then uploads the DMG and appcast to a **draft** release using the generated notes. Review it on GitHub and publish it as the latest full release when ready.

Artifacts, the Xcode archive/dSYMs, notes, and logs live under `build/distribution/X.Y.Z/`. `build/distribution/release.json` identifies the current artifact and records checksums; later steps refuse modified or unnotarized files. Existing version directories are not overwritten. Inspect a failed packaging directory before removing it to retry; never replace an already published version. Do not edit a DMG after appcast generation.

Before the first public release, test the signed, notarized app on a clean Mac and exercise a real older-to-newer Sparkle upgrade, including canceling installation with unfinished attachments. Local tests cover updater gating, release preflight, metadata, and artifact validation; they do not substitute for that signed installation test. No binary is published by `make release` or `make dmg`.

## Notarization troubleshooting

`No Keychain password item found for profile` means the selected profile has no saved credentials. Select an existing profile or create one using the setup command above, then rerun `make notarize`. A missing-profile failure does not require rebuilding the DMG. You do not pass a notarization submission ID: the script submits the artifact and records the ID returned by Apple.
