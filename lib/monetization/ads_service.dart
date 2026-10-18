import 'package:flutter/widgets.dart';

import 'age.dart';

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
/// and https://developers.google.com/admob/flutter/targeting).
class AdAudience {
  const AdAudience({
    required this.treatment,
    required this.maxAdContentRating,
    required this.underAgeOfConsent,
  });

  final AdAgeTreatment treatment;

  /// 'G', 'PG', 'T' or 'MA' (AdMob's MaxAdContentRating values).
  final String maxAdContentRating;

  /// Sent to UMP as `tagForUnderAgeOfConsent`: the person may be below the
  /// GDPR digital age of consent, which EU countries set between 13 and 16
  /// (GDPR Art. 8). UMP then doesn't ask them for consent.
  final bool underAgeOfConsent;

  /// Settings for an age band, as of [youngestAge] years old.
  ///
  /// - Under 13: no ads are loaded at all ([AgeGroup.allowsAds]). The
  ///   child treatment and G rating are kept here as a second line of
  ///   defence, should that ever change.
  /// - 13 to 17: the teen treatment, which restricts ad categories such as
  ///   alcohol, gambling and dating
  ///   (https://ppc.land/googles-new-tfat-signal-kills-tfcd-and-tfua-and-finally-adds-a-teen-tier/,
  ///   https://support.google.com/admob/answer/6219315), and PG.
  /// - 18+: PG as well, since the app is rated for teens.
  factory AdAudience.forAge(AgeGroup group, int youngestAge) {
    switch (group) {
      case AgeGroup.under13:
        return const AdAudience(
          treatment: AdAgeTreatment.child,
          maxAdContentRating: 'G',
          underAgeOfConsent: true,
        );
      case AgeGroup.teen:
        return AdAudience(
          treatment: AdAgeTreatment.teen,
          maxAdContentRating: 'PG',
          underAgeOfConsent: youngestAge < 16,
        );
      case AgeGroup.adult:
        return const AdAudience(
          treatment: AdAgeTreatment.unspecified,
          maxAdContentRating: 'PG',
          underAgeOfConsent: false,
        );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AdAudience &&
      other.treatment == treatment &&
      other.maxAdContentRating == maxAdContentRating &&
      other.underAgeOfConsent == underAgeOfConsent;

  @override
  int get hashCode =>
      Object.hash(treatment, maxAdContentRating, underAgeOfConsent);

  @override
  String toString() =>
      'AdAudience($treatment, $maxAdContentRating, uac: $underAgeOfConsent)';
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

  /// Starts the ad SDK with the age settings. Called once, after consent
  /// allows ad requests.
  Future<void> initialize(AdAudience audience);

  /// A banner for [placement]. It takes no space until an ad has loaded.
  Widget banner(AdPlacement placement);

  /// Loads an interstitial so it is ready at the next natural break.
  Future<void> preloadInterstitial();

  /// Shows the preloaded interstitial. Returns false if none was ready.
  Future<bool> showInterstitial();

  /// Drops a preloaded interstitial (e.g. after "Remove ads").
  void discardInterstitial();
}

/// No ads: web, desktop, or ads switched off.
class NoAdsService implements AdsService {
  const NoAdsService();

  @override
  bool get supported => false;
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
