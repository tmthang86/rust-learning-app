import 'dart:ui';

/// Languages the app (UI and course content) is available in. English is the
/// source language; every other code needs a lib/l10n/app_<code>.arb and may
/// have translated course content under assets/content/<code>/ (see
/// docs/i18n/README.md).
const supportedLanguageCodes = ['en', 'vi'];

/// The language used when nothing else matches.
const defaultLanguageCode = 'en';

/// What the learner picked in the language setting.
enum AppLanguage {
  /// Follow the device: Vietnamese if the device language is Vietnamese,
  /// otherwise English. The default.
  system,
  english,
  vietnamese;

  /// The language code this choice stands for, or null for [system].
  String? get code => switch (this) {
    AppLanguage.system => null,
    AppLanguage.english => 'en',
    AppLanguage.vietnamese => 'vi',
  };

  /// The stored name, or [system] for anything unknown or missing.
  static AppLanguage fromName(String? name) {
    for (final l in AppLanguage.values) {
      if (l.name == name) return l;
    }
    return AppLanguage.system;
  }
}

/// The language code to use: the explicit [choice], or for
/// [AppLanguage.system] the first of the device's preferred [deviceLocales]
/// that the app supports (the order the device lists them in is its owner's
/// preference), else English.
String resolveLanguageCode(
  AppLanguage choice,
  Iterable<Locale> deviceLocales,
) {
  final explicit = choice.code;
  if (explicit != null) return explicit;
  for (final locale in deviceLocales) {
    if (supportedLanguageCodes.contains(locale.languageCode)) {
      return locale.languageCode;
    }
  }
  return defaultLanguageCode;
}
