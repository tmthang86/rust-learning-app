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
  runApp(RustLearnApp(state: state));
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
  const RustLearnApp({super.key, required this.state, this.initialLocation = '/learn'});

  final AppState state;

  /// Where the app opens; tests use it to simulate a deep link.
  final String initialLocation;

  @override
  State<RustLearnApp> createState() => _RustLearnAppState();
}

class _RustLearnAppState extends State<RustLearnApp> {
  late final GoRouter _router = buildRouter(widget.state, initialLocation: widget.initialLocation);

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp.router(
        title: 'Learn Rust',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        routerConfig: _router,
      ),
    );
  }
}
