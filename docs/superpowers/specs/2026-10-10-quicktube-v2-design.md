# QuickTube v2 — design

Date: 2026-10-10
Status: approved in chat
Builds on: `2026-10-03-quicktube-design.md` (v1) and the v1.x additions on
`feature/v1` (HUD, Telegram / Drive / Slack destinations, quality presets,
diagnostics log).

## Goal

Eleven features on top of v1, every one of them switchable in Settings:
capture area/window selection, camera bubble, pause, system audio, link
history, click/keystroke highlighting, head/tail trimming, title template,
local-file cleanup, Sparkle updates, GIF output.

## Principles

- Every feature has an on/off control in Settings (and the relevant
  destinations/modes also in the menu bar menu). Defaults keep v1 behaviour:
  everything new is off except link history and tail trimming (1.0 s).
- Core logic stays in `QuickTubeCore` behind protocols and is unit-tested
  with fakes; anything that needs a window, a camera or TCC lives in the app
  target and is checked manually.
- Settings are one `Codable` struct `AppSettings` persisted in `UserDefaults`
  (`settings.v2`), read by Core through closures, so the app never passes
  loose values around. Secrets stay in the Keychain.
- Swift 6 strict concurrency, macOS 15. One new third-party package: Sparkle.

## Features

### 1. Capture target

`CaptureMode` in Settings and in the menu: `displayUnderCursor` (v1
behaviour), `selectArea`, `selectWindow`. In the two select modes the hotkey
first shows a selection overlay on the display under the cursor:

- area: crosshair cursor, drag a rectangle, release to confirm; Esc cancels;
  the rectangle is shown with its pixel size.
- window: windows under the cursor are highlighted (via
  `SCShareableContent` windows, on-screen, non-QuickTube); click confirms;
  Esc cancels.

The overlay yields a `CaptureTarget`:

```swift
public enum CaptureTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(display: CGDirectDisplayID, rect: CGRect)   // display points
}
```

`ScreenRecorder.start(target:)` replaces `start()`. `Recorder` builds the
`SCContentFilter`: display → as v1; window →
`SCContentFilter(desktopIndependentWindow:)`; region → display filter plus
`sourceRect` and an output size scaled from the region by the quality preset.
Cancelling the overlay returns the state machine to `.idle` silently.

### 2. Camera bubble

`cameraEnabled` toggle, `cameraSize` (S/M/L = 160/220/300 pt), `cameraCorner`
(four corners). A circular, borderless, always-on-top `NSPanel` shows the
default FaceTime camera through `AVCaptureVideoPreviewLayer`, draggable,
shown while recording (and optionally always: `cameraAlwaysOn`). It is
captured into the recording: the recorder's window exclusion list is now
explicit — only the HUD and selection overlay windows are excluded, by
`CGWindowID`, supplied by the app through a closure.

### 3. Pause

`pauseEnabled` toggle exposes hotkey `⌃⌥⌘P` and a menu item. `SCRecordingOutput`
cannot pause, so a recording is a list of segments: pause = stop the current
segment, resume = start a new one with the same target and quality. `stop()`
finalises the last segment and hands all segments to `RecordingFinisher`
(feature 7), which concatenates them into one file. `Phase` gains `.paused`.
The HUD shows "Paused" and the timer stops.

### 4. System audio

`systemAudioEnabled` sets `SCStreamConfiguration.capturesAudio = true`
(microphone stays governed by `microphoneEnabled`, default on). Both tracks go
into the same file. QuickTube's own audio is excluded
(`excludesCurrentProcessAudio`).

### 5. Link history

`historyEnabled` (default on). `AppState` records every successful upload as
`HistoryItem(link, destination, date, title)`; the app persists the last 20 in
`UserDefaults`. Menu: "Recent Links" submenu, newest first, each item
`"title — Destination"`, click copies the link. "Clear History" at the bottom.

### 6. Click and keystroke highlighting

`clickHighlightEnabled`: a transparent, click-through overlay window per
display draws a fading ring at each global mouse-down (global `NSEvent`
monitor; no permission needed). `keystrokeOverlayEnabled`: a small pill at
the bottom shows the last key combo for 1.5 s; needs Input Monitoring —
Settings shows the status and a button to System Settings; the toggle is
disabled until granted. Both overlays are excluded from capture only if
`overlaysInRecording` is off (default: on — they are the point).

### 7. Trimming (and segment concatenation)

`trimTailSeconds` (default 1.0, 0–3) removes the stop-hotkey press;
`trimHeadSeconds` (default 0, 0–3). `RecordingFinisher` (Core) takes the
segment files and the trim values, builds an `AVMutableComposition`, exports
with `AVAssetExportSession` preset passthrough to the final `.mp4`, deletes
the segment files, and returns the final URL. If there is exactly one segment
and both trims are 0, the file is used as is. Export failures surface as
`RecorderError.finishFailed(String)` and keep the segments.

### 8. Title template

`titleTemplate` (default `{date}`), placeholders: `{date}` (recording start,
`yyyy-MM-dd HH.mm.ss`), `{app}` (frontmost application name at start, empty if
none), `{display}` (display name or "Area"/window title for the other
targets). `RecordingNaming.render(template:context:)` is pure and tested.
The rendered title is the file stem and the upload title.

### 9. Local cleanup

`deleteAfterUpload` (default off): after a successful upload the local file
is moved to the Trash (`FileManager.trashItem`), never hard-deleted.
`deleteOlderThanDays` (default 0 = never): at launch, recordings in the
folder older than N days are moved to the Trash. Both are `RecordingCleanup`
in Core with an injected `FileManager`-like protocol for tests.

### 10. Updates

Sparkle 2 via SwiftPM. `Info.plist`: `SUFeedURL` pointing at
`https://wansiedler.github.io/quicktube/appcast.xml`, `SUPublicEDKey`.
Settings → General: "Check for updates automatically" toggle and a "Check
Now" button. `make dmg` builds a signed (Apple Development) DMG with
`create-dmg`-free `hdiutil`. GitHub Actions `release.yml` on tag `v*`: build,
`make dmg`, `sign_update` with the EdDSA private key from a secret, publish a
GitHub Release with the DMG, regenerate `appcast.xml` on the `gh-pages`
branch. Signing identity in CI: the Apple Development certificate (.p12)
from secrets; no notarisation (documented: Gatekeeper will warn on other
Macs).

### 11. GIF

Destination `.gif` with hotkey `⌃⌥⌘G` and `GIFUploader: VideoUploader` in
Core that converts the recording to a GIF next to it
(`<title>.gif`): `AVAssetImageGenerator` frames at `gifFPS` (default 10),
scaled to `gifMaxWidth` (default 800), capped at `gifMaxSeconds` (default 30)
from the start, written with ImageIO (`kCGImagePropertyGIFDelayTime`, loop
forever). The "link" is the file URL; the app puts the GIF file on the
pasteboard (`NSPasteboard` file URL + GIF data) and reveals it in Finder.
`gifEnabled` toggle hides the hotkey/menu item when off.

## Settings model

```swift
public struct AppSettings: Codable, Sendable, Equatable {
    public var captureMode: CaptureMode = .displayUnderCursor
    public var cameraEnabled = false, cameraAlwaysOn = false
    public var cameraSize: CameraSize = .medium, cameraCorner: Corner = .bottomLeft
    public var pauseEnabled = false
    public var systemAudioEnabled = false, microphoneEnabled = true
    public var historyEnabled = true
    public var clickHighlightEnabled = false, keystrokeOverlayEnabled = false, overlaysInRecording = true
    public var trimTailSeconds = 1.0, trimHeadSeconds = 0.0
    public var titleTemplate = "{date}"
    public var deleteAfterUpload = false, deleteOlderThanDays = 0
    public var automaticUpdates = true
    public var gifEnabled = false, gifFPS = 10, gifMaxWidth = 800, gifMaxSeconds = 30
    public var quality = RecordingQuality.default
}
```

Lives in Core (`AppSettings.swift`), decoded with defaults for missing keys so
older stored values keep working. The app owns `SettingsStore` (`@Observable`,
UserDefaults-backed) and hands Core closures such as `{ store.settings }`.

## Settings window layout

Sections: General (launch at login, updates), Recording (capture mode,
quality, fps, system audio, microphone, pause, trim head/tail, title
template), Camera, Overlays (click highlight, keystroke overlay + permission,
overlays in recording), History, Files (delete after upload, delete older
than), GIF, Permissions, Google, Telegram, Google Drive, Slack, Shortcuts
(six rows). The window sizing from v1.x stays.

## Menu

Status line; Start/Stop items per destination (hidden when a destination's
feature is off); Pause/Resume when enabled and recording; Capture mode
submenu; Quality and Frame rate submenus; Camera toggle; Recent Links
submenu; Open Recordings Folder; Open Log File; Check for Updates;
Settings…; Quit.

## Error handling additions

| Situation | Behaviour |
|---|---|
| Selection cancelled (Esc) | back to `.idle`, no notification |
| Window chosen disappears before capture starts | `RecorderError.noDisplay`-style failure with message "The chosen window is gone." |
| Camera unavailable / permission denied | bubble hidden, Settings shows status; recording continues |
| Segment export fails | `.failed` with segments kept; "Retry" re-runs the finisher |
| Input Monitoring not granted | keystroke toggle disabled with "Open System Settings" |
| GIF would exceed 50 MB | still written; HUD mentions the size |
| Sparkle feed unreachable | silent in automatic mode; "Check Now" shows Sparkle's own dialog |

## Testing

Unit (Core): `AppSettings` defaults/decoding; `RecordingNaming.render`;
`RecordingFinisher` composition maths (segment durations, trims clamped,
single-segment-no-trim passthrough) with injected export function; `GIFUploader`
frame schedule maths and ImageIO output on a tiny generated video;
`RecordingCleanup` with a fake file system; `AppState` pause/resume
transitions, history recording, cleanup-after-upload call, GIF destination.
Manual: overlay selection on 2 displays, camera bubble in the recording,
pause/resume audio continuity, system audio, overlays visible in video,
Sparkle check against a test appcast.

## Out of scope (v2)

Editing/annotations beyond trim, multi-camera, streaming, Windows.
