import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import 'account_widgets.dart';

/// Public page at /delete-account (on the web: `<site>/#/delete-account`).
///
/// Google Play asks for a web address where people can ask for their
/// account to be deleted without reinstalling the app. This page explains
/// what deletion removes and runs the same deletion as the Progress screen.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  bool _deleted = false;
  late final AppState _state;

  @override
  void initState() {
    super.initState();
    // After an unconfirmed deletion, check with the server on opening, so
    // an account that is already gone shows as deleted.
    final state = _state = AppScope.read(context);
    if (state.deletionUnconfirmed) {
      state.recheckDeletion().then((exists) {
        if (mounted && exists == false) setState(() => _deleted = true);
      });
    }
  }

  @override
  void dispose() {
    // A child may sign in here only to delete. Leaving without deleting
    // signs them out again (keeping their progress on the device).
    if (!_state.accountsAllowed && _state.user != null) {
      _state.leaveAccountKeepingProgress();
    }
    super.dispose();
  }

  Future<void> _delete() async {
    final deleted = await confirmAndDeleteAccount(context);
    if (mounted && deleted) setState(() => _deleted = true);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final user = state.user;

    final Widget action;
    if (_deleted) {
      action = Semantics(
        liveRegion: true,
        child: Text(
          'Your account has been deleted.',
          style: theme.textTheme.titleMedium,
        ),
      );
    } else if (!state.accounts.available) {
      action = const Text(
        "Accounts aren't switched on in this version of the app, so there is "
        'no account to delete. Progress stays only on your device; '
        'uninstalling the app or clearing its data removes it.',
      );
    } else if (user == null) {
      action = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.signInCreatedNoAccount) ...[
            Semantics(
              liveRegion: true,
              child: const Text(
                'There was no Learn Rust account for that sign-in, so there '
                'is nothing to delete. The sign-in was not kept.',
              ),
            ),
            const SizedBox(height: 12),
          ],
          const Text('Sign in with the account you want to delete.'),
          const SizedBox(height: 4),
          const SignInButtons(toDelete: true),
        ],
      );
    } else {
      action = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Signed in as ${user.label}.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: _delete,
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Delete account'),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Delete your account')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Learn Rust: account deletion',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text(
                'You can delete your Learn Rust account at any time, here or '
                'in the app under Progress → Delete account.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Deleting removes, right away and for good:\n'
                '• your account (the link to your Google or Apple sign-in)\n'
                '• your saved progress: your learning track and the lessons '
                'you finished\n\n'
                'Nothing is kept after deletion. Progress on the device you '
                'delete from is cleared too; on other devices it stays only '
                'until you uninstall the app or clear its data.',
              ),
              if (!state.accountsAllowed) ...[
                const SizedBox(height: 12),
                const Text(
                  'For you, progress on this device stays, saved only here.',
                ),
              ],
              const SizedBox(height: 24),
              action,
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => context.go('/learn'),
                  child: const Text('Go to the app'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
