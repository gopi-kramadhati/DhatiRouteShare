import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Bump this on every change so we can tell at a glance (and in the debug log)
/// exactly which build is running on the device.
const String kAppVersion = 'v1.0.1 · b71 (import shared routes; broadened .json matching)';

/// Clean, public-facing version shown on the splash and About screens.
const String kVersionName = '1.0.2'; // keep in sync with pubspec `version:`

/// Release year for the copyright line. Bump this when you publish a build in
/// a new year — it is NOT the year the app happens to be run.
const int kBuildYear = 2026;

// ─────────────────────────────────────────────────────────────────────────────
// Debug logger — writes timestamped entries to a file we can share
// ─────────────────────────────────────────────────────────────────────────────

class AppLogger {
  static File? _file;
  static int _gpsCount = 0;

  static Future<void> init() async {
    if (!kDebugMode) return;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/routeshare_debug.log');
    await log('=== Session start · $kAppVersion ===');
  }

  static Future<void> log(String msg) async {
    if (!kDebugMode) return;
    final line = '[${DateTime.now().toIso8601String()}] $msg\n';
    debugPrint(line.trim());
    try {
      // Synchronous append so lines aren't lost when the app is backgrounded
      // (e.g. right after launching Google Maps).
      _file?.writeAsStringSync(line, mode: FileMode.append);
    } catch (_) {}
  }

  /// Only logs every 10th GPS fix to avoid flooding the file.
  static Future<void> logGps(Position pos, AppMode mode, int pts) async {
    if (!kDebugMode) return;
    _gpsCount++;
    if (_gpsCount % 10 == 0) {
      await log('GPS #$_gpsCount | mode:$mode | pts:$pts | '
          'lat:${pos.latitude.toStringAsFixed(5)} '
          'lng:${pos.longitude.toStringAsFixed(5)} '
          'spd:${pos.speed.toStringAsFixed(1)} '
          'hdg:${pos.heading.toStringAsFixed(1)}');
    }
  }

  static String? get filePath => _file?.path;
}

// ─────────────────────────────────────────────────────────────────────────────
// Kalman GPS filter
// ─────────────────────────────────────────────────────────────────────────────
//
// Each GPS fix carries an `accuracy` value in metres (the 68% confidence
// radius).  The Kalman filter uses this as the measurement noise variance,
// so a fix with a 5 m accuracy circle gets much more weight than one with a
// 40 m circle.  Between fixes the uncertainty grows by `_processNoise`
// metres²/second, keeping the filter responsive to genuine movement while
// still rejecting jitter.

class GpsFilter {
  double _kLat = 0, _kLng = 0;
  double _kVariance = -1; // negative = not yet initialised
  DateTime? _lastTime;

  /// How fast position uncertainty grows between fixes (m²/s).
  /// Increase for faster vehicles; decrease for pedestrians.
  static const double _processNoise = 3.0;

  /// Hard-reject fixes worse than this (e.g. indoors, tunnels).
  static const double _maxAccuracy = 50.0;

  /// Returns a smoothed [LatLng], or null if the fix should be discarded.
  LatLng? process(Position pos) {
    // Discard very poor fixes
    if (pos.accuracy > _maxAccuracy) return null;

    final now = DateTime.now();

    // First valid fix — initialise state
    if (_kVariance < 0) {
      _kLat = pos.latitude;
      _kLng = pos.longitude;
      _kVariance = pos.accuracy * pos.accuracy;
      _lastTime = now;
      return LatLng(_kLat, _kLng);
    }

    // Predict: variance grows with elapsed time
    final dt = now.difference(_lastTime!).inMilliseconds / 1000.0;
    _lastTime = now;
    _kVariance += dt * _processNoise * _processNoise;

    // Update: blend prediction with measurement weighted by accuracy
    final measVariance = pos.accuracy * pos.accuracy;
    final gain = _kVariance / (_kVariance + measVariance); // Kalman gain
    _kLat += gain * (pos.latitude  - _kLat);
    _kLng += gain * (pos.longitude - _kLng);
    _kVariance *= (1.0 - gain);

    return LatLng(_kLat, _kLng);
  }

  void reset() {
    _kVariance = -1;
    _lastTime = null;
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const RouteShareApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Floating overlay (runs in its OWN Flutter engine over Google Maps)
// ─────────────────────────────────────────────────────────────────────────────

/// Separate entry point launched by flutter_overlay_window. Communicates with
/// the main app only via FlutterOverlayWindow.shareData / overlayListener.
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const _GuideOverlayApp());
}

class _GuideOverlayApp extends StatefulWidget {
  const _GuideOverlayApp();

  @override
  State<_GuideOverlayApp> createState() => _GuideOverlayAppState();
}

class _GuideOverlayAppState extends State<_GuideOverlayApp> {
  String _text = 'Guided drive';

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((event) {
      try {
        final m = jsonDecode(event.toString()) as Map<String, dynamic>;
        setState(() {
          _text = (m['text'] as String?) ?? _text;
        });
      } catch (_) {
        // Non-JSON messages (e.g. our own outgoing 'end') are ignored.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        color: Colors.transparent,
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: kBrandNavy.withValues(alpha: 0.82), // semi-transparent
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBrandCyan, width: 1.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.assistant_direction,
                    color: kBrandCyan, size: 22),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    _text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                // Reopen the CURRENT leg in Maps (e.g. if Maps was closed).
                ElevatedButton.icon(
                  onPressed: () => FlutterOverlayWindow.shareData('resume'),
                  icon: const Icon(Icons.navigation, size: 16),
                  label: const Text('Resume'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4285F4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton(
                  onPressed: () {
                    // Close the overlay directly (reliable) and reset state.
                    FlutterOverlayWindow.closeOverlay();
                    FlutterOverlayWindow.shareData('end');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('End'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────────────────────

// Brand colors used across the app.
const Color kBrandNavy = Color(0xFF1C2280);
const Color kBrandCyan = Color(0xFF00AEEF);

class RouteShareApp extends StatelessWidget {
  const RouteShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RouteShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: kBrandCyan,
          primary: kBrandNavy,
          secondary: kBrandCyan,
        ),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Splash / opening screen
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..forward();
    Timer(const Duration(milliseconds: 2400), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [kBrandNavy, Color(0xFF0E1240)],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _c,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.85, end: 1.0).animate(
                CurvedAnimation(parent: _c, curve: Curves.easeOutBack),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                      border: Border.all(color: kBrandCyan, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: 60,
                      height: 60,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.navigation,
                        color: kBrandCyan,
                        size: 52,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'RouteShare',
                    style: TextStyle(
                      color: kBrandCyan,
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Record · Follow · Navigate',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 13,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 34),
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(kBrandCyan),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Version $kVersionName',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '© $kBuildYear Gopi Kramadhati',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// About screen
// ─────────────────────────────────────────────────────────────────────────────

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget feature(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: kBrandNavy, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(body,
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey[700])),
                  ],
                ),
              ),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBrandNavy,
        foregroundColor: Colors.white,
        title: const Text('About'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          Center(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/images/app_logo.png',
                    width: 84,
                    height: 84,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                        Icons.navigation, color: kBrandNavy, size: 46),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('RouteShare',
                    style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(kAppVersion,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Record GPS routes, mark critical waypoints, then share the route '
            'with others in multiple ways so they can follow the same route.',
            style: TextStyle(fontSize: 14, color: Colors.grey[800]),
          ),
          const Divider(height: 32),
          feature(Icons.fiber_manual_record, 'Record routes',
              'High-accuracy GPS with a Kalman filter and background tracking.'),
          feature(Icons.add_location_alt, 'Critical waypoints',
              'One-tap stops with auto Start/End, saved with each route.'),
          feature(Icons.navigation, 'Follow mode',
              'Guides you through every waypoint with chime + voice alerts and an off-route banner.'),
          feature(Icons.alt_route, 'Google Maps hand-off',
              'Open the route point-to-point through Google Maps, or share a link.'),
          feature(Icons.download_outlined, 'KML export',
              'Share the full route and waypoints, or open in Google Earth / My Maps.'),
          const Divider(height: 32),
          Row(
            children: [
              Icon(Icons.person_outline, size: 18, color: Colors.grey[700]),
              const SizedBox(width: 8),
              Text('Created by Gopi Kramadhati',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[800])),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Maps © Google. Location by device GPS.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode
// ─────────────────────────────────────────────────────────────────────────────

enum AppMode { idle, recording, paused, following }

// ─────────────────────────────────────────────────────────────────────────────
// Waypoint — a user-marked critical point with an optional spoken label.
// Marked by tapping "Add Waypoint" during recording and speaking (or typing)
// a description. These are preserved verbatim for Google Maps / KML export,
// unlike the automatically-simplified track points.
// ─────────────────────────────────────────────────────────────────────────────

class RouteWaypoint {
  final LatLng position;
  final String label;

  const RouteWaypoint(this.position, this.label);

  Map<String, dynamic> toJson() => {
        'lat': position.latitude,
        'lng': position.longitude,
        'label': label,
      };

  factory RouteWaypoint.fromJson(Map<String, dynamic> j) => RouteWaypoint(
        LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        (j['label'] as String?) ?? '',
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Home
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // ── State ──────────────────────────────────────────────────────────────────

  AppMode _mode = AppMode.idle;

  double? latitude;
  double? longitude;
  Position? currentPosition;

  List<LatLng> routePoints = [];         // Kalman-smoothed points
  List<LatLng> loadedRoutePoints = [];
  List<String> savedRouteFiles = [];
  // Last-modified time per saved route file, for display + sorting.
  final Map<String, DateTime> _routeModified = {};
  // User-given display name per saved route file (from the 'name' JSON field).
  final Map<String, String> _routeNames = {};
  final GpsFilter _gpsFilter = GpsFilter();

  // User-marked critical waypoints for the active route (being recorded, or
  // loaded from a file). Exported verbatim as Google Maps navigation stops.
  List<RouteWaypoint> waypoints = [];

  /// Max critical waypoints (including Start and End). User-configurable in
  /// Settings; 0 means no limit. Persisted to routeshare_settings.json.
  int _maxWaypoints = 20;
  bool get _waypointsCapped => _maxWaypoints > 0;

  // Text-to-speech + chime to alert when a critical waypoint is approaching.
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _chimePlayer = AudioPlayer();
  bool _voiceAlertsEnabled = true;
  static const double _waypointAlertDistance = 200.0; // metres
  // Indices of waypoints already announced this following session.
  final Set<int> _alertedWaypoints = {};

  String? _loadedRouteName;
  double? _distanceFromRoute;

  // ── In-app navigation guidance (derived from the recorded route geometry) ──
  // Cumulative along-route distance for each loaded route point.
  List<double> _routeCumDist = [];
  // Nearest route index for each waypoint (precomputed on load).
  List<int> _wpRouteIndex = [];
  String? _navInstruction;      // e.g. "Turn right in 180 m" / "Continue"
  String _navTurnDir = 'straight'; // 'left' | 'right' | 'straight'
  double? _distRemaining;       // metres to the end of the route
  int? _etaMinutes;             // rough ETA from current speed
  String? _nextWpLabel;         // next waypoint ahead
  double? _distToNextWp;        // along-route metres to it
  bool _turnAnnounced = false;  // debounce turn voice

  // ── Guided drive (auto-detect arrival, tap to advance to next leg) ──────────
  bool _guiding = false;
  List<LatLng> _legStops = [];   // ordered stops (Start … End)
  List<String> _legLabels = [];  // matching labels
  int _legIndex = 0;             // leg currently navigated: stops[i] → stops[i+1]
  bool _pendingNextLeg = false;  // arrived; waiting for user to continue
  bool _continueDialogOpen = false;
  StreamSubscription<Position>? _guideStream;
  static const double _arrivalThreshold = 40.0; // metres
  // Cooldown after launching a leg, so close/jittery stops don't fire a burst
  // of navigation intents (which Android can process out of order).
  DateTime? _lastLegLaunchAt;
  static const Duration _legCooldown = Duration(seconds: 12);
  // Nav-launch confirmation: once the driver has clearly moved away from the
  // stop they just left, Google Maps has accepted the new leg, so the pending
  // retry intents are cancelled. (Re-sending a navigation intent while Maps is
  // already navigating is what makes Maps pop its own "Exit navigation?" prompt.)
  LatLng? _legOrigin;            // the stop we launched away from
  bool _legNavConfirmed = false; // moved far enough => nav definitely took hold
  static const double _navConfirmDist = 30.0; // metres of travel = confirmed
  // Floating overlay (Stage 2)
  StreamSubscription? _overlaySub;
  bool _overlayActive = false;

  // Incoming shared route files (opened from WhatsApp, Drive, a file manager…)
  StreamSubscription<List<SharedMediaFile>>? _intentSub;
  bool _handlingSharedFile = false; // guard against double-handling

  // Auto-zoom while following
  bool _userInteracting = false;
  Timer? _resumeTimer;

  StreamSubscription<Position>? positionStream;

  // Google Maps controller + tracked camera state (Google Maps has no
  // synchronous camera getter, so we cache zoom/bearing from onCameraMove).
  GoogleMapController? _mapController;
  double _currentZoom = 15;
  double _currentBearing = 0;
  // True while an animateCamera we triggered is in flight, so we don't mistake
  // it for a user gesture in onCameraMoveStarted.
  bool _programmaticMove = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initForegroundTask();
    _initTts();
    _loadSettings();
    // Clear any foreground service orphaned by an unclean shutdown of a prior
    // session (zombie "GPS active" notification that otherwise stays till reboot).
    _recoverStaleServices();
    // Subscribe to the overlay message stream ONCE — it's a single-subscription
    // stream, so listening again per guided drive throws "already listened".
    try {
      _overlaySub = FlutterOverlayWindow.overlayListener.listen((event) {
        AppLogger.log('Overlay event from widget: $event');
        if (event == 'next') {
          _continueToNextLeg();
        } else if (event == 'resume') {
          _launchCurrentLeg(); // reopen the current leg (no advance)
        } else if (event == 'end') {
          stopGuidedDrive();
        }
      });
    } catch (e) {
      AppLogger.log('overlayListener subscribe failed: $e');
    }
    AppLogger.init().then((_) => _checkAutoSave());
    _initSharedFileIntake();
  }

  /// Listens for route files opened from other apps (WhatsApp, Drive, a file
  /// manager, the system share sheet). Handles both the file that launched the
  /// app and files received while it is already running.
  void _initSharedFileIntake() {
    // File the app was launched with (cold start via "Open with RouteShare").
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty) {
        _handleSharedFiles(files);
        // Tell the plugin we've consumed it so it isn't re-delivered on resume.
        ReceiveSharingIntent.instance.reset();
      }
    });
    // Files received while the app is already open.
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleSharedFiles,
      onError: (e) => AppLogger.log('Shared-intent stream error: $e'),
    );
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (_handlingSharedFile) return;
    if (files.isEmpty) return;
    final path = files.first.path;
    _handlingSharedFile = true;
    try {
      await _importRouteFromFile(File(path), confirmFirst: true);
    } finally {
      _handlingSharedFile = false;
    }
  }

  Future<void> _loadSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/routeshare_settings.json');
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString());
      if (m is Map && m['maxWaypoints'] is int) {
        setState(() => _maxWaypoints = m['maxWaypoints'] as int);
      }
    } catch (e) {
      AppLogger.log('Settings load failed: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/routeshare_settings.json');
      await f.writeAsString(jsonEncode({'maxWaypoints': _maxWaypoints}));
    } catch (e) {
      AppLogger.log('Settings save failed: $e');
    }
  }

  void _showSettingsDialog() {
    final controller = TextEditingController(
        text: _maxWaypoints > 0 ? '$_maxWaypoints' : '');
    bool unlimited = _maxWaypoints <= 0;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                enabled: !unlimited,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Max critical waypoints',
                  border: OutlineInputBorder(),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('No limit'),
                value: unlimited,
                onChanged: (v) => setLocal(() => unlimited = v ?? false),
              ),
              Text(
                'Includes the auto Start and End points (minimum 2). '
                'Each stop is navigated as its own leg, so there is no Google '
                'Maps limit.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                int newVal;
                if (unlimited) {
                  newVal = 0;
                } else {
                  final parsed = int.tryParse(controller.text.trim());
                  newVal = (parsed == null || parsed < 2) ? 2 : parsed;
                }
                setState(() => _maxWaypoints = newVal);
                _saveSettings();
                Navigator.pop(ctx);
                _showSnack(newVal == 0
                    ? 'Waypoint limit: none'
                    : 'Waypoint limit: $newVal');
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _initTts() async {
    try {
      await _tts.setSpeechRate(0.5); // clearer at driving speeds
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
    } catch (e) {
      AppLogger.log('TTS init failed: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    positionStream?.cancel();
    _guideStream?.cancel();
    _overlaySub?.cancel();
    _intentSub?.cancel();
    FlutterOverlayWindow.closeOverlay();
    _resumeTimer?.cancel();
    _tts.stop();
    _chimePlayer.dispose();
    _mapController?.dispose();
    WakelockPlus.disable();
    FlutterForegroundTask.stopService();
    super.dispose();
  }

  /// Logs every app lifecycle transition — lets us see if the app is being
  /// backgrounded or killed when recording stops unexpectedly.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppLogger.log(
      'Lifecycle: $state | mode: $_mode | '
      'recPts: ${routePoints.length} | stream: ${positionStream != null}',
    );
    // Coming back to the app during a guided drive with a pending leg — prompt
    // the user to continue to the next leg.
    if (state == AppLifecycleState.resumed &&
        _guiding &&
        _pendingNextLeg &&
        !_overlayActive &&
        !_continueDialogOpen) {
      _showContinueDialog();
    }
  }

  // ── Foreground service ────────────────────────────────────────────────────

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'route_guide_tracking',
        channelName: 'RouteShare Tracking',
        channelDescription:
            'Keeps GPS active while screen is off.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Android 13+ requires the POST_NOTIFICATIONS permission to be granted at
  /// runtime, otherwise the foreground-service notification is silently hidden
  /// (the service still runs, but the user sees nothing). Ask for it before we
  /// start the service so the tracking notification is actually visible.
  Future<void> _ensureNotificationPermission() async {
    try {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      if (status != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      AppLogger.log('Notification permission request failed: $e');
    }
  }

  Future<void> _startForegroundService(String message) async {
    await _ensureNotificationPermission();
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'RouteShare',
      notificationText: message,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('Foreground service failed: ${result.error}');
    }
  }

  Future<void> _updateForegroundNotification(String message) async {
    await FlutterForegroundTask.updateService(
      notificationTitle: 'RouteShare',
      notificationText: message,
    );
  }

  Future<void> _stopForegroundService() async {
    await FlutterForegroundTask.stopService();
  }

  // ── Stale-session recovery ─────────────────────────────────────────────────
  // If the app process is torn down mid-session (e.g. swiped away, or killed by
  // the OS) without a clean Stop, geolocator can leave its location foreground
  // service running "sticky" with no Dart listener — a zombie notification that
  // stays until reboot. We write a flag while a session is active and clear it
  // on a clean stop; on next launch a lingering flag means the previous session
  // ended uncleanly, so we stop any leftover foreground service.
  Future<File> _sessionFlagFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/session_active.flag');
  }

  Future<void> _setSessionActive(bool active) async {
    try {
      final f = await _sessionFlagFile();
      if (active) {
        await f.writeAsString(DateTime.now().toIso8601String());
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (e) {
      AppLogger.log('Session flag write failed: $e');
    }
  }

  Future<void> _recoverStaleServices() async {
    bool unclean = false;
    try {
      unclean = await (await _sessionFlagFile()).exists();
    } catch (_) {}
    if (!unclean) return;
    AppLogger.log('Stale session flag found — clearing leftover services');
    // FlutterForegroundTask: a static stop clears its notification if it lingered.
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
    // Geolocator: re-bind to its single foreground service with a foreground
    // config (so Android treats it as the same service) and immediately cancel,
    // which stops the service and removes the zombie notification.
    if (Platform.isAndroid) {
      try {
        final sub = Geolocator.getPositionStream(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.lowest,
            distanceFilter: 0,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'RouteShare',
              notificationText: 'Finishing up…',
            ),
          ),
        ).listen((_) {});
        await Future.delayed(const Duration(milliseconds: 400));
        await sub.cancel();
      } catch (e) {
        AppLogger.log('Geolocator stale-service cleanup skipped: $e');
      }
    }
    await _setSessionActive(false);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<LatLng> get _recordedLatLngs => routePoints;

  /// Minimum distance in metres from [pos] to any point on the loaded route.
  /// Uses a ~300 m bounding box as a fast path; if nothing is nearby it falls
  /// back to a full scan so the REAL distance is reported (not a placeholder).
  double _calcDistanceToRoute(Position pos) {
    if (loadedRoutePoints.isEmpty) return double.infinity;

    const double latDelta = 0.0027; // ~300 m
    final double lngDelta =
        latDelta / cos(pos.latitude * pi / 180).clamp(0.01, 1.0);

    final nearby = loadedRoutePoints.where((pt) =>
        pt.latitude >= pos.latitude - latDelta &&
        pt.latitude <= pos.latitude + latDelta &&
        pt.longitude >= pos.longitude - lngDelta &&
        pt.longitude <= pos.longitude + lngDelta);

    // If none within the box, scan the whole route to get the true distance.
    final Iterable<LatLng> search =
        nearby.isNotEmpty ? nearby : loadedRoutePoints;

    double minDist = double.infinity;
    for (final pt in search) {
      final d = Geolocator.distanceBetween(
        pos.latitude, pos.longitude, pt.latitude, pt.longitude,
      );
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  /// Only flag a deviation once the user is clearly off the route (metres).
  /// Below this the live navigation guidance is enough.
  static const double _deviationThreshold = 50.0;

  /// Returns the nearest point on the loaded route to the current position,
  /// using the same bounding-box optimisation as [_calcDistanceToRoute].
  LatLng? _nearestRoutePoint() {
    if (currentPosition == null || loadedRoutePoints.isEmpty) return null;

    const double latDelta = 0.0027;
    final double lngDelta =
        latDelta / cos(currentPosition!.latitude * pi / 180).clamp(0.01, 1.0);

    final candidates = loadedRoutePoints.where((pt) =>
        pt.latitude >= currentPosition!.latitude - latDelta &&
        pt.latitude <= currentPosition!.latitude + latDelta &&
        pt.longitude >= currentPosition!.longitude - lngDelta &&
        pt.longitude <= currentPosition!.longitude + lngDelta);

    final search =
        candidates.isNotEmpty ? candidates.toList() : loadedRoutePoints;

    double minDist = double.infinity;
    LatLng? nearest;
    for (final pt in search) {
      final d = Geolocator.distanceBetween(
        currentPosition!.latitude, currentPosition!.longitude,
        pt.latitude, pt.longitude,
      );
      if (d < minDist) {
        minDist = d;
        nearest = pt;
      }
    }
    return nearest;
  }

  /// Called when the user touches the map while following.
  /// Suspends auto-zoom for 5 seconds then resumes.
  void _onUserMapInteraction() {
    if (!_userInteracting) setState(() => _userInteracting = true);
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _userInteracting = false);
    });
  }

  /// Animates the Google Maps camera to [target], keeping the tracked zoom and
  /// bearing unless overridden. Flags the move as programmatic so it isn't
  /// treated as a user gesture.
  Future<void> _moveCamera(LatLng target,
      {double? zoom, double? bearing}) async {
    final c = _mapController;
    if (c == null) return;
    _programmaticMove = true;
    await c.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: target,
          zoom: zoom ?? _currentZoom,
          bearing: bearing ?? _currentBearing,
        ),
      ),
    );
  }

  /// Bounding box enclosing [pts] with a little padding.
  LatLngBounds _boundsFor(List<LatLng> pts) {
    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLng = max(maxLng, p.longitude);
    }
    const pad = 0.0008; // ~90 m
    return LatLngBounds(
      southwest: LatLng(minLat - pad, minLng - pad),
      northeast: LatLng(maxLat + pad, maxLng + pad),
    );
  }

  /// Camera behaviour while following:
  ///  • On or near the route — keep the user centred at a navigation zoom,
  ///    rotated to [bearing], so the route ahead stays visible.
  ///  • Well off the route — zoom out to show both the user and the nearest
  ///    route point so they can navigate back.
  void _updateFollowCamera(double bearing) {
    if (currentPosition == null || loadedRoutePoints.isEmpty) return;
    final dist = _distanceFromRoute ?? 0;
    if (dist > 100) {
      _fitCameraToTargets();
    } else {
      _moveCamera(
        LatLng(currentPosition!.latitude, currentPosition!.longitude),
        zoom: _currentZoom < 14 ? 17 : _currentZoom,
        bearing: bearing,
      );
    }
  }

  /// Fits the camera so both the current position and the nearest route point
  /// are visible.
  void _fitCameraToTargets() {
    final c = _mapController;
    if (c == null || currentPosition == null || loadedRoutePoints.isEmpty) {
      return;
    }
    final target = _nearestRoutePoint();
    if (target == null) return;
    final current =
        LatLng(currentPosition!.latitude, currentPosition!.longitude);
    _programmaticMove = true;
    c.animateCamera(
      CameraUpdate.newLatLngBounds(_boundsFor([current, target]), 80),
    );
  }

  // ── In-app navigation guidance ──────────────────────────────────────────────

  /// Precomputes along-route cumulative distances and each waypoint's nearest
  /// route index. Call whenever loadedRoutePoints changes.
  void _prepareNav() {
    _routeCumDist = [];
    _wpRouteIndex = [];
    if (loadedRoutePoints.isEmpty) return;

    double acc = 0;
    _routeCumDist.add(0);
    for (int i = 1; i < loadedRoutePoints.length; i++) {
      acc += Geolocator.distanceBetween(
        loadedRoutePoints[i - 1].latitude, loadedRoutePoints[i - 1].longitude,
        loadedRoutePoints[i].latitude, loadedRoutePoints[i].longitude,
      );
      _routeCumDist.add(acc);
    }
    for (final w in waypoints) {
      _wpRouteIndex.add(_nearestLoadedIndex(w.position));
    }
  }

  /// Index of the loaded-route point nearest to [p] (linear scan).
  int _nearestLoadedIndex(LatLng p) {
    double best = double.infinity;
    int idx = 0;
    for (int i = 0; i < loadedRoutePoints.length; i++) {
      final d = Geolocator.distanceBetween(p.latitude, p.longitude,
          loadedRoutePoints[i].latitude, loadedRoutePoints[i].longitude);
      if (d < best) {
        best = d;
        idx = i;
      }
    }
    return idx;
  }

  /// Compass bearing (degrees, 0–360) from [a] to [b].
  double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180, lat2 = b.latitude * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  /// Interpolated point at along-route distance [d] metres.
  LatLng _pointAtDistance(double d) {
    if (d <= 0) return loadedRoutePoints.first;
    if (d >= _routeCumDist.last) return loadedRoutePoints.last;
    int lo = 0, hi = _routeCumDist.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_routeCumDist[mid] < d) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final i = lo == 0 ? 1 : lo;
    final segStart = _routeCumDist[i - 1], segEnd = _routeCumDist[i];
    final t = (segEnd - segStart) <= 0 ? 0.0 : (d - segStart) / (segEnd - segStart);
    final a = loadedRoutePoints[i - 1], b = loadedRoutePoints[i];
    return LatLng(a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t);
  }

  /// Finds the next significant turn ahead of along-route distance [d0].
  /// Returns the direction ('left'/'right') and distance to it, or null.
  ({String dir, double dist})? _nextTurn(double d0) {
    if (_routeCumDist.length < 2) return null;
    final total = _routeCumDist.last;
    const step = 10.0, win = 25.0;
    for (double d = d0 + step; d < min(d0 + 500, total - win); d += step) {
      final b1 = _bearing(_pointAtDistance(d - win), _pointAtDistance(d));
      final b2 = _bearing(_pointAtDistance(d), _pointAtDistance(d + win));
      final diff = ((b2 - b1 + 540) % 360) - 180; // normalise to [-180,180]
      if (diff.abs() > 30) {
        return (dir: diff > 0 ? 'right' : 'left', dist: d - d0);
      }
    }
    return null;
  }

  String _fmtDist(double m) =>
      m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  /// Recomputes the live guidance fields (instruction, distances, ETA, next
  /// waypoint) from the recorded route. Assigns fields only — call inside an
  /// existing setState. Also fires a one-shot turn voice cue.
  void _updateNavFields(Position pos) {
    if (loadedRoutePoints.isEmpty || _routeCumDist.length < 2) return;

    final idx = _nearestRouteIndex(pos);
    final along = _routeCumDist[idx];
    final remaining =
        (_routeCumDist.last - along).clamp(0.0, double.infinity).toDouble();

    _distRemaining = remaining;
    _etaMinutes = pos.speed > 1.0 ? (remaining / pos.speed / 60).round() : null;

    // Next waypoint ahead along the route.
    _nextWpLabel = null;
    _distToNextWp = null;
    for (int i = 0; i < _wpRouteIndex.length; i++) {
      if (_wpRouteIndex[i] > idx) {
        _nextWpLabel = i == 0
            ? 'Start'
            : i == waypoints.length - 1
                ? 'Destination'
                : 'Waypoint ${i + 1}';
        _distToNextWp = (_routeCumDist[_wpRouteIndex[i]] - along)
            .clamp(0.0, double.infinity)
            .toDouble();
        break;
      }
    }

    // Next turn from the route geometry.
    final turn = _nextTurn(along);
    if (turn != null) {
      _navTurnDir = turn.dir;
      _navInstruction = 'Turn ${turn.dir} in ${_fmtDist(turn.dist)}';
      // Speak once when we get close.
      if (_voiceAlertsEnabled && turn.dist < 150 && !_turnAnnounced) {
        _turnAnnounced = true;
        _tts.stop();
        _tts.speak('Turn ${turn.dir} ahead');
      }
    } else {
      _navTurnDir = 'straight';
      _navInstruction = remaining < 30 ? 'Arriving at destination' : 'Continue';
      _turnAnnounced = false;
    }
  }

  /// Index of the loaded-route point nearest to [pos], using a bounding-box
  /// pre-filter for speed on long routes.
  int _nearestRouteIndex(Position pos) {
    const double latDelta = 0.0027;
    final double lngDelta =
        latDelta / cos(pos.latitude * pi / 180).clamp(0.01, 1.0);
    double best = double.infinity;
    int idx = 0;
    for (int i = 0; i < loadedRoutePoints.length; i++) {
      final pt = loadedRoutePoints[i];
      if (pt.latitude < pos.latitude - latDelta ||
          pt.latitude > pos.latitude + latDelta ||
          pt.longitude < pos.longitude - lngDelta ||
          pt.longitude > pos.longitude + lngDelta) {
        continue;
      }
      final d = Geolocator.distanceBetween(
          pos.latitude, pos.longitude, pt.latitude, pt.longitude);
      if (d < best) {
        best = d;
        idx = i;
      }
    }
    return idx;
  }

  void _clearNav() {
    _navInstruction = null;
    _navTurnDir = 'straight';
    _distRemaining = null;
    _etaMinutes = null;
    _nextWpLabel = null;
    _distToNextWp = null;
    _turnAnnounced = false;
  }

  // ── Waypoint proximity alerts ───────────────────────────────────────────────

  /// While following, alerts once for each critical waypoint as it comes within
  /// [_waypointAlertDistance]. Plays a chime, then announces the waypoint number.
  /// Distance-based, so it works regardless of travel direction.
  void _checkWaypointProximity(Position pos) {
    if (!_voiceAlertsEnabled || waypoints.isEmpty) return;
    for (int i = 0; i < waypoints.length; i++) {
      if (_alertedWaypoints.contains(i)) continue;
      final w = waypoints[i];
      final d = Geolocator.distanceBetween(
        pos.latitude, pos.longitude,
        w.position.latitude, w.position.longitude,
      );
      if (d <= _waypointAlertDistance) {
        _alertedWaypoints.add(i);
        _announceWaypoint(i, d);
        break; // one announcement at a time
      }
    }
  }

  Future<void> _announceWaypoint(int index, double metres) async {
    final number = index + 1;
    AppLogger.log(
        'Waypoint alert (${metres.toStringAsFixed(0)} m): critical waypoint $number');
    try {
      await _chimePlayer.stop();
      await _chimePlayer.play(AssetSource('sounds/waypoint_chime.wav'));
    } catch (e) {
      AppLogger.log('Chime failed: $e');
    }
    // Let the chime finish before speaking.
    await Future.delayed(const Duration(milliseconds: 700));
    try {
      await _tts.stop();
      await _tts.speak('Critical waypoint $number approaching');
    } catch (e) {
      AppLogger.log('TTS failed: $e');
    }
  }

  // ── Location permission ────────────────────────────────────────────────────

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!mounted) return false;
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Turn on location'),
          content: const Text(
            'RouteShare needs device location to record and follow routes. '
            'Turn on Location Services, then try again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (openSettings == true) await Geolocator.openLocationSettings();
      return false;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      if (!mounted) return false;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Location required'),
          content: const Text(
            'RouteShare uses your precise location only while you explicitly '
            'record or follow a route. Route data is saved on this device '
            'unless you choose to share it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (proceed != true) return false;
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.deniedForever) {
      if (!mounted) return false;
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow location in settings'),
          content: const Text(
            'Location permission is permanently denied. Open app settings '
            'and allow location to use route recording and guidance.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (openSettings == true) await Geolocator.openAppSettings();
      return false;
    }

    return perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
  }

  // ── GPS stream ────────────────────────────────────────────────────────────

  void _startLocationTracking() {
    // On Android, use AndroidSettings with a ForegroundNotificationConfig so
    // geolocator itself holds a foreground service — this is what actually
    // keeps the location stream alive when the screen turns off.
    // intervalDuration intentionally omitted — let the OS deliver fixes as
    // fast as the hardware allows. Setting a minimum interval was causing
    // 5-10 km gaps at highway speed.
    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 2,
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'RouteShare',
              notificationText: 'GPS active — screen can be turned off safely.',
              enableWakeLock: true,
              enableWifiLock: false,
            ),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 2,
          );

    positionStream =
        Geolocator.getPositionStream(locationSettings: settings).listen(
      (Position pos) {
        AppLogger.logGps(pos, _mode, routePoints.length);
        setState(() {
          latitude = pos.latitude;
          longitude = pos.longitude;
          currentPosition = pos;

          if (_mode == AppMode.recording) {
            final smoothed = _gpsFilter.process(pos);
            if (smoothed != null) {
              routePoints.add(smoothed);
              // Auto-save to disk every 20 pts so an OS kill loses at most ~60 s
              if (routePoints.length % 20 == 0) {
                _autoSaveRoute();
              }
            }
          }

          if (_mode == AppMode.following && loadedRoutePoints.isNotEmpty) {
            _distanceFromRoute = _calcDistanceToRoute(pos);
            _updateNavFields(pos);
          }
        });

        // Google Maps bearing: 0 = north-up, increasing clockwise — same
        // convention as pos.heading (0–360° clockwise from north). Only rotate
        // while actually moving, else keep the last bearing to avoid jitter.
        final moving = pos.speed > 0.5 && pos.heading >= 0;
        final bearing = moving ? pos.heading : _currentBearing;

        if (_mode == AppMode.following) {
          _checkWaypointProximity(pos);
          if (!_userInteracting) {
            _updateFollowCamera(bearing);
          }
        } else if (_mode == AppMode.recording || _mode == AppMode.paused) {
          // Recording: keep map centred on the vehicle, rotated to heading.
          _moveCamera(LatLng(pos.latitude, pos.longitude), bearing: bearing);
        }
      },
      onError: (error) {
        AppLogger.log('GPS stream ERROR: $error — restarting in 3 s');
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _mode != AppMode.idle) {
            AppLogger.log('GPS stream restarting now');
            _stopLocationTracking();
            _startLocationTracking();
          }
        });
      },
    );
  }

  void _stopLocationTracking() {
    positionStream?.cancel();
    positionStream = null;
  }

  // ── Record ─────────────────────────────────────────────────────────────────

  Future<void> startRecording() async {
    routePoints.clear();
    waypoints.clear();
    _gpsFilter.reset();
    loadedRoutePoints.clear();
    _loadedRouteName = null;
    _distanceFromRoute = null;

    if (!await _ensurePermission()) return;
    final pos = await Geolocator.getCurrentPosition(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.high),
    );

    setState(() {
      latitude = pos.latitude;
      longitude = pos.longitude;
      currentPosition = pos;
      _mode = AppMode.recording;
      // The starting point is automatically the first waypoint (Start).
      waypoints.add(RouteWaypoint(LatLng(pos.latitude, pos.longitude), 'Start'));
    });

    _moveCamera(LatLng(pos.latitude, pos.longitude), zoom: 17);
    _startLocationTracking();
    await _setSessionActive(true);
    await _startForegroundService('Recording route — ${routePoints.length} pts');
    // Keep the screen on while recording (auto-timeout only — a manual power
    // press still turns it off).
    await WakelockPlus.enable();
    AppLogger.log('Recording STARTED — Start waypoint marked, screen wake lock on');
  }

  void pauseRecording() {
    AppLogger.log('Recording PAUSED at ${routePoints.length} pts');
    setState(() => _mode = AppMode.paused);
    _updateForegroundNotification('Recording paused — ${routePoints.length} pts');
  }

  void resumeRecording() {
    AppLogger.log('Recording RESUME requested — stream alive: ${positionStream != null}');
    // Always restart the GPS stream — it may have been killed by the OS
    // while the screen was off (common on OnePlus / aggressive OEMs).
    _stopLocationTracking();
    setState(() => _mode = AppMode.recording);
    _startLocationTracking();
    AppLogger.log('Recording RESUMED — ${routePoints.length} pts preserved');
    _updateForegroundNotification(
        'Recording resumed — ${routePoints.length} pts saved so far');
  }

  Future<void> stopRecording({String? name}) async {
    AppLogger.log('Recording STOPPED — ${routePoints.length} pts — saving');
    _stopLocationTracking();

    // The final point is automatically the last waypoint (End).
    final pos = currentPosition;
    if (pos != null && (!_waypointsCapped || waypoints.length < _maxWaypoints)) {
      waypoints.add(RouteWaypoint(LatLng(pos.latitude, pos.longitude), 'End'));
    }

    await _saveRoute(name: name);
    await listSavedRoutes();
    await _stopForegroundService();
    await _setSessionActive(false);
    await WakelockPlus.disable(); // release screen wake lock
    AppLogger.log('Route saved OK with ${waypoints.length} waypoints');

    // Clear the on-map route so the display resets for the next recording.
    setState(() {
      _mode = AppMode.idle;
      routePoints.clear();
      waypoints.clear();
      loadedRoutePoints.clear();
      _loadedRouteName = null;
      _gpsFilter.reset();
    });
  }

  /// Stops recording WITHOUT saving — the recorded track and waypoints are
  /// thrown away and the auto-save file is removed.
  Future<void> discardRecording() async {
    AppLogger.log('Recording DISCARDED — ${routePoints.length} pts thrown away');
    _stopLocationTracking();
    await _stopForegroundService();
    await _setSessionActive(false);
    await WakelockPlus.disable(); // release screen wake lock
    try {
      final dir = await getApplicationDocumentsDirectory();
      final autoSave = File('${dir.path}/route_autosave.json');
      if (await autoSave.exists()) await autoSave.delete();
    } catch (_) {}
    setState(() {
      _mode = AppMode.idle;
      routePoints.clear();
      waypoints.clear();
      loadedRoutePoints.clear();
      _loadedRouteName = null;
      _gpsFilter.reset();
    });
    _showSnack('Recording discarded');
  }

  /// Shows a confirmation dialog before stopping, preventing accidental taps.
  void confirmStopRecording() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop Recording?'),
        content: Text(
            '${routePoints.length} points recorded.\n\n'
            'Save this route, discard it, or keep recording?'),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Continue Recording'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              discardRecording();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Discard'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _promptNameAndSave();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save Route'),
          ),
        ],
      ),
    );
  }

  /// Prompts for a meaningful route name, then saves & stops. Cancelling keeps
  /// recording (nothing is saved).
  Future<void> _promptNameAndSave() async {
    final controller = TextEditingController(
        text: 'Route ${_formatStamp(DateTime.now())}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this route'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Route name',
            hintText: 'e.g. Home to Office',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), // cancel → keep recording
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final t = controller.text.trim();
              Navigator.pop(
                  ctx, t.isEmpty ? 'Route ${_formatStamp(DateTime.now())}' : t);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null) return; // cancelled
    await stopRecording(name: name);
  }

  // ── Waypoints ────────────────────────────────────────────────────────────

  /// Drops a numbered critical waypoint at the current GPS position with a
  /// single tap — no description. Start (first) and End (last) are added
  /// automatically, so this marks the points in between. The exported route is
  /// directional (Start → End).
  ///
  /// When a cap is set, the final slot is reserved for the auto End waypoint;
  /// hitting it saves and ends the recording. With "no limit" (cap 0) there is
  /// no ceiling and recording never auto-stops for stop count.
  Future<void> addWaypoint() async {
    if (_mode != AppMode.recording && _mode != AppMode.paused) return;

    // Reserve one slot for the End waypoint that stopRecording() adds.
    if (_waypointsCapped && waypoints.length >= _maxWaypoints - 1) {
      _showSnack('Waypoint limit ($_maxWaypoints) reached');
      return;
    }

    final pos = currentPosition;
    if (pos == null) {
      _showSnack('No GPS fix yet — waypoint not added');
      return;
    }

    final number = waypoints.length + 1;
    final wpPos = LatLng(pos.latitude, pos.longitude);
    setState(() => waypoints.add(RouteWaypoint(wpPos, 'Waypoint $number')));
    await _autoSaveRoute(); // persist so an OS kill doesn't lose it
    AppLogger.log('Critical waypoint $number added at '
        '${wpPos.latitude.toStringAsFixed(5)},${wpPos.longitude.toStringAsFixed(5)}');

    if (_waypointsCapped && waypoints.length >= _maxWaypoints - 1) {
      AppLogger.log('Waypoint limit reached — ending recording');
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Waypoint Limit Reached'),
            content: Text(
              'You\'ve marked the maximum number of critical waypoints '
              '($_maxWaypoints, including Start and End). You can change this '
              'in Settings.\n\n'
              'This recording will be saved and stopped. Start a new recording '
              'to mark more.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      await stopRecording();
    } else {
      final of = _waypointsCapped ? '/$_maxWaypoints' : '';
      _showSnack('Waypoint $number marked ($number$of)');
    }
  }

  /// Serialises the active route (track points + waypoints) to the on-disk
  /// format. Stored as an object so waypoints travel with the route; old files
  /// that are a bare list of points are still readable by [_parseRouteJson].
  Map<String, dynamic> _routeToJson({String? name}) => {
        if (name != null && name.isNotEmpty) 'name': name,
        'points': routePoints
            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
            .toList(),
        'waypoints': waypoints.map((w) => w.toJson()).toList(),
      };

  /// Parses both the new object format ({name?, points, waypoints}) and the
  /// legacy flat-list-of-points format.
  ({List<LatLng> points, List<RouteWaypoint> waypoints, String? name})
      _parseRouteJson(dynamic decoded) {
    LatLng parsePoint(dynamic value) {
      if (value is! Map || value['lat'] is! num || value['lng'] is! num) {
        throw const FormatException('Route point is missing coordinates');
      }
      final lat = (value['lat'] as num).toDouble();
      final lng = (value['lng'] as num).toDouble();
      if (!lat.isFinite || !lng.isFinite ||
          lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        throw const FormatException('Route point has invalid coordinates');
      }
      return LatLng(lat, lng);
    }

    if (decoded is List) {
      if (decoded.length > 500000) {
        throw const FormatException('Route contains too many points');
      }
      return (
        points: decoded.map<LatLng>(parsePoint).toList(),
        waypoints: const <RouteWaypoint>[],
        name: null,
      );
    }
    if (decoded is Map) {
      final rawPoints = decoded['points'];
      final rawWaypoints = decoded['waypoints'];
      if (rawPoints != null && rawPoints is! List) {
        throw const FormatException('Route points must be a list');
      }
      if (rawWaypoints != null && rawWaypoints is! List) {
        throw const FormatException('Route waypoints must be a list');
      }
      final pointList = rawPoints as List? ?? const [];
      final waypointList = rawWaypoints as List? ?? const [];
      if (pointList.length > 500000 || waypointList.length > 10000) {
        throw const FormatException('Route file is too large');
      }
      final pts = pointList.map<LatLng>(parsePoint).toList();
      final wps = waypointList
          .map<RouteWaypoint>(
              (w) => RouteWaypoint.fromJson(Map<String, dynamic>.from(w)))
          .toList();
      for (final wp in wps) {
        final lat = wp.position.latitude;
        final lng = wp.position.longitude;
        if (!lat.isFinite || !lng.isFinite ||
            lat < -90 || lat > 90 || lng < -180 || lng > 180) {
          throw const FormatException('Waypoint has invalid coordinates');
        }
      }
      return (points: pts, waypoints: wps, name: decoded['name'] as String?);
    }
    return (
      points: const <LatLng>[],
      waypoints: const <RouteWaypoint>[],
      name: null,
    );
  }

  Future<void> _saveRoute({String? name}) async {
    if (routePoints.isEmpty) return;
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${dir.path}/route_$ts.json');
    await file.writeAsString(jsonEncode(_routeToJson(name: name)));
    // Clean up the auto-save file now that we have a proper save
    final autoSave = File('${dir.path}/route_autosave.json');
    if (await autoSave.exists()) await autoSave.delete();
  }

  /// Writes current routePoints to a temp file every 20 GPS fixes.
  /// If the app is killed by the OS, this file survives and can be recovered.
  Future<void> _autoSaveRoute() async {
    if (routePoints.isEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/route_autosave.json');
      await file.writeAsString(jsonEncode(_routeToJson()));
      AppLogger.log(
          'Auto-saved ${routePoints.length} pts / ${waypoints.length} wp to disk');
    } catch (e) {
      AppLogger.log('Auto-save failed: $e');
    }
  }

  /// Called on startup — if an auto-save file exists, the last recording
  /// was interrupted by an OS kill. Offer to recover it.
  Future<void> _checkAutoSave() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/route_autosave.json');
    if (!await file.exists()) return;

    final jsonString = await file.readAsString();
    ({List<LatLng> points, List<RouteWaypoint> waypoints, String? name}) parsed;
    try {
      parsed = _parseRouteJson(jsonDecode(jsonString));
    } catch (_) {
      await file.delete();
      return;
    }
    if (parsed.points.isEmpty) {
      await file.delete();
      return;
    }

    final wpCount = parsed.waypoints.length;
    AppLogger.log(
        'Auto-save found with ${parsed.points.length} pts / $wpCount wp — showing recovery dialog');

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Recover Interrupted Recording?'),
        content: Text(
          'The app was stopped by the system during your last recording.\n\n'
          '${parsed.points.length} points'
          '${wpCount > 0 ? ' and $wpCount waypoint${wpCount == 1 ? '' : 's'}' : ''} '
          'were saved automatically.\n\n'
          'Would you like to recover this route?',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await file.delete();
              AppLogger.log('Auto-save discarded by user');
            },
            child: const Text('Discard'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ts = DateTime.now()
                  .toIso8601String()
                  .replaceAll(':', '-');
              final recovered = File(
                  '${dir.path}/route_recovered_$ts.json');
              await recovered.writeAsString(jsonString);
              await file.delete();
              await listSavedRoutes();
              AppLogger.log(
                  'Auto-save recovered as ${recovered.path}');
              _showSnack(
                  'Route recovered — ${parsed.points.length} pts saved');
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text('Recover Route'),
          ),
        ],
      ),
    );
  }

  // ── Follow ─────────────────────────────────────────────────────────────────

  Future<void> startFollowing() async {
    if (loadedRoutePoints.isEmpty) return;

    if (!await _ensurePermission()) return;
    final pos = await Geolocator.getCurrentPosition(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.high),
    );

    setState(() {
      latitude = pos.latitude;
      longitude = pos.longitude;
      currentPosition = pos;
      _mode = AppMode.following;
      _distanceFromRoute = _calcDistanceToRoute(pos);
    });

    // Center on the user at a navigation zoom so the route ahead is visible.
    _moveCamera(LatLng(pos.latitude, pos.longitude), zoom: 17);

    _startLocationTracking();
    await _setSessionActive(true);
    await _startForegroundService('Following route: $_loadedRouteName');
    await WakelockPlus.enable();   // keep screen ON while following
    AppLogger.log('Following STARTED — screen wake lock enabled');
  }

  Future<void> stopFollowing() async {
    AppLogger.log('Following STOPPED');
    _stopLocationTracking();
    await _stopForegroundService();
    await _setSessionActive(false);
    await WakelockPlus.disable();  // release screen wake lock
    setState(() {
      _mode = AppMode.idle;
      _distanceFromRoute = null;
      _clearNav();
    });
  }

  // ── Route file ops ─────────────────────────────────────────────────────────

  Future<void> listSavedRoutes() async {
    final dir = await getApplicationDocumentsDirectory();

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final n = f.path.split('/').last;
          return n.startsWith('route_') &&
              n.endsWith('.json') &&
              n != 'route_autosave.json';
        })
        .toList();

    // Newest first, by file modification time (robust across the different
    // route_ / route_imported_ / route_recovered_ name prefixes).
    files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    _routeModified.clear();
    _routeNames.clear();
    for (final f in files) {
      final fname = f.path.split('/').last;
      _routeModified[fname] = f.statSync().modified;
      // Read the user-given name, if any, for display in the list.
      try {
        final decoded = jsonDecode(f.readAsStringSync());
        if (decoded is Map && decoded['name'] is String) {
          final n = (decoded['name'] as String).trim();
          if (n.isNotEmpty) _routeNames[fname] = n;
        }
      } catch (_) {}
    }

    savedRouteFiles
      ..clear()
      ..addAll(files.map((f) => f.path.split('/').last));

    setState(() {});
  }

  /// Human-readable timestamp, e.g. "30 Jun 2026, 3:45 PM".
  String _formatStamp(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $h12:$mm $ampm';
  }

  /// A short origin tag for a saved-route filename ('' for a normal recording).
  String _routeTypeTag(String name) {
    if (name.startsWith('route_imported_')) return 'Imported';
    if (name.startsWith('route_recovered_')) return 'Recovered';
    return '';
  }

  Future<void> loadRouteFromFile(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (!await file.exists()) return;

    final parsed = _parseRouteJson(jsonDecode(await file.readAsString()));
    setState(() {
      loadedRoutePoints = parsed.points;
      waypoints = parsed.waypoints;
      // Prefer the user-given name; fall back to the filename.
      _loadedRouteName = (parsed.name != null && parsed.name!.isNotEmpty)
          ? parsed.name
          : fileName;
      _distanceFromRoute = null;
      _clearNav();
    });
    _prepareNav(); // precompute along-route distances + waypoint indices

    if (loadedRoutePoints.isNotEmpty) {
      _moveCamera(loadedRoutePoints.first, zoom: 16);
    }
  }

  Future<void> deleteRouteFile(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) await file.delete();
    await listSavedRoutes();
  }

  Future<void> shareRouteFile(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    if (!await file.exists()) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'Route shared from RouteShare',
      ),
    );
  }

  // ── Google Maps / KML sharing ───────────────────────────────────────────────

  /// Opens Google Maps navigating through the user's critical waypoints in the
  /// order they were marked: the first is the Start (origin) and the last is the
  /// Destination. Google Maps routes from origin to destination, so the
  /// recommended route is only valid in the recorded direction — we confirm the
  /// start/destination with the user first.
  ///
  /// If no waypoints were marked, falls back to the route's first and last
  /// recorded points.
  Future<void> _shareOnGoogleMaps() async {
    List<LatLng> pts;
    List<String> labels;
    if (waypoints.isNotEmpty) {
      pts = waypoints.map((w) => w.position).toList();
      labels = [
        for (int i = 0; i < waypoints.length; i++)
          i == 0
              ? 'Start'
              : i == waypoints.length - 1
                  ? 'Destination'
                  : 'Waypoint ${i + 1}',
      ];
    } else {
      final route =
          loadedRoutePoints.isNotEmpty ? loadedRoutePoints : _recordedLatLngs;
      pts = route.isEmpty ? <LatLng>[] : [route.first, route.last];
      labels = ['Start', 'Destination'];
    }

    if (pts.isEmpty) {
      _showSnack('No waypoints to navigate — mark some while recording');
      return;
    }

    final choice = await _confirmDirection(pts);
    if (choice == null) return;

    // Guided drive: auto-detect arrival at each stop and prompt to continue.
    if (choice == 'guide') {
      await startGuidedDrive(pts, labels);
      return;
    }

    // Navigate every stop as its own point-to-point leg (Start→WP2→…→End).
    // Each leg is a reliable two-point link, so Google Maps honors all stops.
    if (choice == 'stops') {
      await _navigateStops(pts, labels);
      return;
    }

    // Share the route as one tappable Google Maps link per leg, so a recipient
    // (no app needed) can navigate the same stop-by-stop way.
    if (choice == 'sharestops') {
      await _shareStopByStop(pts, labels);
      return;
    }

    // 'open'/'share' use a direct Start → End two-point route.
    final url = _buildMapsDirectionsUrl(pts);
    AppLogger.log('Maps URL ($choice): $url');

    if (choice == 'share') {
      await SharePlus.instance.share(
        ShareParams(
          text: 'RouteShare route — open in Google Maps:\n$url',
          subject: 'RouteShare route',
        ),
      );
      return;
    }

    // choice == 'open'
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      await SharePlus.instance.share(
        ShareParams(
          text: 'Follow this route on Google Maps:\n$url',
          subject: 'RouteShare route',
        ),
      );
    }
  }

  /// Shares the route as one tappable Google Maps link per leg. The recipient
  /// needs no app — they tap Leg 1, drive it, tap Leg 2, and so on, covering
  /// every waypoint. Each link is a reliable two-point route.
  Future<void> _shareStopByStop(List<LatLng> pts, List<String> labels) async {
    final legs = pts.length - 1;
    final buf = StringBuffer()
      ..writeln('RouteShare route — $legs legs. '
          'Open each leg in order in Google Maps:')
      ..writeln();
    for (int i = 0; i < legs; i++) {
      buf
        ..writeln('Leg ${i + 1}: ${labels[i]} → ${labels[i + 1]}')
        ..writeln(_buildMapsDirectionsUrl([pts[i], pts[i + 1]]))
        ..writeln();
    }
    AppLogger.log('Sharing stop-by-stop route: $legs legs');
    await SharePlus.instance.share(
      ShareParams(
        text: buf.toString().trimRight(),
        subject: 'RouteShare route (stop by stop)',
      ),
    );
  }

  // ── Guided drive (tap to advance) ───────────────────────────────────────────

  int get _legCount => _legStops.length - 1;

  /// Starts a guided drive: launches leg 1 in Google Maps and tracks the user
  /// in the background. On reaching each stop it prompts to continue to the
  /// next leg (Stage 1 = tap to advance).
  Future<void> startGuidedDrive(List<LatLng> stops, List<String> labels) async {
    if (stops.length < 2) {
      _showSnack('Need at least a start and end to guide');
      return;
    }
    if (!await _ensurePermission()) return;
    await _ensureNotificationPermission();
    await _setSessionActive(true);

    // Start from the leg nearest the user's current position (so if they begin
    // partway along the route, earlier legs are treated as done).
    int startLeg = 0;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      double best = double.infinity;
      int nearest = 0;
      for (int i = 0; i < stops.length; i++) {
        final d = Geolocator.distanceBetween(pos.latitude, pos.longitude,
            stops[i].latitude, stops[i].longitude);
        if (d < best) {
          best = d;
          nearest = i;
        }
      }
      // Navigate from the nearest stop to the next one (clamp to a valid leg).
      startLeg = nearest.clamp(0, stops.length - 2);
      AppLogger.log('Guided start: nearest stop $nearest → leg ${startLeg + 1}');
    } catch (e) {
      AppLogger.log('Guided start: could not get position ($e), leg 1');
    }

    setState(() {
      _guiding = true;
      _legStops = List<LatLng>.from(stops);
      _legLabels = List<String>.from(labels);
      _legIndex = startLeg;
      _pendingNextLeg = false;
    });
    _startGuideTracking();
    await WakelockPlus.enable();
    await _ensureOverlay();
    AppLogger.log('Guided drive STARTED — $_legCount legs '
        '(overlay: $_overlayActive)');
    // Give the overlay a moment to render before Google Maps takes the
    // foreground, otherwise the overlay engine can be interrupted mid-start.
    if (_overlayActive) {
      await Future.delayed(const Duration(milliseconds: 600));
    }
    _launchCurrentLeg();
  }

  /// Requests the "Display over other apps" permission and shows the floating
  /// overlay. Silently degrades to in-app prompts if permission is declined.
  Future<void> _ensureOverlay() async {
    try {
      AppLogger.log('Overlay: _ensureOverlay entered');
      var granted = await FlutterOverlayWindow.isPermissionGranted();
      AppLogger.log('Overlay: isPermissionGranted=$granted');
      if (!granted) {
        granted = await FlutterOverlayWindow.requestPermission() ?? false;
        AppLogger.log('Overlay: after requestPermission granted=$granted');
      }
      if (!granted) {
        _showSnack('Overlay permission off — you\'ll return to the app to '
            'advance each leg.');
        return;
      }
      // NOTE: overlayListener is subscribed once in initState (single-sub
      // stream) — do NOT listen again here.
      // Explicit PIXEL dimensions: WindowSize.matchParent resolved to a 0-width
      // window on some devices, so compute physical pixels from the screen.
      final mq = MediaQuery.of(context);
      final dpr = mq.devicePixelRatio;
      final wPx = (mq.size.width * dpr).round();
      final hPx = (130 * dpr).round();
      AppLogger.log('Overlay: calling showOverlay ${wPx}x$hPx');
      await FlutterOverlayWindow.showOverlay(
        height: hPx,
        width: wPx,
        // Center on screen so it's always fully visible (no status-bar/notch
        // clipping); it's draggable if the user wants it out of the way.
        alignment: OverlayAlignment.center,
        flag: OverlayFlag.defaultFlag,
        enableDrag: true,
        overlayTitle: 'RouteShare guiding',
        positionGravity: PositionGravity.none,
      );
      AppLogger.log('Overlay: showOverlay returned');
      _overlayActive = true;
      _pushOverlay();
    } catch (e, st) {
      AppLogger.log('Overlay setup failed: $e\n$st');
      _overlayActive = false;
    }
  }

  /// Pushes the current leg state to the floating overlay.
  void _pushOverlay() {
    if (!_overlayActive || !_guiding) return;
    final to = (_legIndex + 1) < _legLabels.length
        ? _legLabels[_legIndex + 1]
        : 'Destination';
    final text = _pendingNextLeg
        ? 'Reached a stop — tap Next leg'
        : 'Leg ${_legIndex + 1} of $_legCount → $to';
    FlutterOverlayWindow.shareData(
        jsonEncode({'text': text, 'pending': _pendingNextLeg}));
  }

  Future<void> stopGuidedDrive() async {
    AppLogger.log('Guided drive STOPPED');
    // Reset the UI state FIRST so "End" always dismisses the panel, even if the
    // async cleanup below throws (e.g. closeOverlay on a device that blocked it).
    setState(() {
      _guiding = false;
      _pendingNextLeg = false;
      _legStops = [];
      _legLabels = [];
      _legIndex = 0;
    });
    try {
      await _guideStream?.cancel();
    } catch (_) {}
    _guideStream = null;
    await _setSessionActive(false);
    // Keep _overlaySub alive for the app's lifetime (single-subscription
    // stream — cancelled only in dispose).
    try {
      if (_overlayActive) await FlutterOverlayWindow.closeOverlay();
    } catch (e) {
      AppLogger.log('closeOverlay failed: $e');
    }
    _overlayActive = false;
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  /// DEBUG: shows the overlay while the app stays foreground (no Google Maps)
  /// to test whether the overlay renders at all on this device.
  Future<void> _testOverlay() async {
    await _ensureOverlay();
    if (_overlayActive) {
      FlutterOverlayWindow.shareData(jsonEncode(
          {'text': 'Overlay test — can you see this card?', 'pending': true}));
      _showSnack('Overlay requested — look for a navy card on screen. '
          'Tap its End button (or Test again) to close.');
    } else {
      _showSnack('Overlay did not activate (permission/plugin).');
    }
  }

  void _startGuideTracking() {
    // distanceFilter: 0 + a 1 s interval means we keep getting fixes even when
    // the car is stopped at a stop-light or mid-road — so "reached the stop"
    // is detected within ~1 s instead of waiting for the driver to move again.
    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 1),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'RouteShare — guided drive',
              notificationText:
                  'Tracking your stops. Return to RouteShare at each stop.',
              enableWakeLock: true,
            ),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.best, distanceFilter: 0);

    _guideStream?.cancel();
    _guideStream =
        Geolocator.getPositionStream(locationSettings: settings).listen(
      _onGuidePosition,
      onError: (e) => AppLogger.log('Guide GPS error: $e'),
    );
  }

  void _onGuidePosition(Position pos) {
    if (!_guiding) return;
    final destIdx = _legIndex + 1;
    if (destIdx >= _legStops.length) return;

    // Confirm the launch took hold: once we've moved clearly away from the stop
    // we just left, Maps is navigating the new leg — cancel any pending retries
    // so we don't re-fire an intent and trigger Maps' "Exit navigation?" prompt.
    // (Runs even during the cooldown, since driving away happens fast.)
    if (!_legNavConfirmed && _legOrigin != null) {
      final moved = Geolocator.distanceBetween(
        pos.latitude, pos.longitude,
        _legOrigin!.latitude, _legOrigin!.longitude,
      );
      if (moved > _navConfirmDist) _legNavConfirmed = true;
    }

    // Cooldown: ignore arrivals right after a launch so close/jittery stops
    // can't fire a burst of navigation intents (and land on an earlier leg).
    if (_lastLegLaunchAt != null &&
        DateTime.now().difference(_lastLegLaunchAt!) < _legCooldown) {
      return;
    }

    final d = Geolocator.distanceBetween(
      pos.latitude, pos.longitude,
      _legStops[destIdx].latitude, _legStops[destIdx].longitude,
    );
    if (d > _arrivalThreshold) return;

    AppLogger.log('Guide: reached stop $destIdx (${_legLabels[destIdx]})');
    if (destIdx == _legStops.length - 1) {
      _finishGuiding();
    } else {
      // Hands-free: announce and automatically launch the next leg. (The
      // overlay permission exempts us from Android's background-launch limit.)
      _alertArrival(destIdx);
      _continueToNextLeg();
    }
  }

  Future<void> _alertArrival(int reachedIdx) async {
    try {
      await _chimePlayer.stop();
      await _chimePlayer.play(AssetSource('sounds/waypoint_chime.wav'));
    } catch (_) {}
    if (!_voiceAlertsEnabled) return;
    await Future.delayed(const Duration(milliseconds: 700));
    try {
      await _tts.stop();
      await _tts.speak(
          'Reached ${_legLabels[reachedIdx]}. Continuing to the next stop.');
    } catch (_) {}
  }

  void _launchCurrentLeg() {
    if (_legIndex + 1 >= _legStops.length) return;
    _lastLegLaunchAt = DateTime.now(); // start the advance cooldown
    final legAtLaunch = _legIndex;
    final dest = _legStops[_legIndex + 1];
    _legOrigin = _legStops[_legIndex]; // the stop we're leaving
    _legNavConfirmed = false;          // reset; confirmed once we drive away
    AppLogger.log('Guide: launching leg ${_legIndex + 1} of $_legCount');
    _launchNavigation(dest);

    // Google Maps ignores a new navigation request while it's still showing the
    // previous leg's "arrived" screen. Re-fire a few times ONLY if we haven't
    // yet moved away — i.e. Maps really did ignore it. Once _legNavConfirmed is
    // set (driver is underway), these no-op, so a healthy leg never gets a
    // second intent (which would trigger Maps' "Exit navigation?" dialog).
    for (final secs in const [6, 12, 20]) {
      Future.delayed(Duration(seconds: secs), () {
        if (_guiding && _legIndex == legAtLaunch && !_legNavConfirmed) {
          AppLogger.log('Guide: retry(${secs}s) leg ${legAtLaunch + 1} '
              '(nav not yet confirmed)');
          _launchNavigation(dest);
        }
      });
    }
  }

  /// Launches Google Maps straight into turn-by-turn navigation to [to] from
  /// the current location — no "Start" tap needed (unlike the directions URL).
  Future<void> _launchNavigation(LatLng to) async {
    final navUri =
        Uri.parse('google.navigation:q=${to.latitude},${to.longitude}&mode=d');
    AppLogger.log('Nav intent: $navUri');
    try {
      await launchUrl(navUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.log('Nav intent failed ($e) — falling back to directions URL');
      await _launchMapsLeg(_legStops[_legIndex], to);
    }
  }

  void _continueToNextLeg() {
    setState(() {
      _legIndex++;
      _pendingNextLeg = false;
    });
    _pushOverlay();
    _launchCurrentLeg();
  }

  Future<void> _finishGuiding() async {
    if (_voiceAlertsEnabled) {
      try {
        await _tts.stop();
        await _tts.speak('You have arrived at your destination.');
      } catch (_) {}
    }
    await stopGuidedDrive();
    _showSnack('Guided drive complete — you have arrived.');
  }

  /// Prompts the user to continue to the next leg. Safe to call multiple times;
  /// only shows when there's a pending leg and no dialog is already open.
  void _showContinueDialog() {
    if (!mounted || !_guiding || !_pendingNextLeg || _continueDialogOpen) return;
    final reachedIdx = _legIndex + 1;
    final nextFrom = _legLabels[reachedIdx];
    final nextTo = _legLabels[reachedIdx + 1];
    _continueDialogOpen = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reached ${_legLabels[reachedIdx]}'),
        content: Text(
            'Leg ${reachedIdx + 1} of $_legCount: $nextFrom → $nextTo.\n\n'
            'Start the next leg in Google Maps?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              stopGuidedDrive();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('End drive'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _continueToNextLeg();
            },
            icon: const Icon(Icons.navigation),
            label: const Text('Next leg'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4285F4),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    ).then((_) => _continueDialogOpen = false);
  }

  /// Opens Google Maps directions for a single leg (two points), always
  /// reliable. Used by the stop-by-stop navigator.
  Future<void> _launchMapsLeg(LatLng from, LatLng to) async {
    final url = _buildMapsDirectionsUrl([from, to]);
    AppLogger.log('Maps leg: $url');
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      _showSnack('Could not open Google Maps');
    }
  }

  /// Walks through the route one leg at a time. Each leg opens a two-point
  /// Google Maps route (pts[i] → pts[i+1]); the user drives it, returns, steps
  /// to the next leg, and opens it — covering every waypoint in order.
  Future<void> _navigateStops(List<LatLng> pts, List<String> labels) async {
    int leg = 0; // current leg: pts[leg] -> pts[leg + 1]
    final legCount = pts.length - 1;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final from = pts[leg];
          final to = pts[leg + 1];
          final isLast = leg == legCount - 1;
          return AlertDialog(
            title: Text('Leg ${leg + 1} of $legCount'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.trip_origin, color: Colors.green, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('From: ${labels[leg]}',
                        style: const TextStyle(fontSize: 14)),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  const Icon(Icons.place, color: Colors.red, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('To: ${labels[leg + 1]}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      tooltip: 'Previous leg',
                      onPressed:
                          leg > 0 ? () => setLocal(() => leg--) : null,
                    ),
                    Text('${leg + 1} / $legCount',
                        style: TextStyle(color: Colors.grey[600])),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      tooltip: 'Next leg',
                      onPressed: leg < legCount - 1
                          ? () => setLocal(() => leg++)
                          : null,
                    ),
                  ],
                ),
                Text(
                  'Opens a point-to-point route to the next stop. Drive it, '
                  'come back, tap ▶ for the next leg, then open it.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
              ElevatedButton.icon(
                onPressed: () => _launchMapsLeg(from, to),
                icon: const Icon(Icons.navigation),
                label: Text(isLast ? 'Open final leg' : 'Open leg'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4285F4),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Google Maps directions URL for a clean Start → End route (two points).
  ///
  /// We deliberately do NOT push the intermediate waypoints into this URL: the
  /// Google Maps consumer app doesn't reliably accept multi-stop routes via any
  /// URL scheme (path, api=1 waypoints, and saddr/daddr+to: each break — it
  /// mis-assigns or drops the destination). A two-point route is always
  /// correct. The full set of critical waypoints is followed in the app's
  /// Follow mode and exported in the KML file.
  ///
  /// Raw commas are used (the app can mis-parse percent-encoded coordinates).
  String _buildMapsDirectionsUrl(List<LatLng> pts) {
    String c(LatLng p) => '${p.latitude},${p.longitude}';
    final destination = 'destination=${c(pts.last)}';
    final origin = pts.length >= 2 ? '&origin=${c(pts.first)}' : '';
    return 'https://www.google.com/maps/dir/?api=1$origin&$destination'
        '&travelmode=driving';
  }

  /// Confirmation dialog that makes travel direction explicit and lets the user
  /// either open Google Maps directly or share the link. Returns 'open',
  /// 'share', or null (cancelled).
  ///
  /// Sharing is offered because opening the multi-stop link directly in the
  /// Maps app can mis-place the destination pin, whereas a shared link is
  /// resolved correctly when tapped.
  Future<String?> _confirmDirection(List<LatLng> pts) {
    String fmt(LatLng p) =>
        '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
    final hasStops = pts.length > 2;
    final legCount = pts.length - 1;

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open in Google Maps'),
        content: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.trip_origin, color: Colors.green, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Start: ${fmt(pts.first)}',
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.place, color: Colors.red, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text('End: ${fmt(pts.last)}',
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
            const Divider(height: 20),
            if (hasStops)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading:
                    const Icon(Icons.assistant_direction, color: Color(0xFF34A853)),
                title: const Text('Guided drive (auto-detect stops)'),
                subtitle: Text(
                    'Opens each leg in Google Maps; tap Continue at each of the '
                    '$legCount stops'),
                onTap: () => Navigator.pop(ctx, 'guide'),
              ),
            if (hasStops)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.alt_route, color: Color(0xFF4285F4)),
                title: const Text('Navigate stops one by one (manual)'),
                subtitle: Text(
                    'Point-to-point through all $legCount legs — every waypoint'),
                onTap: () => Navigator.pop(ctx, 'stops'),
              ),
            if (hasStops)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.share_location,
                    color: Color(0xFF34A853)),
                title: const Text('Share stop-by-stop links'),
                subtitle: Text(
                    'Send $legCount tappable Google Maps legs (no app needed)'),
                onTap: () => Navigator.pop(ctx, 'sharestops'),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.navigation),
              title: const Text('Start → End (direct)'),
              subtitle: const Text('One route, skips the middle stops'),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.ios_share),
              title: const Text('Share Start → End link'),
              subtitle: const Text('Send via Drive, Gmail, WhatsApp'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
          ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// Exports the loaded/recorded route as a .kml file and shares it.
  Future<void> _exportAsKml() async {
    final pts = loadedRoutePoints.isNotEmpty
        ? loadedRoutePoints
        : _recordedLatLngs;
    if (pts.isEmpty) {
      _showSnack('No route to export');
      return;
    }

    final coords = pts
        .map((p) => '${p.longitude},${p.latitude},0')
        .join('\n                ');

    // Clean, human label — never the internal "route_….json" filename.
    final displayName =
        (_loadedRouteName ?? 'RouteShare route').replaceAll('.json', '');
    final routeName = _xmlEscape(displayName); // used inside the KML <name>

    // One labeled Point placemark per user-marked waypoint, so they show up as
    // named pins in Google Earth / Maps alongside the route line.
    final waypointPlacemarks = waypoints
        .map((w) => '''
    <Placemark>
      <name>${_xmlEscape(w.label)}</name>
      <Point>
        <coordinates>${w.position.longitude},${w.position.latitude},0</coordinates>
      </Point>
    </Placemark>''')
        .join('\n');

    final kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>$routeName</name>
    <Placemark>
      <name>$routeName</name>
      <Style>
        <LineStyle>
          <color>ff0000ff</color>
          <width>4</width>
        </LineStyle>
      </Style>
      <LineString>
        <tessellate>1</tessellate>
        <coordinates>
                $coords
        </coordinates>
      </LineString>
    </Placemark>${waypointPlacemarks.isEmpty ? '' : '\n$waypointPlacemarks'}
  </Document>
</kml>''';

    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    // Clean, .kml-named file so Drive/Gmail attach it as a KML (not JSON).
    final base = (_loadedRouteName ?? 'route_$ts')
        .replaceAll('.json', '')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}/$base.kml');
    await file.writeAsString(kml);
    AppLogger.log('KML exported: ${file.path}');
    if (!mounted) return;

    // Google Earth registers to OPEN files (VIEW intent) and won't appear in
    // the SHARE sheet (SEND intent, used by Drive/Gmail/WhatsApp). So offer
    // both: "Open in app" launches Earth; "Share" sends the file elsewhere.
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export KML'),
        content: const Text(
          'Open the route in a map app (e.g. Google Earth), or share the KML '
          'file (Drive, Gmail, WhatsApp)?',
        ),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(ctx, 'open'),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open in app'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'share'),
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('Share'),
          ),
        ],
      ),
    );
    if (action == null) return;

    if (action == 'open') {
      final res = await OpenFilex.open(
        file.path,
        type: 'application/vnd.google-earth.kml+xml',
      );
      AppLogger.log('OpenFilex: ${res.type} ${res.message}');
      if (res.type != ResultType.done) {
        _showSnack('No app opened the KML — try Share instead');
      }
    } else {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(file.path,
                mimeType: 'application/vnd.google-earth.kml+xml',
                name: '$base.kml'),
          ],
          text: 'RouteShare route (KML attached)',
          subject: 'RouteShare route',
        ),
      );
    }
  }

  Future<void> importRouteFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null) return;
    final selectedPath = result.files.single.path;
    if (selectedPath == null) return;
    // User already picked the file explicitly, so no extra confirmation needed.
    await _importRouteFromFile(File(selectedPath), confirmFirst: false);
  }

  /// Reads, sanity-checks, and imports a route file. Used by the in-app
  /// "Import" picker (confirmFirst: false) and by files opened from other apps
  /// such as WhatsApp or Drive (confirmFirst: true — asks before saving).
  Future<void> _importRouteFromFile(File file,
      {required bool confirmFirst}) async {
    if (!await file.exists()) {
      _showSnack('Could not open the shared file');
      return;
    }
    if (await file.length() > 20 * 1024 * 1024) {
      _showSnack('Route file is too large');
      return;
    }

    late final String jsonString;
    late final ({List<LatLng> points, List<RouteWaypoint> waypoints, String? name})
        parsed;
    try {
      jsonString = await file.readAsString();
      parsed = _parseRouteJson(jsonDecode(jsonString));
      if (parsed.points.isEmpty) {
        throw const FormatException('Route contains no points');
      }
    } catch (_) {
      _showSnack('Invalid or unsupported RouteShare file');
      return;
    }

    // Ask before importing a file that arrived from another app.
    if (confirmFirst) {
      if (!mounted) return;
      final label = parsed.name?.trim().isNotEmpty == true
          ? '"${parsed.name!.trim()}"'
          : 'this route';
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import shared route?'),
          content: Text('Import $label into RouteShare?\n\n'
              '${parsed.points.length} track points · '
              '${parsed.waypoints.length} stops'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final importedName = 'route_imported_$ts.json';
    await File('${dir.path}/$importedName').writeAsString(jsonString);

    await listSavedRoutes();
    await loadRouteFromFile(importedName);
    _showSnack('Route imported');
  }

  // ── Dialog ─────────────────────────────────────────────────────────────────

  void showSavedRoutesDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Saved Routes'),
        content: SizedBox(
          width: double.maxFinite,
          child: savedRouteFiles.isEmpty
              ? const Text('No saved routes.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: savedRouteFiles.length,
                  itemBuilder: (ctx, i) {
                    final name = savedRouteFiles[i];
                    final modified = _routeModified[name];
                    final tag = _routeTypeTag(name);
                    final isLatest = i == 0;
                    final customName = _routeNames[name];
                    final dateStr =
                        modified != null ? _formatStamp(modified) : name;
                    // Title = user name if given, else the date.
                    final titleStr = customName ?? dateStr;
                    // Subtitle = date + origin tag (date omitted if it's the title).
                    final subtitleStr = customName != null
                        ? (tag.isEmpty ? dateStr : '$dateStr · $tag')
                        : (tag.isEmpty ? 'Recorded route' : tag);
                    return ListTile(
                      leading: Icon(
                        isLatest ? Icons.star : Icons.route,
                        color: isLatest
                            ? Colors.amber.shade700
                            : const Color(0xFF1C2280),
                        size: 22,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              titleStr,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isLatest
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isLatest)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Text('Latest',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green)),
                            ),
                        ],
                      ),
                      subtitle: Text(
                        subtitleStr,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.share, size: 20),
                            onPressed: () async => shareRouteFile(name),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete, size: 20),
                            onPressed: () async {
                              Navigator.pop(ctx);
                              await deleteRouteFile(name);
                              if (!mounted) return;
                              showSavedRoutesDialog();
                            },
                          ),
                        ],
                      ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await loadRouteFromFile(name);
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Escapes text for safe inclusion in KML/XML (spoken labels may contain
  /// characters like & < >).
  String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// Google Maps markers for the critical waypoints. First = Start (green),
  /// last = Destination (red), the rest numbered (violet). Tapping a pin shows
  /// its label in an info window (Google Maps markers can't show always-on
  /// labels).
  Set<Marker> _buildWaypointMarkers() {
    final markers = <Marker>{};
    for (int i = 0; i < waypoints.length; i++) {
      final isStart = i == 0;
      final isEnd = i == waypoints.length - 1;
      final double hue;
      final String title;
      if (isStart && isEnd) {
        hue = BitmapDescriptor.hueViolet;
        title = 'Start / End';
      } else if (isStart) {
        hue = BitmapDescriptor.hueGreen;
        title = 'Start';
      } else if (isEnd) {
        hue = BitmapDescriptor.hueRed;
        title = 'Destination';
      } else {
        hue = BitmapDescriptor.hueViolet;
        title = 'Waypoint ${i + 1}';
      }
      markers.add(Marker(
        markerId: MarkerId('wp_$i'),
        position: waypoints[i].position,
        icon: BitmapDescriptor.defaultMarkerWithHue(hue),
        infoWindow: InfoWindow(title: title),
      ));
    }
    return markers;
  }

  /// Google Maps polylines: loaded/followed route (blue) and recorded (green).
  Set<Polyline> _buildRoutePolylines() {
    final lines = <Polyline>{};
    if (loadedRoutePoints.isNotEmpty) {
      lines.add(Polyline(
        polylineId: const PolylineId('loaded'),
        points: loadedRoutePoints,
        color: Colors.blue,
        width: 5,
      ));
    }
    if (_recordedLatLngs.isNotEmpty) {
      lines.add(Polyline(
        polylineId: const PolylineId('recorded'),
        points: _recordedLatLngs,
        color: Colors.green,
        width: 4,
      ));
    }
    return lines;
  }

  /// Control panel shown while a guided drive is active.
  Widget _guidingPanel() {
    final leg = _legIndex + 1;
    final toLabel = (_legIndex + 1) < _legLabels.length
        ? _legLabels[_legIndex + 1]
        : 'Destination';
    return Container(
      width: double.infinity,
      color: kBrandNavy,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.assistant_direction, color: kBrandCyan),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _pendingNextLeg
                      ? 'Reached a stop — continue when ready'
                      : 'Guided drive · Leg $leg of $_legCount → $toLabel',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _pendingNextLeg
                ? 'Tap "Next leg" to open the next segment in Google Maps.'
                : 'Follow Google Maps to the next stop. Come back here when you '
                    'arrive.',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (_pendingNextLeg)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _continueToNextLeg,
                    icon: const Icon(Icons.navigation),
                    label: const Text('Next leg'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4285F4),
                      foregroundColor: Colors.white,
                    ),
                  ),
                )
              else
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _launchCurrentLeg,
                    icon: const Icon(Icons.map_outlined, color: Colors.white),
                    label: const Text('Reopen leg in Maps',
                        style: TextStyle(color: Colors.white)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white54),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: stopGuidedDrive,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('End'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Turn-by-turn guidance banner shown over the map while following.
  Widget _navBanner() {
    final icon = _navTurnDir == 'left'
        ? Icons.turn_left
        : _navTurnDir == 'right'
            ? Icons.turn_right
            : Icons.straight;

    final details = <String>[];
    if (_distRemaining != null) {
      details.add('${_fmtDist(_distRemaining!)} left');
    }
    if (_etaMinutes != null) details.add('~$_etaMinutes min');
    if (_nextWpLabel != null && _distToNextWp != null) {
      details.add('Next: $_nextWpLabel (${_fmtDist(_distToNextWp!)})');
    }

    return Card(
      color: kBrandNavy,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: kBrandCyan, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _navInstruction ?? '',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                details.join('   •   '),
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8), fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isRecording = _mode == AppMode.recording;
    final isPaused = _mode == AppMode.paused;
    final isFollowing = _mode == AppMode.following;
    final hasLoadedRoute = loadedRoutePoints.isNotEmpty;

    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF1C2280),
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              icon: Icon(
                  _voiceAlertsEnabled ? Icons.volume_up : Icons.volume_off),
              tooltip: _voiceAlertsEnabled
                  ? 'Waypoint alerts on'
                  : 'Waypoint alerts off',
              onPressed: () {
                setState(() => _voiceAlertsEnabled = !_voiceAlertsEnabled);
                if (!_voiceAlertsEnabled) _tts.stop();
                _showSnack(_voiceAlertsEnabled
                    ? 'Waypoint alerts on'
                    : 'Waypoint alerts off');
              },
            ),
            if (kDebugMode)
              IconButton(
                icon: const Icon(Icons.layers_outlined),
                tooltip: 'Test overlay',
                onPressed: _testOverlay,
              ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: _showSettingsDialog,
            ),
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'About',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AboutScreen()),
              ),
            ),
            if (kDebugMode)
              IconButton(
                icon: const Icon(Icons.bug_report_outlined),
                tooltip: 'Share debug log',
                onPressed: () async {
                  final path = AppLogger.filePath;
                  if (path == null) return;
                  await SharePlus.instance.share(
                    ShareParams(
                      files: [XFile(path)],
                      text: 'RouteShare debug log (contains location data)',
                    ),
                  );
                },
              ),
          ],
          titleSpacing: 0,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Show logo if asset exists, silently skip if not yet placed
              Image.asset(
                'assets/images/logo.png',
                height: 32,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              const Flexible(
                child: Text(
                  'RouteShare',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF00AEEF),
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              // ── Map ────────────────────────────────────────────────────────
              Expanded(
                child: Stack(
                  children: [
                    GoogleMap(
                      onMapCreated: (c) => _mapController = c,
                      initialCameraPosition: CameraPosition(
                        target:
                            LatLng(latitude ?? 12.9716, longitude ?? 77.5946),
                        zoom: 15,
                      ),
                      markers: _buildWaypointMarkers(),
                      polylines: _buildRoutePolylines(),
                      // Native blue location puck (shows heading) — replaces the
                      // old custom arrow marker. Enabled only once we have a fix
                      // so the map doesn't prompt for permission on launch.
                      myLocationEnabled: currentPosition != null,
                      myLocationButtonEnabled: false,
                      compassEnabled: true,
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      // Lock rotation gestures during recording/following so the
                      // heading-based auto-rotation isn't fought by the user.
                      rotateGesturesEnabled: _mode == AppMode.idle,
                      onCameraMove: (position) {
                        _currentZoom = position.zoom;
                        _currentBearing = position.bearing;
                      },
                      onCameraMoveStarted: () {
                        // A move we didn't trigger = the user panned/zoomed;
                        // pause follow auto-centering for a few seconds.
                        if (_mode == AppMode.following && !_programmaticMove) {
                          _onUserMapInteraction();
                        }
                      },
                      onCameraIdle: () => _programmaticMove = false,
                    ),

                    // Turn-by-turn guidance banner while following.
                    if (isFollowing && _navInstruction != null)
                      Positioned(
                        top: 8,
                        left: 8,
                        right: 8,
                        child: _navBanner(),
                      ),
                  ],
                ),
              ),

              // ── Controls (scrollable so nothing gets cut on small screens) ─
              SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Guided drive panel replaces the normal controls.
                    if (_guiding) _guidingPanel(),

                    // Deviation banner — only when meaningfully off the route.
                    if (!_guiding &&
                        isFollowing &&
                        _distanceFromRoute != null &&
                        _distanceFromRoute! > _deviationThreshold)
                      Container(
                        width: double.infinity,
                        color: Colors.red.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Text(
                          'Route Deviation Detected  •  '
                          '${_fmtDist(_distanceFromRoute!)} from route',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),

                    const SizedBox(height: 8),

                    // Status line
                    if (!_guiding)
                      Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        isRecording
                            ? '● Recording  •  ${routePoints.length} pts'
                                '  •  ${waypoints.length}${_waypointsCapped ? '/$_maxWaypoints' : ''} wp'
                            : isPaused
                                ? '⏸ Paused  •  ${routePoints.length} pts saved'
                                    '  •  ${waypoints.length}${_waypointsCapped ? '/$_maxWaypoints' : ''} wp'
                                : isFollowing
                                    ? '● Following  •  ${_loadedRouteName ?? ""}'
                                    : hasLoadedRoute
                                        ? 'Route loaded: ${_loadedRouteName ?? ""}  '
                                            '(${loadedRoutePoints.length} pts'
                                            '${waypoints.isNotEmpty ? ', ${waypoints.length} wp' : ''})'
                                        : 'Idle — record a route or load one to follow',
                        style: TextStyle(
                          fontSize: 12,
                          color: isRecording
                              ? Colors.red
                              : isPaused
                                  ? Colors.orange
                                  : isFollowing
                                      ? Colors.blue
                                      : Colors.grey[600],
                        ),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Buttons
                    if (!_guiding)
                      Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          // Record
                          if (!isFollowing && !isPaused && !isRecording)
                            ElevatedButton.icon(
                              onPressed: startRecording,
                              icon: const Icon(
                                  Icons.fiber_manual_record,
                                  color: Colors.red),
                              label: const Text('Record'),
                            ),

                          // Pause (while recording)
                          if (isRecording)
                            ElevatedButton.icon(
                              onPressed: pauseRecording,
                              icon: const Icon(Icons.pause),
                              label: const Text('Pause'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange,
                                foregroundColor: Colors.white,
                              ),
                            ),

                          // Resume (while paused)
                          if (isPaused)
                            ElevatedButton.icon(
                              onPressed: resumeRecording,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Resume'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                            ),

                          // Mark a numbered critical waypoint (recording/paused)
                          if (isRecording || isPaused)
                            ElevatedButton.icon(
                              onPressed: addWaypoint,
                              icon: const Icon(Icons.add_location_alt),
                              label: Text(
                                  'Mark Waypoint (${waypoints.length}${_waypointsCapped ? '/$_maxWaypoints' : ''})'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8E24AA),
                                foregroundColor: Colors.white,
                              ),
                            ),

                          // Stop (while recording or paused)
                          if (isRecording || isPaused)
                            ElevatedButton.icon(
                              onPressed: confirmStopRecording,
                              icon: const Icon(Icons.stop),
                              label: const Text('Stop'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                              ),
                            ),

                          // Follow Route / Stop Following
                          if (!isRecording && !isPaused)
                            ElevatedButton.icon(
                              onPressed: isFollowing
                                  ? stopFollowing
                                  : hasLoadedRoute
                                      ? startFollowing
                                      : null,
                              icon: Icon(isFollowing
                                  ? Icons.navigation_outlined
                                  : Icons.navigation),
                              label: Text(isFollowing
                                  ? 'Stop Following'
                                  : 'Follow Route'),
                              // Follow route is the primary, in-app experience —
                              // highlight it in brand cyan when a route is ready.
                              style: isFollowing
                                  ? ElevatedButton.styleFrom(
                                      backgroundColor: Colors.orange,
                                      foregroundColor: Colors.white,
                                    )
                                  : hasLoadedRoute
                                      ? ElevatedButton.styleFrom(
                                          backgroundColor: kBrandCyan,
                                          foregroundColor: Colors.white,
                                          textStyle: const TextStyle(
                                              fontWeight: FontWeight.bold),
                                        )
                                      : null,
                            ),

                          // Saved Routes
                          if (!isRecording && !isPaused)
                            ElevatedButton.icon(
                              onPressed: () async {
                                await listSavedRoutes();
                                showSavedRoutesDialog();
                              },
                              icon: const Icon(Icons.folder_open),
                              label: const Text('Saved Routes'),
                            ),

                          // Import
                          if (!isRecording && !isPaused)
                            ElevatedButton.icon(
                              onPressed: importRouteFile,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Import'),
                            ),

                          // Open in Maps (secondary, de-emphasised — Follow route
                          // above is the primary in-app experience)
                          if (!isRecording && !isPaused &&
                              (hasLoadedRoute || routePoints.isNotEmpty))
                            OutlinedButton.icon(
                              onPressed: _shareOnGoogleMaps,
                              icon: const Icon(Icons.map_outlined),
                              label: const Text('Open in Maps'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: kBrandNavy,
                              ),
                            ),

                          // Export as KML (secondary, de-emphasised)
                          if (!isRecording && !isPaused &&
                              (hasLoadedRoute || routePoints.isNotEmpty))
                            OutlinedButton.icon(
                              onPressed: _exportAsKml,
                              icon: const Icon(Icons.download_outlined),
                              label: const Text('Export KML'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: kBrandNavy,
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Build tag shown only in debug/testing builds; hidden
                    // automatically in the release build. Version still shows
                    // on the About page.
                    if (kDebugMode) ...[
                      const SizedBox(height: 10),
                      Text(
                        kAppVersion,
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
