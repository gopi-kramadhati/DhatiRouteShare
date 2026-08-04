# RouteShare — decision log

Plain-English record of the key decisions and fixes, and *why* — so the
reasoning is preserved in the project itself (not only in chat). Newest context
at the bottom of each section.

## Identity & platform strategy

- App is **RouteShare**; Android application ID `com.gopikramadhati.routeshare` (permanent).
- Positioned as a **breadcrumb-trail navigator**: record a trail, follow it back
  with the built-in map (no external app needed); Google Maps hand-off is optional.
- **Cross-platform strategy (decided):** Android keeps **hands-free Guided Drive +
  floating card**; iPhone will use **tap-a-notification to advance each leg**.
  Reason: iOS has no draw-over-apps overlay and forbids launching another app (or
  itself) from the background, so true hands-free is impossible on iOS. Full parity
  would mean dropping to tap-to-advance on both; we chose best-per-platform instead.
- Goals order: (1) publish on Play Store, (2) iPhone version, (3) open source after testing.

## Guided Drive (Android)

- Multi-stop Google Maps is unreliable, so each leg is sent as its own **two-point
  `google.navigation:` intent** (auto-starts turn-by-turn, no "Start" tap).
- Arrival at each stop auto-launches the next leg (hands-free). This relies on the
  **SYSTEM_ALERT_WINDOW (overlay) permission** granting the background-activity-start
  exemption — not on the card being visible per se, but we keep the card for UX + Play.
- **"Exit navigation?" popup fix (b64):** the earlier blind retry re-fired the nav
  intent on every leg, and Google Maps asks "Exit navigation?" when it gets a new
  nav intent while already navigating. Now retries fire **only until the driver has
  moved ~30 m from the stop** (`_legNavConfirmed`) — a healthy leg never gets a
  second intent.
- **Late next-leg fix (b64):** guide GPS stream switched to **time-based ~1 Hz**
  (`distanceFilter: 0`) so arrival is detected within ~1 s even when the car is
  stopped mid-road (movement-based updates never fired while stationary).

## Foreground services & the "zombie notification"

- The app runs **two** foreground services: `flutter_foreground_task` and
  geolocator's own (with `foregroundNotificationConfig`). geolocator's is what keeps
  location alive when the screen is off.
- Symptom: after swiping the app away, geolocator's service restarts **sticky** with
  no Dart listener → a "GPS active" notification that lingered until reboot.
- Confirmed via the log "another flutter engine connected, not stopping location
  service" — the `flutter_overlay_window` second engine (and, in debug, hot-restart
  leftovers) keeps geolocator from stopping. Much of what looked broken was a **debug
  artifact**; release behaved far better.
- **Fix (b67):** a **session flag** file is written when a session starts and deleted
  on a clean stop; on next launch, a lingering flag means an unclean shutdown, so the
  app stops the leftover foreground service. Did NOT rip out geolocator's own service
  (that's what makes tested screen-off recording reliable).

## Permissions (Play compliance)

- **Notification permission (b66):** Android 13+ needs POST_NOTIFICATIONS granted at
  runtime or the tracking notification is silently hidden. Now requested before the
  service starts. (Also, the tracking notification is intentionally LOW importance =
  shows under "Silent notifications", which is correct for an always-on service.)
- **Media permissions stripped (b65):** share/file/audio plugins injected
  READ_MEDIA_IMAGES/VIDEO/AUDIO + READ_EXTERNAL_STORAGE, which triggered Play's
  "photo and video permissions" requirement. RouteShare never reads user media
  (import uses the system document picker; chime plays a bundled asset), so these are
  removed via `tools:node="remove"`.
- **Foreground-service declaration:** Location → **Navigation**; the overlay →
  **Special Use → "Other"** with a written justification + a demo video (YouTube,
  Unlisted). Special Use is manually reviewed by Google.
- **Data Safety:** Location collected, not shared, stored on device, deletable;
  no analytics, **no advertising ID** (verified no AD_ID permission in the manifest).
- **AI asset declaration:** disclosed that the icon/graphics are AI-assisted (the
  horse emblem is original artwork; surrounding elements are AI). Honest disclosure
  doesn't hurt approval.

## Sharing / import (b68 — versionCode 5, not yet built/tested)

- Adopted a custom **`.routeshare`** extension for newly created and imported routes;
  legacy `.json` is still read (to be discontinued later). Content is JSON either way,
  so the parser is unchanged.
- Added **tap-to-import**: `receive_sharing_intent` + manifest VIEW/SEND intent filters
  for `application/json` (reliable via WhatsApp) and the `.routeshare` extension.
  Imported files get a **sanity-check + "Import this route?" confirmation** before saving.

## Icons

- App icon must be a **full square with no transparency and no rounded corners** — the
  store/OS applies the rounding. The original had **black corners**; making them
  transparent left a dark, uneven edge, so we **inpainted the corners** with the
  background to produce a clean full-bleed square. Used for both the store icon and the
  Android launcher icons (all densities).

## Keys & signing

- **Maps API key** restricted (Android) to package + SHA-1. Two SHA-1s matter:
  the **debug** SHA-1 (per developer machine) and the **Play app-signing "Classic"
  SHA-1** (from Play Console → App signing) — the latter is required or the map is
  blank for testers/production. Post-quantum key is ignored for Maps.
- **Upload keystore** `~/routeshare-upload.jks` + `android/key.properties` are
  git-ignored; keep them safe (see `PROJECT_HANDOFF.md`).

## Open source

- **MIT license**, public GitHub repo `gopi-kramadhati/DhatiRouteShare`.
- Privacy policy hosted on **GitHub Pages** from `/docs` (repo Settings → Pages,
  branch `main`, folder `/docs`).
- Contributors must supply their **own** Maps key (documented in README).

## Play Store rollout notes

- New personal accounts must run a **closed test (~12 testers, 14 days)** before
  production access unlocks. The 14-day clock depends on opted-in testers, not the
  (delayed, rounded) install stats.
- Testers must be **added by email in Console first**, then accept via the
  `play.google.com/apps/testing/<package>` opt-in link, signed into that same account;
  eligibility uses the **Play account country**, not physical location.

## Build/version history

- b64 / 1.0.0+? — smart retry + stopped-car arrival.
- b65 / 1.0.0+2 — strip unused media permissions.
- b66 / 1.0.0+3 — request notification permission (Android 13+).
- b67 / 1.0.0+4 — clear orphaned tracking service on launch. **(Live in closed testing.)**
- b68 / 1.0.0+5 — shared-file import + `.routeshare` + clean launcher icon.
  **Committed, NOT yet built or tested — this is the next update.**
