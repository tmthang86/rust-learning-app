import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Age bands the app treats differently. The app is aimed at ages 13+
/// (see docs/ads-and-purchases.md); the first-launch age screen asks
/// everyone for a birth year so younger users are handled safely.
enum AgeGroup {
  /// Possibly under 13: no ads at all (see [AgeGroup.allowsAds]).
  under13,

  /// 13 to 17: ads with the child age treatment (see AdAudience.forAge).
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

  /// No accounts for under-13s. Once someone gives a birth year under 13
  /// the app has actual knowledge that they are a child, and COPPA would
  /// need verifiable parental consent before collecting personal data such
  /// as a Google or Apple sign-in (16 CFR 312.5,
  /// https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions).
  /// They keep their progress on the device instead.
  bool get allowsAccounts => this != AgeGroup.under13;
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

/// The birth year from the first-launch age screen, stored on the device
/// only. Shared by the account rules (AppState) and the ad rules
/// (Monetization), so both always see the same answer.
///
/// Not cleared on sign-out: it belongs to the device's user, and asking
/// again would let a child simply try another year (FTC COPPA FAQ on
/// neutral age screens).
class AgeStore extends ChangeNotifier {
  AgeStore(this.prefs, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _birthYear = prefs.getInt(birthYearKey);

  static const birthYearKey = 'birthYear';

  final SharedPreferences prefs;
  final DateTime Function() _clock;
  int? _birthYear;

  int? get birthYear => _birthYear;
  bool get needsAge => _birthYear == null;
  DateTime now() => _clock();

  /// Null until the age screen was answered.
  AgeGroup? get group {
    final y = _birthYear;
    return y == null ? null : ageGroupFor(y, _clock());
  }

  /// Youngest age the stored year allows, or null.
  int? get youngestAge {
    final y = _birthYear;
    return y == null ? null : youngestPossibleAge(y, _clock());
  }

  Future<void> setBirthYear(int year) async {
    _birthYear = year;
    notifyListeners();
    await prefs.setInt(birthYearKey, year);
  }
}
