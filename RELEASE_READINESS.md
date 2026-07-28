# RouteShare Android closed-beta readiness

Permanent Android application ID: `com.gopikramadhati.routeshare`

## Local values required

1. Let Flutter create `android/local.properties`, then add:

   ```properties
   maps.apiKey=YOUR_RESTRICTED_ANDROID_MAPS_KEY
   ```

2. Copy `android/key.properties.example` to `android/key.properties` and fill
   in the upload-keystore values. Keep both the keystore and passwords private.

## Google Cloud restriction

Restrict the Android Maps key to:

- Application ID: `com.gopikramadhati.routeshare`
- The debug SHA-1 for development and upload/release SHA-1 for release builds
- API restriction: Maps SDK for Android

Use separate development and production keys when the source is made public.

## Verification on the development Mac

Run:

```sh
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build appbundle --release
```

The expected bundle is:

```text
build/app/outputs/bundle/release/app-release.aab
```

## Real-device tests before Play upload

- Deny location once, retry, and permanently deny it; verify recovery text.
- Record for at least 30 minutes with the screen locked.
- Record while another app is in the foreground.
- Pause, resume, stop, save, reload, delete, and recover an interrupted route.
- Import valid, malformed, empty, oversized, and out-of-range route files.
- Exercise every Google Maps leg and the overlay permission denial path.
- Verify foreground notifications on Android 13 and later.
- Verify the release build contains no GPS diagnostic-log action.

The explicit `ACCESS_BACKGROUND_LOCATION` permission and direct battery-
optimization exemption request were removed for the first beta. If screen-off
recording proves unreliable on target devices, revisit the design and Play
policy declarations before restoring either permission.

## Still required outside the source tree

- Public privacy-policy URL
- Store listing text, screenshots, icon, and feature graphic
- Data Safety form matching the shipped dependencies and behaviour
- Foreground-service and special-use declarations requested by Play Console
- Internal test followed by the required closed test

The iOS target has consistent RouteShare naming and bundle ID, but still needs
iOS Maps initialization, location usage descriptions, background modes, and a
platform-specific Guided Drive design before TestFlight.
