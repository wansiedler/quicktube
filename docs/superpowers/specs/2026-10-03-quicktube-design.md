# QuickTube — design

Date: 2026-10-03
Status: approved in chat, pending spec review

## Goal

A macOS menu bar app that records the screen on a global hotkey, uploads the
recording to YouTube as an unlisted video, and puts the share link on the
clipboard. Free, native, no third-party dependencies.

## Non-goals (v1)

- Camera overlay
- Region or single-window selection
- System audio capture
- Trimming or any editing
- Hosting anywhere other than YouTube
- Multiple Google accounts

## User flow

1. Press the hotkey (default `⌃⌥⌘R`). Recording of the display under the
   cursor starts, with microphone audio. The menu bar icon turns red.
2. Press the hotkey again. Recording stops and the upload starts. The menu bar
   icon shows upload progress.
3. When the upload finishes, `https://youtu.be/<id>` is on the clipboard and a
   notification confirms it.

First run: the app asks for Screen Recording and Microphone permission, and
the user signs in to Google from the menu.

## Platform and build

- Swift 6, SwiftUI `MenuBarExtra`, `LSUIElement = true` (no Dock icon).
- Minimum macOS 15 (`SCRecordingOutput` and ScreenCaptureKit microphone
  capture both require it).
- Swift Package with two targets: `QuickTubeCore` (library, all logic) and
  `QuickTube` (executable, UI and wiring). Tests target `QuickTubeCore`.
- `Makefile` assembles `QuickTube.app` from the built executable and
  `Info.plist`, then code-signs it with the user's Developer ID team. A stable
  signature is required so the Screen Recording grant survives rebuilds.
- No third-party packages.

## Components

Each unit has one job and is reachable through a protocol so `AppState` can be
tested with fakes.

### HotkeyManager

Registers one global hotkey with Carbon `RegisterEventHotKey` and calls a
closure when it fires. Carbon hotkeys need no Accessibility permission. The
key combination is stored in `UserDefaults` and re-registered on change.

### Recorder

`start()` picks the `SCDisplay` under the cursor, builds an `SCStream` with
microphone capture enabled, and attaches an `SCRecordingOutput` writing HEVC
`.mp4` to `~/Movies/QuickTube/<yyyy-MM-dd HH.mm.ss>.mp4`. `stop()` stops the
stream and returns the file URL once the recording output has finished
writing.

Errors: permission denied, no display, writer failure.

### GoogleAuth

OAuth 2.0 for installed apps: authorization code flow with PKCE and a loopback
redirect (`http://127.0.0.1:<random port>`), served by a one-shot
`NWListener`. The system browser opens the consent page. Scope:
`https://www.googleapis.com/auth/youtube.upload` only.

The refresh token is stored in the Keychain. `accessToken()` returns a cached
access token or refreshes it. The OAuth client ID and secret come from the
user's own Google Cloud project and are entered in Settings (stored in the
Keychain as well).

Errors: user cancelled, token revoked (forces sign-in again), network.

### YouTubeUploader

Resumable upload against `videos.insert`:

1. `POST /upload/youtube/v3/videos?uploadType=resumable&part=snippet,status`
   with metadata: title = recording timestamp, `privacyStatus = unlisted`,
   `selfDeclaredMadeForKids = false`. Response gives the session URL.
2. `PUT` the file to the session URL in chunks of 8 MiB, reporting progress.
3. On a network failure, query the session for the committed byte offset and
   continue from there. Retry with exponential backoff, up to 5 attempts.

Returns the video id and the `privacyStatus` YouTube actually applied.

### AppState

`@Observable` state machine driving the menu bar UI:

```
idle -> recording -> uploading(progress) -> done(link)
                  \-> failed(error, file?)   <- from any step
```

The hotkey toggles `idle <-> recording`; it is ignored while uploading. On
`done`, the link is written to `NSPasteboard` and a `UNUserNotification` is
posted. `failed` keeps the file URL so the menu can offer "Retry upload".

### UI

Menu bar item with: status line, Start/Stop, Retry upload (when applicable),
Copy last link, Open recordings folder, Settings, Quit. Settings window:
hotkey recorder, Google sign-in/out, OAuth client ID and secret fields.

## Error handling

| Situation | Behaviour |
|---|---|
| Screen Recording or Microphone not granted | Notification with a button opening the right System Settings pane; state returns to idle |
| Not signed in when recording stops | File is kept; notification asks to sign in; Retry upload available |
| Upload fails after retries | File is kept; state `failed`; Retry upload available |
| YouTube applies `private` instead of `unlisted` | Link is still copied; notification states the video is private and why (unverified API project) |
| Quota exceeded (HTTP 403 `quotaExceeded`) | State `failed` with a clear message; file kept |

Recordings are never deleted automatically.

## Known external constraints

- **Private lock.** Videos uploaded through an API project created after
  2020-07-28 that has not passed Google's API compliance audit are forced to
  `private` and cannot be switched by the owner. The app cannot work around
  this. Either the user's Google Cloud project predates that date, or the
  project must pass the audit. The app detects the outcome and reports it.
- **Consent screen status.** With the OAuth consent screen in "Testing",
  refresh tokens expire after 7 days. It must be set to "In production".
- **Quota.** `videos.insert` costs 1600 units against a default daily quota
  of 10000, so about 6 uploads per day.

## Testing

Unit tests on `QuickTubeCore`:

- `YouTubeUploader`: session creation, chunking, resume from a reported
  offset, retry and backoff, privacy status parsing. `URLSession` is stubbed
  with a `URLProtocol` subclass.
- `GoogleAuth`: PKCE verifier and challenge generation, authorization URL
  construction, token refresh, revoked-token handling.
- `AppState`: every transition, using fake recorder, uploader and auth.

Manual checks: permission prompts, actual capture with audio, hotkey
registration, end-to-end upload against a real account.
