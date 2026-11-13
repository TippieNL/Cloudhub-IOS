# CloudHub for iOS

A native SwiftUI client for a self-hosted [CloudHub](https://github.com/TippieNL/Cloudhub-2)
server — the iOS counterpart of the Android app in `Cloudhub-2/android`, talking
to the same REST API.

## Building

Requirements: Xcode 16 or later, iOS 17 or later on the device.

```sh
brew install xcodegen
xcodegen                 # writes CloudHub.xcodeproj from project.yml
open CloudHub.xcodeproj
```

Pick your team under **Signing & Capabilities** (or set `DEVELOPMENT_TEAM` in
`project.yml`), choose a device, and run. The Xcode project is generated rather
than committed, so it never needs merging.

The shared logic lives in a Swift package and is tested on its own — on a Mac
or on Linux, no simulator needed:

```sh
cd Packages/CloudHubCore && swift test
```

CI (`.github/workflows/ci.yml`) runs those tests on Linux and macOS and builds
the app for the iOS Simulator.

## Layout

| Path | What |
|---|---|
| `Packages/CloudHubCore` | API client, models, upload queue and engine, and every rule the screens follow — sorting, search slicing, duplicates, storage meter, sign-in and two-step state machines. Ported from the Android app's Kotlin with its tests. |
| `CloudHub/Net` | The shared `URLSession` (cookies, certificate pinning, redirect handling), the Keychain cookie vault, the image cache. |
| `CloudHub/Uploads` | The queue as the UI sees it, and what keeps it running in the background. |
| `CloudHub/UI` | SwiftUI screens. |
| `project.yml` | XcodeGen spec: targets, Info.plist, permissions. |

## What it covers

Everything the Android app does: server setup with certificate pinning, sign-in
with SMS two-step verification (the code autofills from Messages), browsing as
grid or list with Name / Natural Number / Newest / Largest sorting, filtering
and the sliced All-folders search, new folder, rename, move, copy, delete to
trash, trash restore and empty, favorites, share links, properties, the photo
viewer (paging, pinch / double-tap zoom, Share, Download, Details with EXIF,
rename and delete with Undo), video and audio playback with resume and sidecar
subtitles, uploads from Photos, the camera, Files or another app's share sheet,
storage, the duplicate finder, settings and change password.

## Where iOS differs from Android

- **Downloads** go to the app's Documents folder, shown in the Files app under
  *On My iPhone › CloudHub*. Duplicate names get " (1)", " (2)" as on Android.
  To put a photo in the library, use **Share › Save Image** in the viewer.
- **Files with no viewer of their own** (PDF, text, Office, SVG…) open in Quick
  Look instead of being handed to another app.
- **Uploads in the background.** iOS has no WorkManager. The queue is on disk and
  the server reports what it holds, so nothing is ever sent twice; the app keeps
  uploading for a short while after you leave it, and asks iOS for a background
  processing slot to carry on later. iOS decides when that slot comes — often
  when the phone is idle — so a large upload finishes fastest with the app open.
  There is no progress notification; the bar in the file list shows progress.
- **Camera and microphone** permissions are asked for the first time you take a
  photo or record a video (Android delegates capture to the camera app).
- **Subtitles** are drawn by the app over AVKit's player (AVPlayer cannot attach
  a side-loaded WebVTT track to a progressive MP4). Pick a track from the
  captions button; the language is remembered, as on Android.
- **Video caching.** AVPlayer streams with byte ranges but keeps no disk cache
  between sessions, so the Android app's 256 MB video cache has no equivalent.
- **Folder navigation** stays on one screen with breadcrumbs and an up button,
  as on Android; other screens (Settings, Storage, Trash…) push and swipe back.
- **App Transport Security** is relaxed (`NSAllowsArbitraryLoads`) because
  self-hosted servers use plain http on home networks and self-signed
  certificates; the app itself asks before trusting a certificate and pins it
  by SHA-256. Mention this in App Review notes if you publish to the App Store.

## Security

- The session cookie (PHP's session cookie has no expiry, which iOS would drop
  at exit) is kept in the **Keychain**, readable after first unlock on this
  device only. The password is never stored; *Remember my username* stores the
  name only.
- An untrusted certificate is a question: the system is asked first, then the
  fingerprints you have accepted, and only then are you shown the SHA-256.
  Pins are per certificate, never per host.
- Writes are never followed through a redirect (a 301 turns a POST into a GET);
  the app names the problem instead.
- Recovery codes copied to the clipboard are local-only and expire after five
  minutes.
