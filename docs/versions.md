# Build versions and release tags

[Documentation](README.md) · [SideTable](../README.md)

**SideTable > About SideTable** shows the build version. Builds use the highest `vX.Y.Z` release tag reachable from the current commit:

- A clean tagged commit shows `0.1.0`.
- Later commits show `0.1.0-<commit>`; tracked changes append `-dirty`.
- Before the first tag, builds use the source plist’s `0.1.0` baseline plus the commit hash. Source archives without Git metadata use the plist version alone.

Both `CFBundleShortVersionString` and `CFBundleVersion` use the numeric release version, without an offset or manual build counter. The full development label is stored separately as `SideTableVersion`. Xcode and `make build` generate the versioned plist inside the build directory before signing; the tracked source plist stays unchanged. Build labels ignore untracked files, but release preparation requires a completely clean working tree. Fetch release tags and history when building from a shallow checkout.

Replace `X.Y.Z` with the next release version in the commands below. To prepare a release, add notes under `## Unreleased` in [Changelog.md](../Changelog.md), commit your work, then run:

```sh
make release VERSION=X.Y.Z
```

`make release` requires a branch, a clean working tree, nonempty release notes, and an `X.Y.Z` version newer than all existing release tags. It dates the Unreleased section, commits it as `Prepare release X.Y.Z`, and tags that commit `vX.Y.Z`. It leaves no empty Unreleased section; add one when starting the next changes. It does not build, push, or publish. Use a new release version for each distributed update; rebuilding a tag retains its version.

See [development](development.md) for tool requirements and [releasing](releasing.md) for packaging, notarization, and publishing. `make test-tools` checks the release workflow in temporary repositories without changing this repository’s commits or tags.
