/// Consent for ads, via Google's User Messaging Platform (UMP), which is a
/// Google-certified, TCF-integrated CMP
/// (https://support.google.com/admob/answer/13554020). The messages
/// themselves (GDPR, US states, IDFA explainer) are set up in AdMob; see
/// docs/ads-and-purchases.md.
abstract class ConsentService {
  /// Refreshes consent info (`requestConsentInfoUpdate`) and, if
  /// [showForm], shows the consent form when one is required
  /// (`loadAndShowConsentFormIfRequired`). Minors get no form, so no IDFA
  /// explainer or ATT prompt either. Returns `canRequestAds()` afterwards,
  /// or false if the update or the form failed (e.g. offline), so the app
  /// tries again on the next resume. Never throws.
  Future<bool> gather({required bool underAgeOfConsent, bool showForm = true});

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
  Future<bool> gather({
    required bool underAgeOfConsent,
    bool showForm = true,
  }) async => true;
  @override
  Future<bool> canRequestAds() async => false;
  @override
  Future<bool> privacyOptionsRequired() async => false;
  @override
  Future<void> showPrivacyOptions() async {}
}
