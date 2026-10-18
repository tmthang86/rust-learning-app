import 'package:cloud_firestore/cloud_firestore.dart';

import '../data/models.dart';

class RemoteProgress {
  const RemoteProgress({this.track, this.completed = const {}});

  final Track? track;
  final Set<String> completed;

  /// Reads a `users/{uid}` document without trusting its shape.
  ///
  /// A field with the wrong type (written by an old build, by hand in the
  /// console, ...) is treated as missing instead of failing the whole sync.
  /// The next write then repairs it: `arrayUnion` replaces a non-array field
  /// with an array, and `setTrack` overwrites a bad track.
  factory RemoteProgress.fromMap(Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    final track = d['track'];
    final completed = d['completedLessons'];
    return RemoteProgress(
      track: track is String ? Track.fromName(track) : null,
      completed: completed is List
          ? completed.whereType<String>().where((id) => id.isNotEmpty).toSet()
          : const {},
    );
  }
}

/// Stores a signed-in learner's progress in the cloud.
///
/// Completed lessons are only ever added, never removed, so two devices
/// syncing at the same time can't undo each other's progress.
abstract class ProgressSync {
  Future<RemoteProgress> load(String uid);
  Future<void> addCompleted(String uid, Iterable<String> lessonIds);
  Future<void> setTrack(String uid, Track track);

  /// Removes everything stored for [uid] (account deletion).
  Future<void> deleteAll(String uid);
}

/// Firestore layout: `users/{uid}` with `track`, `completedLessons` and
/// `updatedAt`. firestore.rules limits each user to their own document and
/// to exactly these fields.
class FirestoreProgressSync implements ProgressSync {
  FirestoreProgressSync([FirebaseFirestore? db]) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid);

  @override
  Future<RemoteProgress> load(String uid) async =>
      RemoteProgress.fromMap((await _doc(uid).get()).data());

  @override
  Future<void> addCompleted(String uid, Iterable<String> lessonIds) => _doc(uid).set({
        'completedLessons': FieldValue.arrayUnion(lessonIds.toList()),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  @override
  Future<void> setTrack(String uid, Track track) => _doc(uid).set({
        'track': track.name,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  @override
  Future<void> deleteAll(String uid) => _doc(uid).delete();
}
