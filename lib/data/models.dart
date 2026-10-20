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
