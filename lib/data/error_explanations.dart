import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How to recognise one compiler error in rustc's output, from
/// assets/content/errors/index.json.
class ErrorRule {
  const ErrorRule({
    required this.key,
    this.code,
    this.match,
    this.lessons = const [],
  });

  /// The code ("E0382") or, for errors without a code, the entry id.
  final String key;

  /// Set for errors rustc gives a code to.
  final String? code;

  /// For errors without a code: a substring of rustc's `error: ...` line.
  final String? match;

  /// Lessons that teach the idea behind the error.
  final List<String> lessons;

  /// Null when [json] isn't a usable entry.
  static ErrorRule? tryParse(Object? json) {
    if (json is! Map) return null;
    final code = json['code'];
    final id = json['id'];
    final match = json['match'];
    final lessons = json['lessons'];
    final ok = code is String
        ? RegExp(r'^E\d{4}$').hasMatch(code)
        : id is String && id.isNotEmpty && match is String && match.isNotEmpty;
    if (!ok) return null;
    return ErrorRule(
      key: code is String ? code : id as String,
      code: code is String ? code : null,
      match: code is String ? null : match as String,
      lessons: lessons is List
          ? lessons.whereType<String>().toList()
          : const [],
    );
  }
}

/// The words shown for one error, from assets/content/errors/`<lang>`.json.
class ErrorText {
  const ErrorText({
    required this.title,
    required this.explanation,
    required this.fixes,
  });

  final String title;
  final String explanation;
  final List<String> fixes;

  /// Null when [json] isn't a usable entry.
  static ErrorText? tryParse(Object? json) {
    if (json is! Map) return null;
    final title = json['title'];
    final explanation = json['explanation'];
    final fixes = json['fixes'];
    if (title is! String || explanation is! String) return null;
    return ErrorText(
      title: title,
      explanation: explanation,
      fixes: fixes is List ? fixes.whereType<String>().toList() : const [],
    );
  }
}

/// What to show for one error found in a compile failure.
class ErrorHelp {
  const ErrorHelp({required this.key, this.rule, this.text});

  final String key;

  /// Null for a code the index doesn't know.
  final ErrorRule? rule;

  /// Null when no language has words for it.
  final ErrorText? text;

  String? get code => rule?.code ?? (_codePattern.hasMatch(key) ? key : null);

  /// The official page, for errors that have a code.
  String? get officialUrl => code == null ? null : officialErrorUrl(code!);

  List<String> get lessons => rule?.lessons ?? const [];
}

final _codePattern = RegExp(r'^E\d{4}$');

/// The official explanation of an error code (also printed offline by
/// `rustc --explain`).
String officialErrorUrl(String code) =>
    'https://doc.rust-lang.org/error_codes/$code.html';

/// Most explanations shown for one failed run; the first errors matter most.
const maxErrorCards = 3;

final _errorCodeLine = RegExp(r'^error\[(E\d{4})\]');

/// Keys of the errors in rustc's [stderr], in order of first appearance,
/// without repeats, at most [maxErrorCards].
///
/// A key is a code from an `error[E0382]: ...` line, or the key of a
/// codeless rule whose `match` text is in an `error: ...` line. Warnings and
/// rustc's closing summary lines are ignored.
List<String> findErrorKeys(String stderr, List<ErrorRule> rules) {
  final codeless = rules.where((r) => r.match != null).toList();
  final keys = <String>[];
  for (final line in const LineSplitter().convert(stderr)) {
    String? key;
    final code = _errorCodeLine.firstMatch(line);
    if (code != null) {
      key = code.group(1);
    } else if (line.startsWith('error:') &&
        !line.startsWith('error: aborting due to')) {
      for (final r in codeless) {
        if (line.contains(r.match!)) {
          key = r.key;
          break;
        }
      }
    }
    if (key != null && !keys.contains(key)) {
      keys.add(key);
      if (keys.length == maxErrorCards) break;
    }
  }
  return keys;
}

/// Loads the error explanations bundled under assets/content/errors/.
///
/// Nothing here throws: a missing or broken file is logged and treated as
/// empty, so a content mistake never breaks running code.
class ErrorExplanationRepository {
  ErrorExplanationRepository({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  Future<List<ErrorRule>>? _rules;
  final Map<String, Future<Map<String, ErrorText>>> _texts = {};

  Future<List<ErrorRule>> rules() => _rules ??= _loadRules();

  Future<List<ErrorRule>> _loadRules() async {
    final json = await _loadJson('assets/content/errors/index.json');
    if (json is! List) {
      if (json != null) debugPrint('errors/index.json is not a list');
      return const [];
    }
    final rules = <ErrorRule>[];
    for (final entry in json) {
      final rule = ErrorRule.tryParse(entry);
      if (rule == null) {
        debugPrint('errors/index.json: skipped a bad entry');
      } else {
        rules.add(rule);
      }
    }
    return rules;
  }

  Future<Map<String, ErrorText>> _loadTexts(String lang) =>
      _texts[lang] ??= _readTexts(lang);

  Future<Map<String, ErrorText>> _readTexts(String lang) async {
    final json = await _loadJson('assets/content/errors/$lang.json');
    if (json is! Map) {
      if (json != null) debugPrint('errors/$lang.json is not a map');
      return const {};
    }
    final texts = <String, ErrorText>{};
    for (final e in json.entries) {
      final text = ErrorText.tryParse(e.value);
      if (e.key is String && text != null) {
        texts[e.key as String] = text;
      } else {
        debugPrint('errors/$lang.json: skipped bad entry ${e.key}');
      }
    }
    return texts;
  }

  /// The decoded file, or null when it is missing or not JSON.
  Future<Object?> _loadJson(String path) async {
    try {
      return jsonDecode(await _bundle.loadString(path));
    } catch (e) {
      debugPrint('Could not load $path: $e');
      return null;
    }
  }

  /// Help for each error in [stderr], in the language [lang] ("en", "vi");
  /// entries that language lacks come in English.
  Future<List<ErrorHelp>> explain(String stderr, {String lang = 'en'}) async {
    final known = await rules();
    final keys = findErrorKeys(stderr, known);
    if (keys.isEmpty) return const [];
    final english = await _loadTexts('en');
    final local = lang == 'en' ? english : await _loadTexts(lang);
    final help = <ErrorHelp>[];
    for (final key in keys) {
      final rule = known.where((r) => r.key == key).firstOrNull;
      final h = ErrorHelp(
        key: key,
        rule: rule,
        text: local[key] ?? english[key],
      );
      // A codeless error with no words has nothing to show.
      if (h.text != null || h.code != null) help.add(h);
    }
    return help;
  }
}
