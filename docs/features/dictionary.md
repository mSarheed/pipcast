# Dictionary

`Define Word` is a launcher command and a fallback. The command opens the dictionary screen (`.dictionary`)
empty; the fallback opens it on whatever was typed. The search field stays the term, so a different
word is one edit away. Definitions come from the dictionaries enabled in Dictionary.app. Missing terms
offer macOS spelling corrections and completions, using the system spelling languages. Pipcast adds no
network requests or bundled word list.

## Invariants

- **The command gates the fallback, never the reverse.** Define Word has no feature pane, so
  Settings › Commands is its switch: while the command is hidden there — itself or the whole Commands
  category — `FallbackCoordinator` offers no Define Word fallback and Settings › Fallbacks does not
  list it. While it is visible, the fallback's own checkbox hides just the fallback, leaving the
  command searchable.
- **The page comes from an undocumented call, resolved at run time.** The public
  `DCSCopyTextDefinition` returns one unbroken line, so `DictionaryService` asks for the record's XHTML
  through `DCSGetActiveDictionaries`, `DCSCopyRecordsForSearchString` and `DCSRecordCopyData` — what
  Dictionary.app itself reads. They are found with `dlsym`, never linked: a macOS that drops one loses
  the layout and falls back to the public plain text, rather than failing to launch.
- **The span classes are the only structure, and `DictionaryMarkup` is the only reader of them.**
  `hg` is the headword, `posg` the part of speech, `se2` a numbered sense, `msDict` its definition or a
  `t_subsense` bullet, `note` an aside, `x_xoLblBlk` a section label (`ORIGIN`, `PHRASES`). Unknown
  markup reads as plain text in the nearest block, so a format change degrades rather than drops words.
  `dictionary-test` holds a real record as its fixture.
- **Lookups run off the main actor.** A long entry (`run`, `take`) is a few hundred blocks, so
  `DictionarySession` debounces the query and uses a `@concurrent` lookup.
  The previous page stays up until the next resolves, and ↵ and ⌘K act on that page — what is shown
  is what is copied — so neither the page nor the footer flickers while typing.
- **Suggestions never replace an exact definition.** Only a missing definition asks `NSSpellChecker`
  for asynchronous correction candidates. The system also supplies partial-word completions.
  Only full-query replacements are accepted; echoed input, duplicate and blank candidates are removed,
  preserving system order, with at most eight words shown. Requests are limited to single words of
  2–128 UTF-16 units. Definitions still accept phrases and longer queries.
- **Cancellation owns the wait.** Clearing, replacing or resetting a query cancels its task.
  AppKit exposes no candidate-request cancellation API; cancellation releases the waiter and spell
  document tag, and late callbacks cannot publish. Session teardown cancels its task too.

## Actions

| Key | Does |
| --- | --- |
| ↵ | Copy Definition on a definition page; look up the selected word in a suggestions list |
| ⌥↵ | Copy Word — the displayed entry term or selected suggestion, then the palette closes |
| ⌘↵ | Open in Dictionary — `dict://<term>`, for every other enabled dictionary |

The first enabled dictionary that knows the term answers, in Dictionary.app's own order. If none knows
it, the screen shows Suggestions, navigated with ↑/↓, or "No definition found" when macOS has no
candidates. Selecting a suggestion changes the search field and looks it up without closing the
palette. A spelling candidate may have no definition in the enabled dictionaries; Copy Word still
works directly from the suggestions list. The ⌘K menu exposes all three actions.
An open Actions menu closes when a new lookup result arrives, so its displayed labels cannot
outlive the result its actions address.

`dictionary-session-test` guards filtering, debounce, cancellation and stale-result rejection.
`PIPCAST_TEST_DICTIONARY_SYSTEM=1 ./Scripts/run-tests.sh dictionary-session-test` additionally checks
`reconize` and `recogni` against the Mac's installed spelling service; these English expectations
depend on the system spelling languages.
