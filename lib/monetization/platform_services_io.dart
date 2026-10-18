import 'dart:io' show Platform;

import 'ads_service.dart';
import 'consent_service.dart';
import 'google_ads.dart';
import 'platform_services_stub.dart' show PlatformServices;
import 'purchase_service.dart';
import 'store_purchases.dart';

export 'platform_services_stub.dart' show PlatformServices;

/// Android and iOS get AdMob, UMP and the store; desktop gets nothing.
PlatformServices createPlatformServices() {
  if (Platform.isAndroid || Platform.isIOS) {
    return PlatformServices(
      ads: GoogleAdsService(),
      consent: const UmpConsentService(),
      purchases: StorePurchaseService(),
    );
  }
  return const PlatformServices(
    ads: NoAdsService(),
    consent: NoConsentService(),
    purchases: NoPurchaseService(),
  );
}
