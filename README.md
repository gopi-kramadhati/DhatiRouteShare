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

## Development setup

1. Install the Flutter SDK version compatible with `pubspec.yaml`.
2. Run `flutter pub get`.
3. Copy the `maps.apiKey` line from `android/local.properties.example` into
   the machine-specific `android/local.properties` file.
4. Create an Android Maps SDK key restricted to the application ID
   `com.gopikramadhati.routeshare` and the relevant signing certificate SHA-1.
5. Run `flutter analyze`, `flutter test`, and `flutter run`.

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
