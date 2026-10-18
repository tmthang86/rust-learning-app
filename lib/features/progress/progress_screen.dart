import 'package:flutter/material.dart';

import '../../account/account_service.dart';
import '../../data/app_state.dart';
import '../../data/models.dart';

/// Sign in to sync progress, or shows who is signed in.
class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  bool _busy = false;

  Future<void> _signIn(SignInMethod method) async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).accounts.signIn(method);
    } catch (e) {
      // Closing the sign-in window also lands here; a short note is enough.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Sign-in didn't finish. Please try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'This permanently deletes your account and the progress saved '
          'with it on all your devices. Progress on this device is cleared '
          "too. This can't be undone.\n\n"
          'You may be asked to sign in again to confirm.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await state.deleteAccount();
      messenger.showSnackBar(
        const SnackBar(content: Text('Your account has been deleted.')),
      );
    } catch (e) {
      debugPrint('Account deletion failed: $e');
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Your account wasn't deleted. Please try again."),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
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
                        onPressed: _busy ? null : () => state.accounts.signOut(),
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
                  for (final method in state.accounts.methods)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _signIn(method),
                        icon: Icon(method == SignInMethod.apple
                            ? Icons.apple
                            : Icons.account_circle_outlined),
                        label: Text(method == SignInMethod.apple
                            ? 'Continue with Apple'
                            : 'Continue with Google'),
                      ),
                    ),
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
              if (state.accounts.available) ...[
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
            ],
          ),
        ),
      ),
    );
  }
}
