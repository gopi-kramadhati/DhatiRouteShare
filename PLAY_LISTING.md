# RouteShare — Play Console launch pack

Everything below is copy-paste ready for the Google Play Console. Values in
**[brackets]** are things only you can supply (URLs, screenshots, etc.).

---

## 1. Store listing

**App name (30 char max)**

```
RouteShare: Breadcrumb Trails
```

**Short description (80 char max)**

```
Leave a breadcrumb trail as you drive, then follow it back — no map app needed.
```

**Full description (4000 char max)**

```
RouteShare is a breadcrumb-trail navigator. As you drive, it quietly records the path you take — a trail of digital breadcrumbs — so you can retrace it later, share it, or let someone else follow the exact same route.

LEAVE A BREADCRUMB TRAIL
Start recording and RouteShare traces your path in the background, even with the screen off. Tap once to drop a numbered stop at any turn, landmark, or place worth remembering. Your start and finish points are added automatically. Great for trails without signs, new delivery routes, field sites, off-grid drives, or anywhere you'd rather not depend on a map service.

FOLLOW IT BACK — NO GOOGLE MAPS REQUIRED
RouteShare has its own built-in map and follow mode. It shows your live position against the recorded trail, tells you when you're on track, and alerts you as you approach each stop — all inside the app. You don't need the Google Maps app, or any other navigation app, to retrace your route.

OPTIONAL: HANDS-FREE GUIDED DRIVE WITH GOOGLE MAPS
If you'd like full turn-by-turn voice navigation, Guided Drive is there as an option. It hands each leg of your route to Google Maps and automatically loads the next leg as you reach each stop, so you get turn-by-turn through every point without touching your phone. A small floating card shows the next stop and lets you resume or end the drive. This is a convenience — not a requirement.

SHARE A ROUTE IN ONE TAP
Send any trail to friends as a file, a KML file, or a Google Maps link. Perfect for group drives, delivery runs, field visits, or sharing a scenic route you loved.

YOUR DATA STAYS YOURS
Routes are stored only on your device. There are no accounts, no sign-in, and nothing is uploaded to any server. You share a route only when you choose to.

FEATURES
• One-tap breadcrumb recording with background/screen-off tracking
• Numbered stops (up to 20) with automatic start and end points
• Built-in follow mode — retrace your trail without any other app
• On-track and approaching-stop alerts
• Optional hands-free Guided Drive via Google Maps
• Save, rename, reload, and delete routes
• Share as file, KML, or Google Maps link

Created by Gopi Kramadhati.
```

**Category:** Maps & Navigation
**Contact email:** gopikramadhati@gmail.com
**Privacy policy URL:** **[host PRIVACY_POLICY.md and paste the public URL]**

**Graphics still needed (you supply):**
- App icon 512×512 PNG
- Feature graphic 1024×500 PNG
- At least 2 phone screenshots (recording screen, guided drive, saved routes)

---

## 2. Data Safety form answers

**Does your app collect or share any of the required user data types?**
→ **Yes** (it uses Location; even on-device use must be declared).

**Location → Approximate location**
- Collected: **Yes**
- Shared: **No**
- Processed ephemerally: **No** (routes are stored on device)
- Required or optional: **Required** for the core feature
- Purpose: **App functionality**

**Location → Precise location**
- Collected: **Yes**
- Shared: **No**
- Processed ephemerally: **No**
- Required or optional: **Required**
- Purpose: **App functionality**

**Is all user data encrypted in transit?**
→ Data is not sent to any server. RouteShare has no backend, so no user data is
transmitted by the app. (Answer the Console's phrasing accordingly — typically
"Yes, data is encrypted in transit" is not applicable because nothing is sent;
if the form forces a choice, note that no data leaves the device.)

**Can users request that data be deleted?**
→ **Yes** — users delete routes in-app or by uninstalling. All data is local.

**No other data types** (no personal info, no financial info, no contacts, no
photos, no analytics, no advertising IDs). Answer "No" to everything else.

---

## 3. Permission / policy declarations

**Location permission declaration (App content → Sensitive permissions)**
RouteShare accesses precise location to record the user's travel path as a
reusable route, to show the user's live position while following a saved route,
and to detect arrival at each stop so it can hand the next leg to Google Maps.
Location is used only while the user is actively recording, following, or
running a guided drive, indicated by a foreground-service notification. Location
data is stored only on the device and is never transmitted off the device.

_(Note: this build does not request background/all-the-time location —
ACCESS_BACKGROUND_LOCATION was intentionally omitted. Foreground-service
location covers screen-off recording. If Play asks about background location,
the answer is that the app does not request it.)_

**Foreground service — location type**
Used to continue recording/following a route reliably while the screen is off or
another app is in the foreground. The user starts this explicitly and sees a
persistent notification.

**Foreground service — special use (the floating overlay)**
Subtype value already declared in the manifest:
"Shows the next guided-drive stop in a floating window over the map."
Justification for Play: during Guided Drive the app displays a small always-on
control card over Google Maps showing the next stop, with resume/end controls,
so the driver can complete a multi-stop route hands-free without switching back
to RouteShare. This requires the SYSTEM_ALERT_WINDOW (display over other apps)
permission and a special-use foreground service.

_Heads up: the special-use foreground service and "display over other apps" are
areas Play reviewers scrutinize. Expect possible follow-up questions; the
justification above is the accurate description to give._

---

## 4. Release track

New personal Play accounts must run a **closed test with ~12 testers for 14
days** before production access is granted. Plan for: internal test → closed
test (recruit ~12 testers, keep them opted in 14 days) → production.
