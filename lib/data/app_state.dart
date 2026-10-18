import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_service.dart';
import '../account/progress_sync.dart';
import '../runner/code_runner.dart';
import 'age.dart';
import 'course_repository.dart';
import 'models.dart';

/// App-wide state: the course, the learner's track and their progress.
///
/// Progress is always saved on the device. When the learner is signed in it
/// is also synced to the cloud through [sync].
///
/// Device progress belongs either to nobody (made while signed out and never
/// synced) or to the account it was last synced with ([_syncedUidKey]):
/// - signing in merges nobody's progress into the account;
/// - progress that belongs to another account is dropped and the cloud copy
///   is loaded instead;
/// - signing out (or deleting the account) clears the device, so the next
///   person on a shared device starts fresh.
///
/// Accounts are off for anyone whose birth year says they may be under 13
/// ([accountsAllowed]); see [AgeGroup.allowsAccounts].
class AppState extends ChangeNotifier {
  AppState({
    required this.repository,
    required this.runner,
    required this.prefs,
    this.accounts = const DisabledAccountService(),
    this.sync,
    AgeStore? age,
  }) : age = age ?? AgeStore(prefs) {
    _track = Track.fromName(prefs.getString(_trackKey));
    _completed = (prefs.getStringList(_completedKey) ?? const []).toSet();
    _user = accounts.currentUser;
    _userSub = accounts.userChanges.listen(_onUserChanged);
    this.age.addListener(_onAgeChanged);
    if (_user != null) {
      syncing = accountsAllowed
          ? _mergeWithCloud(_user!)
          : leaveAccountKeepingProgress();
    }
  }

  static const _trackKey = 'track';
  static const _completedKey = 'completedLessons';

  /// The account the device progress was last synced with; absent when the
  /// progress was never synced.
  static const _syncedUidKey = 'syncedUid';

  /// Set when the track was changed on this device and the cloud may not
  /// have that change yet. Without it the cloud's track wins on merge, so
  /// two devices don't keep overwriting each other's choice.
  static const _trackDirtyKey = 'trackDirty';

  /// Set to the uid when deleting that account couldn't be confirmed. The
  /// server may have deleted it while the cached sign-in keeps working for
  /// up to an hour, so nothing is written for that account until a fresh
  /// check says it still exists: a write would recreate users/{uid}, which
  /// the rules then won't let anyone delete.
  static const _unconfirmedKey = 'deletionUnconfirmedUid';

  /// Set to the uid when the app signed a child out of their account (see
  /// [leaveAccountKeepingProgress]), so Progress can offer to delete it.
  static const _childAccountKey = 'childAccountToDelete';

  final CourseRepository repository;
  final CodeRunner runner;
  final SharedPreferences prefs;
  final AccountService accounts;
  final ProgressSync? sync;

  /// The birth year from the age screen.
  final AgeStore age;

  late final StreamSubscription<AccountUser?> _userSub;

  Course? _course;
  Track? _track;
  Set<String> _completed = {};
  AccountUser? _user;
  bool _sawAuthEvent = false;
  bool _syncFailed = false;

  /// Lessons finished while a merge is running; a merge that replaces the
  /// device copy with the cloud's keeps them.
  final Set<String> _finishedDuringMerge = {};
  bool _merging = false;

  /// True while the account is being deleted: no background writes, so
  /// nothing recreates the deleted cloud document.
  bool _deleting = false;

  /// The next sign-out keeps the device's progress (a child leaving their
  /// account, see [leaveAccountKeepingProgress]).
  bool _keepLocalOnSignOut = false;

  /// Changes whenever the person whose progress this is may have changed
  /// (sign-in, sign-out, account deletion, clearing the device). Work that
  /// started under an older value, like a slow code run, must not record
  /// progress.
  int get accountEpoch => _accountEpoch;
  int _accountEpoch = 0;

  /// How long account deletion waits for each server step.
  static const serverTimeout = Duration(seconds: 20);

  /// Bumped on every account change; a merge that started under an older
  /// generation drops its result instead of writing stale progress.
  int _generation = 0;

  /// Completes when the latest sign-in merge has finished.
  Future<void> syncing = Future.value();

  Course? get course => _course;
  Track? get track => _track;
  Set<String> get completedLessons => Set.unmodifiable(_completed);
  AccountUser? get user => _user;

  /// True when the last attempt to sync with the cloud failed.
  bool get syncFailed => _syncFailed;

  /// False when the birth year says the person may be under 13: no sign-in
  /// and no cloud sync, enforced here ([signIn], [_mergeWithCloud],
  /// [_push]). The only exception is signing in to delete an existing
  /// account. True while the age is still unknown.
  bool get accountsAllowed => age.group?.allowsAccounts ?? true;

  /// True after the app signed a child out of an existing account; the
  /// Progress screen then offers to delete that account.
  bool get childAccountToDelete => prefs.getString(_childAccountKey) != null;

  /// Hides the Progress offer to delete an account, for one that no longer
  /// exists (deleted elsewhere), which nothing else would clear.
  Future<void> dismissChildAccountOffer() async {
    await prefs.remove(_childAccountKey);
    notifyListeners();
  }

  /// Signs in. Refused when [accountsAllowed] is false, unless [toDelete]:
  /// signing in only to delete an existing account, which syncs nothing.
  ///
  /// Not async on purpose: the provider's sign-in starts before any await,
  /// so a browser treats its pop-up as a response to the click.
  Future<void> signIn(SignInMethod method, {bool toDelete = false}) {
    if (!accountsAllowed && !toDelete) {
      return Future.error(
        const AccountException(AccountErrorKind.ageRestricted),
      );
    }
    _signInCreatedNoAccount = false;
    final signingIn = accounts.signIn(method);
    if (accountsAllowed) return signingIn.then((_) {});
    return signingIn.then(_afterChildSignIn);
  }

  /// True after a child signed in on /delete-account with a sign-in that
  /// had no account yet: the account it created was deleted at once.
  bool get signInCreatedNoAccount => _signInCreatedNoAccount;
  bool _signInCreatedNoAccount = false;

  /// A child signed in only to delete an account. If that sign-in created
  /// a new one, there was nothing to delete: remove it right away, so no
  /// account is left for a child. (Fresh from signing in, it needs no
  /// second confirmation.)
  Future<void> _afterChildSignIn(SignInResult result) async {
    // Ask the account service, not [_user]: the auth event can arrive
    // after sign-in returns, while the service already has the user.
    final created = accounts.currentUser;
    if (!result.isNewUser || created == null) return;
    _deleting = true;
    _keepLocalOnSignOut = true;
    try {
      await _server(
        accounts.deleteUser(
          ReauthProof(appleAuthorizationCode: result.appleAuthorizationCode),
        ),
      );
      _signInCreatedNoAccount = true;
      // A flag naming this account can never be cleared otherwise.
      if (prefs.getString(_childAccountKey) == created.uid) {
        await prefs.remove(_childAccountKey);
      }
    } catch (e) {
      // Still there: sign out on this device, and Progress offers to
      // delete it.
      debugPrint('Deleting the new account failed: $e');
      _keepLocalOnSignOut = false;
      _deleting = false;
      await leaveAccountKeepingProgress(created);
    } finally {
      _deleting = false;
    }
    notifyListeners();
  }

  void _onAgeChanged() {
    if (!accountsAllowed && _user != null && !_deleting) {
      syncing = leaveAccountKeepingProgress();
    }
    notifyListeners();
  }

  /// For someone who may be under 13 and is signed in (an install from
  /// before the age screen, or after signing in only to delete): stops all
  /// syncing and signs out on this device, keeping the progress here. The
  /// account itself stays until they delete it; Progress offers that.
  ///
  /// Does nothing while a deletion runs: the account is going away, and a
  /// flag naming it could never be cleared. If that deletion fails, it
  /// calls this itself. [known] is the user when the auth event for them
  /// has not arrived yet.
  Future<void> leaveAccountKeepingProgress([AccountUser? known]) async {
    final u = _user ?? known;
    if (u == null || _deleting) return;
    _generation++; // drops any running merge
    _accountEpoch++;
    _merging = false;
    await prefs.setString(_childAccountKey, u.uid);
    // The device copy now belongs to nobody.
    await prefs.remove(_syncedUidKey);
    await prefs.remove(_trackDirtyKey);
    _syncFailed = false;
    _keepLocalOnSignOut = true;
    try {
      await accounts.signOut();
    } catch (e) {
      _keepLocalOnSignOut = false;
      debugPrint('Signing out failed: $e');
    }
    notifyListeners();
  }

  Future<void> load() async {
    _course = await repository.loadCourse();
    notifyListeners();
  }

  Future<void> chooseTrack(Track track) async {
    _track = track;
    await prefs.setString(_trackKey, track.name);
    // A device that never synced (first launch forces a pick before anyone
    // can sign in) must not override an account's track, so only a change
    // made while signed in, or on a device that has synced, counts.
    if (_user != null || prefs.getString(_syncedUidKey) != null) {
      await prefs.setBool(_trackDirtyKey, true);
    }
    notifyListeners();
    _push((s, uid) async {
      await s.setTrack(uid, track);
      if (_track == track && _user?.uid == uid) {
        await prefs.setBool(_trackDirtyKey, false);
      }
    });
  }

  bool isCompleted(String lessonId) => _completed.contains(lessonId);

  Future<void> markCompleted(String lessonId) async {
    final added = _completed.add(lessonId);
    // During a merge the device copy may still be another account's, so a
    // lesson that looks done already is still remembered and sent: the
    // account signing in has just finished it.
    final duringMerge = _user != null && _merging;
    if (duringMerge) _finishedDuringMerge.add(lessonId);
    if (!added && !duringMerge) return;
    if (added) {
      await prefs.setStringList(_completedKey, _completed.toList());
      notifyListeners();
    }
    _push((s, uid) => s.addCompleted(uid, [lessonId]));
  }

  /// Tries the cloud sync again after a failure.
  void retrySync() {
    final u = _user;
    if (u != null) syncing = _mergeWithCloud(u);
  }

  /// Signs out, first making sure this device's progress reached the
  /// account. Returns false, without signing out, when it may not have: the
  /// first sync never finished, a background write failed, or changes are
  /// still waiting to be sent. Signing out clears the device, so the UI
  /// then asks before calling again with [force].
  Future<bool> signOut({bool force = false}) async {
    if (!force && deletionUnconfirmed) {
      final exists = await recheckDeletion();
      if (exists == false) return true; // already cleared and signed out
      if (exists == null) return false; // can't tell: nothing written, ask
    }
    final u = _user;
    final s = sync;
    if (!force && u != null && s != null) {
      if (prefs.getString(_syncedUidKey) != u.uid || _syncFailed) {
        try {
          await (syncing = _mergeWithCloud(
            u,
          )).timeout(const Duration(seconds: 10));
        } on TimeoutException {
          // Treated as not saved below.
        }
      }
      final saved =
          prefs.getString(_syncedUidKey) == u.uid &&
          !_syncFailed &&
          await s.flush(const Duration(seconds: 5));
      if (!saved) return false;
    }
    await accounts.signOut();
    return true;
  }

  void _onUserChanged(AccountUser? user) {
    final firstEvent = !_sawAuthEvent;
    _sawAuthEvent = true;
    final previous = _user;
    _user = user;

    if (user == null && _keepLocalOnSignOut) {
      _keepLocalOnSignOut = false;
      _generation++;
      _accountEpoch++;
      notifyListeners();
      return;
    }

    if (user != null && user.uid == previous?.uid) {
      // Same account (a token refresh, or the first event repeating the
      // user we started with): nothing to merge again.
      notifyListeners();
      return;
    }

    _generation++;
    _accountEpoch++;
    if (user == null) {
      // Signed out now, or found signed out at start while the device still
      // holds an account's progress (the session ended while the app was
      // closed).
      if (previous != null ||
          (firstEvent && prefs.getString(_syncedUidKey) != null)) {
        syncing = _clearLocal();
      } else {
        notifyListeners();
      }
      return;
    }
    notifyListeners();
    // A child signed in only to delete their account: nothing is synced.
    if (accountsAllowed) syncing = _mergeWithCloud(user);
  }

  /// Puts the device back to a fresh state.
  Future<void> _clearLocal() async {
    _accountEpoch++;
    _track = null;
    _completed = {};
    _syncFailed = false;
    notifyListeners();
    await prefs.remove(_trackKey);
    await prefs.remove(_completedKey);
    await prefs.remove(_syncedUidKey);
    await prefs.remove(_trackDirtyKey);
    await prefs.remove(_unconfirmedKey);
    await prefs.remove(_childAccountKey);
  }

  /// True while deleting the signed-in account is unconfirmed; see
  /// [recheckDeletion].
  bool get deletionUnconfirmed {
    final u = _user;
    return u != null && prefs.getString(_unconfirmedKey) == u.uid;
  }

  /// After an unconfirmed deletion, asks the server whether the account
  /// still exists. false: it's gone, so the device is cleared and signed
  /// out locally, with nothing written. true: back to normal syncing.
  /// null: still can't tell; nothing is written and the next sync or
  /// sign-out asks again. Returns true when no deletion is pending.
  Future<bool?> recheckDeletion() async {
    if (!deletionUnconfirmed) return true;
    final exists = await accounts.accountStillExists();
    if (exists == false) {
      await _afterDeletion();
      _keepLocalOnSignOut = !accountsAllowed;
      await accounts.signOut();
      return false;
    }
    if (exists == true) {
      await prefs.remove(_unconfirmedKey);
      notifyListeners();
    }
    return exists;
  }

  /// Combines device and cloud progress so neither side loses anything, as
  /// long as the device progress is this account's or nobody's.
  Future<void> _mergeWithCloud(AccountUser user) async {
    final s = sync;
    if (s == null || _deleting || !accountsAllowed) return;
    // Taken before any wait, so a deletion (or account change) that starts
    // meanwhile makes this merge drop out instead of writing.
    final generation = ++_generation;
    bool stale() =>
        generation != _generation || _user?.uid != user.uid || _deleting;
    if (prefs.getString(_unconfirmedKey) == user.uid) {
      final exists = await recheckDeletion();
      if (stale() || exists == false) return;
      if (exists == null) {
        _markUnsaved();
        return;
      }
    }
    _finishedDuringMerge.clear();
    _merging = true;

    try {
      final remote = await s.load(user.uid);
      if (stale()) return;

      final owner = prefs.getString(_syncedUidKey);
      final Track? finalTrack;
      if (owner != null && owner != user.uid) {
        // Left over from another account: never upload it, take the cloud's.
        // Lessons finished since this sign-in are this account's (they were
        // already sent to it), so they stay.
        _completed = {...remote.completed, ..._finishedDuringMerge};
        _track = finalTrack = remote.track;
        await _saveLocal();
        if (stale()) return;
        if (remote.needsRepair) {
          await s.replace(
            user.uid,
            track: finalTrack,
            completed: {..._completed},
          );
        }
      } else {
        final localOnly = _completed.difference(remote.completed);
        final local = _track;
        final dirty = prefs.getBool(_trackDirtyKey) ?? false;
        final pushTrack = local != null && (dirty || remote.track == null);
        finalTrack = pushTrack ? local : (remote.track ?? local);

        _completed.addAll(remote.completed);
        _track = finalTrack;
        await _saveLocal();
        if (stale()) return;

        if (remote.needsRepair) {
          // One write with everything, so the rules accept it.
          await s.replace(
            user.uid,
            track: finalTrack,
            completed: {..._completed},
          );
        } else {
          if (localOnly.isNotEmpty) await s.addCompleted(user.uid, localOnly);
          if (stale()) return;
          if (pushTrack && local != remote.track) {
            await s.setTrack(user.uid, local);
          }
        }
      }
      if (stale()) return;
      if (_track == finalTrack) await prefs.setBool(_trackDirtyKey, false);
      await prefs.setString(_syncedUidKey, user.uid);
      _syncFailed = false;
      notifyListeners();
    } catch (e) {
      // Offline or misconfigured: keep working from the device copy.
      debugPrint('Progress sync failed: $e');
      if (!stale()) {
        _syncFailed = true;
        notifyListeners();
      }
    } finally {
      if (generation == _generation) _merging = false;
    }
  }

  Future<void> _saveLocal() async {
    await prefs.setStringList(_completedKey, _completed.toList());
    final t = _track;
    if (t == null) {
      await prefs.remove(_trackKey);
    } else {
      await prefs.setString(_trackKey, t.name);
    }
  }

  /// Deletes the signed-in account, its cloud progress and the progress on
  /// this device. Throws [AccountException] if the account wasn't deleted;
  /// the cloud progress is then put back.
  ///
  /// Call it straight from the button press: the first thing it does is
  /// the confirming sign-in, which opens a pop-up on the web.
  Future<void> deleteAccount() async {
    final u = _user;
    if (u == null) throw const AccountException(AccountErrorKind.notSignedIn);
    _deleting = true;
    _accountEpoch++; // A run finishing now must not write progress back.
    try {
      await _deleteAccount(u);
    } catch (_) {
      _deleting = false;
      // Not deleted (cancelled or failed) and still signed in: a merge that
      // ran meanwhile dropped out without saving, so treat the progress as
      // not saved. Signing out then syncs first and asks before clearing.
      if (_user?.uid == u.uid) _markUnsaved();
      rethrow;
    } finally {
      _deleting = false;
    }
  }

  Future<void> _deleteAccount(AccountUser u) async {
    final proof = await accounts.reauthenticate();
    _generation++; // Drop any merge still running for this account.
    _merging = false;
    final s = sync;

    var remote = const RemoteProgress();
    if (s != null) {
      // Read from the server: offline, this fails before anything is
      // deleted. The copy is kept to put back if deleting the account fails.
      remote = await _server(s.load(u.uid, fromServer: true));
      try {
        // The document goes before the account: once the account is gone,
        // the security rules no longer let this app delete it.
        await _server(s.deleteAll(u.uid));
      } catch (_) {
        // A timed-out delete may still be queued; the restore is queued
        // after it, so the document ends up back either way.
        if (!await _restoreCloud(s, u.uid, remote)) {
          await _keepCloudCopy(remote);
          _markUnsaved();
        }
        rethrow;
      }
    }

    try {
      // A child keeps the progress on this device (see [_afterDeletion]),
      // so the sign-out that follows the deletion must not clear it.
      _keepLocalOnSignOut = !accountsAllowed;
      await _server(accounts.deleteUser(proof));
    } catch (e) {
      _keepLocalOnSignOut = false;
      // After a timeout the deletion may still have gone through, so the
      // document is only put back when a fresh check is sure the account
      // is still there.
      final exists = await accounts.accountStillExists();
      if (exists == false) {
        // The error came after the account was in fact removed.
        await _afterDeletion();
        _keepLocalOnSignOut = !accountsAllowed;
        await accounts.signOut();
        return;
      }
      if (exists == null) {
        // Unknown: don't recreate the document for an account that may be
        // gone. The device keeps everything (its own progress plus the
        // cloud copy read above) and nothing is written until a fresh check
        // says the account still exists (recheckDeletion, run before every
        // sync, background write and sign-out). If it's gone, the device
        // is cleared; if it exists, the next sync uploads the progress.
        await prefs.setString(_unconfirmedKey, u.uid);
        await _keepCloudCopy(remote);
        _markUnsaved();
        throw AccountException(AccountErrorKind.unconfirmed, e);
      }
      if (s != null && !await _restoreCloud(s, u.uid, remote)) {
        // The account exists but its cloud copy is gone and couldn't be put
        // back: keep it on the device and mark it as not saved, so signing
        // out asks first and the next sync uploads it.
        await _keepCloudCopy(remote);
        _markUnsaved();
      }
      rethrow;
    }
    await _afterDeletion();
  }

  /// After the account is gone: the device is cleared, except for a child
  /// ([accountsAllowed] false), who keeps their progress on the device.
  Future<void> _afterDeletion() async {
    if (accountsAllowed) return _clearLocal();
    _accountEpoch++;
    _syncFailed = false;
    await prefs.remove(_syncedUidKey);
    await prefs.remove(_trackDirtyKey);
    await prefs.remove(_unconfirmedKey);
    await prefs.remove(_childAccountKey);
    notifyListeners();
  }

  static Future<T> _server<T>(Future<T> step) async {
    try {
      return await step.timeout(serverTimeout);
    } on AccountException {
      rethrow;
    } on TimeoutException catch (e) {
      throw AccountException(AccountErrorKind.network, e);
    } on SyncUnavailable catch (e) {
      throw AccountException(AccountErrorKind.network, e);
    } catch (e) {
      throw AccountException(AccountErrorKind.other, e);
    }
  }

  /// Puts back everything the cloud and this device knew.
  /// Returns false if the write failed.
  Future<bool> _restoreCloud(
    ProgressSync s,
    String uid,
    RemoteProgress remote,
  ) async {
    try {
      // For a child only what the cloud already had goes back: nothing
      // new is uploaded for them.
      await s
          .replace(
            uid,
            track: accountsAllowed ? (_track ?? remote.track) : remote.track,
            completed: accountsAllowed
                ? {...remote.completed, ..._completed}
                : {...remote.completed},
          )
          .timeout(serverTimeout);
      return true;
    } catch (e) {
      debugPrint('Restoring cloud progress failed: $e');
      return false;
    }
  }

  /// Adds the cloud copy read before deleting to the device, so a later
  /// upload doesn't lose lessons that were only in the cloud.
  Future<void> _keepCloudCopy(RemoteProgress remote) async {
    _completed.addAll(remote.completed);
    _track ??= remote.track;
    await _saveLocal();
  }

  /// The cloud may not hold this device's progress any more. Shown on the
  /// Progress screen; [signOut] then retries the sync and asks before
  /// clearing the device.
  void _markUnsaved() {
    _syncFailed = true;
    notifyListeners();
  }

  /// Sends one change to the cloud without making the UI wait for it.
  /// Firestore queues writes while offline and sends them later.
  void _push(Future<void> Function(ProgressSync s, String uid) write) {
    final s = sync;
    final u = _user;
    if (s == null || u == null || _deleting || !accountsAllowed) return;
    if (deletionUnconfirmed) {
      // Kept on the device; the next sync uploads it if the account exists.
      _markUnsaved();
      return;
    }
    unawaited(
      write(s, u.uid).catchError((Object e) {
        // Shown on the Progress screen, which offers a retry (a full merge,
        // which also repairs a document the rules refuse).
        debugPrint('Progress sync failed: $e');
        if (_user?.uid == u.uid) {
          _syncFailed = true;
          notifyListeners();
        }
      }),
    );
  }

  /// Units shown for the learner's track, or every unit if none is chosen.
  List<Unit> get visibleUnits {
    final c = _course;
    if (c == null) return const [];
    final t = _track;
    return t == null ? c.units : c.unitsFor(t);
  }

  int get totalLessons =>
      visibleUnits.fold(0, (sum, u) => sum + u.lessons.length);

  int get completedCount => visibleUnits
      .expand((u) => u.lessons)
      .where((l) => _completed.contains(l.id))
      .length;

  @override
  void dispose() {
    _userSub.cancel();
    age.removeListener(_onAgeChanged);
    super.dispose();
  }
}

/// Makes [AppState] available to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  /// For build methods: rebuilds the caller when the state changes.
  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// For callbacks and init code: reads the state without subscribing.
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
