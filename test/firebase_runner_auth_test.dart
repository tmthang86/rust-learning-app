import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/runner/code_runner.dart';
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

  test('the default wait leaves room for a retry inside one run', () {
    // Two token waits (the second after a 401) plus the server's longest
    // answer (about 10 s in the queue and 20 s for the job) must stay under
    // the whole-run limit, or the app's own message never shows.
    final wait = FirebaseRunnerAuth().timeout;
    expect(wait, const Duration(seconds: 5));
    expect(
      wait * 2 + const Duration(seconds: 30),
      lessThan(HttpCodeRunner.requestTimeout),
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
