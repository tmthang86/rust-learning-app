import 'package:go_router/go_router.dart';

import '../data/app_state.dart';
import '../features/editor/playground_screen.dart';
import '../features/home/home_screen.dart';
import '../features/lesson/lesson_screen.dart';
import '../features/onboarding/track_picker_screen.dart';
import '../features/progress/progress_screen.dart';
import '../features/quiz/quiz_screen.dart';
import 'shell.dart';

GoRouter buildRouter(AppState state) => GoRouter(
      initialLocation: '/learn',
      refreshListenable: state,
      redirect: (context, route) {
        final onWelcome = route.matchedLocation == '/welcome';
        if (state.track == null && !onWelcome) return '/welcome';
        if (state.track != null && onWelcome) return '/learn';
        return null;
      },
      routes: [
        GoRoute(
          path: '/welcome',
          builder: (context, route) => const TrackPickerScreen(),
        ),
        StatefulShellRoute.indexedStack(
          builder: (context, route, shell) =>
              AppShell(navigationShell: shell),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/learn',
                builder: (context, route) => const HomeScreen(),
              ),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/playground',
                builder: (context, route) => const PlaygroundScreen(),
              ),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/progress',
                builder: (context, route) => const ProgressScreen(),
              ),
            ]),
          ],
        ),
        GoRoute(
          path: '/lesson/:id',
          builder: (context, route) =>
              LessonScreen(lessonId: route.pathParameters['id']!),
          routes: [
            GoRoute(
              path: 'quiz',
              builder: (context, route) =>
                  QuizScreen(lessonId: route.pathParameters['id']!),
            ),
          ],
        ),
      ],
    );
