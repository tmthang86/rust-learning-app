/// Which entry path a learner chose on first launch.
enum Track {
  /// New to programming: starts at Unit 0 and sees extra explanations.
  starter,

  /// Knows another language: skips Unit 0 and sees "coming from X" notes.
  fast;

  static Track? fromName(String? name) {
    for (final t in Track.values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

class LessonRef {
  const LessonRef({required this.id, required this.title});

  final String id;
  final String title;

  factory LessonRef.fromJson(Map<String, dynamic> json) =>
      LessonRef(id: json['id'] as String, title: json['title'] as String);
}

class Unit {
  const Unit({
    required this.id,
    required this.number,
    required this.title,
    required this.summary,
    required this.tracks,
    required this.lessons,
  });

  final String id;
  final int number;
  final String title;
  final String summary;
  final Set<Track> tracks;
  final List<LessonRef> lessons;

  bool get comingSoon => lessons.isEmpty;

  factory Unit.fromJson(Map<String, dynamic> json) => Unit(
        id: json['id'] as String,
        number: json['number'] as int,
        title: json['title'] as String,
        summary: json['summary'] as String,
        tracks: (json['tracks'] as List)
            .map((t) => Track.fromName(t as String))
            .whereType<Track>()
            .toSet(),
        lessons: (json['lessons'] as List)
            .map((l) => LessonRef.fromJson(l as Map<String, dynamic>))
            .toList(),
      );
}

class Course {
  const Course(this.units);

  final List<Unit> units;

  /// The title of lesson [id] among the units [track] sees, or null when
  /// there is no such lesson there.
  String? lessonTitle(String id, {Track? track}) {
    for (final u in track == null ? units : unitsFor(track)) {
      for (final l in u.lessons) {
        if (l.id == id) return l.title;
      }
    }
    return null;
  }

  List<Unit> unitsFor(Track track) =>
      units.where((u) => u.tracks.contains(track)).toList();

  factory Course.fromJson(Map<String, dynamic> json) => Course(
        (json['units'] as List)
            .map((u) => Unit.fromJson(u as Map<String, dynamic>))
            .toList(),
      );
}

enum SectionType { text, code, note }

class LessonSection {
  const LessonSection({required this.type, required this.body, this.track});

  final SectionType type;
  final String body;

  /// When set, the section is only shown to learners on this track.
  final Track? track;

  bool visibleTo(Track learnerTrack) => track == null || track == learnerTrack;

  factory LessonSection.fromJson(Map<String, dynamic> json) {
    final type = SectionType.values.byName(json['type'] as String);
    return LessonSection(
      type: type,
      body: (type == SectionType.code ? json['code'] : json['text']) as String,
      track: Track.fromName(json['track'] as String?),
    );
  }
}

/// One test of an exercise. A **code test** ([code]) is a few Rust
/// statements run inside the learner's crate; an **output test** ([output])
/// compares what `main` prints. Hidden tests are shown only as a count in
/// the UI (they still ship with the app: hidden, not secret).
class ExerciseTest {
  const ExerciseTest({
    required this.id,
    this.label,
    this.hidden = false,
    this.code,
    this.panics,
    this.output,
  });

  /// `^[a-z0-9][a-z0-9-]{0,39}$`, unique in the exercise. Not shown.
  final String id;

  /// What the test checks, in words. Required (and translated) on visible
  /// tests; on hidden ones a note for reviewers that is never shown.
  final String? label;
  final bool hidden;

  /// Rust statements, the body of a `fn()`. Null for an output test.
  final String? code;

  /// With [code]: the test passes only if the code panics with a message
  /// containing this text (empty = any panic).
  final String? panics;

  /// The expected stdout of `main`. Null for a code test.
  final String? output;

  bool get isOutput => output != null;

  /// The id the legacy `expectedOutput` is graded under.
  static const legacyId = 'output';

  /// A lesson with only `expectedOutput`: one output test.
  factory ExerciseTest.legacy(String expectedOutput) =>
      ExerciseTest(id: legacyId, output: expectedOutput);

  /// Throws [FormatException] when [json] isn't a test.
  factory ExerciseTest.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final code = json['code'];
    final output = json['output'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('a test needs an "id"');
    }
    if ((code is String) == (output is String)) {
      throw FormatException('test "$id" needs exactly one of code and output');
    }
    return ExerciseTest(
      id: id,
      label: json['label'] as String?,
      hidden: json['hidden'] == true,
      code: code is String ? code : null,
      panics: json['panics'] as String?,
      output: output is String ? output : null,
    );
  }

  /// What the runner is sent: no label and no `hidden`.
  Map<String, Object> toRequestJson() => {
        'id': id,
        'code': ?code,
        'panics': ?panics,
        'output': ?output,
      };
}

class Exercise {
  const Exercise({
    required this.prompt,
    required this.starter,
    this.expectedOutput,
    this.declaredTests = const [],
    this.solution,
    this.hints = const [],
  });

  final String prompt;
  final String starter;

  /// Legacy: the output `main` must print. Only present when the exercise
  /// has no `tests`; graded as one output test.
  final String? expectedOutput;

  /// The `tests` of the lesson file (empty for a legacy exercise).
  final List<ExerciseTest> declaredTests;

  /// A reference answer, checked by tool/check_lessons.py.
  final String? solution;

  /// Up to three nudges, shown one at a time, from general to concrete.
  final List<String> hints;

  /// What grades the exercise: its tests, or the legacy single output test.
  List<ExerciseTest> get tests => declaredTests.isNotEmpty
      ? declaredTests
      : [ExerciseTest.legacy(expectedOutput ?? '')];

  /// Throws [FormatException] when there is neither `tests` nor
  /// `expectedOutput`.
  factory Exercise.fromJson(Map<String, dynamic> json) {
    final tests = json['tests'];
    final expected = json['expectedOutput'];
    if (tests == null && expected is! String) {
      throw const FormatException(
        'an exercise needs "tests" or "expectedOutput"',
      );
    }
    final declared = tests == null
        ? const <ExerciseTest>[]
        : (tests as List)
            .map((t) => ExerciseTest.fromJson(t as Map<String, dynamic>))
            .toList();
    if (tests != null && declared.isEmpty) {
      throw const FormatException('"tests" is empty');
    }
    return Exercise(
      prompt: json['prompt'] as String,
      starter: json['starter'] as String,
      expectedOutput: tests == null ? expected as String : null,
      declaredTests: declared,
      solution: json['solution'] as String?,
      hints: ((json['hints'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
    );
  }
}

class QuizQuestion {
  const QuizQuestion({
    required this.question,
    required this.options,
    required this.answer,
  });

  final String question;
  final List<String> options;
  final int answer;

  factory QuizQuestion.fromJson(Map<String, dynamic> json) => QuizQuestion(
        question: json['question'] as String,
        options: (json['options'] as List).cast<String>(),
        answer: json['answer'] as int,
      );
}

class Lesson {
  const Lesson({
    required this.id,
    required this.title,
    required this.sections,
    this.exercise,
    this.quiz = const [],
  });

  final String id;
  final String title;
  final List<LessonSection> sections;
  final Exercise? exercise;
  final List<QuizQuestion> quiz;

  factory Lesson.fromJson(Map<String, dynamic> json) => Lesson(
        id: json['id'] as String,
        title: json['title'] as String,
        sections: (json['sections'] as List)
            .map((s) => LessonSection.fromJson(s as Map<String, dynamic>))
            .toList(),
        exercise: json['exercise'] == null
            ? null
            : Exercise.fromJson(json['exercise'] as Map<String, dynamic>),
        quiz: ((json['quiz'] as List?) ?? const [])
            .map((q) => QuizQuestion.fromJson(q as Map<String, dynamic>))
            .toList(),
      );
}
