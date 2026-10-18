# Contributing to Pipcast

Check existing [issues](https://github.com/mSarheed/pipcast/issues) and
[pull requests](https://github.com/mSarheed/pipcast/pulls) first.

> **Don't hurry your code. Make sure it works well and is well designed. Don't worry about timing.**

## Non-negotiables

- **RAM.** Under 100 MB, always. No feature is worth going over.
- **No leaks.** Leak-test before you submit. Zero leaks, no retain cycles, memory back to baseline
  after the palette closes.
- **Design.** New UI must look like it shipped with the app — spacing, type, radii and motion from the
  existing tokens ([`docs/ui.md`](docs/ui.md)). If you genuinely need a new one, justify it in the PR.
- **No bloat.** Pipcast stays small on purpose — quality over quantity. A clean patch still gets
  declined if the feature isn't worth its weight. Unsure whether something fits? Ask in an issue.
- **Never break the Non-negotiables** in [`AGENTS.md`](AGENTS.md).

## Setup

- macOS 26+, Xcode 26. Do the one-time signing setup
  ([`docs/signing.md`](docs/signing.md) §1).
- `open Pipcast.xcodeproj` → ⌘R. Debug builds are their own channel (`Pipcast Dev.app`).
- After editing `project.yml`: `xcodegen generate`, commit the result. No SwiftPM.
- Details: [`docs/development.md`](docs/development.md). Architecture:
  [`docs/architecture.md`](docs/architecture.md). Start at [`docs/`](docs/README.md).

## Before submitting

- **The PR title follows [Conventional Commits](https://www.conventionalcommits.org/)**, e.g.
  `fix(launcher): keep the selection after a refresh`. PRs are squash-merged, so the title becomes
  the commit on `main` and the line in the changelog. A check fails until it matches.
- The whole bar in [`docs/testing.md`](docs/testing.md#definition-of-done) passes — harnesses, lint,
  purity, a clean build. Engine changes come with new cases. CI runs all four unless a PR only
  touches docs; run them locally first so it stays green. CodeRabbit reviews the Swift diff on top.
- Runtime changes are leak-tested and memory-measured. Numbers in the PR.
- You actually used the app, on your path and the ones next to it.
- Rebased on `main`.
- Anything in [`docs/`](docs/) your change makes wrong is fixed.
- **Read your own diff top to bottom before you open the PR.** Most review comments are things the
  author would have caught on a second pass.
- You agree to the
  [Contributor License and Feedback Agreement](CONTRIBUTOR_LICENSE_AND_FEEDBACK_AGREEMENT.md).
  Opening a PR is your acceptance.

## Pull requests

- Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md); delete the sections that don't apply.
- If it fixes or implements an issue, put `Closes #<number>` in the description. No issue is needed
  to open a PR.
- **Visual change → side-by-side before/after video. Mandatory.** Same window size, same actions.
  An "after"-only clip doesn't count; stills don't substitute.
- Non-visual → say what you tested.
- Flag anything surprising, and any tradeoff you made on purpose.

## Code style

Read [`AGENTS.md`](AGENTS.md) first — the posture, the Non-negotiables and the naming and comment rules
are all there, and they apply to a human contributor exactly as they do to an agent.
[`docs/standards.md`](docs/standards.md) is the full version: architecture, naming, Swift style,
concurrency and the performance budgets. [`docs/ui.md`](docs/ui.md) before any new view or restyle. Look before "fixing" something that looks
wrong — it may be deliberate.

One thing that is only about contributing, and so is not in those docs: behaviour you didn't mean
to change, didn't change. Say so explicitly in the PR if it did.

## Bugs

macOS version, Pipcast version + channel, steps, expected vs actual. A recording beats a paragraph.

## Security

Not in the issue tracker — see [`SECURITY.md`](SECURITY.md).

## License

[AGPL-3.0](LICENSE). Contributions are licensed under the same terms.
