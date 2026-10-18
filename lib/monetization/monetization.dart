import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ads_service.dart';
import 'age.dart';
import 'consent_service.dart';
import 'purchase_controller.dart';

/// Ads, consent, the learner's age band and the "Remove ads" purchase.
///
/// Ads are only requested when all of these hold ([adsEnabled]):
/// - the platform supports them (Android, iOS; never the web);
/// - "Remove ads" is not owned;
/// - the learner gave a birth year and is not possibly under 13;
/// - UMP says ads may be requested (`canRequestAds`).
///
/// Lessons and code runs never depend on ads.
class Monetization extends ChangeNotifier {
  Monetization({
    required this.prefs,
    required this.purchases,
    this.ads = const NoAdsService(),
    this.consent = const NoConsentService(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _birthYear = prefs.getInt(birthYearKey) {
    purchases.addListener(_onPurchasesChanged);
  }

  /// Stored on the device only. Not cleared on sign-out: it belongs to the
  /// device's user, and asking again would let a child simply try another
  /// year (FTC COPPA FAQ, neutral age screens:
  /// https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions).
  static const birthYearKey = 'birthYear';
  static const sessionCountKey = 'adSessionCount';
  static const lastInterstitialKey = 'lastInterstitialMs';

  /// At most one interstitial per this long, also across app restarts.
  /// Set the AdMob frequency cap to the same (docs/ads-and-purchases.md).
  static const interstitialMinInterval = Duration(minutes: 5);

  final SharedPreferences prefs;
  final PurchaseController purchases;
  final AdsService ads;
  final ConsentService consent;
  final DateTime Function() _clock;

  int? _birthYear;
  bool _started = false;
  bool _disposed = false;
  bool _firstSession = false;
  int _lessonsFinishedThisSession = 0;
  Future<void>? _adsStarting;
  bool _consentGathered = false;
  bool _canRequestAds = false;
  bool _sdkReady = false;
  bool _privacyOptionsRequired = false;

  int? get birthYear => _birthYear;
  bool get needsAge => _birthYear == null;

  AgeGroup? get ageGroup {
    final y = _birthYear;
    return y == null ? null : ageGroupFor(y, _clock());
  }

  /// Whether ads are shown at all; see the class comment.
  bool get adsEnabled => _eligibleForAds && _canRequestAds && _sdkReady;

  /// Everything except consent allows ads.
  bool get _eligibleForAds =>
      ads.supported && !purchases.entitled && (ageGroup?.allowsAds ?? false);

  /// Show a "Privacy options" entry (UMP says one is required).
  bool get privacyOptionsRequired => _privacyOptionsRequired;

  /// Call once at app start.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final sessions = (prefs.getInt(sessionCountKey) ?? 0) + 1;
    _firstSession = sessions == 1;
    await prefs.setInt(sessionCountKey, sessions);
    await purchases.start();
    await _startAdsIfAllowed();
  }

  /// Saves the answer from the age screen.
  Future<void> setBirthYear(int year) async {
    _birthYear = year;
    _notify();
    await prefs.setInt(birthYearKey, year);
    if (_started) await _startAdsIfAllowed();
  }

  /// Runs consent and starts the ad SDK once, when allowed.
  Future<void> _startAdsIfAllowed() =>
      _adsStarting ??= _startAds().whenComplete(() => _adsStarting = null);

  Future<void> _startAds() async {
    if (!_eligibleForAds) return;
    final year = _birthYear!;
    final group = ageGroupFor(year, _clock());
    final audience = AdAudience.forAge(
      group,
      youngestPossibleAge(year, _clock()),
    );
    if (!_consentGathered) {
      _consentGathered = true;
      // UMP's recommended order: update consent info, show the form if
      // required, then check canRequestAds before loading ads.
      await consent.gather(underAgeOfConsent: audience.underAgeOfConsent);
    }
    await _refreshConsent();
    if (!_canRequestAds || !_eligibleForAds) return;
    if (!_sdkReady) {
      await ads.initialize(audience);
      _sdkReady = true;
      _notify();
    }
    unawaited(ads.preloadInterstitial());
  }

  Future<void> _refreshConsent() async {
    _canRequestAds = await consent.canRequestAds();
    _privacyOptionsRequired = await consent.privacyOptionsRequired();
    _notify();
  }

  /// Opens UMP's privacy options form, then applies the new choice.
  Future<void> showPrivacyOptions() async {
    await consent.showPrivacyOptions();
    await _refreshConsent();
    if (_canRequestAds) {
      await _startAdsIfAllowed();
    } else {
      ads.discardInterstitial();
    }
  }

  /// Call at a natural break: the learner just finished a lesson and is
  /// leaving it. Shows an interstitial if one is ready and allowed:
  /// - never for the first lesson of the first session;
  /// - at most one per [interstitialMinInterval].
  /// Returns true if one was shown.
  Future<bool> onLessonFinished() async {
    _lessonsFinishedThisSession++;
    if (!adsEnabled) return false;
    if (_firstSession && _lessonsFinishedThisSession == 1) return false;
    final now = _clock();
    final lastMs = prefs.getInt(lastInterstitialKey);
    if (lastMs != null) {
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (now.isBefore(last.add(interstitialMinInterval))) return false;
    }
    final shown = await ads.showInterstitial();
    if (shown) {
      await prefs.setInt(lastInterstitialKey, now.millisecondsSinceEpoch);
    }
    // Get the next one ready (no-op if ads were switched off meanwhile).
    if (adsEnabled) unawaited(ads.preloadInterstitial());
    return shown;
  }

  void _onPurchasesChanged() {
    if (purchases.entitled) ads.discardInterstitial();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    purchases.removeListener(_onPurchasesChanged);
    super.dispose();
  }
}

/// Makes [Monetization] available to the widget tree.
class MonetizationScope extends InheritedNotifier<Monetization> {
  const MonetizationScope({
    super.key,
    required Monetization monetization,
    required super.child,
  }) : super(notifier: monetization);

  /// For build methods: rebuilds the caller when it changes.
  static Monetization of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MonetizationScope>()!
      .notifier!;

  /// For callbacks: reads it without subscribing.
  static Monetization read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MonetizationScope>()!.notifier!;
}
