# QuickTube v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the eleven v2 features (capture selection, camera bubble, pause, system audio, link history, click/keystroke overlays, trimming, title template, cleanup, Sparkle updates, GIF), each switchable in Settings.

**Architecture:** Core gains `AppSettings` (one Codable struct), `CaptureTarget`, segment-based `Recorder` with a `RecordingFinisher`, `GIFUploader`, `RecordingCleanup`, history in `AppState`. The app gains `SettingsStore`, a selection overlay, camera panel, click/key overlays, Sparkle. Core reads settings through injected closures; the app persists them.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI, ScreenCaptureKit, AVFoundation (composition/export, camera preview, image generator), ImageIO (GIF), Sparkle 2 (SPM), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-10-quicktube-v2-design.md` — binding; v1 spec `docs/superpowers/specs/2026-10-03-quicktube-design.md` for everything unchanged.

## Global Constraints

- Swift 6 language mode, strict concurrency clean on **both** local Swift 6.4 and CI's Xcode 26 / Swift 6.2: never await a method on a non-Sendable SDK object owned by an actor from the actor — wrap such calls in `nonisolated` static helpers returning an `@unchecked Sendable` box (see `Recorder.shareableContent()`).
- macOS 15 minimum. Only Sparkle may be added as a dependency (Task 11); nothing else.
- Every new feature has an on/off (or mode) control in Settings; defaults per spec: all new features off except `historyEnabled = true`, `microphoneEnabled = true`, `trimTailSeconds = 1.0`, `automaticUpdates = true`, `overlaysInRecording = true`.
- Existing behaviour unchanged when everything is off: display under cursor, mic on, HEVC, hotkeys ⌃⌥⌘R/T/D/S, HUD, destinations.
- Hotkeys: pause ⌃⌥⌘P (slot 5), GIF ⌃⌥⌘G (slot 6); all changeable in Settings → Shortcuts; hidden/unregistered when the feature is off.
- Secrets stay in Keychain; settings in `UserDefaults` key `settings.v2`.
- Before every commit: `swift test`, `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`, `swift build -c release --product QuickTube` all clean. `make app` must still assemble. Run `xcrun swift-format format -i --recursive Sources Tests` when lint complains.
- Commit author `wansiedler <apwansiedler@gmail.com>`, no trailers. Branch `feature/v2`.
- Work in `~/IdeaProjects/NAVFLEX/quicktube`. Shell aliases: use `/bin/rm`, `/bin/cp`.

## File structure

```
Sources/QuickTubeCore/
  AppSettings.swift          T1   Codable settings struct + enums (CaptureMode, CameraSize, Corner)
  RecordingNaming.swift      T2   + render(template:context:)
  CaptureTarget.swift        T4   enum CaptureTarget
  Recorder.swift             T3/T4/T6  segments, pause, targets, audio flags, window exclusion
  RecordingFinisher.swift    T3   segment concat + trim via AVFoundation
  AppState.swift             T2/T3/T7/T9/T10  title context, paused phase, history, cleanup hook
  RecordingCleanup.swift     T9
  GIFUploader.swift          T10
Sources/QuickTube/
  SettingsStore.swift        T1   @Observable UserDefaults-backed AppSettings
  SettingsView.swift         T1.. sections per feature
  MenuContent.swift          T1.. submenus/items
  SelectionOverlay.swift     T4   area/window picker windows
  CameraPanel.swift          T6
  ClickOverlay.swift         T8
  KeystrokeOverlay.swift     T8
  Updater.swift              T11  Sparkle wrapper
  AppModel.swift             all  wiring
Tests/QuickTubeCoreTests/
  AppSettingsTests, RecordingNamingTests(+), RecordingFinisherTests, AppStateTests(+),
  RecordingCleanupTests, GIFUploaderTests
Makefile                     T11  dmg target
.github/workflows/release.yml T11
.github/workflows/ci.yml     T12  coverage floors
README.md                    T12
```

---

### Task 1: AppSettings and SettingsStore

**Files:** Create `Sources/QuickTubeCore/AppSettings.swift`, `Sources/QuickTube/SettingsStore.swift`; modify `AppModel.swift`, `SettingsView.swift`, `MenuContent.swift`, `Recorder.swift` (quality closure now reads AppSettings); test `Tests/QuickTubeCoreTests/AppSettingsTests.swift`.

**Interfaces produced:**

```swift
public enum CaptureMode: String, Codable, CaseIterable, Sendable { case displayUnderCursor, selectArea, selectWindow; public var label: String }
public enum CameraSize: String, Codable, CaseIterable, Sendable { case small, medium, large; public var points: CGFloat /*160,220,300*/; public var label: String }
public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight; public var label: String }
public struct AppSettings: Codable, Sendable, Equatable { … exactly the fields in the spec, with defaults … ; public init() }
```
Decoding must tolerate missing keys (use `decodeIfPresent` with defaults in a custom `init(from:)`), so adding fields later never breaks stored data. Migration: if `settings.v2` is absent, seed `quality` from the old `recording.quality` key.

App: `@MainActor @Observable final class SettingsStore { var settings: AppSettings { didSet { persist } }; init(defaults: UserDefaults = .standard); static let key = "settings.v2" }`. `AppModel` owns `settingsStore` and exposes `var settings: AppSettings` (get/set through the store) and replaces the old `quality` property; `Recorder(quality:)` closure reads `UserDefaults` key `settings.v2` and decodes `AppSettings` (keep the UserDefaults handoff pattern). Settings and menu keep working for quality/fps via `$model.settings.quality`.

- [ ] Tests: defaults match the spec; round trip; decoding `{}` yields defaults; decoding a partial JSON keeps the rest at defaults; old `recording.quality` migration (test via a `UserDefaults(suiteName:)` in an app-level test is not possible from Core — cover the Core decoder only).
- [ ] Commit: "Add AppSettings and a UserDefaults-backed SettingsStore".

### Task 2: Title template

**Files:** modify `RecordingNaming.swift`, `AppState.swift`, `AppModel.swift`, `SettingsView.swift`; tests `RecordingNamingTests.swift`, `AppStateTests.swift`.

**Interfaces:**
```swift
public struct TitleContext: Sendable { public var date: Date; public var app: String?; public var display: String?; public var timeZone: TimeZone = .current; public init(...) }
public enum RecordingNaming { public static func render(template: String, context: TitleContext) -> String }  // {date} {app} {display}; collapses double spaces; trims; empty → date
```
Illegal file-name characters (`/`, `:`) in the result are replaced with `-`. `AppState.init` gains `titleProvider: @Sendable () -> TitleContext` (default: now, nil, nil) and `titleTemplate: @Sendable () -> String` (default `"{date}"`); the rendered title is used both for the final file name (Recorder keeps naming segments by date; `RecordingFinisher` in Task 3 writes the final file as `<title>.mp4` — until Task 3 lands, rename the single file after `stop()`) and the upload title. The app supplies `app` from `NSWorkspace.shared.frontmostApplication?.localizedName` captured at `start`, and the template from settings. Settings → Recording: text field "Title template" with the placeholder legend.

- [ ] Tests: render with all placeholders; missing app → no trailing space; illegal characters; AppState uses rendered title for the upload.
- [ ] Commit: "Add the title template".

### Task 3: Segments, pause and the finisher

**Files:** create `RecordingFinisher.swift`; modify `Recorder.swift`, `AppState.swift`, `HotkeyManager`/`AppModel.swift`, `MenuContent.swift`, `HUD.swift`, `SettingsView.swift`; tests `RecordingFinisherTests.swift`, `AppStateTests.swift`.

**Interfaces:**
```swift
public protocol ScreenRecorder: Sendable {
    func start(target: CaptureTarget) async throws      // CaptureTarget arrives in Task 4; in this task add the enum with only `.display(CGDirectDisplayID)` + `displayUnderCursor` resolution inside Recorder
    func pause() async throws                            // RecorderError.notRecording if not recording
    func resume() async throws                           // RecorderError.notPaused
    func stop() async throws -> [URL]                    // segment files, in order
}
public struct TrimSettings: Sendable, Equatable { public var head: TimeInterval; public var tail: TimeInterval }
public protocol RecordingFinishing: Sendable { func finish(segments: [URL], trim: TrimSettings, output: URL) async throws -> URL }
public actor RecordingFinisher: RecordingFinishing   // AVMutableComposition + AVAssetExportSession(.passthrough); single segment & zero trim → move file to output
public enum Phase { …, case paused }
```
`Recorder` holds `segments: [URL]` and the current `Session`; `pause()` stops the session (bounded, like `stop()` today) and appends its file; `resume()` starts a new session with the stored target; `stop()` returns all segments. `AppState`: `pause()`/`resume()` public, `toggle()` while `.paused` stops and uploads; after `recorder.stop()` it calls `finisher.finish(segments:trim:output:)` with output `<recordingsDir>/<title>.mp4` then uploads; on finisher failure → `.failed` with `file: nil` but segments kept, message "Could not finalize the recording; segments are kept in the recordings folder." HUD: `.paused` shows "Paused ⏸ m:ss". Hotkey slot 5 (⌃⌥⌘P) registered only when `pauseEnabled`; menu "Pause"/"Resume". Settings → Recording: pause toggle, trim head/tail steppers (0–3 s, 0.5 steps).

Finisher maths must be pure and tested: `static func plan(durations: [TimeInterval], trim:) -> [(segment: Int, range: ClosedRange<TimeInterval>)]` clamps so total trim never exceeds total duration (leave ≥ 0.5 s). The AV export itself is tested once on two tiny generated clips (use `AVAssetWriter` in the test to make 1-second black HEVC/H.264 clips; skip the test with `.disabled` reason if the writer cannot be created on CI).

- [ ] Tests: plan maths (clamping, multi-segment tail trimming spanning segments), single-segment passthrough, AppState pause/resume/stop transitions and finisher failure path, hotkey hidden when disabled (app-level: not unit-tested).
- [ ] Commit: "Add pause via recording segments and a trimming finisher".

### Task 4: Capture target selection and audio flags

**Files:** create `CaptureTarget.swift`, `Sources/QuickTube/SelectionOverlay.swift`; modify `Recorder.swift`, `AppState.swift`, `AppModel.swift`, `MenuContent.swift`, `SettingsView.swift`; tests `AppStateTests.swift`.

**Interfaces:**
```swift
public enum CaptureTarget: Sendable, Equatable { case display(CGDirectDisplayID), window(CGWindowID), region(display: CGDirectDisplayID, rect: CGRect) }
@MainActor public protocol CaptureTargetPicker { func pick(mode: CaptureMode) async -> CaptureTarget? }  // nil = cancelled
```
`AppState.init` gains `picker: CaptureTargetPicker?` and `captureMode: @Sendable () -> CaptureMode`; `toggle()` from idle: mode `.displayUnderCursor` → `.display(current)` resolved by the recorder (`CaptureTarget.displayUnderCursor` static helper in Core using `CGEvent` + `CGGetDisplaysWithPoint`), else `await picker.pick(mode:)`; nil → stay `.idle` silently. `Recorder` builds filters: display as today; window `SCContentFilter(desktopIndependentWindow:)` looked up in `SCShareableContent.windows` (missing → `RecorderError.windowGone`); region → display filter + `configuration.sourceRect = rect` (points) + output size = quality preset applied to `rect.size * scale`. Audio: `configuration.capturesAudio = settings.systemAudioEnabled`, `excludesCurrentProcessAudio = true`, `captureMicrophone = settings.microphoneEnabled`; the recorder reads these through its settings closure.

App `SelectionOverlay` (@MainActor class implementing `CaptureTargetPicker`): a borderless `NSWindow` covering the display under the cursor, level `.screenSaver`, `ignoresMouseEvents = false`; area mode: crosshair, drag rectangle, label with size, Esc cancels; window mode: on mouse move highlight the frontmost on-screen window under the cursor from `SCShareableContent` (exclude own bundle id, windows with zero size, desktop), click selects. Returns via `CheckedContinuation`. Settings → Recording: Capture mode picker (segmented), System audio toggle, Microphone toggle. Menu: "Capture: …" submenu.

- [ ] Tests: AppState with a fake picker (returns target / nil); nil leaves `.idle` and never calls `recorder.start`; the target passed to the fake recorder is the picked one.
- [ ] Commit: "Add area/window capture selection and audio toggles".

### Task 5: Camera bubble and explicit window exclusion

**Files:** create `Sources/QuickTube/CameraPanel.swift`; modify `Recorder.swift` (exclusion by window IDs), `HUD.swift`/`SelectionOverlay.swift` (expose `windowNumber`), `AppModel.swift`, `MenuContent.swift`, `SettingsView.swift`, `Permissions.swift` (camera status), `Info.plist` (`NSCameraUsageDescription`).

`Recorder.init` gains `excludedWindows: @Sendable () -> [CGWindowID]` (default `[]`) and uses `SCContentFilter(display:excludingWindows:)` with the matching `SCWindow`s instead of excluding the whole app. The app passes the HUD panel, selection overlay and (Task 8) overlay windows when `overlaysInRecording` is off — never the camera panel. `CameraPanel`: circular `NSPanel` (`.nonactivatingPanel`, `.floating`, `canJoinAllSpaces`), `AVCaptureSession` with the default video device, `AVCaptureVideoPreviewLayer` with `cornerRadius = size/2`, mirrored, draggable by background, positioned at `cameraCorner` with 24 pt inset, size from `cameraSize`; shown while recording when `cameraEnabled`, always when `cameraAlwaysOn`. Camera permission requested on first enable; status row in Settings → Permissions. Menu: "Camera" toggle. Settings → Camera: enabled, always on, size (segmented), corner (picker).

- [ ] Manual check only (document in the report: bubble visible in a recording, HUD not).
- [ ] Commit: "Add the camera bubble and exclude only overlay windows from capture".

### Task 6: Link history

**Files:** modify `AppState.swift`, `AppModel.swift`, `MenuContent.swift`, `SettingsView.swift`; tests `AppStateTests.swift`.

```swift
public struct HistoryItem: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let link: URL; public let destination: Destination; public let date: Date; public let title: String }
// AppState: public private(set) var history: [HistoryItem]; init(..., history: [HistoryItem] = [], historyEnabled: @Sendable () -> Bool = { true }, onHistoryChange: (([HistoryItem]) -> Void)? = nil)
public func clearHistory()
```
Max 20, newest first; the app persists via `onHistoryChange` to `UserDefaults` key `history.v2` and seeds `history:` at launch. Menu: "Recent Links" submenu with `"<title> — <Destination>"` items (click → pasteboard) and "Clear History"; hidden when `historyEnabled` is off. Settings → History: toggle + "Clear" button.

- [ ] Tests: entries added on success with the right destination/title; cap at 20; disabled → nothing recorded; clear.
- [ ] Commit: "Add link history".

### Task 7: Click and keystroke overlays

**Files:** create `Sources/QuickTube/ClickOverlay.swift`, `Sources/QuickTube/KeystrokeOverlay.swift`; modify `AppModel.swift`, `SettingsView.swift`, `Permissions.swift`.

`ClickOverlay`: one transparent, click-through (`ignoresMouseEvents = true`) borderless window per screen at level `.screenSaver - 1`, `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` draws a 44 pt ring that fades over 0.4 s (SwiftUI view with an array of timestamped points). `KeystrokeOverlay`: pill at bottom-centre (above the HUD) showing the last combo (`⌘⇧S` style, via `NSEvent.modifierFlags` + `charactersIgnoringModifiers`) for 1.5 s, from a global `.keyDown` monitor — works only with Input Monitoring; `Permissions.inputMonitoring` uses `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()`. Both are started/stopped with recording when enabled (and only then). When `overlaysInRecording` is false their window numbers join the recorder's exclusion list. Settings → Overlays: two toggles (keystroke disabled until granted, with a Request / Open System Settings button) and "Show overlays in recording".

- [ ] Manual check only.
- [ ] Commit: "Add click and keystroke overlays".

### Task 8: Local cleanup

**Files:** create `RecordingCleanup.swift`; modify `AppState.swift`, `AppModel.swift`, `SettingsView.swift`; tests `RecordingCleanupTests.swift`, `AppStateTests.swift`.

```swift
public protocol RecordingFiles: Sendable { func recordings(in directory: URL) throws -> [(url: URL, modified: Date)]; func trash(_ url: URL) throws }
public struct RecordingCleanup: Sendable { public init(files: RecordingFiles, now: @Sendable () -> Date = { Date() }); public func trashOlder(than days: Int, in directory: URL) throws -> [URL]; public func trashAfterUpload(_ file: URL) throws }
public struct DefaultRecordingFiles: RecordingFiles  // FileManager-backed, trashItem
```
`AppState.init` gains `afterUpload: (@Sendable (URL) throws -> Void)?`; on success it calls it (errors → log only, never fail the upload). The app wires `trashAfterUpload` when `deleteAfterUpload`, and runs `trashOlder(than:)` at launch when `deleteOlderThanDays > 0`. Settings → Files: toggle + stepper (days).

- [ ] Tests: older-than selection with a fake file list; 0 days = nothing; after-upload called only on success and with the uploaded file.
- [ ] Commit: "Add local recording cleanup".

### Task 9: GIF destination

**Files:** create `GIFUploader.swift`; modify `AppState.swift` (Destination `.gif`), `AppModel.swift`, `HotkeyManager.swift` (slot 6, ⌃⌥⌘G), `MenuContent.swift`, `SettingsView.swift`, `AppNotifier.swift`; tests `GIFUploaderTests.swift`.

```swift
public struct GIFOptions: Sendable, Equatable { public var fps: Int; public var maxWidth: Int; public var maxSeconds: Int }
public actor GIFUploader: VideoUploader { public init(options: @Sendable () -> GIFOptions, log:) ; static func frameTimes(duration:, fps:, maxSeconds:) -> [CMTime]; static func outputSize(for natural: CGSize, maxWidth: Int) -> CGSize }
```
Frames via `AVAssetImageGenerator` (`requestedTimeToleranceBefore/After = .zero`, `maximumSize`), written with `CGImageDestinationCreateWithURL(kUTTypeGIF)`, file properties loop count 0, per-frame delay `1/fps`. Output next to the recording: `<stem>.gif`; the result link is the file URL. `AppNotifier.linkReady` for a `file://` link writes both the file URL and the GIF data to the pasteboard and calls `NSWorkspace.shared.activateFileViewerSelecting`. HUD/notification text "GIF ready · <size> MB". Destination hidden (menu + hotkey) unless `gifEnabled`. Settings → GIF: toggle, fps (5–30), max width (320–1920), max seconds (5–120).

- [ ] Tests: `frameTimes` count/cap; `outputSize` keeps aspect and never upscales; end-to-end on a generated 1-second clip produces a GIF whose `CGImageSource` frame count equals the plan (skip if the writer is unavailable).
- [ ] Commit: "Add GIF output as a destination".

### Task 10: Sparkle updates, DMG and release workflow

**Files:** modify `Package.swift` (Sparkle 2.x dependency, `QuickTube` target only), `Info.plist` (`SUFeedURL`, `SUPublicEDKey` placeholder `REPLACE_WITH_PUBLIC_KEY`), `Makefile` (`dmg` target: `hdiutil create` from a staged folder with the app and an Applications symlink, codesign the DMG), create `Sources/QuickTube/Updater.swift` (`SPUStandardUpdaterController`, `automaticallyChecksForUpdates` bound to `automaticUpdates`, `checkForUpdates()`), `.github/workflows/release.yml`, `docs/releasing.md`; modify `SettingsView.swift` (General: toggle + Check Now), `MenuContent.swift` ("Check for Updates…"), `.github/dependabot.yml` already covers swift packages.

`release.yml`: on `push: tags: ['v*']`, `macos-15`, Xcode 26: import the `.p12` from secrets (`APPLE_DEV_CERT_P12`, `APPLE_DEV_CERT_PASSWORD`) into a temporary keychain, `make dmg IDENTITY="$IDENTITY"`, `sign_update` (Sparkle's tool from the SPM artifact bundle) with `SPARKLE_PRIVATE_KEY`, create the GitHub Release with the DMG, generate `appcast.xml` with `generate_appcast` and push it to the `gh-pages` branch. All actions SHA-pinned; `persist-credentials: false`; zizmor clean. `docs/releasing.md`: generating EdDSA keys (`generate_keys`), putting the public key in Info.plist, the three secrets, tagging. Do NOT run the workflow; do not generate or commit keys.

- [ ] Verify: `swift build` resolves Sparkle; `make app` and `make dmg` succeed locally (ad-hoc or dev identity); `actionlint` and `zizmor --persona=regular` clean.
- [ ] Commit: "Add Sparkle updates, a DMG target and a release workflow".

### Task 11: Shortcuts section, CI floors, README, PR

**Files:** modify `SettingsView.swift` (six shortcut rows), `.github/workflows/ci.yml` (floors for new pure files: `AppSettings.swift`, `RecordingNaming.swift`, `RecordingFinisher.swift` plan maths ≥ 80, `RecordingCleanup.swift`, `GIFUploader.swift` maths — measure first, set to floor(measured)), `README.md` (v2 features, settings, Sparkle note).

- [ ] Run the full suite, lint, release build, `make app`; push `feature/v2`; open a draft PR to `main` listing every feature and what was checked manually.
- [ ] Commit: "Document v2 and raise coverage floors".
