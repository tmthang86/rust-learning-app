import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'data/app_state.dart';
import 'data/course_repository.dart';
import 'runner/code_runner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(
    repository: CourseRepository(),
    runner: const PlaceholderCodeRunner(),
    prefs: await SharedPreferences.getInstance(),
  );
  await state.load();
  runApp(RustLearnApp(state: state));
}

class RustLearnApp extends StatefulWidget {
  const RustLearnApp({super.key, required this.state});

  final AppState state;

  @override
  State<RustLearnApp> createState() => _RustLearnAppState();
}

class _RustLearnAppState extends State<RustLearnApp> {
  late final GoRouter _router = buildRouter(widget.state);

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
