import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../data/models.dart';

class RemoteProgress {
  const RemoteProgress({
    this.track,
    this.completed = const {},
    this.needsRepair = false,
  });

  final Track? track;
  final Set<String> completed;

  /// The stored document breaks firestore.rules (a field with the wrong
  /// type, or a field that isn't allowed). The rules check the whole
  /// document on every write, so even a valid merge write would be refused
  /// until the document is rewritten with [ProgressSync.replace].
  ///
  /// Only ever set from a server read with no pending writes: a cached or
  /// half-written snapshot is out of date, and rewriting the document from
  /// it would remove lessons another device added.
  final bool needsRepair;

  static const fields = {'track', 'completedLessons', 'updatedAt'};

  /// Reads a `users/{uid}` document without trusting its shape.
  ///
  /// A field with the wrong type (written by an old build, by hand in the
  /// console, ...) is treated as missing instead of failing the whole sync.
  ///
  /// [confirmed] says the snapshot came from the server with no pending
  /// local writes; only then can it ask for a repair.
  ///
  /// `updatedAt` isn't checked: while a write is waiting for the server,
  /// Firestore shows its server timestamp as null, and every write sets a
  /// fresh value anyway (the rules check only the new one).
  factory RemoteProgress.fromMap(
    Map<String, dynamic>? data, {
    bool confirmed = true,
  }) {
    final d = data ?? const <String, dynamic>{};
    final track = d['track'];
    final completed = d['completedLessons'];
    final parsedTrack = track is String ? Track.fromName(track) : null;
    final repair =
        d.keys.any((k) => !fields.contains(k)) ||
        (d.containsKey('track') && parsedTrack == null) ||
        (d.containsKey('completedLessons') &&
            (completed is! List || completed.any((e) => e is! String)));
    return RemoteProgress(
      track: parsedTrack,
      completed: completed is List
          ? completed.whereType<String>().where((id) => id.isNotEmpty).toSet()
          : const {},
      needsRepair: repair && confirmed,
    );
  }
}

/// Stores a signed-in learner's progress in the cloud.
///
/// Completed lessons are only ever added, never removed, so two devices
/// syncing at the same time can't undo each other's progress.
/// The cloud couldn't be reached (offline, or the server timed out).
class SyncUnavailable implements Exception {
  const SyncUnavailable([this.cause]);
  final Object? cause;
  @override
  String toString() => 'SyncUnavailable($cause)';
}

abstract class ProgressSync {
  /// With [fromServer], fails with [SyncUnavailable] when offline instead
  /// of reading a cached copy.
  Future<RemoteProgress> load(String uid, {bool fromServer = false});
  Future<void> addCompleted(String uid, Iterable<String> lessonIds);
  Future<void> setTrack(String uid, Track track);

  /// Rewrites the whole document in one write. Used to repair a document
  /// that firestore.rules would otherwise refuse to update, and to put
  /// progress back after a failed account deletion.
  Future<void> replace(
    String uid, {
    Track? track,
    required Set<String> completed,
  });

  /// Removes everything stored for [uid] (account deletion).
  Future<void> deleteAll(String uid);

  /// Whether every change made so far reached the server within [timeout].
  Future<bool> flush(Duration timeout);
}

/// Firestore layout: `users/{uid}` with `track`, `completedLessons` and
/// `updatedAt`. firestore.rules limits each user to their own document and
/// to exactly these fields.
class FirestoreProgressSync implements ProgressSync {
  FirestoreProgressSync([FirebaseFirestore? db])
    : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid);

  static bool _confirmed(DocumentSnapshot<Map<String, dynamic>> snap) =>
      !snap.metadata.isFromCache && !snap.metadata.hasPendingWrites;

  static bool _offline(FirebaseException e) =>
      e.code == 'unavailable' || e.code == 'deadline-exceeded';

  @override
  Future<RemoteProgress> load(String uid, {bool fromServer = false}) async {
    final DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      snap = await _doc(uid)
          .get(fromServer ? const GetOptions(source: Source.server) : null);
    } on FirebaseException catch (e) {
      if (_offline(e)) throw SyncUnavailable(e);
      rethrow;
    }
    final progress = RemoteProgress.fromMap(
      snap.data(),
      confirmed: _confirmed(snap),
    );
    final looksBroken = RemoteProgress.fromMap(snap.data()).needsRepair;
    if (!looksBroken || progress.needsRepair || fromServer) return progress;

    // The cached copy looks broken. Check the server before repairing; if
    // that isn't possible now, merge as usual (a refused write shows as a
    // sync problem and the next sync tries again).
    try {
      final fresh = await _doc(uid)
          .get(const GetOptions(source: Source.server));
      return RemoteProgress.fromMap(fresh.data(), confirmed: _confirmed(fresh));
    } catch (_) {
      return progress;
    }
  }

  @override
  Future<void> addCompleted(String uid, Iterable<String> lessonIds) => _doc(uid)
      .set({
        'completedLessons': FieldValue.arrayUnion(lessonIds.toList()),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  @override
  Future<void> setTrack(String uid, Track track) => _doc(uid).set({
    'track': track.name,
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  @override
  Future<void> replace(
    String uid, {
    Track? track,
    required Set<String> completed,
  }) =>
      // No merge: fields that aren't listed here are removed.
      _doc(uid).set({
        if (track != null) 'track': track.name,
        'completedLessons': completed.toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  @override
  Future<void> deleteAll(String uid) async {
    try {
      await _doc(uid).delete();
    } on FirebaseException catch (e) {
      if (_offline(e)) throw SyncUnavailable(e);
      rethrow;
    }
  }

  @override
  Future<bool> flush(Duration timeout) async {
    try {
      await _db.waitForPendingWrites().timeout(timeout);
      return true;
    } catch (_) {
      return false;
    }
  }
}
