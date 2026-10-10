# QuickTube

Menu bar app for macOS 15+: press a hotkey, record the screen with your
voice, press it again, and the YouTube link lands on your clipboard.

## Install

```bash
make install
open /Applications/QuickTube.app
```

`make app` builds `QuickTube.app` in the repo; `make install` copies it to
`/Applications`. The app icon is rendered from `Resources/AppIcon.svg`, which
needs `rsvg-convert` (`brew install librsvg`). The bundle is signed with the first "Apple Development"
identity in your keychain, or ad-hoc if there is none (then macOS re-asks
for Screen Recording after each rebuild).

## Google setup (once)

1. Google Cloud console → enable **YouTube Data API v3**.
2. **OAuth consent screen** → External → publish to **In production**.
   In "Testing" the refresh token expires after 7 days.
3. **Credentials** → Create OAuth client ID → **Desktop app**.
4. QuickTube menu → Settings → paste client ID and secret → Save client →
   Sign in with Google.

Known limit: an API project created after 2020-07-28 that has not passed
Google's compliance audit uploads as **private** no matter what. QuickTube
tells you in the notification; the link is still copied.

Quota: each upload costs 1600 of the default 10000 daily units, about six
recordings a day.

## Use

| Action | How |
|---|---|
| Start recording | `⌃⌥⌘R` (change in Settings) |
| Stop and upload | `⌃⌥⌘R` again |
| Retry a failed upload | menu → Retry Upload |
| Find the files | menu → Open Recordings Folder (`~/Movies/QuickTube`) |

Files are never deleted automatically.

## Develop

```bash
swift test
make lint
```
