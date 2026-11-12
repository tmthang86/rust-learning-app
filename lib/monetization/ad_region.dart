import 'dart:ui' show Locale, PlatformDispatcher;

/// Whether the device looks like it belongs to someone in Vietnam, so ads
/// are requested non-personalised only.
///
/// Why: Vietnam's Law on Personal Data Protection (No. 91/2025/QH15, in
/// force from 1 January 2026) requires the customer's consent before their
/// personal data is processed for advertising, with a way to refuse
/// (Art. 28); it also covers foreign organisations that process the data of
/// Vietnamese citizens (Art. 1(2)). Google's consent tool (UMP) has no
/// consent message for Vietnam, so no consent is ever collected there. The
/// app therefore never asks for personalised ads in Vietnam.
///
/// How: the app has no server-side IP lookup, and Dart has no portable API
/// for the SIM or Play Store country. The device's preferred locales are the
/// signal: any locale with country `VN`, or Vietnamese (`vi`) as the first
/// language. This errs on the side of non-personalised: a Vietnamese speaker
/// abroad, or a VPN user in Vietnam with a foreign locale, is the only
/// misclassification, and the cost is lower ad revenue, not a legal risk. A
/// traveller from Vietnam with an English device is the residual gap;
/// accepted and listed in docs/ads-and-purchases.md.
bool looksLikeVietnam(Iterable<Locale> preferredLocales) {
  final locales = preferredLocales.toList();
  if (locales.isEmpty) return false;
  if (locales.any((l) => l.countryCode?.toUpperCase() == 'VN')) return true;
  return locales.first.languageCode.toLowerCase() == 'vi';
}

/// [looksLikeVietnam] for this device's current locales.
bool deviceLooksLikeVietnam() =>
    looksLikeVietnam(PlatformDispatcher.instance.locales);
