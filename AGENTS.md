# Repository Guidelines

## Project Structure & Module Organization

This repository is currently uninitialized beyond Git metadata. There is no application code, test suite, or asset directory yet. When adding the initial implementation, choose a structure appropriate to the language and framework, and document it in `README.md`. Keep source code, tests, and static assets clearly separated; possible directory names include `src/`, `tests/`, and `assets/`. Create directories only when they contain useful files.

## Build, Test, and Development Commands

No build system, dependency manifest, or development commands are configured. The first implementation should provide reproducible setup, local execution, and verification instructions in `README.md`. Document exact commands and required tool versions alongside any environment prerequisites. Do not assume commands such as `npm test` or `make build` work until their configuration exists.

## Coding Style & Naming Conventions

Follow the selected language’s standard formatting conventions and configure its formatter or linter when introducing code. Use consistent indentation within each file, descriptive identifiers, and filenames that match the language’s conventions. Keep modules focused and avoid introducing dependencies without a clear purpose. Commit formatter configuration so contributors can reproduce the same output.

## Testing Guidelines

No testing framework or coverage target is established. Add appropriate tests with the initial implementation and document how to run them. Name tests after the behavior they verify, following the chosen framework’s discovery rules. Bug fixes should include regression tests where practical.

## Commit & Pull Request Guidelines

There is no commit history from which to infer conventions. Use concise, imperative commit subjects, such as `Add initial project setup`, and keep commits focused. Pull requests should explain the change, its purpose, and verification performed. Link relevant issues and include screenshots for visible interface changes. Explicitly identify checks that could not be run.

## Security & Configuration

Keep credentials, local environment files, dependency caches, and generated build output out of version control. Add appropriate `.gitignore` entries as tooling is introduced, and provide placeholder configuration examples instead of secrets.
