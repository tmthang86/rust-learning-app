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
}
