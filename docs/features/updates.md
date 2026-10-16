# Updates

By default, Pipcast checks `mSarheed/pipcast` GitHub Releases once a day and offers the newest release for its own
channel in a native window with its release notes, installs it and relaunches. There is no Sparkle and
no appcast: GitHub Releases is the only feed.

## Invariants

- **Pipcast installs its own updates, and Homebrew stays out of the way.** Both casks declare
  `auto_updates true`, which is Homebrew's own flag for an app that manages its own version. `brew
  update && brew upgrade` therefore skips Pipcast entirely — it is never reported outdated, never
  re-downloaded, and a self-updated copy is never trashed or rolled back. `brew install`, `brew
  uninstall` and `brew list` keep working unchanged.
- **The archive is a zip, never the DMG.** A zip expands with `ditto`; a DMG would have to be mounted,
  which means a volume, a Spotlight handle and a detach that can fail. A release published without a
  zip is not installable and is not offered.
- **The zip is chosen by architecture.** A stable release carries a thin arm64 zip and a
  `-Universal-` one. Intel takes the universal zip and is offered *nothing* if it is missing, since a
  thin build would install and then refuse to launch; Apple silicon prefers the thin zip and falls
  back to universal.
- **Nobody ever runs `xattr`.** An archive Pipcast fetched itself is not quarantined — macOS sets
  that flag for sandboxed downloaders and for apps that opt in with `LSFileQuarantineEnabled`, and
  Pipcast is neither. `Quarantine` checks anyway through `getxattr`/`removexattr` rather than the
  `xattr` tool, and an app that still carries the flag is refused rather than installed.
- **Updates require the configured Apple Developer team.** The nested code signature must
  validate against Apple's Developer ID chain and the Team ID embedded in the running app.
  Renewed Developer ID Application certificates under the same team are accepted.
- **A build only ever updates within its own channel.** The channels are separate bundle ids installed
  side by side; crossing would mean installing a different app. `io.github.msarheed.pipcast.app.dev` never updates
  at all, and does not advertise the command.
- **Nothing is installed unless every check passes.** Bundle id, version and signature are all checked
  on the expanded copy before `replaceItemAt` runs, and the running app survives any failure untouched.
- **Relaunching goes through `NSApp.terminate`, never `exit`.** That is what flushes a pending note
  draft and hands back the Hyper Key's HID-level caps remap, which outlives the process.
- **An automatic prompt defers to whatever the user is doing, and is never spent unshown.**
  `UpdateReadiness` withholds it while a snippet is expanding, an extension command is running, an
  uninstall is trashing, a shortcut is being recorded, a prompt or dialog is up, or the palette is
  open. A withheld prompt is still owed: `presentIfAvailable` answers `false`, the version is left
  unannounced, and the pump re-offers it every two minutes for half an hour before falling back to
  the daily rhythm. That is what a hand-launched copy depends on — its one announcement falls 30 s
  in, straight into the palette the user opened the app to use, where a launch-at-login copy would
  have found the desktop idle. The window itself still appears at most once per version per launch:
  `announcedVersion` is set the moment an offer lands, so re-offering can never turn into nagging.
  Readiness is asked again at the click.
- **Automatic checking is optional; manual checking stays available.** Settings → General →
  Automatically check for updates defaults on. Turning it off stops the background task and any
  in-flight automatic request, so neither a response nor a cached release can raise a new prompt.
  The preference travels through settings backups and `general.automaticallyCheckForUpdates` in
  settings.json; release metadata and skipped versions stay in the feature's own cache file.
- **The window shows the changelog and nothing else.** CI writes install instructions below
  `<!-- pipcast:install -->`, and `ReleaseNotes.summary` — the single reader of that marker, called
  where the feed is parsed so the cache holds the cut text too — drops them. An app that installs its
  own updates has no use for a Homebrew command, and a body published before the marker existed has
  none, so it comes back whole.
- **The notes are laid out by `ReleaseNotesView`, which is this feature's own.** `AttributedString`
  parses inline styling only; headings and bullets are placed by hand or they arrive as literal `##`
  and `*`. `ExtensionMarkdownView` does the same job and is deliberately not reused — an extension's
  views never leave `Features/Extensions/`.
- **`@handle` and `#304` are linked by the app, never by the release body.** GitHub autolinks both on
  the web, and a bare mention is what notifies the contributor, so the published body keeps them
  plain and `ReleaseNotes` spells them as Markdown links on the way to the window. Both point at
  `ReleaseFeed.repository`, the one place the repo is named.

## What's New

`CHANGELOG.md` is copied into the app bundle, and `ChangelogStore` parses it once at launch into
`Changelog` entries. The palette's What's New screen (`.changelog`, `ChangelogScreen`) lists the
versions this build has reached beside the selected one's notes, laid out by `ReleaseNotesView`;
↵ opens that release on GitHub. It opens from the What's New launcher command and the palette's
app menu, which replaced a link to the GitHub releases page.

- **What's New reads the build's own file, never the network.** The notes a user reads are the ones
  this build shipped with, offline, and the release body on GitHub is published from the same section
  ([release.md](../release.md#changelog)), so the two cannot disagree.
- **A beta reads the section of the release it leads to.** `AppVersion.release` maps
  `0.4.0-beta.3` to `0.4.0`; a beta never has a section of its own, and its row links to the release
  list because the tag does not exist yet. A section for a version this build has not reached is
  hidden.
- **An update is announced once, with a HUD and a dot.** After a launch on a newer version than the
  last one read, the palette's menu button and its What's New row carry an `UnreadDot`, and four
  seconds in a clickable HUD says what the app updated to. The HUD is recorded as `lastAnnounced` the
  moment it shows, so it is said once per version, never once per launch. It waits while the user is
  busy (`canInterruptUser`) or the message pill is in use — a Quick Action's progress and Cancel
  share it — retrying for two minutes before leaving it to the next launch. Opening What's New
  is what clears the dot, recorded as `lastSeen`.
- **An unread update also leads the empty launcher.** `WhatsNewCard` takes the lead-card slot
  (`LauncherScreen.Row.whatsNew`) with the release's headline, shaped like the meeting card; ↵ opens
  What's New, and ⌘K adds View on GitHub and Dismiss, which marks the notes read unopened. A due
  meeting keeps the slot: it is the one that cannot wait.
- **One setting gates the card, the HUD and the dot.** General → Show What's New after updates
  (`showsWhatsNewAfterUpdates`, `general.showWhatsNewAfterUpdates` in settings.json) defaults on;
  `ChangelogCoordinator.unreadRelease` is the single read all three take. Off, nothing is pinned,
  announced or dotted, while What's New stays one command away and the notes stay unread.
- **The HUD and the menu row open What's New; only the command toggles it.** `showChangelog` uses
  `showPalette`, so a second click never closes the screen it just opened; `toggleChangelog` keeps
  the launcher command's hotkey behaving like every other screen's.
- **A fresh install has nothing to catch up on.** `isFirstLaunch` is read before `start()` writes
  the onboarding marker; a fresh install records its version silently, and a copy that predates the
  record counts as updated. Both versions live in Application Support as `changelog.json`.

## Channel and version

`ReleaseChannel` is derived from the bundle id, and nothing else:

| Bundle id | Channel | Takes |
| --- | --- | --- |
| `io.github.msarheed.pipcast.app` | `.stable` | releases |
| `io.github.msarheed.pipcast.app.beta` | `.beta` | prereleases |
| anything else | `.development` | nothing |

`AppVersion` parses `MAJOR.MINOR.PATCH` and `MAJOR.MINOR.PATCH-beta.N` with semver precedence: a
prerelease sorts below the release it leads to, and `beta.10` above `beta.9`. Everything else parses
to nil, so an off-shape tag can never be offered as an update. A release whose tag disagrees with
its `prerelease` flag is treated as mis-published and skipped.

The Intel build is *not* a channel. It shares the stable tag, version, bundle id and signature, so it
resolves to `.stable` like any other; `ReleaseArchitecture` picks its asset, and nothing about
identity changes.

## Checking

`UpdateCheckStore` copies `CurrencyRateStore`: a private `.ephemeral`, `urlCache = nil` session, a
self-rescheduling pump, and one atomic JSON file.

```text
~/Library/Caches/<bundle-id>/update-check.json
```

It holds `lastCheckedAt`, the newest release seen, and the version the user dismissed. Freshness is
measured from `lastCheckedAt`, so relaunching never re-asks GitHub; the interval is 24 h, dropping to
2 h after a failed attempt, and the first check waits 30 s so it never lands in the login rush. The
request carries a `User-Agent`, which the GitHub API rejects requests without.

Disabling automatic checks takes effect immediately and survives relaunch. Turning them back on
resumes the same schedule, with the startup delay and cached check time respected. Check for Updates
always works independently of this preference, including while automatic checking is disabled.

**Later means skip.** It records the version, so that release stops asking; a newer one still asks.
Check for Updates ignores the record and always offers whatever is newer than what is running.

## Installing

One route, whatever the install came from:

1. Stream the zip into `~/Library/Caches/<bundle-id>/Updates/`, with real byte progress and a Cancel
   that actually aborts the transfer.
2. `ditto -x -k` it into a staging folder, and take whatever `.app` lands there — the bundle is named
   for its channel, so it is `Pipcast Beta.app` on beta.
3. Check quarantine natively; clear it if somehow present, and refuse the update if it survives.
4. Verify the bundle id, the version, and that the code signature is valid and proves the bundle is
   ours — by matching the configured Developer ID team.
5. `FileManager.replaceItemAt`. The staging folder is on the same volume as `/Applications`, which is
   what lets this be atomic. A non-writable `/Applications` is reported, not worked around; there is
   no privileged helper.
6. Offer Relaunch, which spawns a detached waiter that reopens the app once this process exits —
   `open` on a bundle id that is still running would only re-activate the instance on its way out.

Nothing here touches `~/Library/Preferences`, `~/Library/Caches` or `Application Support`, so no
setting, clipboard entry, note or snippet is affected by an update, by `brew upgrade`, or by both.

## Releasing into it

See [release.md](../release.md). The manual workflow signs, notarizes, and staples Pipcast
before publishing arm64 and universal DMGs and ZIPs. It updates the Pipcast Homebrew tap
after publication. The ZIP is made with `ditto` to preserve the signature and symlinks.
