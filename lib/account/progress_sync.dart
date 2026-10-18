import 'package:cloud_firestore/cloud_firestore.dart';

import '../data/models.dart';

class RemoteProgress {
  const RemoteProgress({this.track, this.completed = const {}});

  final Track? track;
  final Set<String> completed;
}

/// Stores a signed-in learner's progress in the cloud.
///
/// Completed lessons are only ever added, never removed, so two devices
/// syncing at the same time can't undo each other's progress.
abstract class ProgressSync {
  Future<RemoteProgress> load(String uid);
  Future<void> addCompleted(String uid, Iterable<String> lessonIds);
  Future<void> setTrack(String uid, Track track);
}

/// Firestore layout: `users/{uid}` with `track`, `completedLessons` and
/// `updatedAt`. firestore.rules limits each user to their own document.
class FirestoreProgressSync implements ProgressSync {
  FirestoreProgressSync([FirebaseFirestore? db]) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid);

  @override
  Future<RemoteProgress> load(String uid) async {
    final data = (await _doc(uid).get()).data() ?? const {};
    return RemoteProgress(
      track: Track.fromName(data['track'] as String?),
      completed: ((data['completedLessons'] as List?) ?? const []).cast<String>().toSet(),
    );
  }

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
}
