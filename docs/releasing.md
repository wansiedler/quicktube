# Releasing QuickTube

A tag `v<version>` runs `.github/workflows/release.yml`: it builds and signs
the app, packs `QuickTube-<version>.dmg`, signs the DMG for Sparkle, publishes
a GitHub Release with it, and adds the release to the Sparkle feed
`appcast.xml` on the `gh-pages` branch, served at
`https://wansiedler.github.io/quicktube/appcast.xml`.

Builds are signed with an Apple Development certificate and are **not
notarised**: on a Mac other than yours Gatekeeper warns on first launch
(right-click → Open, or System Settings → Privacy & Security → Open Anyway).
Sparkle updates install without that prompt once the app has been opened.

## One-time setup

### 1. EdDSA update keys

Sparkle verifies every update against the public key in the app. Generate
the pair once with Sparkle's tool (it is in the SwiftPM artifact after any
`swift build`):

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It stores the private key in your login keychain and prints the public key.
Put the public key into `Sources/QuickTube/Info.plist`, replacing the
placeholder:

```xml
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_PUBLIC_KEY</string>
```

Until that is done the app never starts Sparkle and the update controls are
disabled. Never lose the private key: without it no installed copy can be
updated again. Back it up (for example in your password manager):

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p   # prints the public key again
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key   # exports the private key
```

### 2. Repository secrets

| Secret | Value |
| --- | --- |
| `APPLE_DEV_CERT_P12` | base64 of the Apple Development certificate and its private key, exported from Keychain Access as `.p12` |
| `APPLE_DEV_CERT_PASSWORD` | the password chosen when exporting the `.p12` |
| `SPARKLE_PRIVATE_KEY` | the exported EdDSA private key (the contents of `sparkle_private_key`) |

```bash
base64 -i QuickTube.p12 | gh secret set APPLE_DEV_CERT_P12
gh secret set APPLE_DEV_CERT_PASSWORD
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key
rm -P QuickTube.p12 sparkle_private_key
```

Never commit the `.p12` or the private key (`.gitignore` excludes `*.p12`).

### 3. GitHub Pages

The first release creates the `gh-pages` branch. Then turn Pages on for it
(Settings → Pages → Deploy from a branch → `gh-pages` / root), or:

```bash
gh api -X POST repos/wansiedler/quicktube/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'
```

## Cutting a release

1. Bump the version in `Sources/QuickTube/Info.plist`:
   - `CFBundleShortVersionString` to the new version, e.g. `0.2.0`; the
     workflow fails if it does not match the tag.
   - `CFBundleVersion` to a number greater than every earlier release.
     Sparkle compares this value, so an update with the same or a lower
     build number is never offered. The workflow fails before publishing
     anything if it is not greater than the newest `sparkle:version` in the
     `appcast.xml` on `gh-pages` (or if `SUPublicEDKey` is still the
     placeholder).
2. Commit, merge to `main`, then tag and push the tag:

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. Watch the Release run. The Sparkle signature of the DMG is in the run
   summary; the release is under Releases and `appcast.xml` on `gh-pages`
   now lists it (older releases stay in the feed).

To check a DMG locally before tagging: `make dmg` (signs with your
Apple Development identity, ad-hoc without one) and
`codesign --verify --deep --strict QuickTube.app`. Ad-hoc builds are signed
with `QuickTube.adhoc.entitlements`, which adds
`com.apple.security.cs.disable-library-validation`: without a Team ID the
hardened runtime would refuse to load the bundled Sparkle.framework.

If a run fails after the release was created, delete the release and the tag
(`gh release delete v0.2.0 --cleanup-tag`), fix, and tag again.
