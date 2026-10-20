import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import '../../data/models.dart';
import '../account/account_widgets.dart';
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
    if (await confirmAndDeleteAccount(context)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Your account has been deleted.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
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
                            Text(user.label, style: theme.textTheme.titleMedium),
                            Text(state.syncFailed
                                ? "Couldn't sync your progress right now."
                                : 'Progress is synced across your devices.'),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _signOut,
                        child: const Text('Sign out'),
                      ),
                    ],
                  ),
                  if (state.syncFailed)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _busy ? null : state.retrySync,
                        child: const Text('Try syncing again'),
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
                      label: const Text('Delete account'),
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Save your progress', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Sign in to keep your progress on all your devices.'),
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
                    'Your progress is saved on this device',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (state.childAccountToDelete) ...[
              const SizedBox(height: 12),
              const Text(
                'You were signed out of your account on this device. You can '
                'delete the account and the progress saved with it.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: () => context.push('/delete-account'),
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Delete your account'),
              ),
              TextButton(
                onPressed: state.dismissChildAccountOffer,
                child: const Text('Already deleted? Hide this'),
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
    final total = state.totalLessons;
    final done = state.completedCount;

    return Scaffold(
      appBar: AppBar(title: const Text('Progress')),
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
                      Text('$done of $total lessons done',
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
              Text('Learning track', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<Track>(
                segments: const [
                  ButtonSegment(value: Track.starter, label: Text('New to coding')),
                  ButtonSegment(value: Track.fast, label: Text('Experienced')),
                ],
                selected: {if (state.track != null) state.track!},
                emptySelectionAllowed: true,
                onSelectionChanged: (s) {
                  if (s.isNotEmpty) state.chooseTrack(s.first);
                },
              ),
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
