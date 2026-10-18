/// Consent for ads, via Google's User Messaging Platform (UMP), which is a
/// Google-certified, TCF-integrated CMP
/// (https://support.google.com/admob/answer/13554020). The messages
/// themselves (GDPR, US states, IDFA explainer) are set up in AdMob; see
/// docs/ads-and-purchases.md.
abstract class ConsentService {
  /// Refreshes consent info and shows the consent form if one is required
  /// (`requestConsentInfoUpdate`, then `loadAndShowConsentFormIfRequired`).
  /// Never throws: on failure ads may still be allowed from an earlier
  /// session, which [canRequestAds] reports.
  Future<void> gather({required bool underAgeOfConsent});

  /// Whether ads may be requested now (UMP `canRequestAds`).
  Future<bool> canRequestAds();

  /// Whether the app must offer a way to change privacy choices
  /// (`getPrivacyOptionsRequirementStatus() == required`).
  Future<bool> privacyOptionsRequired();

  /// Shows UMP's privacy options form.
  Future<void> showPrivacyOptions();
}

/// No consent needed because no ads are shown (web, desktop).
class NoConsentService implements ConsentService {
  const NoConsentService();

  @override
  Future<void> gather({required bool underAgeOfConsent}) async {}
  @override
  Future<bool> canRequestAds() async => false;
  @override
  Future<bool> privacyOptionsRequired() async => false;
  @override
  Future<void> showPrivacyOptions() async {}
}
