import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:rust_learn/account/account_service.dart';
import 'package:rust_learn/account/progress_sync.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/data/models.dart';
import 'package:rust_learn/l10n/app_localizations.dart';
import 'package:rust_learn/reminders/reminder_scheduler.dart';
import 'package:rust_learn/monetization/ad_config.dart';
import 'package:rust_learn/monetization/ads_service.dart';
import 'package:rust_learn/monetization/consent_service.dart';
import 'package:rust_learn/monetization/purchase_service.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAccounts implements AccountService {
  FakeAccounts({AccountUser? initialUser, List<String>? steps})
    : _user = initialUser,
      steps = steps ?? [];

  final _controller = StreamController<AccountUser?>.broadcast();
  AccountUser? _user;

  /// When true, the confirming sign-in is cancelled.
  bool cancelReauth = false;

  /// When set, deleting the user fails with this error.
  Object? deleteError;

  /// With [deleteError]: the account was removed anyway.
  bool goneDespiteError = false;

  /// Order of the deletion steps, for checking the sequence. Can be shared
  /// with [FakeSync.steps] to see auth and cloud steps in one list.
  final List<String> steps;

  /// What [accountStillExists] answers after a failed delete; null means
  /// "can't tell". Defaults to the truth.
  bool? Function()? stillExistsAnswer;
  int reauthCount = 0;
  bool deleted = false;

  void emit(AccountUser? user) {
    _user = user;
    _controller.add(user);
  }

  void signInAs(String uid) => emit(AccountUser(uid: uid, displayName: uid));

  @override
  bool get available => true;
  @override
  AccountUser? get currentUser => _user;
  @override
  Stream<AccountUser?> get userChanges => _controller.stream;
  @override
  List<SignInMethod> get methods => SignInMethod.values;

  /// When set, signing in fails with this error.
  Object? signInError;

  /// When true, the next sign-in creates a new account.
  bool nextSignInIsNew = false;

  /// When true, sign-in sets [currentUser] but the auth-state event comes
  /// after the result, as FlutterFire may do. Later events stay in order.
  bool lateSignInEvent = false;

  @override
  Future<SignInResult> signIn(SignInMethod method) async {
    final e = signInError;
    if (e != null) throw e;
    const user = AccountUser(uid: 'u1', displayName: 'Ferris');
    if (lateSignInEvent) {
      _user = user;
      Timer.run(() => _controller.add(user));
    } else {
      emit(user);
    }
    final isNew = nextSignInIsNew;
    nextSignInIsNew = false;
    return SignInResult(isNewUser: isNew);
  }

  @override
  Future<void> signOut() async => emit(null);

  /// When set, the confirming sign-in waits for it.
  Completer<void>? reauthGate;

  @override
  Future<ReauthProof> reauthenticate() async {
    steps.add('reauth');
    final g = reauthGate;
    if (g != null) await g.future;
    reauthCount++;
    if (cancelReauth) throw const AccountException(AccountErrorKind.cancelled);
    return const ReauthProof(appleAuthorizationCode: 'code');
  }

  /// When set, deleting the user waits for it.
  Completer<void>? deleteUserGate;

  @override
  Future<void> deleteUser(ReauthProof proof) async {
    steps.add('deleteUser');
    // Let a late sign-in event arrive first.
    if (lateSignInEvent) await Future<void>.delayed(Duration.zero);
    final g = deleteUserGate;
    if (g != null) await g.future;
    final e = deleteError;
    if (e != null) {
      if (goneDespiteError) deleted = true;
      throw e;
    }
    deleted = true;
    // Firebase signs the user out after deleting them.
    emit(null);
  }

  /// When set, [accountStillExists] waits for it (a slow check).
  Completer<void>? stillExistsGate;

  @override
  Future<bool?> accountStillExists() async {
    final g = stillExistsGate;
    if (g != null) await g.future;
    return stillExistsAnswer != null ? stillExistsAnswer!() : !deleted;
  }
}

class CloudDoc {
  CloudDoc({this.track, Set<String>? completed, Map<String, int>? dailyXp})
    : completed = completed ?? {},
      dailyXp = dailyXp ?? {};
  Track? track;
  final Set<String> completed;

  /// XP per day, as stored under `dailyXp`.
  final Map<String, int> dailyXp;

  /// Raw fields stored on top of the clean ones, e.g. `{'track': 42}` or
  /// `{'legacy': true}`. firestore.rules refuses merge writes to a document
  /// with such fields until it is replaced as a whole.
  final Map<String, Object?> raw = {};

  bool get broken =>
      raw.keys.any((k) => !RemoteProgress.fields.contains(k)) ||
      (raw.containsKey('track') && raw['track'] is! String) ||
      (raw.containsKey('completedLessons') &&
          raw['completedLessons'] is! List) ||
      (raw.containsKey('dailyXp') && raw['dailyXp'] is! Map);

  void breakWith(Map<String, Object?> fields) => raw.addAll(fields);
}

class FakeWriteError implements Exception {
  const FakeWriteError(this.what);
  final String what;
  @override
  String toString() => 'FakeWriteError($what)';
}

/// In-memory cloud with one document per uid.
class FakeSync implements ProgressSync {
  /// Seeds the document of `u1`, the account [FakeAccounts.signIn] uses.
  FakeSync({
    Track? track,
    Set<String>? completed,
    Map<String, int>? dailyXp,
    this.steps,
  }) {
    docs['u1'] = CloudDoc(track: track, completed: completed, dailyXp: dailyXp);
  }

  final Map<String, CloudDoc> docs = {};
  final List<String> loads = [];
  final List<Track> trackWrites = [];

  /// Every `setDailyXp` call, in order.
  final List<Map<String, int>> xpWrites = [];
  int replaces = 0;

  /// When given, each call is logged here (shared with [FakeAccounts.steps]).
  final List<String>? steps;

  /// When set, `load` waits for it, to test slow networks.
  Completer<void>? gate;

  /// Simulates being offline for reads.
  bool failLoads = false;

  /// Simulates every write being refused.
  bool failWrites = false;

  /// What [flush] answers.
  bool flushResult = true;

  /// Simulates a snapshot from the local cache or with a write still
  /// pending (Firestore then shows `updatedAt` as null).
  bool unconfirmedReads = false;

  CloudDoc doc(String uid) => docs.putIfAbsent(uid, CloudDoc.new);

  // The `u1` document, for the original tests.
  Track? get track => docs['u1']?.track;
  Set<String> get completed => doc('u1').completed;
  Map<String, int> get dailyXp => doc('u1').dailyXp;

  void _write(String uid, {bool replacing = false}) {
    if (failWrites) throw const FakeWriteError('offline');
    if (!replacing && (docs[uid]?.broken ?? false)) {
      throw const FakeWriteError('permission-denied');
    }
  }

  @override
  Future<RemoteProgress> load(String uid, {bool fromServer = false}) async {
    steps?.add('load');
    loads.add(uid);
    final snapshot = docs[uid];
    final g = gate;
    if (g != null) await g.future;
    if (failLoads) throw const SyncUnavailable('offline');
    if (snapshot == null) return RemoteProgress.fromMap(null);
    // Built like the real thing, through the same parser.
    return RemoteProgress.fromMap({
      if (snapshot.track != null) 'track': snapshot.track!.name,
      'completedLessons': snapshot.completed.toList(),
      if (snapshot.dailyXp.isNotEmpty) 'dailyXp': {...snapshot.dailyXp},
      'updatedAt': unconfirmedReads ? null : 'server-time',
      ...snapshot.raw,
    }, confirmed: !unconfirmedReads);
  }

  @override
  Future<void> addCompleted(String uid, Iterable<String> ids) async {
    _write(uid);
    doc(uid).completed.addAll(ids);
  }

  /// When set, `setDailyXp` waits for it before taking effect (a slow
  /// write). Each call waits on the same gate.
  Completer<void>? xpGate;

  /// Runs at the start of every `setDailyXp` call, with the call number
  /// (from 1); a test can hold individual calls here.
  Future<void> Function(int call)? onXpWrite;
  int _xpCalls = 0;
  Future<void>? _xpChain;

  /// Like Firestore, writes take effect in the order they were made, even
  /// when an earlier one is slow.
  @override
  Future<void> setDailyXp(String uid, Map<String, int> days) async {
    final call = ++_xpCalls;
    final previous = _xpChain;
    final done = Completer<void>();
    _xpChain = done.future;
    try {
      if (previous != null) await previous;
      await onXpWrite?.call(call);
      final g = xpGate;
      if (g != null) await g.future;
      _write(uid);
      xpWrites.add({...days});
      // Like a Firestore merge write: only these days change.
      doc(uid).dailyXp.addAll(days);
    } finally {
      done.complete();
    }
  }

  @override
  Future<void> setTrack(String uid, Track t) async {
    _write(uid);
    trackWrites.add(t);
    doc(uid).track = t;
  }

  @override
  Future<void> replace(
    String uid, {
    Track? track,
    required Set<String> completed,
    Map<String, int> dailyXp = const {},
  }) async {
    steps?.add('replace');
    _write(uid, replacing: true);
    replaces++;
    docs[uid] = CloudDoc(
      track: track,
      completed: {...completed},
      dailyXp: {...dailyXp},
    );
  }

  @override
  Future<void> deleteAll(String uid) async {
    steps?.add('deleteAll');
    _write(uid, replacing: true);
    docs.remove(uid);
  }

  @override
  Future<bool> flush(Duration timeout) async => flushResult;
}

/// Reminder scheduler stand-in that records what the app asks for.
class FakeReminderScheduler implements ReminderScheduler {
  FakeReminderScheduler({
    this.supported = true,
    this.permission = true,
    this.grantOnRequest = true,
  });

  @override
  bool supported;

  /// What [hasPermission] answers (the system setting).
  bool permission;

  /// Whether a request for permission is granted.
  bool grantOnRequest;

  /// Make the next calls throw, like a failing plugin.
  bool throws = false;

  int initializes = 0;
  int permissionRequests = 0;
  int cancels = 0;

  /// The reminders waiting right now.
  List<ScheduledReminder> scheduled = [];

  /// Every [replaceAll] call, in order.
  final List<List<ScheduledReminder>> schedules = [];

  /// The language of the last [initialize] call (the notification text).
  AppLocalizations? l10n;

  @override
  Future<void> initialize(AppLocalizations l10n) async {
    this.l10n = l10n;
    if (throws) throw StateError('plugin failed');
    initializes++;
  }

  @override
  Future<bool> hasPermission() async => permission;

  /// When set, [requestPermission] waits for it (the system dialog is open).
  Completer<void>? requestGate;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    final g = requestGate;
    if (g != null) await g.future;
    if (grantOnRequest) permission = true;
    return permission;
  }

  @override
  Future<void> replaceAll(List<ScheduledReminder> reminders) async {
    if (throws) throw StateError('plugin failed');
    schedules.add(reminders);
    scheduled = [...reminders];
  }

  /// When set, [cancelAll] waits for it (a plugin call that hangs).
  Completer<void>? cancelGate;

  @override
  Future<void> cancelAll() async {
    cancels++;
    scheduled = [];
    final g = cancelGate;
    if (g != null) await g.future;
    scheduled = [];
  }
}

/// Returns fixed output, e.g. the exercise's expected answer.
///
/// Grading answers with [graded] when set; otherwise it grades the fixed
/// [result] the way the runner would grade a program that printed it: output
/// tests pass when the run succeeded and its stdout matches, code tests are
/// reported as not run.
class FakeRunner implements CodeRunner {
  FakeRunner(this.result, {this.graded});
  RunResult result;
  GradeResult? graded;

  /// The tests of every grading request, newest last.
  final List<List<ExerciseTest>> gradeRequests = [];

  @override
  Future<RunResult> run(String source) async => result;

  @override
  Future<GradeResult> grade(String source, List<ExerciseTest> tests) async {
    gradeRequests.add(tests);
    final fixed = graded;
    if (fixed != null) return fixed;
    final r = result;
    if (r.stage == RunStage.unavailable) {
      return GradeResult.unavailable(r.stderr);
    }
    return GradeResult(
      success: r.success,
      stage: r.stage,
      stdout: r.stdout,
      stderr: r.stderr,
      warnings: r.warnings,
      tests: [
        for (final t in tests)
          TestResult(
            id: t.id,
            status: !t.isOutput || r.stage != RunStage.run
                ? TestStatus.notRun
                : r.success && r.stdout.trim() == t.output!.trim()
                ? TestStatus.pass
                : TestStatus.fail,
            expected: t.output,
            actual: r.stdout,
          ),
      ],
    );
  }
}

/// Serves course content from memory instead of the bundled assets.
class MapBundle extends CachingAssetBundle {
  MapBundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) throw FlutterError('Unable to load asset: $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// A small course with one lesson of each kind.
CourseRepository fakeCourse({Map<String, String> extraFiles = const {}}) {
  String lesson(String id, {bool exercise = false, bool quiz = false}) =>
      jsonEncode({
        'id': id,
        'title': 'Lesson $id',
        'sections': [
          {'type': 'text', 'text': 'Body of $id'},
        ],
        if (exercise)
          'exercise': {
            'prompt': 'Print hi',
            'starter': 'fn main() {}',
            'expectedOutput': 'hi',
          },
        if (quiz)
          'quiz': [
            {
              'question': 'Pick B',
              'options': ['A', 'B'],
              'answer': 1,
            },
          ],
      });

  return CourseRepository(
    bundle: MapBundle({
      'assets/content/course.json': jsonEncode({
        'units': [
          {
            'id': 'u1',
            'number': 1,
            'title': 'Basics',
            'summary': 'The basics',
            'tracks': ['starter', 'fast'],
            'lessons': [
              {'id': 'plain', 'title': 'Lesson plain'},
              {'id': 'exercise', 'title': 'Lesson exercise'},
              {'id': 'quiz', 'title': 'Lesson quiz'},
              {
                'id': 'u1-check',
                'title': 'Checkpoint challenge',
                'checkpoint': true,
              },
            ],
          },
        ],
      }),
      'assets/content/lessons/plain.json': lesson('plain'),
      'assets/content/lessons/exercise.json': lesson(
        'exercise',
        exercise: true,
      ),
      'assets/content/lessons/quiz.json': lesson('quiz', quiz: true),
      'assets/content/lessons/u1-check.json': lesson('u1-check', exercise: true),
      ...extraFiles,
    }),
  );
}

Future<AppState> makeState(
  FakeAccounts accounts,
  FakeSync sync, {
  CourseRepository? repository,
  CodeRunner runner = const PlaceholderCodeRunner(),
  DateTime Function()? clock,
  ReminderScheduler reminderScheduler = const NoopReminderScheduler(),
}) async => AppState(
  repository: repository ?? CourseRepository(),
  runner: runner,
  prefs: await SharedPreferences.getInstance(),
  accounts: accounts,
  sync: sync,
  clock: clock,
  reminderScheduler: reminderScheduler,
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Like [SharedPreferences.setMockInitialValues], but with a birth year
/// already given (an adult), so the first-launch age question doesn't get
/// in the way of tests about other screens.
void mockPrefs(Map<String, Object> values, {bool ageKnown = true}) =>
    SharedPreferences.setMockInitialValues({
      if (ageKnown) 'birthYear': 1990,
      ...values,
    });

/// Ad SDK stand-in. Banners render as a box keyed by placement.
class FakeAds implements AdsService {
  FakeAds({this.supported = true});

  @override
  final bool supported;

  @override
  List<String> get unitIds => const [
    'test-banner-unit',
    'test-interstitial-unit',
  ];

  final List<AdAudience> initializedWith = [];
  int preloads = 0;
  int shown = 0;
  int discards = 0;

  /// Whether an interstitial is loaded and ready to show.
  bool interstitialReady = true;

  /// When true, showInterstitial never completes (a stuck SDK callback).
  bool hangOnShow = false;

  /// Runs during initialize (e.g. a purchase finishing meanwhile).
  Future<void> Function()? duringInitialize;

  static Key bannerKey(AdPlacement p) => ValueKey('fake-banner-${p.name}');

  @override
  Future<void> initialize(AdAudience audience) async {
    initializedWith.add(audience);
    final f = duringInitialize;
    if (f != null) await f();
  }

  @override
  Widget banner(AdPlacement placement) =>
      SizedBox(key: bannerKey(placement), height: 50, width: 300);

  @override
  Future<void> preloadInterstitial() async => preloads++;

  @override
  Future<bool> showInterstitial() async {
    if (hangOnShow) return Completer<bool>().future;
    if (!interstitialReady) return false;
    shown++;
    return true;
  }

  @override
  void discardInterstitial() => discards++;
}

/// UMP stand-in.
class FakeConsent implements ConsentService {
  FakeConsent({this.allowAds = true, this.privacyRequired = false});

  /// What canRequestAds answers.
  bool allowAds;
  bool privacyRequired;

  /// Whether the consent info update succeeds (false: offline).
  bool updateSucceeds = true;

  /// What canRequestAds answers after the privacy options form closes.
  bool? allowAdsAfterPrivacyForm;

  final List<bool> gatheredWithUnderAge = [];
  final List<bool> formsAllowed = [];
  int privacyFormsShown = 0;

  /// When true, the consent form reports an error.
  bool formFails = false;

  @override
  Future<bool> gather({
    required bool underAgeOfConsent,
    bool showForm = true,
  }) async {
    gatheredWithUnderAge.add(underAgeOfConsent);
    formsAllowed.add(showForm);
    if (!updateSucceeds || (showForm && formFails)) return false;
    return allowAds;
  }

  @override
  Future<bool> canRequestAds() async => allowAds;

  @override
  Future<bool> privacyOptionsRequired() async => privacyRequired;

  @override
  Future<void> showPrivacyOptions() async {
    privacyFormsShown++;
    final after = allowAdsAfterPrivacyForm;
    if (after != null) allowAds = after;
  }
}

/// Store stand-in for in_app_purchase, behaving like the real plugins:
/// - Google Play (in_app_purchase_android 0.5.4) reports a cancel, or an
///   error that comes with no purchase, as an update with an empty product
///   id that needs no completion ([androidCancel], [androidError]);
/// - StoreKit 2 needs completion only for purchased updates.
class FakeStore implements PurchaseService {
  FakeStore({this.supported = true, this.restoresSilently = false});

  @override
  final bool supported;
  @override
  final bool restoresSilently;

  final _updates = StreamController<List<StorePurchase>>.broadcast();

  bool available = true;
  StoreProduct? product = const StoreProduct(
    id: removeAdsProductId,
    title: 'Remove ads',
    price: r'$2.99',
  );

  /// What the store sends after a tap on Buy; nothing when null.
  List<StorePurchase>? onBuy;

  /// What the store sends after restore(); Google Play sends an empty list
  /// when nothing is owned.
  List<StorePurchase> onRestore = const [];

  /// Becomes [onRestore] after syncWithStore (App Store sync).
  List<StorePurchase>? afterSync;

  /// When set, buyNonConsumable throws it (StoreKit 2 reports errors so).
  Object? buyThrows;

  /// When set, restore throws it.
  Object? restoreThrows;

  /// When set, completing a purchase waits for it (slow store).
  Completer<void>? completeGate;

  bool buyAccepted = true;
  int buys = 0;
  int restores = 0;
  int syncs = 0;
  int availabilityChecks = 0;
  final List<StorePurchase> completed = [];

  void emit(List<StorePurchase> purchases) => _updates.add(purchases);

  @override
  Stream<List<StorePurchase>> get purchaseUpdates => _updates.stream;

  @override
  Future<bool> isAvailable() async {
    availabilityChecks++;
    return available;
  }

  @override
  Future<StoreProduct?> queryProduct(String id) async =>
      product?.id == id ? product : null;

  @override
  Future<bool> buyNonConsumable(StoreProduct product) async {
    buys++;
    final e = buyThrows;
    if (e != null) throw e;
    final updates = onBuy;
    if (updates != null) emit(updates);
    return buyAccepted;
  }

  @override
  Future<void> restore() async {
    restores++;
    final e = restoreThrows;
    if (e != null) throw e;
    emit(onRestore);
  }

  @override
  Future<void> complete(StorePurchase purchase) async {
    final g = completeGate;
    if (g != null) await g.future;
    completed.add(purchase);
  }

  @override
  Future<void> syncWithStore() async {
    syncs++;
    final next = afterSync;
    if (next != null) onRestore = next;
  }
}

/// Google Play's update for a cancelled purchase sheet.
const androidCancel = StorePurchase(
  productId: '',
  status: StorePurchaseStatus.canceled,
);

/// Google Play's update for a billing error with no purchase, e.g.
/// 'BillingResponse.itemAlreadyOwned'.
StorePurchase androidError(String billingResponse) => StorePurchase(
  productId: '',
  status: StorePurchaseStatus.error,
  errorMessage: billingResponse,
  error: storeErrorFrom(billingResponse),
);

StorePurchase removeAds(
  StorePurchaseStatus status, {
  bool needsCompletion = true,
  String? error,
}) => StorePurchase(
  productId: removeAdsProductId,
  status: status,
  needsCompletion: needsCompletion,
  errorMessage: error,
  error: error == null ? null : storeErrorFrom(error),
);

/// Lets queued stream events and their async handlers run.
Future<void> flushAsync() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A cloud whose full rewrites (`replace`) can be held, to test what
/// happens while one is in flight.
class HoldingReplaceSync extends FakeSync {
  HoldingReplaceSync({super.dailyXp});

  final Completer<void> hold = Completer<void>();
  final Completer<void> started = Completer<void>();

  @override
  Future<void> replace(
    String uid, {
    Track? track,
    required Set<String> completed,
    Map<String, int> dailyXp = const {},
  }) async {
    if (!started.isCompleted) started.complete();
    await hold.future;
    return super.replace(
      uid,
      track: track,
      completed: completed,
      dailyXp: dailyXp,
    );
  }
}
