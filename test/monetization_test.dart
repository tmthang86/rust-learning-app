import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_learn/data/app_state.dart';
import 'package:rust_learn/data/course_repository.dart';
import 'package:rust_learn/features/editor/code_editor.dart';
import 'package:rust_learn/main.dart';
import 'package:rust_learn/monetization/ad_banner.dart';
import 'package:rust_learn/monetization/ad_config.dart';
import 'package:rust_learn/monetization/ads_service.dart';
import 'package:rust_learn/monetization/age.dart';
import 'package:rust_learn/monetization/monetization.dart';
import 'package:rust_learn/monetization/purchase_controller.dart';
import 'package:rust_learn/monetization/purchase_service.dart';
import 'package:rust_learn/runner/code_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

final today = DateTime(2026, 10, 18, 12);

class RejectingVerifier implements PurchaseVerifier {
  @override
  Future<bool> verify(StorePurchase purchase) async => false;
}

Future<Monetization> makeMonetization({
  FakeAds? ads,
  FakeConsent? consent,
  FakeStore? store,
  PurchaseVerifier verifier = const TrustDeviceVerifier(),
  DateTime Function()? clock,
  bool start = true,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final m = Monetization(
    prefs: prefs,
    purchases: PurchaseController(
      store: store ?? FakeStore(),
      prefs: prefs,
      verifier: verifier,
      restoreGrace: const Duration(milliseconds: 50),
    ),
    ads: ads ?? FakeAds(),
    consent: consent ?? FakeConsent(),
    clock: clock ?? () => today,
  );
  if (start) await m.start();
  return m;
}

/// A course whose 'long' lesson has two reading sections and an exercise.
CourseRepository adCourse() => fakeCourse(
  extraFiles: {
    'assets/content/lessons/long.json': jsonEncode({
      'id': 'long',
      'title': 'Lesson long',
      'sections': [
        {'type': 'text', 'text': 'First part of long'},
        {'type': 'text', 'text': 'Second part of long'},
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

void main() {
  group('age bands', () {
    test('a birth year counts as the youngest age it could mean', () {
      // Born in 2013: 12 or 13 on 18 Oct 2026, so possibly under 13.
      expect(ageGroupFor(2013, today), AgeGroup.under13);
      expect(ageGroupFor(2012, today), AgeGroup.teen);
      expect(ageGroupFor(2008, today), AgeGroup.teen);
      expect(ageGroupFor(2007, today), AgeGroup.adult);
      expect(ageGroupFor(2026, today), AgeGroup.under13);
    });

    test('ad settings per age band', () {
      expect(
        AdAudience.forAge(AgeGroup.under13, 10),
        const AdAudience(
          treatment: AdAgeTreatment.child,
          maxAdContentRating: 'G',
          underAgeOfConsent: true,
        ),
      );
      final youngTeen = AdAudience.forAge(AgeGroup.teen, 13);
      expect(youngTeen.treatment, AdAgeTreatment.teen);
      expect(youngTeen.underAgeOfConsent, isTrue);
      expect(AdAudience.forAge(AgeGroup.teen, 16).underAgeOfConsent, isFalse);
      final adult = AdAudience.forAge(AgeGroup.adult, 30);
      expect(adult.treatment, AdAgeTreatment.unspecified);
      expect(adult.maxAdContentRating, 'PG');
      expect(adult.underAgeOfConsent, isFalse);
    });
  });

  group('when ads load', () {
    setUp(() => mockPrefs({}));

    test(
      'adult with consent on a phone: ads on, with the adult settings',
      () async {
        final ads = FakeAds();
        final consent = FakeConsent();
        final m = await makeMonetization(ads: ads, consent: consent);
        expect(m.adsEnabled, isTrue);
        expect(consent.gatheredWithUnderAge, [false]);
        expect(ads.initializedWith, [AdAudience.forAge(AgeGroup.adult, 35)]);
        expect(ads.preloads, 1);
      },
    );

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
      expect(m.ageGroup, AgeGroup.under13);
      expect(m.adsEnabled, isFalse);
      // The ad SDK and UMP are never even started.
      expect(consent.gatheredWithUnderAge, isEmpty);
      expect(ads.initializedWith, isEmpty);
      expect(await m.onLessonFinished(), isFalse);
      expect(await m.onLessonFinished(), isFalse);
      expect(ads.shown, 0);
    });

    test('no ads before the age question is answered', () async {
      mockPrefs({}, ageKnown: false);
      final ads = FakeAds();
      final m = await makeMonetization(ads: ads);
      expect(m.needsAge, isTrue);
      expect(m.adsEnabled, isFalse);
      expect(ads.initializedWith, isEmpty);

      await m.setBirthYear(1990);
      expect(m.adsEnabled, isTrue);
      expect(ads.initializedWith, hasLength(1));
    });

    test('teens get the teen treatment and UMP under-age tag', () async {
      mockPrefs({'birthYear': 2011}); // 14 or 15
      final ads = FakeAds();
      final consent = FakeConsent();
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(m.adsEnabled, isTrue);
      expect(consent.gatheredWithUnderAge, [true]);
      expect(ads.initializedWith.single.treatment, AdAgeTreatment.teen);
      expect(ads.initializedWith.single.maxAdContentRating, 'PG');
    });

    test('no ads when consent does not allow ad requests', () async {
      final ads = FakeAds();
      final consent = FakeConsent(allowAds: false);
      final m = await makeMonetization(ads: ads, consent: consent);
      expect(consent.gatheredWithUnderAge, [false]);
      expect(m.adsEnabled, isFalse);
      expect(ads.initializedWith, isEmpty);
      expect(await m.onLessonFinished(), isFalse);
      expect(await m.onLessonFinished(), isFalse);
      expect(ads.shown, 0);
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
      expect(await m.onLessonFinished(), isFalse);
      expect(await m.onLessonFinished(), isFalse);
      expect(ads.shown, 0);
    });

    test('privacy options: offered when required; withdrawing consent stops '
        'ads', () async {
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
  });

  group('interstitial cap', () {
    setUp(() => mockPrefs({}));

    test(
      'never after the first lesson of the first session; then at most '
      'one per ${Monetization.interstitialMinInterval.inMinutes} min',
      () async {
        var now = today;
        final ads = FakeAds();
        final m = await makeMonetization(ads: ads, clock: () => now);

        expect(await m.onLessonFinished(), isFalse); // first lesson ever
        expect(await m.onLessonFinished(), isTrue);
        expect(ads.shown, 1);

        now = now.add(const Duration(minutes: 4, seconds: 59));
        expect(await m.onLessonFinished(), isFalse); // too soon
        expect(ads.shown, 1);

        now = now.add(const Duration(seconds: 1)); // exactly 5 minutes
        expect(await m.onLessonFinished(), isTrue);
        expect(ads.shown, 2);
      },
    );

    test('the cap holds across app restarts; later sessions may show one '
        'after their first lesson', () async {
      var now = today;
      final first = await makeMonetization(clock: () => now);
      await first.onLessonFinished();
      expect(await first.onLessonFinished(), isTrue);

      // Restarted two minutes later: still capped.
      now = now.add(const Duration(minutes: 2));
      final ads = FakeAds();
      final second = await makeMonetization(ads: ads, clock: () => now);
      expect(await second.onLessonFinished(), isFalse);

      now = now.add(const Duration(minutes: 3));
      expect(await second.onLessonFinished(), isTrue);
      expect(ads.shown, 1);
    });

    test('nothing is recorded when no interstitial was ready', () async {
      var now = today;
      final ads = FakeAds()..interstitialReady = false;
      final m = await makeMonetization(ads: ads, clock: () => now);
      await m.onLessonFinished();
      expect(await m.onLessonFinished(), isFalse);

      ads.interstitialReady = true;
      now = now.add(const Duration(seconds: 10));
      expect(await m.onLessonFinished(), isTrue);
    });
  });

  group('"Remove ads" purchase', () {
    late SharedPreferences prefs;
    late FakeStore store;
    late PurchaseController p;

    Future<void> make({
      PurchaseVerifier verifier = const TrustDeviceVerifier(),
      bool silent = false,
    }) async {
      prefs = await SharedPreferences.getInstance();
      store = FakeStore(restoresSilently: silent);
      p = PurchaseController(
        store: store,
        prefs: prefs,
        verifier: verifier,
        restoreGrace: const Duration(milliseconds: 50),
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
      expect(store.buys, 1);
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

    test('error: not granted, reported, and completed', () async {
      await make();
      final failed = removeAds(StorePurchaseStatus.error, error: 'declined');
      store.onBuy = [failed];
      await p.buy();
      await flushAsync();
      expect(p.entitled, isFalse);
      expect(p.state, PurchaseFlowState.error);
      expect(p.errorMessage, 'declined');
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

    test('a buy request the store refuses is an error', () async {
      await make();
      store.buyAccepted = false;
      await p.buy();
      expect(p.state, PurchaseFlowState.error);
      expect(p.entitled, isFalse);
    });

    test(
      'a purchase the verifier rejects is not granted but is completed',
      () async {
        await make(verifier: RejectingVerifier());
        final purchase = removeAds(StorePurchaseStatus.purchased);
        store.emit([purchase]);
        await flushAsync();
        expect(p.entitled, isFalse);
        expect(p.state, PurchaseFlowState.error);
        expect(store.completed, [purchase]);
      },
    );

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

    test('Google Play: restores quietly at start', () async {
      prefs = await SharedPreferences.getInstance();
      store = FakeStore(restoresSilently: true)
        ..onRestore = [removeAds(StorePurchaseStatus.restored)];
      p = PurchaseController(store: store, prefs: prefs);
      await p.start();
      await flushAsync();
      expect(store.restores, 1);
      expect(p.entitled, isTrue);
      // No message for a restore nobody asked for.
      expect(p.state, PurchaseFlowState.idle);
    });

    test('nothing happens where there is no store (web)', () async {
      prefs = await SharedPreferences.getInstance();
      store = FakeStore(supported: false);
      p = PurchaseController(store: store, prefs: prefs);
      await p.start();
      expect(p.supported, isFalse);
      expect(p.product, isNull);
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
      bool adsSupported = true,
      bool storeSupported = true,
      bool allowAds = true,
      bool privacyRequired = false,
    }) async {
      mockPrefs(prefs, ageKnown: ageKnown);
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ads = FakeAds(supported: adsSupported);
      store = FakeStore(supported: storeSupported);
      consent = FakeConsent(
        allowAds: allowAds,
        privacyRequired: privacyRequired,
      );
      await tester.runAsync(() async {
        state = AppState(
          repository: adCourse(),
          runner: FakeRunner(
            const RunResult(success: true, stage: RunStage.run, stdout: 'hi\n'),
          ),
          prefs: await SharedPreferences.getInstance(),
        );
        await state.load();
        monetization = await makeMonetization(
          ads: ads,
          consent: consent,
          store: store,
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

    testWidgets('course map shows one banner when ads are on', (tester) async {
      await open(tester, '/learn');
      expect(banner(AdPlacement.courseMap), findsOneWidget);
      expect(find.text('Advertisement'), findsOneWidget);
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
      expect(find.byType(AdBannerSlot), findsOneWidget); // the slot is empty
      expect(banner(AdPlacement.courseMap), findsNothing);
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
      expect(editorTop - adBottom, greaterThan(AdFrame.gap));
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

    testWidgets('finishing a quiz is a break for an interstitial, within the '
        'cap', (tester) async {
      await open(tester, '/lesson/long/quiz');
      Future<void> passQuiz() async {
        await tester.tap(find.text('B'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Check'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Back to lessons'));
        await tester.pumpAndSettle();
      }

      await passQuiz();
      expect(find.text('Learn Rust'), findsOneWidget);
      expect(ads.shown, 0); // first lesson of the first session

      await tester.tap(find.text('Basics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lesson plain'));
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
      expect(find.text('Restore purchases'), findsOneWidget);

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
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(store.restores, 1);
      expect(find.text('Ads removed'), findsOneWidget);
      expect(find.textContaining('was restored'), findsOneWidget);
    });

    testWidgets('Progress: pending and cancelled purchases are explained', (
      tester,
    ) async {
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
      expect(find.text('Ads removed'), findsNothing);
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
      expect(monetization.needsAge, isTrue);

      await tester.enterText(find.byType(TextField), '1990');
      await tester.tap(find.text('Continue'));
      await tester.runAsync(flushAsync);
      await tester.pumpAndSettle();
      expect(find.text('Where would you like to start?'), findsOneWidget);

      await tester.tap(find.text('I already know another language'));
      await tester.pumpAndSettle();
      expect(find.text('Body of plain'), findsOneWidget);
      expect(monetization.birthYear, 1990);
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

  test('default ids are Google test ids', () {
    expect(AdUnitIds.android.areTestIds, isTrue);
    expect(AdUnitIds.ios.areTestIds, isTrue);
    expect(removeAdsProductId, 'remove_ads');
  });
}
