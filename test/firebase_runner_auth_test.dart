import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/runner/firebase_runner_auth.dart';

void main() {
  test('returns the token and passes the refresh flag on', () async {
    final asked = <bool>[];
    final auth = FirebaseRunnerAuth(
      fetch: (refresh) async {
        asked.add(refresh);
        return 'abc';
      },
    );

    expect(await auth.appCheckToken(), 'abc');
    expect(await auth.appCheckToken(refresh: true), 'abc');
    expect(asked, [false, true]);
  });

  test('returns null when Firebase fails or has no token', () async {
    expect(
      await FirebaseRunnerAuth(fetch: (_) async => throw StateError('boom'))
          .appCheckToken(),
      isNull,
    );
    expect(
      await FirebaseRunnerAuth(fetch: (_) async => null).appCheckToken(),
      isNull,
    );
    expect(
      await FirebaseRunnerAuth(fetch: (_) async => '').appCheckToken(),
      isNull,
    );
  });

  test('gives up on a token that takes too long', () async {
    final never = Completer<String?>();
    final auth = FirebaseRunnerAuth(
      fetch: (_) => never.future,
      timeout: const Duration(milliseconds: 20),
    );

    expect(await auth.appCheckToken(), isNull);
  });
}
