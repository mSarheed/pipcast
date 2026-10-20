# Apple Shortcuts

The shortcuts a user builds in Apple's Shortcuts app appear in the launcher as their own section,
searchable by name and runnable with ↵, a favorite slot or a global shortcut. Pipcast lists and runs
them and nothing else: creating, editing, permissions and the actions themselves stay with Shortcuts.

The feature ships **off**. **Settings → Apple Shortcuts** carries the one switch, and lists the
library only while it is on. Off is fully off: the `shortcuts` tool is never spawned, the launcher
section is empty, and `AppleShortcutCoordinator.run(id:)` refuses to run anything. Bindings stay
registered, so re-enabling restores every global shortcut.

## Invariants

- **Shortcuts owns the library.** Nothing about a shortcut is stored except what every launcher entry
  already keys by `preferenceKey` — alias, visibility, favorite, ranking — and its hotkey binding.
  Its icon is a cache Shortcuts can always answer again, never preferences or a backup.
- **Only the Settings pane may raise the Automation prompt.** The launcher reads icons unprompted, so
  a system dialog never lands on top of the palette.
- **`run(id:)` is the single funnel** for a launcher row and a global shortcut alike, so the switch
  can't be bypassed.
- **A failed read keeps the last good library.** Emptying the launcher because one spawn failed would
  look like every shortcut was deleted.
- **Only a successful read frees anything.** A shortcut missing from one loses its binding, alias,
  visibility, favorite slot and ranking; a failed read changes nothing, since it can't tell deleted
  from unreadable. An empty read and turning the feature off free nothing either.
- **`Model/` stays Foundation-only and pure** for `apple-shortcut-test`.

## Discovery

There is no public API that enumerates shortcuts, so `AppleShortcutRunner` runs Apple's own
`/usr/bin/shortcuts` through `ToolRunner`. It needs no TCC grant and no Apple-event entitlement.

```text
shortcuts list --show-identifiers   →   Set Volume to 50% (97A1DDFA-76F3-4872-A672-25D5F35B7882)
```

`AppleShortcut.parseList` anchors on the **trailing** `(UUID)`, so a name carrying parentheses of its
own survives, and drops every other line — `ToolRunner` merges standard error into the output. The
identifier, not the name, is the shortcut's identity: it survives a rename in Shortcuts, so an alias
or a binding follows the shortcut rather than its old title. The entry id is
`apple-shortcut:<uuid>`, with no bundle id, so shortcuts never share a `preferenceKey` with the
Shortcuts app itself.

The list is re-read whenever the launcher opens, the Settings pane appears, or the switch turns on.
The tool answers in ~10 ms, so an overlapping request is simply dropped rather than queued. An
unchanged list publishes nothing.

## Sweeping deleted shortcuts

A read that differs from the last one — and the first read after launch, so a shortcut deleted while
Pipcast wasn't running is caught too — sweeps. `AppleShortcut.staleIDs` collects every
`apple-shortcut:` key the alias, favorite, visibility and ranking stores hold, plus
`boundAppleShortcutIDs`, and returns those the library no longer names. Each is unbound and its
per-entry preferences removed, the way deleting a quicklink unwinds them. A shortcut renamed in
Shortcuts keeps its UUID, so a rename is never a deletion.

**An empty read never sweeps.** Deleting every shortcut and a tool that answers with an empty list
look identical, and guessing wrong would free every binding at once. The cost is that the last
shortcut's references linger until the library holds one again.

## Running

`shortcuts run <uuid>` runs the shortcut headless. The palette hides first and hands focus back, since
a shortcut usually acts on the app the user was in. There is **no timeout** — a shortcut can wait on a
dialog of its own for as long as it likes. Success is silent; a non-zero exit shows the tool's last
lines in Pipcast's own dialog.

## Icons

Each row draws the shortcut's own icon, its glyph on its colour, as Shortcuts renders it. No public API
lists shortcut icons, and the Shortcuts database under `~/Library/Shortcuts` needs Full Disk Access, so
`AppleShortcutIconProvider` asks **Shortcuts Events** through its public scripting dictionary: the
`icon` property of `shortcut id "<UUID>"`, a 256-pixel TIFF of the finished tile. The identifier must
be the uppercase spelling; Shortcuts answers a lowercase one with nothing. It is a raw `getd` Apple
event rather than AppleScript, so every send can carry `kAEDoNotPromptForUserConsent`.

Sending needs **Automation permission for Shortcuts Events**, granted in Privacy & Security ›
Automation. `canRead(prompting:)` launches the helper hidden, since permission can only be determined
against a running target, then asks `AEDeterminePermissionToAutomateTarget`. The Settings pane's read
passes `prompting: true`, so opening the pane or turning the switch on raises the system prompt once.
Every launcher read passes `false`: a refusal, or a prompt never answered, stops the launcher trying
until the pane asks again. Running and listing shortcuts need no permission either way.

`AppleShortcutIconCache` keeps one 128-pixel PNG per shortcut in Caches, named
`<uuid>-<digest>.png` from a hash of the TIFF, so a changed icon is a new path and `IconCache` never
serves the old bitmap. Rows draw it as `.artwork` at `IconCache.appIconExtent`, the size of an app icon.
Icons are read one shortcut at a time, so a large library never holds more than one full-size TIFF.

- **The first read after launch, and every read the pane makes, sweeps**: every icon is fetched again,
  since a new glyph or colour keeps the shortcut's identifier. Unchanged icons write nothing.
- **Any other read fetches only shortcuts with no icon yet**, so an ordinary launcher open sends no
  Apple event at all. An icon edited while Pipcast runs updates on the next pane visit or launch.
- **The folder is scanned once per launch**, deleting files for shortcuts no longer listed. A replaced
  icon's file is deleted only after rows point at its successor. An empty or failed read scans nothing.

Without permission, or for a shortcut Shortcuts can't answer, the row keeps the Shortcuts app's icon.
Turning the feature off cancels a read in flight; the files stay for the next time it turns on.

## Launcher and Settings

`AppEntry.Kind.appleShortcut` is its own section, published right after Quicklinks. It is file-backed
rather than a symbol tile: every row's `url` is Shortcuts.app, whose icon a row draws until its own
is cached. Reveal in Finder is refused, because the file is the app, not the shortcut.

The pane lists rows through `LauncherItemsList`, the same table the launcher-category panes use: icon,
name, alias, shortcut recorder and the checkbox that hides one row from launcher search while its
shortcut keeps working. Its filter is membership in `AppIndex.matches`, so it answers to aliases.

`HotKeyAction.appleShortcut(id:)` persists under `hotkey.appleShortcut.<uuid>` with a
`boundAppleShortcutIDs` index. `appleShortcutsEnabled` rides in settings backups like the quicklink
flags, since running a shortcut the user built grants no permission class. Bindings are included in
`SettingsBackup.HotkeyBackup`, as are extension-command bindings. Apple Shortcut bindings still follow
the normal cleanup after a successful library read; a backup does not create the underlying shortcuts.

## Standalone harness

```sh
./Scripts/run-tests.sh apple-shortcut-test
```
