import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../account/account_widgets.dart';
import '../settings/language_picker.dart';
import 'monetization_widgets.dart';

/// Sign in to sync progress, or shows who is signed in.
class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  bool _busy = false;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await signOutWithCheck(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    if (await confirmAndDeleteAccount(context)) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.accountDeletedSnack)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final user = state.user;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: user != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(state.syncFailed
                          ? Icons.cloud_off_outlined
                          : Icons.cloud_done_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.name ?? l10n.signedInFallback,
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(state.syncFailed
                                ? l10n.accountSyncFailed
                                : l10n.accountSynced),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _signOut,
                        child: Text(l10n.signOut),
                      ),
                    ],
                  ),
                  if (state.syncFailed)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _busy ? null : state.retrySync,
                        child: Text(l10n.trySyncAgain),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error),
                      onPressed: _busy ? null : _deleteAccount,
                      icon: const Icon(Icons.delete_forever_outlined),
                      label: Text(l10n.deleteAccount),
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.saveProgressTitle, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(l10n.saveProgressBody),
                  const SizedBox(height: 12),
                  const SignInButtons(),
                ],
              ),
      ),
    );
  }
}

/// For someone who may be under 13: no accounts, progress stays on the
/// device. If the app signed them out of an existing account, deleting it
/// is offered prominently.
class _DeviceOnlyCard extends StatelessWidget {
  const _DeviceOnlyCard();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.phone_android_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.deviceOnlyTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (state.childAccountToDelete) ...[
              const SizedBox(height: 12),
              Text(l10n.childAccountOffer),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: () => context.push('/delete-account'),
                icon: const Icon(Icons.delete_forever_outlined),
                label: Text(l10n.deleteYourAccount),
              ),
              TextButton(
                onPressed: state.dismissChildAccountOffer,
                child: Text(l10n.hideChildOffer),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Overall progress and track setting.
class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final total = state.totalLessons;
    final done = state.completedCount;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navProgress)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.lessonsDoneProgress(done, total),
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: total == 0 ? 0 : done / total,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
                ),
              ),
              if (!state.accountsAllowed) ...[
                const SizedBox(height: 16),
                const _DeviceOnlyCard(),
              ] else if (state.accounts.available) ...[
                const SizedBox(height: 16),
                const _AccountCard(),
              ],
              const SizedBox(height: 16),
              for (final unit in state.visibleUnits.where((u) => !u.comingSoon))
                ListTile(
                  leading: CircleAvatar(child: Text('${unit.number}')),
                  title: Text(unit.title),
                  trailing: Text(
                    '${unit.lessons.where((l) => state.isCompleted(l.id)).length}'
                    '/${unit.lessons.length}',
                  ),
                ),
              const Divider(height: 32),
              Text(l10n.learningTrack, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<Track>(
                segments: [
                  ButtonSegment(
                    value: Track.starter,
                    label: Text(l10n.trackNewToCoding),
                  ),
                  ButtonSegment(
                    value: Track.fast,
                    label: Text(l10n.trackExperienced),
                  ),
                ],
                selected: {if (state.track != null) state.track!},
                emptySelectionAllowed: true,
                onSelectionChanged: (s) {
                  if (s.isNotEmpty) state.chooseTrack(s.first);
                },
              ),
              const SizedBox(height: 24),
              const LanguageSetting(),
              const SizedBox(height: 24),
              const RemoveAdsCard(),
              const PrivacyOptionsTile(),
              const ReportAdTile(),
            ],
          ),
        ),
      ),
    );
  }
}
