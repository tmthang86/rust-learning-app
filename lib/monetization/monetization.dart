import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/age.dart';
import 'ad_report.dart';
import 'ads_service.dart';
import 'consent_service.dart';
import 'purchase_controller.dart';

/// Opens a link outside the app; returns false if nothing could open it.
typedef UriLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Ads, consent and the "Remove ads" purchase.
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
    required this.age,
    required this.purchases,
    this.ads = const NoAdsService(),
    this.consent = const NoConsentService(),
    DateTime Function()? clock,
    UriLauncher? launcher,
    this.interstitialShowTimeout = const Duration(seconds: 10),
  }) : _clock = clock ?? DateTime.now,
       _launch = launcher ?? _launchExternally {
    purchases.addListener(_onPurchasesChanged);
    age.addListener(_onAgeChanged);
  }

  static const sessionCountKey = 'adSessionCount';
  static const lastInterstitialKey = 'lastInterstitialMs';

  /// Lessons whose finish already counted as a break for an interstitial;
  /// finishing them again doesn't count.
  static const finishedLessonsKey = 'interstitialLessons';

  /// At most one interstitial per this long, also across app restarts.
  /// Set the AdMob frequency cap to the same (docs/ads-and-purchases.md).
  static const interstitialMinInterval = Duration(minutes: 5);

  final SharedPreferences prefs;

  /// The birth year; shared with AppState.
  final AgeStore age;
  final PurchaseController purchases;
  final AdsService ads;
  final ConsentService consent;

  /// [onLessonFinished] gives up waiting for the interstitial after this.
  final Duration interstitialShowTimeout;

  final DateTime Function() _clock;
  final UriLauncher _launch;

  bool _started = false;
  bool _disposed = false;
  bool _firstSession = false;
  int _lessonsFinishedThisSession = 0;
  Future<void>? _adsStarting;
  bool _consentGathered = false;
  bool _canRequestAds = false;
  bool _sdkReady = false;
  bool _privacyOptionsRequired = false;

  /// Whether ads are shown at all; see the class comment.
  bool get adsEnabled => _eligibleForAds && _canRequestAds && _sdkReady;

  /// Everything except consent allows ads.
  bool get _eligibleForAds =>
      ads.supported && !purchases.entitled && (age.group?.allowsAds ?? false);

  /// Whether to show the "Remove ads" offer: only to people who would see
  /// ads (not under-13s, not on the web), or as "Ads removed" to people
  /// who already own it.
  bool get showRemoveAdsCard =>
      purchases.supported &&
      (purchases.entitled ||
          (ads.supported && (age.group?.allowsAds ?? false)));

  /// Show a "Privacy options" entry (UMP says one is required).
  bool get privacyOptionsRequired => _privacyOptionsRequired;

  /// Call once at app start. The silent restore runs first (bounded by
  /// [PurchaseController.quietRestoreWait]), so someone who already paid
  /// doesn't get the consent form.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    // Set before any await, so an age answer that arrives meanwhile waits
    // for it too.
    final purchasesStarting = _purchasesStarting = purchases.start();
    final sessions = (prefs.getInt(sessionCountKey) ?? 0) + 1;
    _firstSession = sessions == 1;
    await prefs.setInt(sessionCountKey, sessions);
    await purchasesStarting;
    await _startAdsIfAllowed();
  }

  /// The purchase start (with its silent restore). Ads never start before
  /// it ends, also when the age is answered meanwhile, so someone who
  /// already paid never sees consent or an ad.
  Future<void>? _purchasesStarting;

  /// Call when the app comes back to the foreground: retries the store and
  /// a consent update that failed (e.g. offline at start).
  Future<void> onResume() async {
    if (!_started) return;
    await purchases.onResume();
    if (!_consentGathered) await _startAdsIfAllowed();
  }

  void _onAgeChanged() {
    _notify();
    if (_started) unawaited(_startAdsIfAllowed());
  }

  /// Runs consent and starts the ad SDK once, when allowed.
  Future<void> _startAdsIfAllowed() =>
      _adsStarting ??= _startAds().whenComplete(() => _adsStarting = null);

  Future<void> _startAds() async {
    await _purchasesStarting;
    final group = age.group;
    if (!_eligibleForAds || group == null) return;
    final audience = AdAudience.forAge(group);
    if (!_consentGathered) {
      // UMP's order: update consent info, show the form if required (not
      // for minors), then check canRequestAds before loading ads.
      _consentGathered = await consent.gather(
        underAgeOfConsent: audience.underAgeOfConsent,
        showForm: !audience.minor,
      );
    }
    await _refreshConsent();
    if (!_canRequestAds || !_eligibleForAds) return;
    if (!_sdkReady) {
      await ads.initialize(audience);
      _sdkReady = true;
    }
    // "Remove ads" may have been bought while the SDK started.
    if (!_eligibleForAds) return;
    _notify();
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

  /// Call at a natural break: the learner just finished lesson [lessonId]
  /// (passed its quiz, or "Mark as done") and is leaving it. Only the first
  /// finish of each lesson counts, remembered across restarts; solving the
  /// exercise first doesn't use it up. Shows an interstitial if one is
  /// ready and allowed:
  /// - never for the first lesson of the first session;
  /// - at most one per [interstitialMinInterval], counted from when one
  ///   was actually shown.
  /// Returns true if one was shown. Never waits longer than
  /// [interstitialShowTimeout].
  Future<bool> onLessonFinished(String lessonId) async {
    final finished = prefs.getStringList(finishedLessonsKey) ?? const [];
    if (finished.contains(lessonId)) return false;
    await prefs.setStringList(finishedLessonsKey, [...finished, lessonId]);
    _lessonsFinishedThisSession++;
    if (!adsEnabled) return false;
    if (_firstSession && _lessonsFinishedThisSession == 1) return false;
    final lastMs = prefs.getInt(lastInterstitialKey);
    if (lastMs != null) {
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (_clock().isBefore(last.add(interstitialMinInterval))) return false;
    }
    final shown = await ads.showInterstitial().timeout(
      interstitialShowTimeout,
      onTimeout: () => false,
    );
    if (shown) {
      await prefs.setInt(lastInterstitialKey, _clock().millisecondsSinceEpoch);
    }
    // Get the next one ready (not if ads were switched off meanwhile).
    if (adsEnabled) unawaited(ads.preloadInterstitial());
    return shown;
  }

  /// The placement of the last banner shown, for ad reports.
  String? lastAdScreen;

  /// Opens a report for an ad seen on [screen] (App Store guideline
  /// 2.5.18). Returns false if no mail app or browser could open it.
  Future<bool> reportAd(String screen) async {
    final uri = adReportUri(
      time: _clock(),
      screen: screen,
      adUnits: ads.unitIds,
    );
    try {
      return await _launch(uri);
    } catch (e) {
      debugPrint('Opening the ad report failed: $e');
      return false;
    }
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
    age.removeListener(_onAgeChanged);
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
