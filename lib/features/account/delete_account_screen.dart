import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_state.dart';
import '../../l10n/l10n.dart';
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
    final l10n = context.l10n;
    final user = state.user;

    final Widget action;
    if (_deleted) {
      action = Semantics(
        liveRegion: true,
        child: Text(
          l10n.accountDeletedSnack,
          style: theme.textTheme.titleMedium,
        ),
      );
    } else if (!state.accounts.available) {
      action = Text(l10n.deletePageNoAccounts);
    } else if (user == null) {
      action = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.signInCreatedNoAccount) ...[
            Semantics(
              liveRegion: true,
              child: Text(l10n.deletePageNothingToDelete),
            ),
            const SizedBox(height: 12),
          ],
          Text(l10n.deletePageSignInPrompt),
          const SizedBox(height: 4),
          const SignInButtons(toDelete: true),
        ],
      );
    } else {
      action = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.deletePageSignedInAs(user.name ?? l10n.signedInFallback),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: _delete,
            icon: const Icon(Icons.delete_forever_outlined),
            label: Text(l10n.deleteAccount),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.deleteYourAccount)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                l10n.deletePageHeading,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(l10n.deletePageIntro),
              const SizedBox(height: 12),
              Text(l10n.deletePageWhatRemoved),
              if (!state.accountsAllowed) ...[
                const SizedBox(height: 12),
                Text(l10n.deletePageChildNote),
              ],
              const SizedBox(height: 24),
              action,
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => context.go('/learn'),
                  child: Text(l10n.goToApp),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
