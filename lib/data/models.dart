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

class Exercise {
  const Exercise({
    required this.prompt,
    required this.starter,
    required this.expectedOutput,
    this.solution,
  });

  final String prompt;
  final String starter;
  final String expectedOutput;

  /// A reference answer, checked by tool/check_lessons.py.
  final String? solution;

  factory Exercise.fromJson(Map<String, dynamic> json) => Exercise(
        prompt: json['prompt'] as String,
        starter: json['starter'] as String,
        expectedOutput: json['expectedOutput'] as String,
        solution: json['solution'] as String?,
      );
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

  /// True when [other] differs from this lesson in texts only: the same
  /// id, sections (types, tracks, code), exercise (starter, expected
  /// output, solution) and quiz (number of options, right answer). A
  /// translation must be this close to the English lesson to be used, so
  /// completing it, checking the exercise and scoring the quiz work the
  /// same in every language.
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
        (e.starter != f.starter ||
            e.expectedOutput != f.expectedOutput ||
            e.solution != f.solution)) {
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
