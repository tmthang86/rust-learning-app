import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// `context.l10n.signOut`: the UI strings in the language the app is shown
/// in. They come from lib/l10n/app_*.arb (see docs/i18n/README.md).
extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
