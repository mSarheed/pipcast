# Pipcast releases

Releases are manual: Actions → Release → Run workflow. Choose `beta` or `stable` and a
base version such as `0.1.0`. Beta versions append the workflow run number.
Only run this after signing and Homebrew credentials are configured.

Before running it, add the version's section to `CHANGELOG.md` (see [Changelog](#changelog)).
The workflow checks for it first and stops before building if it is missing.

The workflow compiles arm64 and x86_64 once each in parallel, then combines their main and helper
executables into the universal app. Separate packaging jobs reuse the arm64 build, sign both apps
with Developer ID Application, notarize and staple the app and DMG, and validate their signatures.
Both architecture builds and both packaging jobs must succeed before anything is published.
It publishes DMGs, updater ZIPs, and the matching AGPL source archive, then updates the cask in
`mSarheed/homebrew-pipcast` with SHA-256 hashes.
Stable uses `pipcast`; beta uses `pipcast@beta`. Merging to main publishes nothing.

Repository variable:
- `APPLE_TEAM_ID`: your 10-character Apple Developer Team ID. Embedded in the signed app
  as its updater's allowed team. A missing or malformed value is rejected.

Repository Actions secrets:
- `SIGNING_P12_BASE64`: base64 encoding of only your Developer ID Application certificate
  and its private key exported as PKCS#12.
- `SIGNING_P12_PASSWORD`: password for that PKCS#12 export.
- `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_PRIVATE_KEY`: an App Store Connect team API
  key authorized for notarization, with its issuer and `.p8` private-key contents.
- `HOMEBREW_TAP_TOKEN`: a fine-grained GitHub token with Contents read/write access only
  to `mSarheed/homebrew-pipcast`.

Enter credentials through GitHub's Actions secret settings or `gh secret set` using
protected file/stdin input. Never commit or paste private keys into issue or chat text.

The beta is available now; stable becomes available after its first manual release:

```sh
brew install --cask mSarheed/pipcast/pipcast@beta
```

The cask declares `auto_updates true`; the in-app updater continues to offer new releases.
No quarantine-removal hook is used. User data is preserved on uninstall.

If publication succeeds but the tap update fails, the release remains available. Repair the
tap token and update the cask to that existing release; do not overwrite published assets.

Compilation jobs carry no signing or notarization secrets. They transfer app bundles in tar archives
so executable permissions and symlinks survive artifact storage. Packaging checks that both slices
have matching bundle identities, versions, signing teams and Xcode/SDK builds. The existing arm64
and `-Universal-` asset names stay unchanged so installed updaters and Homebrew keep selecting the
correct download.

## Changelog

`CHANGELOG.md` at the repo root is the one changelog. The app bundles it for What's New, the
`changelog` job in the Release workflow runs `Scripts/changelog-notes.py <version>` and stops the
release when the version has no section, and `publish-release.py` publishes that section as the
GitHub release body, above the install marker.

```markdown
## 0.2.0 — 2026-11-20

One line that sums up the release.

### New

- **Feature name** — what it lets you do, in a sentence.

### Improved

### Fixed
```

- One `## MAJOR.MINOR.PATCH` section per stable version, newest first; the date goes on when the
  stable release is cut. A beta never gets a section of its own: it shows, and publishes, the
  section of the version it leads to, so keep that section current as betas land.
- Summarize the release for users. Lead each bullet with a bold feature name, keep to the changes
  that matter, and leave the full commit history to GitHub's compare view.
- Wrapping a bullet across lines is fine; a blank line ends it.
- `changelog-test` fails while `project.yml`'s `MARKETING_VERSION` has no section, so bumping the
  version and writing its notes land together.
