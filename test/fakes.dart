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

  @override
  Future<SignInResult> signIn(SignInMethod method) async {
    final e = signInError;
    if (e != null) throw e;
    emit(const AccountUser(uid: 'u1', displayName: 'Ferris'));
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
  CloudDoc({this.track, Set<String>? completed}) : completed = completed ?? {};
  Track? track;
  final Set<String> completed;

  /// Raw fields stored on top of the clean ones, e.g. `{'track': 42}` or
  /// `{'legacy': true}`. firestore.rules refuses merge writes to a document
  /// with such fields until it is replaced as a whole.
  final Map<String, Object?> raw = {};

  bool get broken =>
      raw.keys.any((k) => !RemoteProgress.fields.contains(k)) ||
      (raw.containsKey('track') && raw['track'] is! String) ||
      (raw.containsKey('completedLessons') && raw['completedLessons'] is! List);

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
  FakeSync({Track? track, Set<String>? completed, this.steps}) {
    docs['u1'] = CloudDoc(track: track, completed: completed);
  }

  final Map<String, CloudDoc> docs = {};
  final List<String> loads = [];
  final List<Track> trackWrites = [];
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
      'updatedAt': unconfirmedReads ? null : 'server-time',
      ...snapshot.raw,
    }, confirmed: !unconfirmedReads);
  }

  @override
  Future<void> addCompleted(String uid, Iterable<String> ids) async {
    _write(uid);
    doc(uid).completed.addAll(ids);
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
  }) async {
    steps?.add('replace');
    _write(uid, replacing: true);
    replaces++;
    docs[uid] = CloudDoc(track: track, completed: {...completed});
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

/// Returns fixed output, e.g. the exercise's expected answer.
class FakeRunner implements CodeRunner {
  FakeRunner(this.result);
  RunResult result;

  @override
  Future<RunResult> run(String source) async => result;
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
      ...extraFiles,
    }),
  );
}

Future<AppState> makeState(
  FakeAccounts accounts,
  FakeSync sync, {
  CourseRepository? repository,
  CodeRunner runner = const PlaceholderCodeRunner(),
}) async => AppState(
  repository: repository ?? CourseRepository(),
  runner: runner,
  prefs: await SharedPreferences.getInstance(),
  accounts: accounts,
  sync: sync,
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
  List<String> get unitIds => const ['test-banner-unit', 'test-interstitial-unit'];

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
