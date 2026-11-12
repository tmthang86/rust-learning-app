import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show AgeRestrictedTreatment;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:rust_learn/data/age.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/features/editor/code_editor.dart';
import 'package:rust_learn/features/progress/monetization_widgets.dart';
import 'package:rust_learn/l10n/app_localizations_en.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/monetization/ad_banner.dart';
import 'package:rust_learn/monetization/ad_region.dart';
import 'package:rust_learn/monetization/ad_config.dart';
import 'package:rust_learn/monetization/ad_report.dart';
import 'package:rust_learn/monetization/ads_service.dart';
import 'package:rust_learn/monetization/google_ads.dart';
import 'package:rust_learn/monetization/monetization.dart';
import 'package:rust_learn/monetization/purchase_controller.dart';
import 'package:rust_learn/monetization/purchase_service.dart';
import 'package:rust_learn/monetization/store_purchases.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

final today = DateTime(2026, 10, 18, 12);

/// A lesson id not finished before (only a lesson's first finish counts).
var _lessonCounter = 0;
String nextLesson() => 'lesson-${_lessonCounter++}';

class RejectingVerifier implements PurchaseVerifier {
  @override
  Future<bool> verify(StorePurchase purchase) async => false;
}

/// A store whose restore never answers (slow network).
class SilentStore extends FakeStore {
  SilentStore() : super(restoresSilently: true);
  @override
  Future<void> restore() async => restores++;
}

/// A store whose product query waits for [gate] (slow network at start).
class SlowStore extends FakeStore {
  SlowStore() : super(restoresSilently: true);
  final gate = Completer<void>();
  @override
  Future<StoreProduct?> queryProduct(String id) async {
    await gate.future;
    return super.queryProduct(id);
  }
}

/// Banner that never loads, like a failed ad request.
class EmptyBannerAds extends FakeAds {
  @override
  Widget banner(AdPlacement placement) => const SizedBox.shrink();
}

/// Counts banner States, like the real banner, which requests a new ad
/// for each State.
class CountingAds extends FakeAds {
  static int created = 0;
  @override
  Widget banner(AdPlacement placement) => const _CountingBanner();
}

class _CountingBanner extends StatefulWidget {
  const _CountingBanner();
  @override
  State<_CountingBanner> createState() => _CountingBannerState();
}

class _CountingBannerState extends State<_CountingBanner> {
  @override
  void initState() {
    super.initState();
    CountingAds.created++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 50);
}

final List<Uri> launched = [];

Future<Monetization> makeMonetization({
  FakeAds? ads,
  FakeConsent? consent,
  FakeStore? store,
  AgeStore? age,
  PurchaseVerifier verifier = const TrustDeviceVerifier(),
  DateTime Function()? clock,
  Duration quietRestoreWait = const Duration(milliseconds: 50),
  Duration interstitialShowTimeout = const Duration(seconds: 10),
  bool start = true,
  bool vietnam = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final m = Monetization(
    prefs: prefs,
    age: age ?? AgeStore(prefs, clock: clock ?? () => today),
    purchases: PurchaseController(
      store: store ?? FakeStore(),
      prefs: prefs,
      verifier: verifier,
      restoreGrace: const Duration(milliseconds: 50),
      quietRestoreWait: quietRestoreWait,
    ),
    ads: ads ?? FakeAds(),
    consent: consent ?? FakeConsent(),
    clock: clock ?? () => today,
    launcher: (uri) async {
      launched.add(uri);
      return true;
    },
    interstitialShowTimeout: interstitialShowTimeout,
    inVietnam: () => vietnam,
  );
  if (start) await m.start();
  return m;
}

/// A course whose 'long' lesson has two reading sections and an exercise.
CourseRepository adCourse({String second = 'Second part of long'}) =>
    fakeCourse(
      extraFiles: {
        'assets/content/lessons/long.json': jsonEncode({
          'id': 'long',
          'title': 'Lesson long',
          'sections': [
            {'type': 'text', 'text': 'First part of long'},
            {'type': 'text', 'text': second},
          ],
          'exercise': {
            'prompt': 'Print hi',
            'starter': 'fn main() {}',
            'expectedOutput': 'hi',
          },
          'quiz': [
            {
              'question': 'Pick B',
              'options': ['A', 'B'],
              'answer': 1,
            },
          ],
        }),
      },
    );

GooglePlayPurchaseDetails playPurchase({
  required PurchaseStateWrapper state,
  bool acknowledged = false,
}) => GooglePlayPurchaseDetails.fromPurchase(
  PurchaseWrapper(
    orderId: 'GPA.1',
    packageName: 'com.rustlearn.rust_learn',
    purchaseTime: 0,
    purchaseToken: 'token',
    signature: 'sig',
    products: const [removeAdsProductId],
    isAutoRenewing: false,
    originalJson: '{}',
    isAcknowledged: acknowledged,
    purchaseState: state,
  ),
).single;

void main() {
  setUp(launched.clear);

  group('age bands', () {
    test('a birth year counts as the youngest age it could mean', () {
      // Born in 2013: 12 or 13 on 18 Oct 2026, so possibly under 13.
      expect(ageGroupFor(2013, today), AgeGroup.under13);
      expect(ageGroupFor(2012, today), AgeGroup.teen);
      expect(ageGroupFor(2008, today), AgeGroup.teen);
      expect(ageGroupFor(2007, today), AgeGroup.adult);
      expect(ageGroupFor(2026, today), AgeGroup.under13);
    });

    test('everyone under 18 gets the child treatment and G; adults PG', () {
      const child = AdAudience(
        treatment: AdAgeTreatment.child,
        maxAdContentRating: 'G',
        underAgeOfConsent: true,
      );
      expect(AdAudience.forAge(AgeGroup.under13), child);
      expect(AdAudience.forAge(AgeGroup.teen), child);
      expect(AdAudience.forAge(AgeGroup.teen).minor, isTrue);
      final adult = AdAudience.forAge(AgeGroup.adult);
      expect(adult.treatment, AdAgeTreatment.unspecified);
      expect(adult.maxAdContentRating, 'PG');
      expect(adult.underAgeOfConsent, isFalse);
      expect(adult.minor, isFalse);
    });

    test('Vietnam adds non-personalised and keeps the age settings', () {
      expect(AdAudience.forAge(AgeGroup.adult).nonPersonalized, isFalse);
      final adult = AdAudience.forAge(AgeGroup.adult, vietnam: true);
      expect(adult.nonPersonalized, isTrue);
      expect(adult.treatment, AdAgeTreatment.unspecified);
      expect(adult.maxAdContentRating, 'PG');
      final teen = AdAudience.forAge(AgeGroup.teen, vietnam: true);
      expect(teen.nonPersonalized, isTrue);
      expect(teen.treatment, AdAgeTreatment.child);
      expect(teen.maxAdContentRating, 'G');
      expect(teen.underAgeOfConsent, isTrue);
      expect(adult, isNot(AdAudience.forAge(AgeGroup.adult)));
    });

    test('the ad request is non-personalised only for Vietnam', () {
      expect(
        adRequestFor(AdAudience.forAge(AgeGroup.adult)).nonPersonalizedAds,
        isNot(true),
      );
      expect(
        adRequestFor(
          AdAudience.forAge(AgeGroup.adult, vietnam: true),
        ).nonPersonalizedAds,
        isTrue,
      );
    });

    test('device locales that count as Vietnam', () {
      expect(looksLikeVietnam(const [Locale('vi', 'VN')]), isTrue);
      expect(looksLikeVietnam(const [Locale('en', 'VN')]), isTrue);
      expect(looksLikeVietnam(const [Locale('en', 'US'), Locale('vi', 'VN')]), isTrue);
      expect(looksLikeVietnam(const [Locale('vi')]), isTrue);
      expect(looksLikeVietnam(const [Locale('en', 'US')]), isFalse);
      expect(looksLikeVietnam(const [Locale('en', 'US'), Locale('vi')]), isFalse);
      expect(looksLikeVietnam(const []), isFalse);
    });

    test('the audience maps to the plugin request configuration', () {
      final teen = requestConfigurationFor(AdAudience.forAge(AgeGroup.teen));
      expect(teen.ageRestrictedTreatment, AgeRestrictedTreatment.child);
      expect(teen.maxAdContentRating, 'G');
      final adult = requestConfigurationFor(
        AdAudience.forAge(AgeGroup.adult),
      );
      expect(adult.ageRestrictedTreatment, AgeRestrictedTreatment.unspecified);
      expect(adult.maxAdContentRating, 'PG');
    });
  });

  group('when ads load', () {
    setUp(() => mockPrefs({}));

    test('adult with consent on a phone: ads on, with the adult settings', () async {
      final ads = FakeAds();
      final consent = FakeConsent();
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.adsEnabled, isTrue);
      expect(consent.gatheredWithUnderAge, [false]);
      expect(consent.formsAllowed, [true]);
      expect(ads.initializedWith, [AdAudience.forAge(AgeGroup.adult)]);
      expect(ads.preloads, 1);
    });

    test('Vietnam: UMP unchanged, SDK started non-personalised', () async {
      final ads = FakeAds();
      final consent = FakeConsent();
      final m = await makeMonetization(
        ads: ads,
        consent: consent,
        vietnam: true,
      );
      expect(m.adsEnabled, isTrue);
      expect(consent.gatheredWithUnderAge, [false]);
      expect(consent.formsAllowed, [true]);
      expect(ads.initializedWith, [
        AdAudience.forAge(AgeGroup.adult, vietnam: true),
      ]);
      expect(ads.initializedWith.single.nonPersonalized, isTrue);
    });

    test('Vietnam teen: still child settings, no form, non-personalised', () async {
      mockPrefs({AgeStore.birthYearKey: 2010});
      final ads = FakeAds();
      final consent = FakeConsent();
      await makeMonetization(ads: ads, consent: consent, vietnam: true);
      expect(consent.formsAllowed, [false]);
      expect(ads.initializedWith.single.treatment, AdAgeTreatment.child);
      expect(ads.initializedWith.single.nonPersonalized, isTrue);
    });

    test('no ads, and no consent form, once "Remove ads" is owned', () async {
      mockPrefs({PurchaseController.entitlementKey: true});
      final ads = FakeAds();
      final consent = FakeConsent();
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.adsEnabled, isFalse);
      expect(consent.gatheredWithUnderAge, isEmpty);
      expect(ads.initializedWith, isEmpty);
    });

    test('no ads at all for someone possibly under 13', () async {
      mockPrefs({'birthYear': 2013});
      final ads = FakeAds();
      final consent = FakeConsent();
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.age.group, AgeGroup.under13);
      expect(m.adsEnabled, isFalse);
      // The ad SDK and UMP are never even started.
      expect(consent.gatheredWithUnderAge, isEmpty);
      expect(ads.initializedWith, isEmpty);
      expect(await m.onLessonFinished(nextLesson()), isFalse);
      expect(await m.onLessonFinished(nextLesson()), isFalse);
      expect(ads.shown, 0);
    });

    test('no ads before the age question is answered', () async {
      mockPrefs({}, ageKnown: false);
      final ads = FakeAds();
      final m = await makeMonetization(ads: ads);
      expect(m.age.needsAge, isTrue);
      expect(m.adsEnabled, isFalse);
      expect(ads.initializedWith, isEmpty);

      await m.age.setBirthYear(1990);
      await flushAsync();
      expect(m.adsEnabled, isTrue);
      expect(ads.initializedWith, hasLength(1));
    });

    test('teens: limited ads (child treatment, G) and no consent form, so '
        'no IDFA/ATT prompt', () async {
      mockPrefs({'birthYear': 2009}); // 16 or 17
      final ads = FakeAds();
      final consent = FakeConsent();
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.adsEnabled, isTrue);
      expect(consent.gatheredWithUnderAge, [true]);
      expect(consent.formsAllowed, [false]);
      expect(ads.initializedWith.single.treatment, AdAgeTreatment.child);
      expect(ads.initializedWith.single.maxAdContentRating, 'G');
    });

    test('no ads when consent does not allow ad requests', () async {
      final ads = FakeAds();
      final consent = FakeConsent(allowAds: false);
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.adsEnabled, isFalse);
      expect(ads.initializedWith, isEmpty);
      expect(await m.onLessonFinished(nextLesson()), isFalse);
      expect(await m.onLessonFinished(nextLesson()), isFalse);
      expect(ads.shown, 0);
    });

    test('a failed consent update is retried on resume', () async {
      final consent = FakeConsent()..updateSucceeds = false;
      final m = await makeMonetization(consent: consent);
      expect(consent.gatheredWithUnderAge, hasLength(1));

      consent.updateSucceeds = true;
      await m.onResume();
      expect(consent.gatheredWithUnderAge, hasLength(2));
      await m.onResume();
      expect(consent.gatheredWithUnderAge, hasLength(2)); // done now
    });

    test('a consent form error, or canRequestAds still false, is retried on '
        'resume', () async {
      final ads = FakeAds();
      final consent = FakeConsent()
        ..formFails = true
        ..allowAds = false;
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.adsEnabled, isFalse);

      consent.formFails = false;
      consent.allowAds = false;
      await m.onResume();
      expect(consent.gatheredWithUnderAge, hasLength(2));
      expect(m.adsEnabled, isFalse);

      consent.allowAds = true;
      await m.onResume();
      expect(consent.gatheredWithUnderAge, hasLength(3));
      expect(m.adsEnabled, isTrue);
      await m.onResume();
      expect(consent.gatheredWithUnderAge, hasLength(3)); // done now
    });

    test('no ads on the web (no ad service)', () async {
      final consent = FakeConsent();
      final m = await makeMonetization(
        ads: FakeAds(supported: false),
        consent: consent,
      );
      expect(m.adsEnabled, isFalse);
      expect(consent.gatheredWithUnderAge, isEmpty);
    });

    test('buying "Remove ads" mid-session turns ads off at once', () async {
      final ads = FakeAds();
      final store = FakeStore();
      final m = await makeMonetization(ads: ads, store: store);
      expect(m.adsEnabled, isTrue);

      store.emit([removeAds(StorePurchaseStatus.purchased)]);
      await flushAsync();
      expect(m.adsEnabled, isFalse);
      expect(ads.discards, greaterThan(0));
      expect(await m.onLessonFinished(nextLesson()), isFalse);
      expect(await m.onLessonFinished(nextLesson()), isFalse);
      expect(ads.shown, 0);
    });

    test('a purchase that lands while the SDK starts: no preload', () async {
      final store = FakeStore();
      final ads = FakeAds();
      ads.duringInitialize = () async {
        store.emit([removeAds(StorePurchaseStatus.purchased)]);
        await flushAsync();
      };
      final m = await makeMonetization(ads: ads, store: store);
      expect(ads.initializedWith, hasLength(1));
      expect(m.adsEnabled, isFalse);
      expect(ads.preloads, 0);
    });

    test('privacy options: offered when required; ads stop only when '
        'canRequestAds turns false after the form', () async {
      final ads = FakeAds();
      final consent = FakeConsent(privacyRequired: true)
        ..allowAdsAfterPrivacyForm = false;
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.privacyOptionsRequired, isTrue);
      expect(m.adsEnabled, isTrue);

      await m.showPrivacyOptions();
      expect(consent.privacyFormsShown, 1);
      expect(m.adsEnabled, isFalse);
    });

    test('"Remove ads" offer: only where ads would show, or when owned', () async {
      expect((await makeMonetization()).showRemoveAdsCard, isTrue);

      mockPrefs({'birthYear': 2015});
      expect((await makeMonetization()).showRemoveAdsCard, isFalse);

      mockPrefs({'birthYear': 2015, PurchaseController.entitlementKey: true});
      expect((await makeMonetization()).showRemoveAdsCard, isTrue);

      mockPrefs({});
      expect(
        (await makeMonetization(ads: FakeAds(supported: false)))
            .showRemoveAdsCard,
        isFalse,
      );
    });
  });

  group('startup race', () {
    setUp(() => mockPrefs({}));

    test('a silent restore that finds "Remove ads" wins over consent', () async {
      final consent = FakeConsent();
      final ads = FakeAds();
      final store = FakeStore(restoresSilently: true)
        ..onRestore = [removeAds(StorePurchaseStatus.restored)];
      final m = await makeMonetization(ads: ads, consent: consent, store: store);
      expect(m.purchases.entitled, isTrue);
      expect(consent.gatheredWithUnderAge, isEmpty);
      expect(ads.initializedWith, isEmpty);
    });

    test('a restore that never answers holds consent up only briefly', () async {
      final consent = FakeConsent();
      final m = await makeMonetization(consent: consent, store: SilentStore());
      expect(m.purchases.entitled, isFalse);
      expect(consent.gatheredWithUnderAge, hasLength(1));
      expect(m.adsEnabled, isTrue);
    });

    test('the age arriving while start runs starts the SDK once', () async {
      mockPrefs({}, ageKnown: false);
      final ads = FakeAds();
      final m = await makeMonetization(ads: ads, start: false);
      final starting = m.start();
      await m.age.setBirthYear(1990);
      await starting;
      await flushAsync();
      expect(ads.initializedWith, hasLength(1));
      expect(m.adsEnabled, isTrue);
    });

    test('a payer who answers the age screen while the store is still '
        'loading never gets consent or the ad SDK', () async {
      mockPrefs({}, ageKnown: false);
      final consent = FakeConsent();
      final ads = FakeAds();
      final store = SlowStore()
        ..onRestore = [removeAds(StorePurchaseStatus.restored)];
      final m = await makeMonetization(
        ads: ads,
        consent: consent,
        store: store,
        start: false,
      );
      final starting = m.start();
      await m.age.setBirthYear(1990); // before the store replied
      await flushAsync();
      expect(consent.gatheredWithUnderAge, isEmpty);
      expect(ads.initializedWith, isEmpty);
      store.gate.complete();
      await starting;
      await flushAsync();
      expect(m.purchases.entitled, isTrue);
      expect(consent.gatheredWithUnderAge, isEmpty);
      expect(ads.initializedWith, isEmpty);
      expect(m.adsEnabled, isFalse);
    });
  });

  group('interstitial cap', () {
    setUp(() => mockPrefs({}));

    test('never after the first lesson of the first session; then at most '
        'one per ${Monetization.interstitialMinInterval.inMinutes} min', () async {
      var now = today;
      final ads = FakeAds();
      final m = await makeMonetization(ads: ads, clock: () => now);

      expect(await m.onLessonFinished(nextLesson()), isFalse); // first lesson ever
      expect(await m.onLessonFinished(nextLesson()), isTrue);
      expect(ads.shown, 1);

      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(await m.onLessonFinished(nextLesson()), isFalse); // too soon
      expect(ads.shown, 1);

      now = now.add(const Duration(seconds: 1)); // exactly 5 minutes
      expect(await m.onLessonFinished(nextLesson()), isTrue);
      expect(ads.shown, 2);
    });

    test('the cap holds across app restarts', () async {
      var now = today;
      final first = await makeMonetization(clock: () => now);
      await first.onLessonFinished(nextLesson());
      expect(await first.onLessonFinished(nextLesson()), isTrue);

      now = now.add(const Duration(minutes: 2));
      final ads = FakeAds();
      final second = await makeMonetization(ads: ads, clock: () => now);
      expect(await second.onLessonFinished(nextLesson()), isFalse);

      now = now.add(const Duration(minutes: 3));
      expect(await second.onLessonFinished(nextLesson()), isTrue);
      expect(ads.shown, 1);
    });

    test('nothing is recorded when no interstitial was ready', () async {
      var now = today;
      final ads = FakeAds()..interstitialReady = false;
      final m = await makeMonetization(ads: ads, clock: () => now);
      await m.onLessonFinished(nextLesson());
      expect(await m.onLessonFinished(nextLesson()), isFalse);

      ads.interstitialReady = true;
      now = now.add(const Duration(seconds: 10));
      expect(await m.onLessonFinished(nextLesson()), isTrue);
    });

    test('a stuck interstitial times out and is not counted', () async {
      final ads = FakeAds()..hangOnShow = true;
      final m = await makeMonetization(
        ads: ads,
        interstitialShowTimeout: const Duration(milliseconds: 20),
      );
      await m.onLessonFinished(nextLesson());
      expect(await m.onLessonFinished(nextLesson()), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(Monetization.lastInterstitialKey), isNull);
    });
  });

  group('"Remove ads" purchase', () {
    late SharedPreferences prefs;
    late FakeStore store;
    late PurchaseController p;

    Future<void> make({
      PurchaseVerifier verifier = const TrustDeviceVerifier(),
      FakeStore? using,
    }) async {
      prefs = await SharedPreferences.getInstance();
      store = using ?? FakeStore();
      p = PurchaseController(
        store: store,
        prefs: prefs,
        verifier: verifier,
        restoreGrace: const Duration(milliseconds: 50),
        quietRestoreWait: const Duration(milliseconds: 50),
      );
      await p.start();
    }

    setUp(() => mockPrefs({}));

    test('loads the product at start', () async {
      await make();
      expect(p.storeAvailable, isTrue);
      expect(p.product?.price, r'$2.99');
      expect(p.entitled, isFalse);
      expect(store.restores, 0); // not silent on this store
    });

    test('purchased: granted, saved and completed', () async {
      await make();
      final purchase = removeAds(StorePurchaseStatus.purchased);
      store.onBuy = [purchase];
      await p.buy();
      await flushAsync();
      expect(p.entitled, isTrue);
      expect(p.state, PurchaseFlowState.purchased);
      expect(prefs.getBool(PurchaseController.entitlementKey), isTrue);
      expect(store.completed, [purchase]);
    });

    test('the entitlement survives a restart', () async {
      mockPrefs({PurchaseController.entitlementKey: true});
      await make();
      expect(p.entitled, isTrue);
    });

    test('restored from the button: granted and completed', () async {
      await make();
      final restored = removeAds(StorePurchaseStatus.restored);
      store.onRestore = [restored];
      await p.restore();
      expect(store.restores, 1);
      expect(p.entitled, isTrue);
      expect(p.state, PurchaseFlowState.restored);
      expect(store.completed, [restored]);
    });

    test('restore that finds nothing syncs with the store and tries again', () async {
      await make();
      store.afterSync = [
        removeAds(StorePurchaseStatus.restored, needsCompletion: false),
      ];
      await p.restore();
      expect(store.syncs, 1);
      expect(store.restores, 2);
      expect(p.entitled, isTrue);
      expect(p.state, PurchaseFlowState.restored);
    });

    test('restore with nothing owned says so', () async {
      await make();
      await p.restore();
      expect(p.entitled, isFalse);
      expect(p.state, PurchaseFlowState.nothingToRestore);
    });

    test('pending: not granted and not completed until it settles', () async {
      await make();
      store.onBuy = [
        removeAds(StorePurchaseStatus.pending, needsCompletion: false),
      ];
      await p.buy();
      await flushAsync();
      expect(p.entitled, isFalse);
      expect(p.state, PurchaseFlowState.pending);
      expect(store.completed, isEmpty);

      final paid = removeAds(StorePurchaseStatus.purchased);
      store.emit([paid]);
      await flushAsync();
      expect(p.entitled, isTrue);
      expect(store.completed, [paid]);
    });

    test('error: not granted, reported in plain terms, and completed', () async {
      await make();
      final failed = removeAds(
        StorePurchaseStatus.error,
        error: 'BillingResponse.serviceUnavailable',
      );
      store.onBuy = [failed];
      await p.buy();
      await flushAsync();
      expect(p.entitled, isFalse);
      expect(p.state, PurchaseFlowState.error);
      expect(p.error, StoreError.network);
      expect(store.completed, [failed]);
    });

    test('cancelled: not granted, reported, and completed', () async {
      await make();
      final cancelled = removeAds(StorePurchaseStatus.canceled);
      store.onBuy = [cancelled];
      await p.buy();
      await flushAsync();
      expect(p.entitled, isFalse);
      expect(p.state, PurchaseFlowState.cancelled);
      expect(store.completed, [cancelled]);
    });

    test('Android cancel (empty product id) ends the buy; Buy works again', () async {
      await make();
      store.onBuy = [androidCancel];
      await p.buy();
      await flushAsync();
      expect(p.state, PurchaseFlowState.cancelled);
      expect(p.busy, isFalse);
      expect(store.completed, isEmpty);

      await p.buy();
      expect(store.buys, 2);
    });

    test('Android billing error (empty product id) ends the buy', () async {
      await make();
      store.onBuy = [androidError('BillingResponse.serviceUnavailable')];
      await p.buy();
      await flushAsync();
      expect(p.state, PurchaseFlowState.error);
      expect(p.error, StoreError.network);
      expect(p.busy, isFalse);
    });

    test('Android "already owned" restores the purchase with one store '
        'restore and no store sync', () async {
      await make();
      final restoresBefore = store.restores;
      store.onBuy = [androidError('BillingResponse.itemAlreadyOwned')];
      store.onRestore = [
        removeAds(StorePurchaseStatus.restored, needsCompletion: false),
      ];
      await p.buy();
      await flushAsync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(store.restores - restoresBefore, 1);
      expect(store.syncs, 0);
      expect(p.entitled, isTrue);
      expect(p.state, PurchaseFlowState.restored);
    });

    test('a restore waits for its own batch, not one that arrived before '
        'its call', () async {
      await make();
      final restoresBefore = store.restores;
      // An earlier batch (another product) is still being handled, slowly,
      // when the person taps Restore.
      store.completeGate = Completer<void>();
      store.emit([
        const StorePurchase(
          productId: 'other_product',
          status: StorePurchaseStatus.purchased,
          needsCompletion: true,
        ),
      ]);
      await flushAsync();
      store.onRestore = [
        removeAds(StorePurchaseStatus.restored, needsCompletion: false),
      ];
      final restoring = p.restore();
      await flushAsync();
      store.completeGate!.complete();
      await restoring;
      expect(store.restores - restoresBefore, 1);
      expect(store.syncs, 0);
      expect(p.entitled, isTrue);
      expect(p.state, PurchaseFlowState.restored);
    });

    test('a failed restore has its own wording', () async {
      await make();
      store.restoreThrows = Exception('boom');
      await p.restore();
      expect(p.state, PurchaseFlowState.error);
      expect(p.errorWhileRestoring, isTrue);
      expect(purchaseMessage(AppLocalizationsEn(), p), "Couldn't check for earlier purchases. "
          'Please try again.');

      store.restoreThrows = null;
      store.buyThrows = Exception('boom');
      await p.buy();
      expect(p.errorWhileRestoring, isFalse);
      expect(purchaseMessage(AppLocalizationsEn(), p), "The purchase didn't go through. "
          'Please try again.');
    });

    test('a store exception (StoreKit 2) becomes a plain error', () async {
      await make();
      store.buyThrows = Exception('storekit_duplicate_product_object');
      await p.buy();
      expect(p.state, PurchaseFlowState.error);
      expect(p.error, StoreError.pendingTransaction);
      expect(p.busy, isFalse);
    });

    test('a buy request the store refuses is an error', () async {
      await make();
      store.buyAccepted = false;
      await p.buy();
      expect(p.state, PurchaseFlowState.error);
      expect(p.entitled, isFalse);
    });

    test('a purchase the verifier rejects is neither granted nor completed', () async {
      await make(verifier: RejectingVerifier());
      store.emit([removeAds(StorePurchaseStatus.purchased)]);
      await flushAsync();
      expect(p.entitled, isFalse);
      expect(p.state, PurchaseFlowState.error);
      expect(store.completed, isEmpty);
    });

    test('other products are completed but unlock nothing', () async {
      await make();
      const other = StorePurchase(
        productId: 'something_else',
        status: StorePurchaseStatus.purchased,
        needsCompletion: true,
      );
      store.emit([other]);
      await flushAsync();
      expect(p.entitled, isFalse);
      expect(store.completed, [other]);
    });

    test('updates that need no completion are not completed', () async {
      await make();
      store.emit([
        removeAds(StorePurchaseStatus.restored, needsCompletion: false),
      ]);
      await flushAsync();
      expect(p.entitled, isTrue);
      expect(store.completed, isEmpty);
    });

    test('silent restore at start: granted quietly', () async {
      await make(
        using: FakeStore(restoresSilently: true)
          ..onRestore = [removeAds(StorePurchaseStatus.restored)],
      );
      expect(store.restores, 1);
      expect(p.entitled, isTrue);
      expect(p.state, PurchaseFlowState.idle);
    });

    test('Android: an unacknowledged purchase is acknowledged at every start '
        'and resume, even once entitled', () async {
      mockPrefs({PurchaseController.entitlementKey: true});
      final unacked = removeAds(StorePurchaseStatus.restored);
      await make(
        using: FakeStore(restoresSilently: true)..onRestore = [unacked],
      );
      expect(store.restores, 1);
      expect(store.completed, [unacked]);

      await p.onResume();
      expect(store.restores, 2);
      expect(store.completed, hasLength(2));
    });

    test('the store is tried again when it was unavailable', () async {
      final s = FakeStore()..available = false;
      await make(using: s);
      expect(p.storeAvailable, isFalse);
      expect(p.product, isNull);

      s.available = true;
      await p.refresh();
      expect(p.storeAvailable, isTrue);
      expect(p.product, isNotNull);
    });

    test('nothing happens where there is no store (web)', () async {
      await make(using: FakeStore(supported: false));
      expect(p.supported, isFalse);
      expect(p.product, isNull);
    });
  });

  group('store plugin mapping', () {
    test('error codes become plain kinds', () {
      expect(
        storeErrorFrom('BillingResponse.itemAlreadyOwned'),
        StoreError.alreadyOwned,
      );
      expect(
        storeErrorFrom('BillingResponse.networkError'),
        StoreError.network,
      );
      expect(
        storeErrorFrom('BillingResponse.billingUnavailable'),
        StoreError.storeUnavailable,
      );
      expect(
        storeErrorFrom('BillingResponse.itemUnavailable'),
        StoreError.itemUnavailable,
      );
      expect(storeErrorFrom('something odd'), StoreError.other);
    });

    test('a Play purchase still waiting for payment stays pending, even when '
        'restore labels it restored', () {
      final details = playPurchase(state: PurchaseStateWrapper.pending)
        ..status = PurchaseStatus.restored;
      final p = StorePurchaseService.convert(details);
      expect(p.status, StorePurchaseStatus.pending);
      expect(p.needsCompletion, isFalse);
    });

    test('a paid, unacknowledged Play purchase needs completion', () {
      final p = StorePurchaseService.convert(
        playPurchase(state: PurchaseStateWrapper.purchased),
      );
      expect(p.status, StorePurchaseStatus.purchased);
      expect(p.needsCompletion, isTrue);
      expect(p.productId, removeAdsProductId);
      expect(p.serverVerificationData, 'token');
    });

    test('an acknowledged Play purchase needs no completion', () {
      final p = StorePurchaseService.convert(
        playPurchase(state: PurchaseStateWrapper.purchased, acknowledged: true)
          ..status = PurchaseStatus.restored,
      );
      expect(p.status, StorePurchaseStatus.restored);
      expect(p.needsCompletion, isFalse);
    });

    test('a Play error without a purchase keeps its kind', () {
      final details = PurchaseDetails(
        productID: '',
        status: PurchaseStatus.error,
        transactionDate: null,
        verificationData: PurchaseVerificationData(
          localVerificationData: '',
          serverVerificationData: '',
          source: 'google_play',
        ),
      )..error = IAPError(
          source: 'google_play',
          code: 'purchase_error',
          message: 'BillingResponse.itemAlreadyOwned',
        );
      final p = StorePurchaseService.convert(details);
      expect(p.productId, '');
      expect(p.status, StorePurchaseStatus.error);
      expect(p.error, StoreError.alreadyOwned);
    });
  });

  group('ad report', () {
    test('mailto with time, screen and ad units', () {
      final uri = adReportUri(
        time: DateTime.utc(2026, 10, 18, 12),
        screen: 'lessonReading',
        adUnits: const ['unit-a', 'unit-b'],
        email: 'report@example.org',
        url: '',
      );
      expect(uri.scheme, 'mailto');
      expect(uri.path, 'report@example.org');
      final text = Uri.decodeComponent(uri.toString());
      expect(text, contains('2026-10-18T12:00:00.000Z'));
      expect(text, contains('Screen: lessonReading'));
      expect(text, contains('unit-a, unit-b'));
      expect(uri.toString(), isNot(contains('+')));
    });

    test('a report URL gets the details as parameters', () {
      final uri = adReportUri(
        time: DateTime.utc(2026),
        screen: 'courseMap',
        adUnits: const ['u'],
        url: 'https://example.org/report?app=rust',
      );
      expect(uri.host, 'example.org');
      expect(uri.queryParameters['app'], 'rust');
      expect(uri.queryParameters['screen'], 'courseMap');
      expect(uri.queryParameters['adUnits'], 'u');
    });
  });

  group('screens', () {
    late AppState state;
    late Monetization monetization;
    late FakeAds ads;
    late FakeStore store;
    late FakeConsent consent;

    Future<void> open(
      WidgetTester tester,
      String location, {
      Map<String, Object> prefs = const {'track': 'fast'},
      bool ageKnown = true,
      FakeAds? useAds,
      bool adsSupported = true,
      bool storeSupported = true,
      bool allowAds = true,
      bool privacyRequired = false,
      CourseRepository? repository,
      Size size = const Size(390, 2400),
    }) async {
      mockPrefs(prefs, ageKnown: ageKnown);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ads = useAds ?? FakeAds(supported: adsSupported);
      store = FakeStore(supported: storeSupported);
      consent = FakeConsent(
        allowAds: allowAds,
        privacyRequired: privacyRequired,
      );
      await tester.runAsync(() async {
        final sp = await SharedPreferences.getInstance();
        final age = AgeStore(sp, clock: () => today);
        state = AppState(
          repository: repository ?? adCourse(),
          runner: FakeRunner(
            const RunResult(success: true, stage: RunStage.run, stdout: 'hi\n'),
          ),
          prefs: sp,
          age: age,
        );
        await state.load();
        monetization = await makeMonetization(
          ads: ads,
          consent: consent,
          store: store,
          age: age,
        );
      });
      // A fresh app each time, so a second open in one test starts over.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        RustLearnApp(
          state: state,
          monetization: monetization,
          initialLocation: location,
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder banner(AdPlacement p) => find.byKey(FakeAds.bannerKey(p));

    testWidgets('course map shows one banner, after the last unit', (
      tester,
    ) async {
      await open(tester, '/learn');
      expect(banner(AdPlacement.courseMap), findsOneWidget);
      expect(find.text('Advertisement'), findsOneWidget);
      expect(
        tester.getTopLeft(banner(AdPlacement.courseMap)).dy,
        greaterThan(tester.getBottomLeft(find.text('Basics')).dy),
      );
    });

    testWidgets('the banner space is reserved even if the ad never loads', (
      tester,
    ) async {
      await open(tester, '/learn');
      final loaded = tester.getSize(find.byType(AdBannerSlot)).height;
      await open(tester, '/learn', useAds: EmptyBannerAds());
      final empty = tester.getSize(find.byType(AdBannerSlot)).height;
      expect(empty, loaded);
      expect(empty, greaterThan(AdBannerSlot.adHeight));
    });

    testWidgets('no banner once "Remove ads" is owned', (tester) async {
      await open(
        tester,
        '/learn',
        prefs: const {'track': 'fast', PurchaseController.entitlementKey: true},
      );
      expect(banner(AdPlacement.courseMap), findsNothing);
      expect(find.text('Advertisement'), findsNothing);
    });

    testWidgets('no banner for someone possibly under 13', (tester) async {
      await open(
        tester,
        '/learn',
        prefs: const {'track': 'fast', 'birthYear': 2014},
      );
      expect(banner(AdPlacement.courseMap), findsNothing);
      expect(find.text('Advertisement'), findsNothing);
    });

    testWidgets('no banner without consent', (tester) async {
      await open(tester, '/learn', allowAds: false);
      expect(banner(AdPlacement.courseMap), findsNothing);
    });

    testWidgets('no banner and no purchase UI on the web', (tester) async {
      await open(tester, '/learn', adsSupported: false, storeSupported: false);
      expect(banner(AdPlacement.courseMap), findsNothing);
      await tester.tap(find.text('Progress'));
      await tester.pumpAndSettle();
      expect(find.text('Remove ads'), findsNothing);
      expect(find.text('Restore purchases'), findsNothing);
    });

    testWidgets('lesson: banner sits in the reading part, with text between '
        'it and the editor', (tester) async {
      await open(tester, '/lesson/long');
      final ad = banner(AdPlacement.lessonReading);
      expect(ad, findsOneWidget);
      final adBottom = tester.getBottomLeft(ad).dy;
      final secondPart = tester.getTopLeft(find.text('Second part of long')).dy;
      final editorTop = tester.getTopLeft(find.byType(CodeEditor)).dy;
      expect(secondPart, greaterThan(adBottom));
      expect(editorTop, greaterThan(secondPart));
      expect(editorTop - adBottom, greaterThan(AdBannerSlot.gap));
    });

    testWidgets('scrolling a lesson keeps the same banner (no re-request)', (
      tester,
    ) async {
      CountingAds.created = 0;
      await open(
        tester,
        '/lesson/long',
        useAds: CountingAds(),
        repository: adCourse(second: 'Second part\n' * 400),
        size: const Size(390, 844),
      );
      expect(CountingAds.created, 1);
      for (var i = 0; i < 3; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView), const Offset(0, 6000));
        await tester.pumpAndSettle();
      }
      expect(CountingAds.created, 1);
    });

    testWidgets('lesson with a single section before its exercise: no banner', (
      tester,
    ) async {
      await open(tester, '/lesson/exercise');
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(banner(AdPlacement.lessonReading), findsNothing);
    });

    testWidgets('no banner on the playground (editor) or quiz screens', (
      tester,
    ) async {
      await open(tester, '/playground');
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(find.byType(AdBannerSlot), findsNothing);
      expect(find.text('Advertisement'), findsNothing);

      await open(tester, '/lesson/long/quiz');
      expect(find.text('Pick B'), findsOneWidget);
      expect(find.byType(AdBannerSlot), findsNothing);
      expect(find.text('Advertisement'), findsNothing);

      // Run output in a lesson: the banner stays above the reading text.
      await open(tester, '/lesson/long');
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('Correct! Nice work.'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Correct! Nice work.')).dy,
        greaterThan(tester.getTopLeft(find.text('Second part of long')).dy),
      );
    });

    testWidgets('nothing tappable beside a banner; Progress "Report an ad" '
        'names the screen of the last banner seen', (tester) async {
      await open(tester, '/learn');
      expect(find.text('Advertisement'), findsOneWidget);
      expect(find.text('Report ad'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AdBannerSlot),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
      await tester.tap(find.text('Progress'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Report an ad'), 200);
      await tester.tap(find.text('Report an ad'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(1));
      final text = Uri.decodeComponent(launched.single.toString());
      expect(text, startsWith('mailto:$adReportEmail'));
      expect(text, contains('Screen: courseMap'));
      expect(text, contains('test-banner-unit'));
    });

    testWidgets('Progress: "Report an ad" only while ads are on', (
      tester,
    ) async {
      await open(tester, '/progress');
      await tester.scrollUntilVisible(find.text('Report an ad'), 200);
      await tester.tap(find.text('Report an ad'));
      await tester.pumpAndSettle();
      expect(launched, hasLength(1));

      await open(tester, '/progress', allowAds: false);
      expect(find.text('Report an ad'), findsNothing);
    });

    void goTo(WidgetTester tester, String location) =>
        GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);

    Future<void> passQuizAndLeave(WidgetTester tester) async {
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back to lessons'));
      await tester.pumpAndSettle();
    }

    testWidgets('R1: solve the exercise, then pass the quiz (the usual path): '
        'one interstitial; passing again shows none', (tester) async {
      await open(
        tester,
        '/lesson/long',
        prefs: {'track': 'fast', Monetization.sessionCountKey: 3},
      );
      expect(monetization.adsEnabled, isTrue);
      await tester.ensureVisible(find.text('Run'));
      await tester.tap(find.text('Run'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(state.isCompleted('long'), isTrue); // the exercise completed it
      await tester.ensureVisible(find.text('Take the quiz'));
      await tester.tap(find.text('Take the quiz'));
      await tester.pumpAndSettle();
      await passQuizAndLeave(tester);
      expect(find.text('Learn Rust'), findsOneWidget);
      expect(ads.shown, 1);

      // Past the time cap, so only the repeat rule can stop it.
      await tester.runAsync(() async {
        final sp = await SharedPreferences.getInstance();
        await sp.remove(Monetization.lastInterstitialKey);
      });
      goTo(tester, '/lesson/long/quiz');
      await tester.pumpAndSettle();
      await passQuizAndLeave(tester);
      expect(ads.shown, 1);
    });

    testWidgets('first lesson of the first session: no interstitial; the '
        'next finish ("Mark as done") shows one, a repeat does not', (
      tester,
    ) async {
      await open(tester, '/lesson/long/quiz');
      await passQuizAndLeave(tester);
      expect(find.text('Learn Rust'), findsOneWidget);
      expect(ads.shown, 0); // first lesson of the first session

      goTo(tester, '/lesson/plain');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as done'));
      await tester.pumpAndSettle();
      expect(ads.shown, 1);

      await tester.runAsync(() async {
        final sp = await SharedPreferences.getInstance();
        await sp.remove(Monetization.lastInterstitialKey);
      });
      goTo(tester, '/lesson/plain');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as done'));
      await tester.pumpAndSettle();
      expect(ads.shown, 1);
    });

    testWidgets('Progress: buy "Remove ads", then the ads are gone', (
      tester,
    ) async {
      await open(tester, '/progress');
      await tester.scrollUntilVisible(find.text('Restore purchases'), 200);
      expect(find.text(r'Remove ads for $2.99'), findsOneWidget);

      store.onBuy = [removeAds(StorePurchaseStatus.purchased)];
      await tester.tap(find.text(r'Remove ads for $2.99'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();

      expect(find.text('Ads removed'), findsOneWidget);
      expect(find.text('Restore purchases'), findsNothing);
      expect(store.completed, hasLength(1));

      await tester.tap(find.text('Learn'));
      await tester.pumpAndSettle();
      expect(banner(AdPlacement.courseMap), findsNothing);
    });

    testWidgets('Progress: the Restore button restores the purchase', (
      tester,
    ) async {
      await open(tester, '/progress');
      store.onRestore = [removeAds(StorePurchaseStatus.restored)];
      await tester.scrollUntilVisible(find.text('Restore purchases'), 200);
      await tester.tap(find.text('Restore purchases'));
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(store.restores, 1);
      expect(find.text('Ads removed'), findsOneWidget);
      expect(find.textContaining('was restored'), findsOneWidget);
    });

    testWidgets('Progress: pending, cancelled and failed purchases are '
        'explained in plain words', (tester) async {
      await open(tester, '/progress');
      await tester.scrollUntilVisible(find.text('Restore purchases'), 200);
      store.onBuy = [
        removeAds(StorePurchaseStatus.pending, needsCompletion: false),
      ];
      await tester.tap(find.text(r'Remove ads for $2.99'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(find.textContaining('pending'), findsOneWidget);

      store.emit([removeAds(StorePurchaseStatus.canceled)]);
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(find.text('Purchase cancelled.'), findsOneWidget);

      store.onBuy = [androidError('BillingResponse.serviceUnavailable')];
      await tester.tap(find.text(r'Remove ads for $2.99'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't reach the store"), findsOneWidget);
      expect(find.textContaining('BillingResponse'), findsNothing);
      expect(find.text('Ads removed'), findsNothing);
    });

    testWidgets('Progress: no "Remove ads" offer for an under-13', (
      tester,
    ) async {
      await open(
        tester,
        '/progress',
        prefs: const {'track': 'fast', 'birthYear': 2015},
      );
      expect(find.textContaining('Remove ads'), findsNothing);
      expect(find.text('Restore purchases'), findsNothing);
    });

    testWidgets('Progress: "Privacy options" only when UMP requires it', (
      tester,
    ) async {
      await open(tester, '/progress');
      expect(find.text('Privacy options'), findsNothing);

      await open(tester, '/progress', privacyRequired: true);
      await tester.scrollUntilVisible(find.text('Privacy options'), 200);
      await tester.tap(find.text('Privacy options'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(consent.privacyFormsShown, 1);
    });

    testWidgets('first launch: age, then track, then the deep link', (
      tester,
    ) async {
      await open(tester, '/lesson/plain', prefs: const {}, ageKnown: false);
      expect(find.text('What year were you born?'), findsOneWidget);
      // Neutral: no year filled in and nothing about age limits.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      expect(find.textContaining('13'), findsNothing);

      await tester.enterText(find.byType(TextField), '19');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Please enter a four-digit year.'), findsOneWidget);
      expect(state.age.needsAge, isTrue);

      await tester.enterText(find.byType(TextField), '1990');
      await tester.tap(find.text('Continue'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(find.text('Where would you like to start?'), findsOneWidget);

      await tester.tap(find.text('I already know another language'));
      await tester.pumpAndSettle();
      expect(find.text('Body of plain'), findsOneWidget);
      expect(state.age.birthYear, 1990);
    });

    testWidgets('existing user (track, no birth year) with a deep link: age '
        'screen, then straight to the link', (tester) async {
      await open(tester, '/lesson/plain', ageKnown: false);
      expect(find.text('What year were you born?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '1990');
      await tester.tap(find.text('Continue'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(find.text('Body of plain'), findsOneWidget);
    });

    testWidgets('age screen is not shown again, even when going there', (
      tester,
    ) async {
      await open(tester, '/age');
      expect(find.text('What year were you born?'), findsNothing);
      expect(find.text('Learn Rust'), findsOneWidget);
    });

    testWidgets('a future birth year is refused', (tester) async {
      await open(tester, '/learn', prefs: const {}, ageKnown: false);
      await tester.enterText(find.byType(TextField), '2099');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Please enter a four-digit year.'), findsOneWidget);
    });

    testWidgets('an under-13 answer: the app works, with no ads', (
      tester,
    ) async {
      await open(tester, '/learn', prefs: const {}, ageKnown: false);
      await tester.enterText(find.byType(TextField), '2015');
      await tester.tap(find.text('Continue'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      await tester.tap(find.text("I'm new to programming"));
      await tester.pumpAndSettle();
      expect(find.text('Basics'), findsOneWidget);
      expect(banner(AdPlacement.courseMap), findsNothing);
      expect(ads.initializedWith, isEmpty);
      expect(consent.gatheredWithUnderAge, isEmpty);
    });
  });

  test('release guard: any test unit id, or the placeholder report address '
      'with no URL, means no ads', () {
    const real = AdUnitIds(
      banner: 'ca-app-pub-1/1',
      interstitial: 'ca-app-pub-1/2',
    );
    const oneTest = AdUnitIds(
      banner: 'ca-app-pub-1/1',
      interstitial: 'ca-app-pub-3940256099942544/1033173712',
    );
    expect(oneTest.areTestIds, isTrue);
    expect(real.areTestIds, isFalse);
    String? problem(AdUnitIds ids, String email, [String url = '']) =>
        releaseAdsProblem(ids: ids, reportEmail: email, reportUrl: url);
    expect(problem(oneTest, 'a@b.c'), contains('TEST'));
    expect(problem(real, placeholderAdReportEmail), contains('placeholder'));
    expect(problem(real, placeholderAdReportEmail, 'https://x.y/r'), isNull);
    expect(problem(real, 'a@b.c'), isNull);
    // The documentation's example address is not a real one either.
    expect(problem(real, 'ads@your-domain.example'), contains('example'));
    expect(problem(real, 'Ads@Your-Domain.EXAMPLE'), contains('example'));
    expect(problem(real, 'ads@your-domain.example', 'https://x.y/r'), isNull);
    expect(problem(real, 'ads@example.org'), isNull);
  });

  test('default ids are Google test ids', () {
    expect(AdUnitIds.android.areTestIds, isTrue);
    expect(AdUnitIds.ios.areTestIds, isTrue);
    expect(removeAdsProductId, 'remove_ads');
  });
}
