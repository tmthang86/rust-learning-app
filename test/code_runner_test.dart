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
    expect(r1.stderr, 'code is empty');

    final offline = HttpCodeRunner(base, client: MockClient((_) async {
      throw http.ClientException('no network');
    }));
    final r2 = await offline.run('fn main() {}');
    expect(r2.stage, RunStage.unavailable);
    expect(r2.stderr, contains("Couldn't reach"));
  });
}
