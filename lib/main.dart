import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
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
import 'runner/code_runner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final firebase = await _initFirebase();
  final state = AppState(
    repository: CourseRepository(),
    runner: codeRunnerFromEnvironment(),
    prefs: await SharedPreferences.getInstance(),
    accounts: firebase ? FirebaseAccountService() : const DisabledAccountService(),
    sync: firebase ? FirestoreProgressSync() : null,
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
    onResume: () => _monetization.onResume(),
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
