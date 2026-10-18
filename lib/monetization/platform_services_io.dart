import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'ad_config.dart';
import 'ads_service.dart';
import 'consent_service.dart';
import 'google_ads.dart';
import 'platform_services_stub.dart' show PlatformServices;
import 'purchase_service.dart';
import 'store_purchases.dart';

export 'platform_services_stub.dart' show PlatformServices;

/// Set with `--dart-define=ALLOW_TEST_ADS_IN_RELEASE=true` to try a release
/// build with Google's test ids (also lets the Android Gradle check pass).
const allowTestAdsInRelease = bool.fromEnvironment('ALLOW_TEST_ADS_IN_RELEASE');

/// Android and iOS get AdMob, UMP and the store; desktop gets nothing.
PlatformServices createPlatformServices() {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return const PlatformServices(
      ads: NoAdsService(),
      consent: NoConsentService(),
      purchases: NoPurchaseService(),
    );
  }
  final store = StorePurchaseService();
  final ids = Platform.isIOS ? AdUnitIds.ios : AdUnitIds.android;
  if (kReleaseMode && ids.areTestIds && !allowTestAdsInRelease) {
    // A release build without the real ad unit ids: show no ads at all
    // rather than test ads. See docs/ads-and-purchases.md.
    debugPrint(
      '*** ADS ARE OFF: this release build uses Google\'s TEST ad unit ids. '
      'Pass the real ids with --dart-define or --dart-define-from-file. ***',
    );
    return PlatformServices(
      ads: const NoAdsService(),
      consent: const NoConsentService(),
      purchases: store,
    );
  }
  return PlatformServices(
    ads: GoogleAdsService(ids: ids),
    consent: const UmpConsentService(),
    purchases: store,
  );
}
