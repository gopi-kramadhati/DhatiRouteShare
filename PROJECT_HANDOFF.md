# RouteShare — moving the project to another laptop

Everything needed to continue development on a new machine. The code travels via
Git; a few **secrets are deliberately NOT in Git** and must be copied by hand.

## Step 1 — On the OLD laptop: push everything first

```sh
cd /Users/gopi_imac/route_share_app
git add -A
git commit -m "docs + wip"      # commit anything outstanding
git push
git status                       # should say "nothing to commit, working tree clean"
git log --oneline -3             # note the latest commit hash
```

Do not skip this — anything not pushed will not appear on the new laptop.

## Step 2 — Copy the secrets (these are git-ignored, so Git will NOT bring them)

Transfer these securely (AirDrop, encrypted drive, password manager — NOT email/chat):

1. **Upload keystore:** `~/routeshare-upload.jks`
   - This signs app updates. If lost, you can recover via Play App Signing, but keep it safe.
2. **`android/key.properties`** — keystore passwords + alias + path to the .jks.
   - On the new laptop, fix the `storeFile=` path to wherever you place the .jks.
3. **Maps API key value(s)** — you'll re-add these to `android/local.properties`
   (Android) and, later, `AppDelegate.swift` (iOS). The key itself lives in your
   Google Cloud Console, so you can also just copy it from there.

Note: `android/local.properties` also contains a machine-specific Flutter SDK
path. Let Flutter regenerate that file on the new laptop, then add the single
line `maps.apiKey=YOUR_ANDROID_MAPS_KEY` back into it.

## Step 3 — Install the toolchain on the NEW laptop

- **Flutter SDK** (stable channel) + add to PATH.
- **Android Studio** + Android SDK + platform tools.
- **JDK** (Android Studio bundles one; `keytool` comes with it).
- For iOS: **Xcode** + **CocoaPods** (`sudo gem install cocoapods`).
- Run `flutter doctor` and resolve anything it flags.

## Step 4 — Accounts / logins (same identities, not files)

- **GitHub** — sign in; you'll clone from `github.com/gopi-kramadhati/DhatiRouteShare`.
- **Google Play Console** — same Google account (`gopikramadhati@gmail.com`).
- **Google Cloud Console** — where the Maps keys live (restrict the new machine's
  debug SHA-1 too, see Step 6).
- **Apple Developer** account (for the iOS build later).

## Step 5 — Clone and configure on the NEW laptop

```sh
git clone https://github.com/gopi-kramadhati/DhatiRouteShare.git route_share_app
cd route_share_app

# put the keystore somewhere, then create android/key.properties (Step 2)
# let Flutter create android/local.properties, then add maps.apiKey=...

flutter pub get
flutter run                      # debug run to confirm it builds
```

## Step 6 — Add the new laptop's debug SHA-1 to the Maps key

Each computer signs debug builds with its own debug keystore, so the map will be
blank until you add this machine's debug SHA-1 to the Android Maps key:

```sh
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
```

Add that SHA-1 (with package `com.gopikramadhati.routeshare`) in Google Cloud
Console → your Android Maps key → Application restrictions.

(The Play **app-signing** SHA-1 is already on the key and unchanged, so released/
tester builds keep working regardless of laptop.)

## Step 7 — Release builds

`android/key.properties` + the keystore must be in place, then:

```sh
flutter build appbundle --release
```

## Current project state (as of this handoff)

- **Android app is live in closed testing** (versionCode 4 / 1.0.0+4).
- **versionCode 5 (1.0.0+5) is committed but NOT yet built or tested.** It adds:
  shared-file import + `.routeshare` extension, runtime notification permission,
  orphaned-service cleanup, and the cleaned launcher icon. Run `flutter pub get`
  (new dependency `receive_sharing_intent`) then build + test on-device before
  uploading it as the next update.
- **iOS not started** — see `IOS_CHECKLIST.md`.
- Reference docs in the repo: `README.md`, `PRIVACY_POLICY.md`, `PLAY_LISTING.md`,
  `RELEASE_READINESS.md`, `IOS_CHECKLIST.md`, `CONTRIBUTING.md`.
