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
  const LessonRef({
    required this.id,
    required this.title,
    this.checkpoint = false,
  });

  final String id;
  final String title;

  /// True for a unit's end-of-unit challenge (`"checkpoint": true` in
  /// course.json). It is a normal lesson otherwise: same id rules, same
  /// completion tracking and counts.
  final bool checkpoint;

  factory LessonRef.fromJson(Map<String, dynamic> json) => LessonRef(
        id: json['id'] as String,
        title: json['title'] as String,
        checkpoint: json['checkpoint'] as bool? ?? false,
      );
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

  /// This course with the unit titles and summaries and the lesson titles
  /// of [translated], matched by id. Structure (units, lessons, tracks,
  /// order) always comes from this course; ids [translated] doesn't have
  /// keep their own texts.
  Course withTextsFrom(Course translated) {
    final byUnit = {for (final u in translated.units) u.id: u};
    return Course([
      for (final unit in units)
        if (byUnit[unit.id] case final t?)
          Unit(
            id: unit.id,
            number: unit.number,
            title: t.title,
            summary: t.summary,
            tracks: unit.tracks,
            lessons: [
              for (final lesson in unit.lessons)
                LessonRef(
                  id: lesson.id,
                  checkpoint: lesson.checkpoint,
                  title:
                      t.lessons
                          .where((l) => l.id == lesson.id)
                          .firstOrNull
                          ?.title ??
                      lesson.title,
                ),
            ],
          )
        else
          unit,
    ]);
  }

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
    final label = json['label'];
    final panics = json['panics'];
    if ((label != null && label is! String) ||
        (panics != null && panics is! String)) {
      throw FormatException('test "$id" has a "label" or "panics" that is not text');
    }
    return ExerciseTest(
      id: id,
      label: label as String?,
      hidden: json['hidden'] == true,
      code: code is String ? code : null,
      panics: panics as String?,
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
    if (tests != null && tests is! List) {
      throw const FormatException('"tests" is not a list');
    }
    final declared = tests == null
        ? const <ExerciseTest>[]
        : [
            for (final t in tests as List)
              if (t is Map<String, dynamic>)
                ExerciseTest.fromJson(t)
              else
                throw const FormatException('a test is not an object'),
          ];
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
    this.explanation = '',
  });

  final String question;
  final List<String> options;
  final int answer;

  /// Why the right answer is right (and the others are not), shown after
  /// Check. Empty when the lesson has none (old content).
  final String explanation;

  factory QuizQuestion.fromJson(Map<String, dynamic> json) => QuizQuestion(
        question: json['question'] as String,
        options: (json['options'] as List).cast<String>(),
        answer: json['answer'] as int,
        explanation: (json['explanation'] as String?)?.trim() ?? '',
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

  /// True when [other] differs from this lesson in texts only: the same
  /// id, sections (types, tracks, code), exercise (starter, expected
  /// output, solution) and quiz (number of options, right answer). A
  /// translation must be this close to the English lesson to be used, so
  /// completing it, checking the exercise and scoring the quiz work the
  /// same in every language.
  /// Tests match when everything but the translated `label` is equal.
  static bool _sameTests(List<ExerciseTest> a, List<ExerciseTest> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.id != y.id ||
          x.hidden != y.hidden ||
          x.code != y.code ||
          x.panics != y.panics ||
          x.output != y.output) {
        return false;
      }
    }
    return true;
  }

  bool hasSameStructureAs(Lesson other) {
    if (id != other.id || sections.length != other.sections.length) {
      return false;
    }
    for (var i = 0; i < sections.length; i++) {
      final a = sections[i], b = other.sections[i];
      if (a.type != b.type || a.track != b.track) return false;
      if (a.type == SectionType.code && a.body != b.body) return false;
    }
    final e = exercise, f = other.exercise;
    if ((e == null) != (f == null)) return false;
    if (e != null &&
        f != null &&
        (e.hints.length != f.hints.length ||
            e.starter != f.starter ||
            e.expectedOutput != f.expectedOutput ||
            e.solution != f.solution ||
            !_sameTests(e.declaredTests, f.declaredTests))) {
      return false;
    }
    if (quiz.length != other.quiz.length) return false;
    for (var i = 0; i < quiz.length; i++) {
      if (quiz[i].answer != other.quiz[i].answer ||
          quiz[i].options.length != other.quiz[i].options.length) {
        return false;
      }
    }
    return true;
  }

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
