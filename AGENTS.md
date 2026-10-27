# Repository Guidelines

## Project Structure & Module Organization

SideTable is a native SwiftUI/AppKit macOS client for Apron, targeting macOS 14 or later. `Sidetable/App/` owns application state and lifecycle, `Sidetable/Features/` contains views, and `Sidetable/Platform/` contains storage, media, and native integrations. Resources live in `Sidetable/Resources/`; branding and documentation assets live in `brand/` and `assets/`.

`Packages/ApronCore/` is an independent Swift package for wire models, the record store, sessions, transport, and the protocol probe. Its tests live in `Packages/ApronCore/Tests/`. Hosted app tests and UI tests live in `SidetableTests/` and `SidetableUITests/`. Python release tooling is in `scripts/`, with tests in `tests/`. Read `docs/architecture.md` and `docs/protocol.md` for implementation limits and protocol decisions; design/history documents live in `plans/`.

## Build, Test, and Development Commands

Run commands from the repository root. The verified development toolchain is Xcode 27.1 with Swift 6.4; the package and project use Swift 6 language mode. Git and Python 3.9+ are required by the build/release scripts. Xcode resolves the pinned Swift Markdown and Sparkle dependencies.

- `make build`: build the app into `build/Build/Products/Debug/SideTable.app`.
- `make run`: build and launch the app; `make preview`: launch with sample data.
- `make test-core`: run the independent core's Swift Testing suite.
- `make test-app`: run hosted app tests with isolated credentials and preview startup.
- `make test-ui`: run XCUITest; requires a usable GUI automation session.
- `make test-tools`: run Python release/distribution tests without publishing.
- `make check`: run tooling tests, core tests, and an app build. It does not run app or UI tests.

`project.yml` is the source of the checked-in Xcode project. Run `make generate` using XcodeGen 2.46.0 after adding app/test source files or changing project configuration. Swift package source/test discovery does not require regeneration. See `docs/development.md` and `docs/testing.md` for setup, integration checks, and the transcript benchmark.

## Coding Style & Naming Conventions

Match the existing Swift style: four-space indentation, descriptive type/member names, and focused files. UI state and AppKit work belong on the main actor; session and media state use actors, and shared values must preserve Sendable and snapshot semantics. There is no repository-wide formatter/linter configured; run `git diff --check` and avoid unrelated reformatting. Keep new dependencies purposeful and pinned.

## Testing Guidelines

Core and app tests use Swift Testing (`@Test`, `#expect`); UI tests use XCTest/XCUITest, and tooling tests use Python unittest. Name tests after behavior and add regression coverage for bugs where practical. Use scripted transports, temporary directories, and injected in-memory credentials; app tests must never touch real Keychain accounts. Run `make test-core` for core changes and `make test-app` for app changes or core changes affecting the app. Run `make test-tools` for release-tool changes. Live protocol/upload probes mutate only disposable loopback servers; see `docs/testing.md` before using them.

## Commit & Pull Request Guidelines

Use concise, imperative commit subjects and keep commits focused. Record the problem, resulting behavior, and verification in change descriptions; identify checks that were not run. Include screenshots for visible interface changes when useful. As stated in `CONTRIBUTING.md`, this project accepts issue reports and feature requests, but does not accept pull requests. Do not publish releases or push commits unless requested; release procedures are documented in `docs/releasing.md`.

## Security & Configuration

Keep credentials, local environment files, dependency caches, and generated build output out of version control. Add appropriate `.gitignore` entries as tooling is introduced, and provide placeholder configuration examples instead of secrets.
