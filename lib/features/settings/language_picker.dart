import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/language.dart';
import '../../l10n/l10n.dart';

/// The language setting: System (follow the device), English or Tiếng Việt.
/// The language names are written in their own language, so anyone can find
/// theirs whichever language the app is showing.
class LanguagePicker extends StatelessWidget {
  const LanguagePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.languageLabel,
      child: SegmentedButton<AppLanguage>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: AppLanguage.system,
            label: Text(l10n.languageSystem),
          ),
          ButtonSegment(
            value: AppLanguage.english,
            label: Text(l10n.languageEnglish),
          ),
          ButtonSegment(
            value: AppLanguage.vietnamese,
            label: Text(l10n.languageVietnamese),
          ),
        ],
        selected: {state.language},
        onSelectionChanged: (s) => state.setLanguage(s.first),
      ),
    );
  }
}

/// The picker with a heading, for a screen of its own settings (Progress)
/// or the bottom of a first-launch screen.
class LanguageSetting extends StatelessWidget {
  const LanguageSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.language, size: 20),
            const SizedBox(width: 8),
            Text(context.l10n.languageLabel, style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 8),
        const SizedBox(width: double.infinity, child: LanguagePicker()),
      ],
    );
  }
}
