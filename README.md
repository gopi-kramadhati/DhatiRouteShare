# RouteShare

Record any drive as a reusable route, mark your stops, and drive it
**hands-free** — RouteShare hands each leg to Google Maps and automatically loads
the next one as you arrive at each stop, so you never touch your phone on the
road. Another person can follow the same path later, too.

Built with Flutter. Routes are stored locally and can be shared as RouteShare
JSON files, KML files, or stop-by-stop Google Maps links.

## Features

- One-tap route recording with background / screen-off GPS tracking
- Numbered stops (up to 20) with automatic start and end points
- **Guided Drive** (Android): automatic leg-by-leg Google Maps navigation with a
  small floating control card showing the next stop
- Follow mode with on-track and approaching-stop alerts
- Save, rename, reload, delete, and share routes
- No accounts, no server — all data stays on the device

## Platform status

| Platform | Status |
| --- | --- |
| Android | Supported (hands-free Guided Drive + floating card) |
| iOS | Planned (tap-a-notification to advance each leg; Apple platform limits prevent background auto-launch) |

## Google Maps API key (required)

**You must supply your own Google Maps API key to build RouteShare.** The
project's key is deliberately not committed — it lives only in
`android/local.properties`, which is git-ignored — so every person who clones the
repo provides their own.

To get set up:

1. In the [Google Cloud Console](https://console.cloud.google.com/), create a
   project and enable **Maps SDK for Android**. A billing account must be
   attached to the project, though map *display* itself is free.
2. Create an API key and **restrict it** to:
   - Application: your Android app package `com.gopikramadhati.routeshare`
     **plus your own signing SHA-1**. For local development this is your debug
     keystore's SHA-1 (`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android`). Your debug SHA-1 is different from
     anyone else's, so restrict the key to yours.
   - API: **Maps SDK for Android** only.
3. Add the key to `android/local.properties` (Flutter creates this file on first
   build; you can also copy `android/local.properties.example`):

   ```properties
   maps.apiKey=YOUR_OWN_ANDROID_MAPS_KEY
   ```

   It is injected into the manifest at build time via the `${MAPS_API_KEY}`
   placeholder — the key is never hardcoded in source.

Note: the in-app **map display** needs this key. The hands-free **Guided Drive**
hands off to your installed Google Maps *app* via an intent and needs no key, so
route recording and navigation hand-off still work even before the key is set —
you'll just see a blank base map inside RouteShare until it is.

## Development setup

1. Install the Flutter SDK version compatible with `pubspec.yaml`.
2. Run `flutter pub get`.
3. Add your Maps API key as described in
   [Google Maps API key (required)](#google-maps-api-key-required) above.
4. Run `flutter analyze`, `flutter test`, and `flutter run`.

## Troubleshooting

**The map is blank / grey inside the app.** This almost always means the Maps
API key is missing, invalid, or not restricted correctly. Check that
`android/local.properties` contains a valid `maps.apiKey`, that **Maps SDK for
Android** is enabled on the key's Cloud project, that billing is attached, and
that the key's app restriction includes *your* debug SHA-1. Recording and the
Google Maps hand-off work regardless — only the embedded base map depends on the
key.

## Android release signing

Create an upload keystore outside the repository. Copy
`android/key.properties.example` to `android/key.properties` and fill in its
four values. Both the keystore and `key.properties` are excluded from Git.

Release builds intentionally fail when signing configuration is absent:

```sh
flutter build appbundle --release
```

## Privacy model

Route points and waypoints are stored in the app's local documents directory.
They leave the device only when the user explicitly shares or opens an exported
route. Production builds do not create or expose the detailed GPS diagnostic
log used during development.

## Status

The Android application is being prepared for closed beta. The iOS project is
scaffolded but still requires its platform-specific Maps and background-location
configuration before it is ready for TestFlight.

## License

[MIT](LICENSE) © 2026 Gopi Kramadhati
