import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rust_learn/runner/code_runner.dart';

void main() {
  final base = Uri.parse('https://runner.example/');

  test('sends code and parses a successful run', () async {
    late http.Request sent;
    final runner = HttpCodeRunner(base, client: MockClient((req) async {
      sent = req;
      return http.Response(
        jsonEncode({
          'success': true,
          'stage': 'run',
          'stdout': 'Hello, Rust!\n',
          'stderr': '',
          'durationMs': 420,
        }),
        200,
      );
    }));

    final result = await runner.run('fn main() {}');

    expect(sent.url.toString(), 'https://runner.example/run');
    expect(jsonDecode(sent.body), {'code': 'fn main() {}'});
    expect(result.success, isTrue);
    expect(result.stage, RunStage.run);
    expect(result.stdout, 'Hello, Rust!\n');
  });

  test('parses compile errors', () async {
    final runner = HttpCodeRunner(base, client: MockClient((_) async {
      return http.Response(
        jsonEncode({
          'success': false,
          'stage': 'compile',
          'stdout': '',
          'stderr': 'error[E0308]: mismatched types',
        }),
        200,
      );
    }));

    final result = await runner.run('bad');
    expect(result.stage, RunStage.compile);
    expect(result.stderr, contains('mismatched types'));
  });

  test('reports server errors and network failures as unavailable', () async {
    final badRequest = HttpCodeRunner(base, client: MockClient((_) async {
      return http.Response(jsonEncode({'error': 'code is empty'}), 400);
    }));
    final r1 = await badRequest.run(' ');
    expect(r1.stage, RunStage.unavailable);
    expect(r1.stderr, contains('no code to run'));

    final other = await HttpCodeRunner(base, client: MockClient((_) async {
      return http.Response(jsonEncode({'error': 'invalid JSON body'}), 400);
    })).run('x');
    expect(other.stderr, 'invalid JSON body');

    final offline = HttpCodeRunner(base, client: MockClient((_) async {
      throw http.ClientException('no network');
    }));
    final r2 = await offline.run('fn main() {}');
    expect(r2.stage, RunStage.unavailable);
    expect(r2.stderr, contains("Couldn't reach"));
  });

  HttpCodeRunner answering(http.Response response) =>
      HttpCodeRunner(base, client: MockClient((_) async => response));

  test('parses compiler warnings apart from the program output', () async {
    final result = await answering(http.Response(
      jsonEncode({
        'success': true,
        'stage': 'run',
        'stdout': 'hi\n',
        'stderr': 'debug line\n',
        'warnings': 'warning: unused variable: `x`',
      }),
      200,
    )).run('fn main() {}');
    expect(result.stdout, 'hi\n');
    expect(result.stderr, 'debug line\n');
    expect(result.warnings, contains('unused variable'));

    // Older runners send no warnings field.
    final old = await answering(http.Response(
      jsonEncode({'success': true, 'stage': 'run', 'stdout': 'hi'}),
      200,
    )).run('fn main() {}');
    expect(old.warnings, isEmpty);
  });

  test('a non-JSON 502 from a proxy is not reported as a network failure', () async {
    final html = await answering(
      http.Response('<html><body>502 Bad Gateway</body></html>', 502),
    ).run('fn main() {}');
    expect(html.stage, RunStage.unavailable);
    expect(html.stderr, contains('error 502'));
    expect(html.stderr, isNot(contains("Couldn't reach")));

    final text = await answering(http.Response('upstream connect error', 502))
        .run('fn main() {}');
    expect(text.stderr, 'upstream connect error');
  });

  test('413 says the code is too long', () async {
    final r = await answering(http.Response('Payload Too Large', 413)).run('x');
    expect(r.stage, RunStage.unavailable);
    expect(r.stderr, contains('too long'));
  });

  test('503 and 429 say the runner is busy, using Retry-After', () async {
    final busy = await answering(http.Response(
      jsonEncode({'error': 'server busy'}),
      503,
      headers: {'retry-after': '5'},
    )).run('x');
    expect(busy.stage, RunStage.unavailable);
    expect(busy.stderr, 'The code runner is busy. Try again in 5 seconds.');

    final limited = await answering(
      http.Response(jsonEncode({'error': 'rate limited'}), 429),
    ).run('x');
    expect(limited.stderr, 'The code runner is busy. Try again shortly.');
  });

  test('a 200 that is not a run result is reported, not thrown', () async {
    final r = await answering(http.Response('<html>login</html>', 200)).run('x');
    expect(r.stage, RunStage.unavailable);
    expect(r.stderr, contains('could not read'));

    final wrongShape = await answering(http.Response('[1, 2]', 200)).run('x');
    expect(wrongShape.stage, RunStage.unavailable);
  });

  test('waits long enough for a queued job (F10)', () {
    expect(HttpCodeRunner.requestTimeout, greaterThanOrEqualTo(const Duration(seconds: 45)));
  });

  group('App Check', () {
    final okBody = jsonEncode({
      'success': true,
      'stage': 'run',
      'stdout': 'hi',
    });
    String errorBody(String code) => jsonEncode({'error': 'x', 'code': code});

    test('sends the token in X-Firebase-AppCheck', () async {
      late http.Request sent;
      final auth = _FakeAuth(['token-1']);
      final runner = HttpCodeRunner(
        base,
        auth: auth,
        client: MockClient((req) async {
          sent = req;
          return http.Response(okBody, 200);
        }),
      );

      final result = await runner.run('fn main() {}');

      expect(result.success, isTrue);
      expect(sent.headers['X-Firebase-AppCheck'], 'token-1');
      expect(sent.headers['content-type'], 'application/json');
      expect(auth.refreshFlags, [false]);
    });

    test('sends no header without a token or with NoRunnerAuth', () async {
      final sent = <http.Request>[];
      http.Client client() => MockClient((req) async {
        sent.add(req);
        return http.Response(okBody, 200);
      });

      await HttpCodeRunner(base, client: client()).run('x');
      await HttpCodeRunner(
        base,
        auth: const NoRunnerAuth(),
        client: client(),
      ).run('x');
      await HttpCodeRunner(
        base,
        auth: _FakeAuth([null]),
        client: client(),
      ).run('x');

      expect(sent, hasLength(3));
      for (final req in sent) {
        expect(
          req.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-firebase-appcheck')),
        );
      }
    });

    test(
      'a bad token is refreshed and the request is sent once more',
      () async {
        final tokens = <String?>[];
        final auth = _FakeAuth(['stale', 'fresh']);
        final runner = HttpCodeRunner(
          base,
          auth: auth,
          client: MockClient((req) async {
            final token = req.headers['X-Firebase-AppCheck'];
            tokens.add(token);
            return token == 'fresh'
                ? http.Response(okBody, 200)
                : http.Response(errorBody('app_check_invalid'), 401);
          }),
        );

        final result = await runner.run('x');

        expect(result.success, isTrue);
        expect(tokens, ['stale', 'fresh']);
        expect(auth.refreshFlags, [false, true]);
      },
    );

    test('a missing token is fetched again if one is available now', () async {
      final tokens = <String?>[];
      final auth = _FakeAuth([null, 'late']);
      final runner = HttpCodeRunner(
        base,
        auth: auth,
        client: MockClient((req) async {
          final token = req.headers['X-Firebase-AppCheck'];
          tokens.add(token);
          return token == null
              ? http.Response(errorBody('app_check_missing'), 401)
              : http.Response(okBody, 200);
        }),
      );

      expect((await runner.run('x')).success, isTrue);
      expect(tokens, [null, 'late']);
    });

    test('a missing token that stays missing is not retried', () async {
      var requests = 0;
      final auth = _FakeAuth([null, null]);
      final runner = HttpCodeRunner(
        base,
        auth: auth,
        client: MockClient((_) async {
          requests++;
          return http.Response(errorBody('app_check_missing'), 401);
        }),
      );

      final result = await runner.run('x');

      expect(requests, 1);
      expect(result.stage, RunStage.unavailable);
      expect(result.stderr, contains("couldn't be verified"));
    });

    test('a second 401 gives the message and no third request', () async {
      var requests = 0;
      final auth = _FakeAuth(['a', 'b', 'c']);
      final runner = HttpCodeRunner(
        base,
        auth: auth,
        client: MockClient((_) async {
          requests++;
          return http.Response(errorBody('app_check_invalid'), 401);
        }),
      );

      final result = await runner.run('x');

      expect(requests, 2);
      expect(auth.refreshFlags, [false, true]);
      expect(result.stage, RunStage.unavailable);
      expect(result.stderr, contains("couldn't be verified"));
      expect(result.stderr, contains('up to date'));
    });

    test('403 and 401 without a known code are not retried', () async {
      var requests = 0;
      final auth = _FakeAuth(['a', 'b']);
      final forbidden = await HttpCodeRunner(
        base,
        auth: auth,
        client: MockClient((_) async {
          requests++;
          return http.Response(errorBody('app_not_allowed'), 403);
        }),
      ).run('x');
      expect(requests, 1);
      expect(
        forbidden.stderr,
        "This version of the app can't run code. Please update the app.",
      );

      requests = 0;
      final proxy401 = await HttpCodeRunner(
        base,
        auth: _FakeAuth(['a', 'b']),
        client: MockClient((_) async {
          requests++;
          return http.Response('Unauthorized', 401);
        }),
      ).run('x');
      expect(requests, 1);
      expect(proxy401.stderr, contains("couldn't be verified"));
    });

    test('429 rate_limited says how long to wait', () async {
      final waits = await answering(
        http.Response(
          errorBody('rate_limited'),
          429,
          headers: {'retry-after': '12'},
        ),
      ).run('x');
      expect(waits.stage, RunStage.unavailable);
      expect(
        waits.stderr,
        "You're running code very quickly. Try again in 12 seconds.",
      );

      final noHeader = await answering(
        http.Response(errorBody('rate_limited'), 429),
      ).run('x');
      expect(
        noHeader.stderr,
        "You're running code very quickly. Try again in a minute.",
      );

      // Nonsense values are ignored.
      for (final bad in ['soon', '0', '-3', '99999']) {
        final r = await answering(
          http.Response(
            errorBody('rate_limited'),
            429,
            headers: {'retry-after': bad},
          ),
        ).run('x');
        expect(r.stderr, endsWith('Try again in a minute.'), reason: bad);
      }
    });

    test('503 busy and auth_unavailable keep the busy message', () async {
      for (final code in ['busy', 'auth_unavailable']) {
        final r = await answering(
          http.Response(errorBody(code), 503, headers: {'retry-after': '5'}),
        ).run('x');
        expect(r.stderr, 'The code runner is busy. Try again in 5 seconds.');
      }
    });

    test('the 45 s budget covers the token fetch and the retry', () async {
      expect(HttpCodeRunner.requestTimeout, const Duration(seconds: 45));
    });
  });
}

/// Hands out the given tokens in order and records how each was asked for.
class _FakeAuth implements RunnerAuth {
  _FakeAuth(this._tokens);

  final List<String?> _tokens;
  final refreshFlags = <bool>[];

  @override
  Future<String?> appCheckToken({bool refresh = false}) async {
    refreshFlags.add(refresh);
    return _tokens.isEmpty ? null : _tokens.removeAt(0);
  }
}
