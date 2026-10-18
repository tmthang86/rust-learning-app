import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../data/app_state.dart';
import '../features/account/delete_account_screen.dart';
import '../features/editor/playground_screen.dart';
import '../features/home/home_screen.dart';
import '../features/lesson/lesson_screen.dart';
import '../features/onboarding/age_screen.dart';
import '../features/onboarding/track_picker_screen.dart';
import '../features/progress/progress_screen.dart';
import '../features/quiz/quiz_screen.dart';
import '../monetization/monetization.dart';
import 'shell.dart';

GoRouter buildRouter(
  AppState state,
  Monetization monetization, {
  String initialLocation = '/learn',
}) =>
    GoRouter(
      initialLocation: initialLocation,
      refreshListenable: Listenable.merge([state, monetization]),
      redirect: (context, route) {
        // Reachable without picking a track: linked from the store listing.
        if (route.matchedLocation == '/delete-account') return null;
        final from = route.uri.toString();

        // First launch asks for a birth year, then for a track. A deep
        // link is remembered through both.
        final onAge = route.matchedLocation == '/age';
        if (monetization.needsAge && !onAge) {
          return from == '/learn'
              ? '/age'
              : Uri(path: '/age', queryParameters: {'from': from}).toString();
        }
        if (!monetization.needsAge && onAge) {
          return safeReturnLocation(route.uri.queryParameters['from']);
        }
        if (onAge) return null;

        final onWelcome = route.matchedLocation == '/welcome';
        if (state.track == null && !onWelcome) {
          // Remember a deep link so it opens once a track is picked.
          return from == '/learn'
              ? '/welcome'
              : Uri(path: '/welcome', queryParameters: {'from': from}).toString();
        }
        if (state.track != null && onWelcome) {
          return safeReturnLocation(route.uri.queryParameters['from']);
        }
        return null;
      },
      routes: [
        GoRoute(
          path: '/delete-account',
          builder: (context, route) => const DeleteAccountScreen(),
        ),
        GoRoute(
          path: '/age',
          builder: (context, route) => const AgeScreen(),
        ),
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

/// Where to go after the age or welcome screen: the remembered in-app location,
/// or the course map. Only plain in-app paths are accepted.
String safeReturnLocation(String? from) {
  if (from == null ||
      !from.startsWith('/') ||
      from.startsWith('//') ||
      from.startsWith('/welcome') ||
      from == '/age' ||
      from.startsWith('/age?')) {
    return '/learn';
  }
  return from;
}
