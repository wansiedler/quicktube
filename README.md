# QuickTube

Menu bar app for macOS 15+: press a hotkey, record the screen (a display, an
area or one window) with your voice, press `⌃⌥⌘R` again to just save the file,
or press a destination shortcut to upload it to YouTube, Telegram, Google Drive,
Slack or Vimeo (or turn it into a GIF) and get the link on your clipboard.

## Install

```bash
make install
open /Applications/QuickTube.app
```

`make app` builds `QuickTube.app` in the repo; `make install` copies it to
`/Applications`. The app icon is rendered from `Resources/AppIcon.svg`, which
needs `rsvg-convert` (`brew install librsvg`). The bundle is signed with the first "Apple Development"
identity in your keychain, or ad-hoc if there is none (then macOS re-asks
for Screen Recording after each rebuild, and the app is signed with
`QuickTube.adhoc.entitlements`, which turns off library validation so the
ad-hoc Sparkle.framework loads).

## Updates

Released builds update themselves with [Sparkle](https://sparkle-project.org):
Settings → General → "Check for updates automatically", or menu → Check for
Updates… The feed is `https://wansiedler.github.io/quicktube/appcast.xml`.
Builds from source carry a placeholder update key (`REPLACE_WITH_PUBLIC_KEY`
in `Sources/QuickTube/Info.plist`), so Sparkle never starts there and the
controls are disabled until a release key is set; see
[docs/releasing.md](docs/releasing.md) for the key and the repository secrets.

`make dmg` builds `build/QuickTube-<version>.dmg` (the app plus an
Applications link) with the same signing identity. Releases are signed with
an Apple Development certificate and not notarised, so on another Mac
Gatekeeper blocks the first launch: open it once, then allow it under System
Settings → Privacy & Security → Open Anyway (on macOS 15 right-click → Open
no longer bypasses Gatekeeper). How to cut a release:
[docs/releasing.md](docs/releasing.md).

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

Telegram's phone apps cannot play a full-resolution recording (6016×3384
HEVC shows a white screen; desktop plays it). So "Mobile-friendly (H.264, up
to 1080p)" in Settings → Telegram is on by default: every recording is sent as
H.264 High profile with the long side at most 1920 (1920×1080 for a 16:9
screen, aspect kept, never upscaled, frame rate unchanged), even when it is
under the size limit; a recording that already is H.264 at 1080p and 60 fps
or less is sent as is. The bitrate fits the size limit but stays at most 12 Mbit/s (up to
30 fps) or 16 Mbit/s (above), scaled down for smaller frames, so short clips
are not inflated; the retry pass below still applies.
Turn it off to get the behaviour described next (HEVC at full size,
re-encoded only when over the limit).

The Bot API accepts files up to 50 MB. Longer recordings are re-encoded into a
temporary `<name>.telegram.mp4` that is sent and then deleted; the original
stays on disk:

- With mobile-friendly off, only the bitrate drops: the video is re-encoded to
  HEVC (hardware encoder first, software fallback logged if it is
  unavailable), the frame size and length are kept. Enable "Allow downscaling
  when compressing" in Settings → Telegram to let it shrink the frame size too.
- Audio is not degraded: a single track is copied untouched; microphone plus
  system audio are mixed into one 160 kbit/s AAC track.
- If the encoder overshoots the limit, one retry pass re-encodes at a
  proportionally lower bitrate.
- The caption is the title plus a line with the display, size, frame rate and
  file size, for example `Pro Display XDR · 6016×3384 · 43 fps · 138 MB → 49 MB`
  (the arrow shows the size actually sent).

Settings → Telegram can turn compression off or change the limit — raise it
only if you run a self-hosted Bot API server (up to 2000 MB).

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

## Vimeo (optional)

`⌃⌥⌘V` stops the recording and uploads it to your Vimeo account (tus
resumable upload in 32 MB chunks, resumed after network hiccups); the video
link goes on the clipboard right away and shows "processing" until Vimeo has
transcoded it.

1. developer.vimeo.com → Create an app → Generate an access token
   (Authenticated, "you") with the scopes `upload`, `private` and `edit`.
2. QuickTube → Settings → Vimeo: paste the token → Save Vimeo. The token is
   kept in the Keychain (service `com.wansiedler.quicktube`, account
   `vimeo.token`); an empty field clears it.
3. Pick the privacy: Unlisted (`unlisted`: only people with the link, which
   includes a hash), Public (`anybody`: listed on your profile and
   searchable) or Only me (`nobody`).

Free (Basic) plans have weekly/total upload quotas and may refuse `unlisted`;
Vimeo's error text is shown as is ("Vimeo: …"), so pick another privacy or
plan if that happens.

## Use

### Shortcuts

Any destination shortcut starts a recording; the one that stops it picks the
destination. Change them in Settings → Shortcuts (hold ⌘ or ⌃ plus any other
modifiers).

| Shortcut | Action |
|---|---|
| `⌃⌥⌘R` | start; pressed again, stop and just save the file (Finder shows it, its URL is on the clipboard) |
| `⌃⌥⌘Y` | stop and upload to YouTube |
| `⌃⌥⌘T` | stop and send to Telegram |
| `⌃⌥⌘D` | stop and upload to Google Drive |
| `⌃⌥⌘S` | stop and send to Slack |
| `⌃⌥⌘V` | stop and upload to Vimeo |
| `⌃⌥⌘G` | stop and save a GIF (when Settings → GIF is on) |
| `⌃⌥⌘P` | pause / resume (when pause is on in Settings → Recording; fixed) |

### Features

- **Capture target** (Settings → Recording → Capture, also in the menu): the
  display under the cursor, a selected area (drag a rectangle; the pixel size
  is shown) or a selected window (click it). Esc cancels the chooser.
- **Quality**: Native / 4K / 1080p at 30 or 60 fps, for the next recording.
- **Bitrate** (Settings → Recording, also in the menu): QuickTube encodes the
  capture itself (hardware HEVC) at width × height × fps × a per-preset bits per
  pixel, clamped to 2–80 Mbit/s. Approximate video size per minute at 60 fps
  (30 fps is half, down to the 2 Mbit/s floor ≈ 14 MB/min); still screens take less:

  | Preset | bits/pixel/frame | 6K (6016×3384) | 4K | 1080p |
  | --- | --- | --- | --- | --- |
  | High | 0.032 | ≈ 280 MB/min (39 Mbit/s) | ≈ 114 MB/min | ≈ 28 MB/min |
  | Balanced (default) | 0.012 | ≈ 105 MB/min (15 Mbit/s) | ≈ 43 MB/min | ≈ 14 MB/min |
  | Compact | 0.006 | ≈ 52 MB/min (7 Mbit/s) | ≈ 21 MB/min | ≈ 14 MB/min |

  ScreenCaptureKit's built-in recording output, used before, wrote ≈ 21 Mbit/s
  (≈ 158 MB/min) at 6K with no control. Audio adds ≈ 2 MB/min (system stereo
  160 kbit/s and microphone 128 kbit/s, two separate AAC tracks).
- **System audio** next to the microphone; QuickTube's own sounds are never
  recorded.
- **Pause and resume**: each pause starts a new segment; on stop the segments
  are joined into one file. The status pill shows "Paused".
- **Trimming**: "Trim end" (default 1 s) cuts the stop-shortcut press, "Trim
  start" the beginning; at least half a second is always kept.
- **Title template**: `{date}`, `{app}` (frontmost app) and `{display}` name the
  file and the upload.
- **Camera bubble**: a round, draggable camera view in a chosen corner and size,
  shown while recording (or always). It is part of the recording for display
  and area captures; window recordings capture only that window, so they never
  contain it. The status pill and selection overlays are never recorded.
- **Overlays**: "Highlight clicks" draws a ring at each click, "Show
  keystrokes" a pill with the last key combo (needs Input Monitoring; Settings
  → Overlays shows the status and opens System Settings). "Show only
  shortcuts" (on by default) leaves out plain typing: only combos with ⌘ ⌃ ⌥
  and keys such as ⎋, ↩, arrows and F-keys appear, and nothing is shown while
  a password field is active. "Show overlays in recording" decides whether the
  video contains them.
- **History**: the last 20 uploaded links under Recent Links in the menu; click
  copies one. Settings → History can turn it off or clear it.
- **Cleanup**: "Move to Trash after upload" and "Trash recordings older than N
  days" (checked at launch). Files only ever go to the Trash.
- **GIF**: frame rate (default 10 fps), max width (800 px) and max length (30 s,
  cut from the start). Frames are capped at a 512 MB memory budget: fps drops
  first, then width, and the log says so. The GIF is saved next to the
  recording, copied and shown in Finder.

### Everyday

| Action | How |
|---|---|
| Grant permissions | asked at first launch; status under Settings → Permissions |
| Watch progress | a small pill at the bottom of the screen: recording timer → upload % → link (click opens it); it is excluded from the recording |
| Retry a failed upload | menu → Retry Upload |
| Find the files | menu → Open Recordings Folder (`~/Movies/QuickTube`) |
| Start with macOS | Settings → General → Launch at login (installed app only) |

### Settings

General (launch at login, updates) · Recording (capture, quality, frame rate, bitrate,
system audio, microphone, pause, trimming, title template) · Camera · History ·
Overlays · Files (cleanup) · GIF · Permissions · Google · Telegram · Google
Drive · Slack · Vimeo · Shortcuts.

## Develop

```bash
swift test
make lint
```
