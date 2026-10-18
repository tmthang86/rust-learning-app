/// AdMob ad unit ids and the "Remove ads" product id.
///
/// By default every id is one of Google's public **test** ids, so debug
/// builds never serve live ads. Release builds pass the real ids with
/// `--dart-define`, without code changes:
///
/// ```sh
/// flutter build appbundle \
///   --dart-define=ADMOB_APP_ID_ANDROID=ca-app-pub-XXXX~YYYY \
///   --dart-define=ADMOB_BANNER_ANDROID=ca-app-pub-XXXX/BBBB \
///   --dart-define=ADMOB_INTERSTITIAL_ANDROID=ca-app-pub-XXXX/IIII
/// flutter build ipa \
///   --dart-define=ADMOB_BANNER_IOS=ca-app-pub-XXXX/BBBB \
///   --dart-define=ADMOB_INTERSTITIAL_IOS=ca-app-pub-XXXX/IIII
/// ```
///
/// The AdMob *app* ids live in the platform files (AndroidManifest.xml
/// reads ADMOB_APP_ID_ANDROID through android/app/build.gradle.kts;
/// iOS reads ios/Flutter/AdMob.xcconfig). See docs/ads-and-purchases.md.
///
/// Test ids are from Google's sample apps in the google_mobile_ads 9.1.0
/// package (example/lib/anchored_adaptive_example.dart and
/// example/lib/main.dart), which match
/// https://developers.google.com/admob/flutter/test-ads.
library;

/// Google's test app ids; also the defaults in the platform files.
const testAppIdAndroid = 'ca-app-pub-3940256099942544~3347511713';
const testAppIdIos = 'ca-app-pub-3940256099942544~1458002511';

/// Google's test adaptive banner and interstitial unit ids.
const testBannerAndroid = 'ca-app-pub-3940256099942544/9214589741';
const testBannerIos = 'ca-app-pub-3940256099942544/2435281174';
const testInterstitialAndroid = 'ca-app-pub-3940256099942544/1033173712';
const testInterstitialIos = 'ca-app-pub-3940256099942544/4411468910';

/// The ad unit ids for one platform.
class AdUnitIds {
  const AdUnitIds({required this.banner, required this.interstitial});

  final String banner;
  final String interstitial;

  /// True when these are Google's test ids.
  bool get areTestIds =>
      banner.startsWith('ca-app-pub-3940256099942544/') &&
      interstitial.startsWith('ca-app-pub-3940256099942544/');

  static const android = AdUnitIds(
    banner: String.fromEnvironment(
      'ADMOB_BANNER_ANDROID',
      defaultValue: testBannerAndroid,
    ),
    interstitial: String.fromEnvironment(
      'ADMOB_INTERSTITIAL_ANDROID',
      defaultValue: testInterstitialAndroid,
    ),
  );

  static const ios = AdUnitIds(
    banner: String.fromEnvironment(
      'ADMOB_BANNER_IOS',
      defaultValue: testBannerIos,
    ),
    interstitial: String.fromEnvironment(
      'ADMOB_INTERSTITIAL_IOS',
      defaultValue: testInterstitialIos,
    ),
  );
}

/// The one non-consumable product, set up with this id in both Play
/// Console and App Store Connect.
const removeAdsProductId = 'remove_ads';
