import 'package:flutter/material.dart';

import '../../account/account_service.dart';
import '../../data/app_state.dart';
import '../../l10n/l10n.dart';

/// What to tell the person when an account action didn't finish.
String accountErrorMessage(
  AppLocalizations l10n,
  AccountErrorKind kind, {
  SignInMethod? attempted,
}) => switch (kind) {
  AccountErrorKind.cancelled => l10n.errCancelled,
  AccountErrorKind.popupBlocked => l10n.errPopupBlocked,
  AccountErrorKind.otherProvider => switch (attempted) {
    SignInMethod.apple => l10n.errOtherProviderGoogle,
    SignInMethod.google => l10n.errOtherProviderApple,
    null => l10n.errOtherProviderUnknown,
  },
  AccountErrorKind.wrongAccount => l10n.errWrongAccount,
  AccountErrorKind.network => l10n.errNetwork,
  AccountErrorKind.unconfirmed => l10n.errUnconfirmed,
  AccountErrorKind.notSignedIn => l10n.errNotSignedIn,
  AccountErrorKind.ageRestricted => l10n.errAgeRestricted,
  AccountErrorKind.other => l10n.errOther,
};

/// "Continue with Google / Apple" buttons.
class SignInButtons extends StatefulWidget {
  const SignInButtons({super.key, this.toDelete = false});

  /// Signing in only to delete an existing account (allowed even when
  /// accounts are otherwise off, see [AppState.signIn]).
  final bool toDelete;

  @override
  State<SignInButtons> createState() => _SignInButtonsState();
}

class _SignInButtonsState extends State<SignInButtons> {
  bool _busy = false;

  Future<void> _signIn(SignInMethod method) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    // Start the sign-in before any await, so a browser treats the pop-up
    // as a response to the click.
    final signIn = AppScope.read(
      context,
    ).signIn(method, toDelete: widget.toDelete);
    setState(() => _busy = true);
    try {
      await signIn;
    } catch (e) {
      final kind = e is AccountException ? e.kind : AccountErrorKind.other;
      messenger.showSnackBar(
        SnackBar(
          content: Text(accountErrorMessage(l10n, kind, attempted: method)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = AppScope.of(context).accounts;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final method in accounts.methods)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _signIn(method),
              icon: Icon(
                method == SignInMethod.apple
                    ? Icons.apple
                    : Icons.account_circle_outlined,
              ),
              label: Text(
                method == SignInMethod.apple
                    ? l10n.continueWithApple
                    : l10n.continueWithGoogle,
              ),
            ),
          ),
      ],
    );
  }
}

/// Signs out, asking first if this device's progress may not be saved to
/// the account yet (signing out clears it from the device).
Future<void> signOutWithCheck(BuildContext context) async {
  final state = AppScope.read(context);
  if (await state.signOut()) return;
  if (!context.mounted) return;
  final anyway = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.signOutAnywayTitle),
      content: Text(context.l10n.signOutAnywayBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.staySignedIn),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n.signOutAnyway),
        ),
      ],
    ),
  );
  if (anyway == true) await state.signOut(force: true);
}

/// Confirms and deletes the signed-in account. Returns true once deleted.
Future<bool> confirmAndDeleteAccount(BuildContext context) async {
  final state = AppScope.read(context);
  // An earlier attempt couldn't be confirmed: ask the server first, so an
  // account that is already gone shows as deleted.
  if (state.deletionUnconfirmed && await state.recheckDeletion() == false) {
    return true;
  }
  if (!context.mounted) return false;
  await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _DeleteAccountDialog(),
  );
  // Not the dialog's result: clearing the device can send the app back to
  // the welcome screen, which closes the dialog before it can answer.
  return state.user == null;
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    // The confirming sign-in starts right here, in the click handler, so
    // a browser lets its pop-up open.
    final l10n = context.l10n;
    final deletion = AppScope.read(context).deleteAccount();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await deletion;
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      debugPrint('Account deletion failed: $e');
      if (!mounted) return;
      final kind = e is AccountException ? e.kind : AccountErrorKind.other;
      setState(() {
        _busy = false;
        final reason = accountErrorMessage(l10n, kind);
        _error = kind == AccountErrorKind.unconfirmed
            ? l10n.deleteMaybeFailed(reason)
            : l10n.deleteFailed(reason);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    // The system back button must not close the dialog mid-deletion.
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.deleteDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.deleteDialogBody),
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: _busy ? null : _delete,
            child: Text(l10n.deleteAccount),
          ),
        ],
      ),
    );
  }
}
