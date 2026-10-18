# Pipcast

<img src="docs/branding/pipcast-logo.svg" alt="Pipcast" width="128">

**A free, native macOS launcher that runs Raycast extensions.** No account, no subscription,
no Electron. Requires macOS 26 or later.

- **Launch and search:** apps, files, menu items, the dictionary, and Apple Shortcuts
- **Clipboard history** for text and images, plus snippets and quicklinks
- **Window management**, with saved layouts and rooms
- **Calculator** with currency conversion, plus notes, an emoji picker, and calendar
- **Global and per-app hotkeys**
- **Raycast extensions**, running natively in JavaScriptCore
- **Raycast import** that brings over your existing setup

## Install

```sh
brew install --cask mSarheed/pipcast/pipcast@beta
```

Or download the DMG from [Releases](https://github.com/mSarheed/pipcast/releases). Builds are
Developer ID signed and notarized, and the in-app updater follows your installed channel.

## FAQ

### Is Pipcast built with AI?

Yes. About 90% of the code was written with AI, and we're not going to pretend otherwise.

AI-written doesn't mean careless. Pipcast runs on Swift 6 with strict concurrency, so a data race
fails the build. Our test harnesses compile the same source files we ship. Lint is enforced.
Every change has to clear the same bar no matter who or what wrote it, and you can read that bar
in [standards.md](docs/standards.md).

Is it perfect? No. Some code still needs a human to look at it, which is true of every codebase.
If you find a problem, [open an issue](https://github.com/mSarheed/pipcast/issues) and point to
the line. That helps us much more than "AI slop" with no specifics. We'll fix what you find.

### Why use Pipcast instead of Tinycast?

Pipcast started as a fork of Tinycast, and we're grateful for that starting point. The two
projects now want different things:

- **The goal is to replace Raycast, not to compete with it on philosophy.** If you know Raycast,
  you already know Pipcast: the same habits and the same extensions.
- **Bugs get fixed.** Reported issues are triaged and fixed instead of left open.
- **It's built for current macOS.** Pipcast uses current Apple APIs and treats deprecated code
  as a defect to remove.
- **You can install it side by side.** Pipcast keeps its own settings, storage and permissions,
  and can import your `.tinycast` backups.

### Is it affiliated with Raycast or Tinycast?

No. Pipcast is an independent project. Raycast is a trademark of Raycast Technologies.

## Documentation

| I want to…                            | Read                                                            |
| ------------------------------------- | --------------------------------------------------------------- |
| build and run it locally              | [development.md](docs/development.md)                           |
| understand how it's wired             | [architecture.md](docs/architecture.md)                         |
| know how code here is written         | [standards.md](docs/standards.md)                               |
| verify a change before a PR           | [testing.md](docs/testing.md)                                   |
| add or restyle UI                     | [ui.md](docs/ui.md)                                             |
| dig into one feature                  | [docs/features/](docs/README.md#features)                       |
| package a release                     | [release.md](docs/release.md)                                   |
| contribute or report a security issue | [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) |

The full docs index is at [docs/README.md](docs/README.md). AI agents should start with
[AGENTS.md](AGENTS.md).

## Repository layout

| Path                    | What's there                                               |
| ----------------------- | ---------------------------------------------------------- |
| `Pipcast/App/`          | entry point and `AppCore`, the composition root            |
| `Pipcast/Features/`     | one folder per feature                                     |
| `Pipcast/Palette/`      | the launcher panel shell                                   |
| `Pipcast/Windows/`      | dialogs, HUDs, About, and other non-palette windows        |
| `Pipcast/DesignSystem/` | shared visual primitives and `Theme`                       |
| `Pipcast/Platform/`     | system shims such as permissions, paths and signposts      |
| `Tests/`                | standalone test harnesses, run by `./Scripts/run-tests.sh` |
| `Scripts/`              | tests, lint, data generators, packaging                    |
| `website/`              | the project site                                           |

`project.yml` is the source of truth for the project. Run `xcodegen generate` after editing it.

## Contribute

Report bugs and ideas in [Issues](https://github.com/mSarheed/pipcast/issues). Before opening a
PR, read [CONTRIBUTING.md](CONTRIBUTING.md). Pipcast has no donations and no paid features.

## License

Pipcast is an independent fork of [Tinycast](https://github.com/abue-ammar/tinycast), created by
Abue Ammar and contributors. It is not an official Tinycast release. Modified by mSarheed on
2026-10-16. Pipcast modifications copyright © 2026 mSarheed. Licensed under AGPL-3.0-or-later.
See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
