import 'package:flutter/material.dart';

import '../../account/account_service.dart';
import '../../data/app_state.dart';

/// What to tell the person when an account action didn't finish.
String accountErrorMessage(AccountErrorKind kind, {SignInMethod? attempted}) =>
    switch (kind) {
      AccountErrorKind.cancelled => "Sign-in didn't finish. Please try again.",
      AccountErrorKind.popupBlocked =>
        'Your browser blocked the sign-in window. Allow pop-ups for this '
            'site, then try again.',
      AccountErrorKind.otherProvider => switch (attempted) {
        SignInMethod.apple =>
          'This email already has an account that uses Google. '
              'Please use "Continue with Google" instead.',
        SignInMethod.google =>
          'This email already has an account that uses Apple. '
              'Please use "Continue with Apple" instead.',
        null =>
          'This email already has an account with another sign-in method.',
      },
      AccountErrorKind.wrongAccount =>
        'That was a different account. Please confirm with the account you '
            'are signed in with.',
      AccountErrorKind.network =>
        "Couldn't reach the server. Check your connection and try again.",
      AccountErrorKind.unconfirmed =>
        "We couldn't confirm whether it went through. Your progress is kept "
            'on this device and nothing is sent to the cloud for now. When '
            "you're back online, open this again: the app checks with the "
            'server and either shows the account as deleted or lets you '
            'delete it again.',
      AccountErrorKind.notSignedIn => 'Please sign in first.',
      AccountErrorKind.ageRestricted =>
        "Accounts aren't available. Your progress is saved on this device.",
      AccountErrorKind.other => 'Something went wrong. Please try again.',
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
        SnackBar(content: Text(accountErrorMessage(kind, attempted: method))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = AppScope.of(context).accounts;
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
                    ? 'Continue with Apple'
                    : 'Continue with Google',
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
      title: const Text('Sign out anyway?'),
      content: const Text(
        "Progress on this device isn't saved to your account yet. Signing "
        'out removes it from this device, so it would be lost.\n\n'
        'Stay signed in and try again when you are online to keep it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Stay signed in'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Sign out anyway'),
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
        _error = kind == AccountErrorKind.unconfirmed
            ? 'Your account may not have been deleted. ${accountErrorMessage(kind)}'
            : "Your account wasn't deleted. ${accountErrorMessage(kind)}";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The system back button must not close the dialog mid-deletion.
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This permanently deletes your account and the progress saved '
              'with it on all your devices. Progress on this device is cleared '
              "too. This can't be undone.\n\n"
              "You'll be asked to sign in again to confirm.",
            ),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: _busy ? null : _delete,
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
  }
}
