# Contributing to RouteShare

Thanks for your interest in improving RouteShare! Contributions of all kinds are
welcome — bug reports, fixes, features, docs, and testing on real devices.

## Before you start

RouteShare is a Flutter app. You'll need the Flutter SDK (stable channel) and,
for the map to render, **your own Google Maps API key**. See the
[README](README.md#google-maps-api-key-required) for the full key setup — it's
required and each contributor supplies their own (the project's key is never
committed).

Quick start:

```sh
flutter pub get
# add maps.apiKey=YOUR_OWN_KEY to android/local.properties
flutter run
```

## Ground rules

- **Never commit secrets.** `android/local.properties` (your Maps key),
  `android/key.properties`, and any `*.jks` / `*.keystore` are git-ignored and
  must stay that way. Double-check with
  `git ls-files | grep -Ei "local.properties$|key.properties$|\.jks$|\.keystore$"`
  (should print nothing) before pushing.
- Keep changes focused — one logical change per pull request.
- Match the existing code style; run `flutter analyze` and `flutter test` and
  make sure both pass before opening a PR.

## Workflow

1. Fork the repo and create a branch from `main`:
   `git checkout -b my-feature`.
2. Make your change, with tests where it makes sense (see `test/`).
3. Run `flutter analyze` and `flutter test` locally.
4. Commit with a clear message (e.g. `fix: next leg lagged when car stopped`).
5. Push your branch and open a pull request against `main`, describing what
   changed and how you tested it — ideally on a real Android device, since GPS
   and the Guided Drive hand-off behave differently in the emulator.

## Reporting bugs

Please open an issue using the **Bug report** template and include your device,
Android version, and steps to reproduce. Location- and navigation-related bugs
are much easier to fix with a real-device description.

## Proposing features

Open an issue using the **Feature request** template first, so we can discuss
scope before you invest time in a PR.

## Code of conduct

Be respectful and constructive. We want RouteShare to be a welcoming project.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
