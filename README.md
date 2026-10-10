# QuickTube

Menu bar app for macOS 15+: press a hotkey, record the screen with your
voice, press `⌃⌥⌘R` again to just save the file, or `⌃⌥⌘Y` to upload it to YouTube
and get the link on your clipboard.

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

## Telegram (optional)

A second shortcut, `⌃⌥⌘T`, stops the recording and sends it to a Telegram
channel instead of YouTube; the message link goes on the clipboard.

1. Create a bot with [@BotFather](https://t.me/BotFather), copy its token.
2. Add the bot to your channel as an administrator.
3. QuickTube → Settings → Telegram: paste the token and the channel
   (`@name` for a public channel, or the `-100…` id for a private one) → Save.

The Bot API accepts files up to 50 MB. Longer recordings are re-encoded
(HEVC + AAC at a lower bitrate; the frame size and length are kept) into a temporary
`<name>.telegram.mp4` that is sent and then deleted; the original stays on disk.
Settings → Telegram can turn compression off or change the limit — raise it
only if you run a self-hosted Bot API server (up to 2000 MB). Compression
never shrinks the frame size unless you enable "Allow downscaling when
compressing" there.

## Google Drive (optional)

`⌃⌥⌘D` stops the recording and uploads it to a "QuickTube" folder in your
Drive, shared as "anyone with the link"; the Drive link goes on the
clipboard. It uses the same Google sign-in (scope `drive.file`, which needs
no app verification). If you signed in before Drive support existed, sign out
and in again once. Free Drive storage is 15 GB.

## Slack (optional)

`⌃⌥⌘S` stops the recording and posts it to a Slack channel; the file's
permalink goes on the clipboard (visible to workspace members).

1. api.slack.com/apps → Create New App → OAuth & Permissions → Bot Token
   Scopes: `files:write` → Install to Workspace → copy the `xoxb-…` token.
2. Invite the bot to the channel (`/invite @yourbot`) and copy the channel ID
   (channel details → bottom of the About tab).
3. QuickTube → Settings → Slack: token + channel ID → Save.

## Use

| Action | How |
|---|---|
| Grant permissions | asked at first launch; status under Settings → Permissions |
| Start recording | `⌃⌥⌘R` (change in Settings) |
| Stop and just save the file (no upload) | `⌃⌥⌘R` again; Finder shows the file and its URL is on the clipboard |
| Stop and upload to YouTube | `⌃⌥⌘Y` |
| Stop and send to Telegram | `⌃⌥⌘T` |
| Stop and upload to Google Drive | `⌃⌥⌘D` |
| Stop and send to Slack | `⌃⌥⌘S` (any shortcut starts a recording; the one that stops it picks the destination) |
| Pick quality | Settings → Recording: Native / 4K / 1080p and 30 / 60 fps (applies to the next recording) |
| Watch progress | a small pill at the bottom of the screen: recording timer → upload % → link (click opens it); it is excluded from the recording |
| Retry a failed upload | menu → Retry Upload |
| Find the files | menu → Open Recordings Folder (`~/Movies/QuickTube`) |
| Start with macOS | Settings → General → Launch at login (installed app only) |

Files are never deleted automatically.

## Develop

```bash
swift test
make lint
```
