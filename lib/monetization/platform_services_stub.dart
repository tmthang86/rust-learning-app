import 'ads_service.dart';
import 'consent_service.dart';
import 'purchase_service.dart';

/// The services this platform supports.
class PlatformServices {
  const PlatformServices({
    required this.ads,
    required this.consent,
    required this.purchases,
  });

  final AdsService ads;
  final ConsentService consent;
  final PurchaseService purchases;
}

/// Web: no ads, no consent form, nothing for sale.
PlatformServices createPlatformServices() => const PlatformServices(
  ads: NoAdsService(),
  consent: NoConsentService(),
  purchases: NoPurchaseService(),
);
