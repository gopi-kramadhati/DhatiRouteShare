# RouteShare — iOS build checklist

Porting the Android app to iPhone. The app is Flutter, so most Dart code is
shared, but iOS needs its own config, some plugin substitutions, and a
platform-specific Guided Drive design.

## 0. Reality check — parity

| Feature | iOS status |
| --- | --- |
| Record route, mark stops, save, list, delete | Works as-is |
| Share route (file / KML / Maps link) | Works (share sheet is native) |
| In-app Google Map + follow mode + alerts | Works (needs iOS Maps key) |
| Background / screen-off recording | Works, via iOS background location (needs "Always" permission + background mode) |
| Hands-free Guided Drive + floating card | NOT possible on iOS. Replace with tap-a-notification per leg |
| Auto-launch next leg from background | NOT possible on iOS (Apple forbids it) |

## 1. Prerequisites

- [ ] A Mac with the latest **Xcode** installed.
- [ ] **Apple Developer Program** membership ($99/year) — required for TestFlight and the App Store.
- [ ] **CocoaPods** installed (`sudo gem install cocoapods`).
- [ ] Run `flutter doctor` and clear any iOS toolchain issues.

## 2. Google Maps (iOS key)

- [ ] In Google Cloud Console, enable **Maps SDK for iOS** and create a new API key.
- [ ] Restrict the key to **iOS apps** with bundle ID `com.gopikramadhati.routeshare`.
- [ ] In `ios/Runner/AppDelegate.swift`, initialize it:
      `GMSServices.provideAPIKey("YOUR_IOS_MAPS_KEY")` (import GoogleMaps).
- [ ] Keep the key out of git (e.g., read from a config the way Android does).

## 3. Xcode / signing / bundle ID

- [ ] Open `ios/Runner.xcworkspace` in Xcode.
- [ ] Set **Bundle Identifier** = `com.gopikramadhati.routeshare`.
- [ ] Select your **Team** under Signing & Capabilities (automatic signing).
- [ ] Set the **minimum iOS version** in the Podfile to what the plugins require (e.g., `platform :ios, '13.0'`).
- [ ] Add capability: **Background Modes → Location updates**.

## 4. Info.plist entries (ios/Runner/Info.plist)

- [ ] `NSLocationWhenInUseUsageDescription` — "RouteShare uses your location to record and follow routes."
- [ ] `NSLocationAlwaysAndWhenInUseUsageDescription` — same, for background recording.
- [ ] `UIBackgroundModes` → include `location`.
- [ ] `LSApplicationQueriesSchemes` → `comgooglemaps`, `maps` (so we can open Google/Apple Maps).
- [ ] For file import: `CFBundleDocumentTypes` (open route files) + `UTExportedTypeDeclarations` for the `.routeshare` type, and the receive_sharing_intent **Share Extension** target.

## 5. Dart code changes (make it build + behave on iOS)

- [ ] **Guard Android-only plugins** with `Platform.isAndroid`:
      all `FlutterOverlayWindow.*` and `FlutterForegroundTask.*` calls.
- [ ] **Navigation launch:** on iOS use
      `comgooglemaps://?daddr=<lat>,<lng>&directionsmode=driving` (Google Maps app)
      or `http://maps.apple.com/?daddr=<lat>,<lng>&dirflg=d` (Apple Maps fallback).
      The `google.navigation:` intent is Android-only.
- [ ] **Guided Drive (iOS design):** geofence each stop → on arrival fire a
      **local notification** ("Reached stop N — tap to navigate to the next")
      → user taps → open Maps for the next leg. No floating card, no auto-launch.
- [ ] Add **flutter_local_notifications** for the tap-to-advance prompts.
- [ ] **Background location:** configure geolocator's iOS settings
      (`allowBackgroundLocationUpdates = true`, `pauseLocationUpdatesAutomatically = false`, `showBackgroundLocationIndicator = true`).

## 6. Plugin iOS notes

- geolocator, google_maps_flutter, share_plus, url_launcher, path_provider,
  file_picker, wakelock_plus, flutter_tts, audioplayers, open_filex → iOS-supported (some need the Info.plist keys above).
- receive_sharing_intent → iOS needs a **Share Extension** target added in Xcode.
- flutter_overlay_window → **Android only** (guard it out on iOS).
- flutter_foreground_task → Android-centric (guard out; rely on iOS background location instead).

## 7. Icons & launch screen

- [ ] Generate the **iOS app icon set** (AppIcon.appiconset) from the square logo.
      iOS icons must have **no alpha/transparency and no rounded corners** — the
      clean full-square icon is exactly right (Apple rounds it).
- [ ] Update the **LaunchScreen.storyboard** to match the splash branding.

## 8. App Store Connect

- [ ] Create the app record (bundle ID, name, SKU, primary language).
- [ ] **App Privacy** ("nutrition labels"): declare Location — used for app
      functionality, not linked to identity, not used for tracking. Matches the
      Android Data Safety answers.
- [ ] **Privacy policy URL:** reuse the existing GitHub Pages URL.
- [ ] **Screenshots:** required iPhone sizes (6.7" and 6.5" at minimum). Can reuse
      the same shots re-captured on an iPhone / simulator.
- [ ] **Export compliance:** app uses only standard HTTPS → typically exempt ("No" to custom encryption).
- [ ] **Age rating** questionnaire.

## 9. TestFlight (beta) then release

- [ ] Archive in Xcode (or `flutter build ipa`) and upload the build.
- [ ] **TestFlight:** internal testers work immediately; external testers require a
      short Beta App Review.
- [ ] Once happy, submit for **App Store review** (first review usually 1–3 days).

## Suggested order

1. Prereqs + Apple Developer account.
2. Xcode config (bundle ID, signing, background mode, Info.plist).
3. iOS Maps key + AppDelegate.
4. Dart guards so it compiles and runs on iOS (map, recording, sharing).
5. iOS Guided Drive (geofence → notification → tap → Maps).
6. Icons + launch screen.
7. TestFlight, then App Store submission.
