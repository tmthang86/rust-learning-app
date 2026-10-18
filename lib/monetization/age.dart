/// Age bands the app treats differently. The app is aimed at ages 13+
/// (see docs/ads-and-purchases.md); the first-launch age screen asks
/// everyone for a birth year so younger users are handled safely.
enum AgeGroup {
  /// Possibly under 13: no ads at all (see [AgeGroup.allowsAds]).
  under13,

  /// 13 to 17: ads with the teen age treatment.
  teen,

  /// 18 or older.
  adult;

  /// Under-13s never see ads, not even non-personalised child-directed
  /// ones. It is the safer of the two options in the brief:
  /// - Google Play's Families policy says apps that serve children must
  ///   only use self-certified ad SDKs and must not send the advertising ID
  ///   of children or users of unknown age
  ///   (https://support.google.com/googleplay/android-developer/answer/9893335).
  /// - The amended COPPA Rule (compliance date 22 Apr 2026) covers "mixed
  ///   audience" services
  ///   (https://www.federalregister.gov/documents/2025/04/22/2025-05904).
  /// - Apple's Kids rules effectively ban third-party ads (guidelines 1.3
  ///   and 5.1.4).
  /// Not starting the ad SDK at all for them means no ad request and no
  /// device identifier leaves the device, which sidesteps all three.
  bool get allowsAds => this != AgeGroup.under13;
}

/// Oldest birth year the age screen accepts.
const earliestBirthYear = 1900;

/// The age band for someone born in [birthYear], as of [now].
///
/// With only a year we can't tell whether this year's birthday has passed,
/// so the youngest possible age is used: someone born 13 years ago may
/// still be 12 and counts as under 13.
AgeGroup ageGroupFor(int birthYear, DateTime now) {
  final youngestPossibleAge = now.year - birthYear - 1;
  if (youngestPossibleAge < 13) return AgeGroup.under13;
  if (youngestPossibleAge < 18) return AgeGroup.teen;
  return AgeGroup.adult;
}

/// Youngest age someone born in [birthYear] could be; see [ageGroupFor].
int youngestPossibleAge(int birthYear, DateTime now) =>
    now.year - birthYear - 1;
