import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account/account_service.dart';
import 'account/progress_sync.dart';
import 'app/router.dart';
import 'firebase_options.dart';
import 'app/theme.dart';
import 'data/app_state.dart';
import 'data/course_repository.dart';
import 'monetization/monetization.dart';
import 'monetization/platform_services.dart';
import 'monetization/purchase_controller.dart';
import 'monetization/purchase_service.dart';
import 'reminders/local_notifications_scheduler.dart';
import 'reminders/reminder_scheduler.dart';
import 'runner/code_runner.dart';
import 'runner/firebase_runner_auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final firebase = await _initFirebase();
  final appCheck = firebase && await _activateAppCheck();
  final state = AppState(
    repository: CourseRepository(),
    // Without Firebase and App Check the runner gets no token. A
    // development runner accepts that; a production one refuses it.
    runner: codeRunnerFromEnvironment(
      auth: appCheck ? FirebaseRunnerAuth() : const NoRunnerAuth(),
    ),
    prefs: await SharedPreferences.getInstance(),
    accounts: firebase ? FirebaseAccountService() : const DisabledAccountService(),
    sync: firebase ? FirestoreProgressSync() : null,
    // The web can't schedule reminders; there the UI hides them.
    reminderScheduler: kIsWeb
        ? const NoopReminderScheduler()
        : LocalNotificationsScheduler(),
  );
  await state.load();
  final services = createPlatformServices();
  final monetization = Monetization(
    prefs: state.prefs,
    age: state.age,
    purchases: PurchaseController(
      store: services.purchases,
      prefs: state.prefs,
      // To add server-side receipt checks later, pass a PurchaseVerifier
      // here (see lib/monetization/purchase_service.dart).
    ),
    ads: services.ads,
    consent: services.consent,
  );
  runApp(RustLearnApp(state: state, monetization: monetization));
  // Not awaited: the consent form and store run alongside the UI and
  // never block lessons.
  unawaited(monetization.start());
  // Plans the reminders again (does nothing unless the learner turned them
  // on). Not awaited, and never asks for permission.
  unawaited(state.reminders.refresh());
}

/// Starts Firebase if this build is configured for it (see
/// docs/firebase-setup.md). Without it the app runs with on-device progress.
Future<bool> _initFirebase() async {
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    return true;
  } catch (e) {
    debugPrint('Accounts are off: $e');
    return false;
  }
}

/// Debug builds register this token in the Firebase console (App Check →
/// Apps → Manage debug tokens) and pass it with
/// `--dart-define=APP_CHECK_DEBUG_TOKEN=...`. Never commit it. Without it,
/// the plugin makes up a token and prints it to the log. Register that one
/// instead.
const _debugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');

/// reCAPTCHA Enterprise site key for release web builds
/// (`--dart-define=APP_CHECK_WEB_SITE_KEY=...`).
const _webSiteKey = String.fromEnvironment('APP_CHECK_WEB_SITE_KEY');

/// Turns on Firebase App Check, which proves to the code runner that
/// requests come from this app. Call it only after Firebase started.
/// Returns false, and the app carries on without a token, when App Check
/// can't start (see docs/firebase-setup.md and runner/deploy/README.md).
Future<bool> _activateAppCheck() async {
  try {
    if (kIsWeb && !kDebugMode && _webSiteKey.isEmpty) return false;
    final debug = _debugToken.isEmpty ? null : _debugToken;
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? AndroidDebugProvider(debugToken: debug)
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? AppleDebugProvider(debugToken: debug)
          : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      providerWeb: kDebugMode
          ? WebDebugProvider(debugToken: debug)
          : ReCaptchaEnterpriseProvider(_webSiteKey),
    );
    return true;
  } catch (e) {
    debugPrint('App Check is off: $e');
    return false;
  }
}

class RustLearnApp extends StatefulWidget {
  const RustLearnApp({
    super.key,
    required this.state,
    this.monetization,
    this.initialLocation = '/learn',
  });

  final AppState state;

  /// Ads, consent, age and purchases. Defaults to one with no ads and no
  /// store (what the web gets), so tests don't need plugins.
  final Monetization? monetization;

  /// Where the app opens; tests use it to simulate a deep link.
  final String initialLocation;

  @override
  State<RustLearnApp> createState() => _RustLearnAppState();
}

class _RustLearnAppState extends State<RustLearnApp> {
  late final Monetization _monetization =
      widget.monetization ??
      Monetization(
        prefs: widget.state.prefs,
        age: widget.state.age,
        purchases: PurchaseController(
          store: const NoPurchaseService(),
          prefs: widget.state.prefs,
        ),
      );
  late final GoRouter _router = buildRouter(
    widget.state,
    initialLocation: widget.initialLocation,
  );

  /// Store and consent retries when the app comes back to the foreground.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () {
      _monetization.onResume();
      widget.state.onResume();
    },
  );

  @override
  void initState() {
    super.initState();
    assert(
      identical(_monetization.age, widget.state.age),
      'Monetization and AppState must share one AgeStore',
    );
    _lifecycle; // start listening
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _router.dispose();
    if (widget.monetization == null) {
      _monetization.purchases.dispose();
      _monetization.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MonetizationScope(
        monetization: _monetization,
        child: MaterialApp.router(
          title: 'Learn Rust',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          routerConfig: _router,
        ),
      ),
    );
  }
}
