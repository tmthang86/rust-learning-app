import 'package:flutter/widgets.dart';

import 'ad_banner.dart' show AdBannerSlot;

import '../data/age.dart';

/// Where a banner may appear. Only reading and list screens are listed, so
/// a banner can't be put on the editor, run output or quiz screens by
/// mistake (the brief and Google's accidental-click guidance:
/// https://support.google.com/admob/answer/6275345).
enum AdPlacement {
  /// The course map (list of units and lessons).
  courseMap,

  /// The reading part of a lesson, kept away from its code editor.
  lessonReading,
}

/// Age-related settings sent with every ad request.
///
/// Uses the `ageRestrictedTreatment` setting that replaced the deprecated
/// child-directed (TFCD) and under-age-of-consent (TFUA) tags in
/// google_mobile_ads 9.1.0 (see RequestConfiguration in the package source
/// and https://developers.google.com/admob/flutter/targeting). The mapping
/// to the plugin's RequestConfiguration is `requestConfigurationFor` in
/// google_ads.dart.
class AdAudience {
  const AdAudience({
    required this.treatment,
    required this.maxAdContentRating,
    required this.underAgeOfConsent,
    this.nonPersonalized = false,
  });

  final AdAgeTreatment treatment;

  /// 'G', 'PG', 'T' or 'MA' (AdMob's MaxAdContentRating values).
  final String maxAdContentRating;

  /// Sent to UMP as `tagForUnderAgeOfConsent` (set for everyone under 18,
  /// which covers every EU digital age of consent, 13 to 16, GDPR Art. 8).
  /// UMP doesn't pass it on to ad requests; [treatment] does that.
  final bool underAgeOfConsent;

  /// Request only non-personalised ads (AdRequest `nonPersonalizedAds`).
  /// Set for users in Vietnam, where personal data may only be processed
  /// for advertising with the user's consent (Law 91/2025/QH15, Art. 28)
  /// and UMP has no consent form for Vietnam. See ad_region.dart.
  final bool nonPersonalized;

  /// True for anyone under 18.
  bool get minor => treatment == AdAgeTreatment.child;

  /// Settings for an age band.
  ///
  /// - Under 18 (both under 13 and 13 to 17): the child treatment and a G
  ///   rating. Under-13s get no ads at all ([AgeGroup.allowsAds]); the
  ///   setting is kept as a second line of defence. For 13 to 17 the child
  ///   treatment keeps every ad non-personalised. That is the safer course
  ///   under New York's Child Data Protection Act, which limits processing
  ///   the data of users under 18 (N.Y. Gen. Bus. Law art. 45-A, in force
  ///   20 Jun 2025), and it matches what UMP's under-age-of-consent tag
  ///   means under the new age setting (TFUA maps to the child treatment:
  ///   https://developers.google.com/admob/flutter/targeting).
  /// - 18+: no age treatment, PG.
  ///
  /// [vietnam] only adds [nonPersonalized]; it never loosens the age
  /// settings above.
  factory AdAudience.forAge(AgeGroup group, {bool vietnam = false}) {
    switch (group) {
      case AgeGroup.under13:
      case AgeGroup.teen:
        return AdAudience(
          treatment: AdAgeTreatment.child,
          maxAdContentRating: 'G',
          underAgeOfConsent: true,
          nonPersonalized: vietnam,
        );
      case AgeGroup.adult:
        return AdAudience(
          treatment: AdAgeTreatment.unspecified,
          maxAdContentRating: 'PG',
          underAgeOfConsent: false,
          nonPersonalized: vietnam,
        );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AdAudience &&
      other.treatment == treatment &&
      other.maxAdContentRating == maxAdContentRating &&
      other.underAgeOfConsent == underAgeOfConsent &&
      other.nonPersonalized == nonPersonalized;

  @override
  int get hashCode =>
      Object.hash(
        treatment,
        maxAdContentRating,
        underAgeOfConsent,
        nonPersonalized,
      );

  @override
  String toString() =>
      'AdAudience($treatment, $maxAdContentRating, uac: $underAgeOfConsent, npa: $nonPersonalized)';
}

/// Mirrors google_mobile_ads' AgeRestrictedTreatment without importing it,
/// so this file also compiles for the web.
enum AdAgeTreatment { unspecified, child, teen }

/// Shows ads. The real one wraps google_mobile_ads on Android and iOS;
/// the web and other platforms get [NoAdsService]. Only [Monetization]
/// calls it, and only once ads are allowed.
abstract class AdsService {
  /// False where this build can't show ads (web, desktop).
  bool get supported;

  /// The ad unit ids in use, for "Report an ad". Empty without ads.
  List<String> get unitIds;

  /// Starts the ad SDK with the age settings. Called once, after consent
  /// allows ad requests.
  Future<void> initialize(AdAudience audience);

  /// The ad for [placement], sized to fit [AdBannerSlot]'s reserved space
  /// (at most [AdBannerSlot.adHeight] tall). Shows nothing until loaded.
  Widget banner(AdPlacement placement);

  /// Loads an interstitial so it is ready at the next natural break.
  Future<void> preloadInterstitial();

  /// Shows the preloaded interstitial. Completes with true as soon as it
  /// is on screen, false if none was ready or it failed to show.
  Future<bool> showInterstitial();

  /// Drops a preloaded interstitial, and one still loading (e.g. after
  /// "Remove ads").
  void discardInterstitial();
}

/// No ads: web, desktop, or ads switched off.
class NoAdsService implements AdsService {
  const NoAdsService();

  @override
  bool get supported => false;
  @override
  List<String> get unitIds => const [];
  @override
  Future<void> initialize(AdAudience audience) async {}
  @override
  Widget banner(AdPlacement placement) => const SizedBox.shrink();
  @override
  Future<void> preloadInterstitial() async {}
  @override
  Future<bool> showInterstitial() async => false;
  @override
  void discardInterstitial() {}
}
