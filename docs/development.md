# Development

[Documentation](README.md) · [SideTable](../README.md)

Run these commands from the repository root. Open `Sidetable.xcodeproj`, choose the **Sidetable** scheme and **My Mac**, and run. The core is a local Swift package. Native Markdown parsing uses pinned Swift Markdown and swift-cmark dependencies; in-app updates use Sparkle 2.10.1. Xcode resolves these dependencies.

```sh
make build
make run
```

The app is built at `build/Build/Products/Debug/SideTable.app`. Development builds use ad-hoc signing. Distribution signing/notarization requires your own Apple Developer identity. Development was verified with Xcode 27.1 / Swift 6.4, targeting macOS 14.

To see sample conversations without connecting or changing saved accounts:

```sh
make preview
```

## Project generation

The checked-in Xcode project is generated from `project.yml`. After adding source files or changing project configuration, run:

```sh
make generate
```

Project regeneration was verified with XcodeGen 2.46.0. XcodeGen is only needed for regeneration. Git and Python 3.9 or later (`/usr/bin/python3`, supplied with the Xcode command-line tools) are required for build-version and release scripts.

See [testing](testing.md) for checks and preview fixtures, [architecture](architecture.md) for the source layout, and [releasing](releasing.md) for signed distribution builds.
