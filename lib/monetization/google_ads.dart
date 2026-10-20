// Android and iOS only: imported through platform_services_io.dart, never
// on the web (google_mobile_ads imports dart:io and has no web plugin).
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_banner.dart';
import 'ad_config.dart';
import 'ads_service.dart';
import 'consent_service.dart';

/// The plugin's request settings for [audience]: the age treatment and
/// maximum content rating sent with every ad request.
RequestConfiguration requestConfigurationFor(AdAudience audience) =>
    RequestConfiguration(
      maxAdContentRating: audience.maxAdContentRating,
      ageRestrictedTreatment: switch (audience.treatment) {
        AdAgeTreatment.child => AgeRestrictedTreatment.child,
        AdAgeTreatment.teen => AgeRestrictedTreatment.teen,
        AdAgeTreatment.unspecified => AgeRestrictedTreatment.unspecified,
      },
    );

/// AdMob through google_mobile_ads 9.1.0. API checked against the package
/// source (lib/src/ad_containers.dart, request_configuration.dart) and its
/// example app.
class GoogleAdsService implements AdsService {
  GoogleAdsService({AdUnitIds? ids})
    : ids = ids ?? (Platform.isIOS ? AdUnitIds.ios : AdUnitIds.android);

  final AdUnitIds ids;
  InterstitialAd? _interstitial;
  bool _loadingInterstitial = false;

  /// False after [discardInterstitial]: one that finishes loading then is
  /// thrown away instead of kept.
  bool _wantInterstitial = false;

  @override
  bool get supported => true;

  @override
  List<String> get unitIds => [ids.banner, ids.interstitial];

  @override
  Future<void> initialize(AdAudience audience) async {
    // Age settings first, so the very first request carries them. With
    // the DELAY_APP_MEASUREMENT_INIT / GADDelayAppMeasurementInit flags in
    // the platform files, nothing is measured before this point.
    await MobileAds.instance.updateRequestConfiguration(
      requestConfigurationFor(audience),
    );
    await MobileAds.instance.initialize();
  }

  @override
  Widget banner(AdPlacement placement) =>
      _AdaptiveBanner(adUnitId: ids.banner, key: ValueKey(placement));

  @override
  Future<void> preloadInterstitial() async {
    _wantInterstitial = true;
    if (_interstitial != null || _loadingInterstitial) return;
    _loadingInterstitial = true;
    await InterstitialAd.load(
      adUnitId: ids.interstitial,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _loadingInterstitial = false;
          if (_wantInterstitial) {
            _interstitial = ad;
          } else {
            ad.dispose(); // "Remove ads" was bought while it loaded.
          }
        },
        onAdFailedToLoad: (error) {
          _loadingInterstitial = false;
          debugPrint('Interstitial failed to load: $error');
        },
      ),
    );
  }

  @override
  Future<bool> showInterstitial() async {
    final ad = _interstitial;
    if (ad == null) return false;
    _interstitial = null;
    // Completes once the ad is on screen, so the frequency cap counts
    // from then and the caller never waits for the person to close it.
    final done = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        if (!done.isCompleted) done.complete(true);
      },
      onAdImpression: (ad) {
        if (!done.isCompleted) done.complete(true);
      },
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!done.isCompleted) done.complete(true);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('Interstitial failed to show: $error');
        ad.dispose();
        if (!done.isCompleted) done.complete(false);
      },
    );
    await ad.show();
    return done.future;
  }

  @override
  void discardInterstitial() {
    _wantInterstitial = false;
    _interstitial?.dispose();
    _interstitial = null;
  }
}

/// A small inline adaptive banner as wide as its space allows and no
/// taller than [AdBannerSlot.adHeight], which the slot reserves. Inline
/// (not anchored) because it sits inside scrolling content, away from the
/// navigation bar. The slot keeps it alive while scrolled away.
class _AdaptiveBanner extends StatefulWidget {
  const _AdaptiveBanner({super.key, required this.adUnitId});

  final String adUnitId;

  @override
  State<_AdaptiveBanner> createState() => _AdaptiveBannerState();
}

class _AdaptiveBannerState extends State<_AdaptiveBanner> {
  BannerAd? _ad;
  AdSize? _size;
  int? _width;

  void _load(int width) {
    _width = width;
    _ad?.dispose();
    _ad = null;
    _size = null;
    final ad = BannerAd(
      adUnitId: widget.adUnitId,
      size: AdSize.getInlineAdaptiveBannerAdSize(
        width,
        AdBannerSlot.adHeight.toInt(),
      ),
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) async {
          final banner = ad as BannerAd;
          AdSize? size;
          try {
            // Inline adaptive ads report their real height after loading.
            size = await banner.getPlatformAdSize();
          } catch (e) {
            debugPrint('Banner size unavailable: $e');
          }
          if (!mounted || _ad != banner) {
            if (_ad != banner) await banner.dispose();
            return;
          }
          // Without the real size, use the slot's full height: the
          // requested InlineAdaptiveSize always reports height 0
          // (google_mobile_ads 9.1.0 ad_containers.dart).
          final fallback = AdSize(
            width: banner.size.width,
            height: AdBannerSlot.adHeight.toInt(),
          );
          final real = size != null && size.height > 0 ? size : null;
          setState(() => _size = real ?? fallback);
        },
        onAdFailedToLoad: (ad, error) {
          // The slot keeps its space; nothing moves.
          debugPrint('Banner failed to load: $error');
          ad.dispose();
          if (mounted && _ad == ad) setState(() => _ad = null);
        },
      ),
    );
    _ad = ad;
    ad.load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.truncate();
        if (width != _width && width > 0) {
          // Load after this frame; a width change (rotation) reloads.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && width != _width) _load(width);
          });
        }
        final ad = _ad;
        final size = _size;
        if (ad == null || size == null) return const SizedBox.shrink();
        return SizedBox(
          width: size.width.toDouble(),
          height: size.height.toDouble().clamp(0, AdBannerSlot.adHeight),
          child: AdWidget(ad: ad),
        );
      },
    );
  }
}

/// UMP through google_mobile_ads (lib/src/ump in the package source).
class UmpConsentService implements ConsentService {
  const UmpConsentService();

  @override
  Future<bool> gather({
    required bool underAgeOfConsent,
    bool showForm = true,
  }) async {
    final updated = Completer<bool>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(
        tagForUnderAgeOfConsent: underAgeOfConsent,
        consentDebugSettings: _debugSettings(),
      ),
      () => updated.complete(true),
      (error) {
        debugPrint('Consent info update failed: ${error.message}');
        updated.complete(false);
      },
    );
    if (!await updated.future) return false;
    if (showForm) {
      final formOk = Completer<bool>();
      await ConsentForm.loadAndShowConsentFormIfRequired((error) {
        if (error != null) debugPrint('Consent form: ${error.message}');
        if (!formOk.isCompleted) formOk.complete(error == null);
      });
      if (!await formOk.future) return false;
    }
    final canRequest = await canRequestAds();
    if (kDebugMode) {
      // For the device check in docs/ads-and-purchases.md.
      final status = await ConsentInformation.instance.getConsentStatus();
      debugPrint(
        'UMP: underAgeOfConsent=$underAgeOfConsent showForm=$showForm '
        'status=$status canRequestAds=$canRequest',
      );
    }
    return canRequest;
  }

  /// For testing the consent messages on a device (debug builds only):
  /// `--dart-define=UMP_DEBUG_GEOGRAPHY=eea` (or `us_state`, `other`) and
  /// `--dart-define=UMP_TEST_DEVICE_ID=<hashed id from the device log>`.
  static ConsentDebugSettings? _debugSettings() {
    if (!kDebugMode) return null;
    const geo = String.fromEnvironment('UMP_DEBUG_GEOGRAPHY');
    const device = String.fromEnvironment('UMP_TEST_DEVICE_ID');
    if (geo.isEmpty) return null;
    return ConsentDebugSettings(
      debugGeography: switch (geo) {
        'eea' => DebugGeography.debugGeographyEea,
        'us_state' => DebugGeography.debugGeographyRegulatedUsState,
        _ => DebugGeography.debugGeographyOther,
      },
      testIdentifiers: device.isEmpty ? null : [device],
    );
  }

  @override
  Future<bool> canRequestAds() => ConsentInformation.instance.canRequestAds();

  @override
  Future<bool> privacyOptionsRequired() async =>
      await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() ==
      PrivacyOptionsRequirementStatus.required;

  @override
  Future<void> showPrivacyOptions() async {
    final done = Completer<void>();
    await ConsentForm.showPrivacyOptionsForm((error) {
      if (error != null) debugPrint('Privacy options: ${error.message}');
      done.complete();
    });
    await done.future;
  }
}
