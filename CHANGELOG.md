# Changelog

What changed in each Pipcast release, newest first. The release workflow writes each version's
section from its commits, and Pipcast shows this file in What's New.

## 0.2.1

1 fix.

### Fixed

- **updates** — Report a failed check as a check, not a download by @mSarheed in #43

## 0.2.0 — 2026-10-19

5 new features, 5 fixes and 6 other changes.

### New

- **launcher** — Set an alias or hotkey from the ⌘K actions menu by @mSarheed in #38
- **quicklinks** — Fetch website icons behind an opt-in setting by @mSarheed in #37
- **launcher** — Search settings with ? prefix by @AlexanderWillner in #32
- **palette** — Reach clipboard history with number slots and reveal chords instantly by @AlexanderWillner in #28
- **file-search** — Scope searches to folders and debounce queries by @mSarheed in #27

### Fixed

- **calculator** — Drop a currency fetch superseded by a newer one by @mSarheed
- **extensions** — Fill http STATUS_CODES and METHODS with node's tables by @mSarheed in #40
- **palette** — Stop retaining launcher snapshots by @mSarheed in #24
- **scripts** — Fail fast on the wrong toolchain and concurrent test runs by @mSarheed in #31
- **extensions** — Honor form tab navigation and action shortcuts by @mSarheed in #26

### Other

- Merge upstream tinycast main by @mSarheed
- **file-search** — Wait for recents instead of the clock by @mSarheed in #36
- **clipboard** — Stop the text indexer starving on loaded runners by @mSarheed in #33
- **coderabbit** — Review the whole repo and slim the swift instructions by @mSarheed in #30
- Replace the tinycast triage bots with build and title checks by @mSarheed in #29
- Point agents at the contribution rules by @mSarheed in #23

## 0.1.1 — 2026-10-17

1 fix.

### Fixed

- **release** — Use symbol form for depends_on macos by @AlexanderWillner in #20

## 0.1.0 — 2026-10-17

The first release of Pipcast: a fast, native launcher that lives in your menu bar.

### New

- **launcher** — Activate an exact alias with space by @mSarheed in #18
- **release** — Generate the changelog and version from commits by @mSarheed in #17
- **clipboard** — Create snippets from text history by @mSarheed in #14
- **updates** — Pin What's New atop the launcher after an update by @mSarheed in #10
- **dictionary** — Suggest words and copy selected terms by @mSarheed in #9
- **launcher** — Find What's New by changelog and release notes by @mSarheed in #8
- Add a built-in What's New changelog by @mSarheed in #7

### Improved

- Speed up launch, palette screens, chat history and image loading by @mSarheed in #15

### Fixed

- **palette** — Split menu observers so release builds type-check by @mSarheed in #16
- **launcher** — Activate search results with numbered shortcuts by @mSarheed
- **extensions** — Recover cancelled sign-ins and queue authorization by @mSarheed in #11
- **extensions** — Restore oauth web redirects by @mSarheed

### Other

- Merge upstream tinycast main by @mSarheed
- Merge upstream tinycast main by @mSarheed in #12
- Rewrite the README as a short entry point with an FAQ by @mSarheed in #6
- Remove the unused website by @mSarheed in #4
- **release** — Compile release architectures once in parallel by @mSarheed in #3
- Require conventional commit format for commits and PR titles by @mSarheed
- Fix extension executable fallback and child PATH lookup by @mSarheed in #2
- Complete Pipcast naming and replace the app, menu bar, and web logos by @mSarheed in #1
- Fix Homebrew repository API URL in release publishing by @mSarheed
- Fix inline signing requirement verification in releases by @mSarheed
- Prepare Developer ID releases, notarization, and the Pipcast Homebrew tap by @mSarheed
- Use Pipcast releases and an independent update signing identity by @mSarheed
- Name the app Pipcast, isolate its settings, and credit Tinycast by @mSarheed
