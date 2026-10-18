import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AccountUser {
  const AccountUser({required this.uid, this.displayName, this.email});

  final String uid;
  final String? displayName;
  final String? email;

  /// Best short label for the signed-in person.
  String get label => displayName ?? email ?? 'Signed in';
}

enum SignInMethod { google, apple }

/// Signing in and out. Lets the rest of the app ignore whether Firebase is
/// configured in this build.
abstract class AccountService {
  /// False when accounts aren't set up in this build; the UI hides sign-in.
  bool get available;

  AccountUser? get currentUser;
  Stream<AccountUser?> get userChanges;

  /// Sign-in methods to offer on this platform.
  List<SignInMethod> get methods;

  Future<void> signIn(SignInMethod method);
  Future<void> signOut();

  /// Permanently deletes the signed-in account (App Store guideline
  /// 5.1.1(v)). Asks the person to sign in again when the provider requires
  /// a recent sign-in. Throws if the account wasn't deleted, for example
  /// when that sign-in is cancelled.
  Future<void> deleteAccount();
}

/// Runs [delete]; if Firebase says the last sign-in is too old, runs
/// [reauthenticate] and tries once more.
Future<void> deleteWithRecentLogin({
  required Future<void> Function() delete,
  required Future<void> Function() reauthenticate,
}) async {
  try {
    await delete();
  } on FirebaseAuthException catch (e) {
    if (e.code != 'requires-recent-login') rethrow;
    await reauthenticate();
    await delete();
  }
}

/// Used when Firebase isn't configured: progress stays on the device.
class DisabledAccountService implements AccountService {
  const DisabledAccountService();

  @override
  bool get available => false;
  @override
  AccountUser? get currentUser => null;
  @override
  Stream<AccountUser?> get userChanges => const Stream.empty();
  @override
  List<SignInMethod> get methods => const [];
  @override
  Future<void> signIn(SignInMethod method) async {}
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteAccount() async {}
}

class FirebaseAccountService implements AccountService {
  FirebaseAccountService([FirebaseAuth? auth]) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  static AccountUser? _toUser(User? u) => u == null
      ? null
      : AccountUser(uid: u.uid, displayName: u.displayName, email: u.email);

  @override
  bool get available => true;

  @override
  AccountUser? get currentUser => _toUser(_auth.currentUser);

  @override
  Stream<AccountUser?> get userChanges => _auth.authStateChanges().map(_toUser);

  @override
  List<SignInMethod> get methods {
    // Apple sign-in on Android needs extra web-flow setup, so it's offered on
    // Apple platforms and the web. App Store rules require it on iOS
    // whenever Google sign-in is offered.
    final apple = kIsWeb ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    return [SignInMethod.google, if (apple) SignInMethod.apple];
  }

  static AuthProvider _provider(SignInMethod method) => switch (method) {
        SignInMethod.google => GoogleAuthProvider(),
        SignInMethod.apple => AppleAuthProvider()..addScope('email')..addScope('name'),
      };

  static const _appleId = 'apple.com';

  @override
  Future<void> signIn(SignInMethod method) async {
    final provider = _provider(method);
    if (kIsWeb) {
      await _auth.signInWithPopup(provider);
    } else {
      await _auth.signInWithProvider(provider);
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();

  Future<UserCredential> _reauthenticate(User user, SignInMethod method) {
    final provider = _provider(method);
    return kIsWeb
        ? user.reauthenticateWithPopup(provider)
        : user.reauthenticateWithProvider(provider);
  }

  @override
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final providers = user.providerData.map((p) => p.providerId).toSet();

    if (providers.contains(_appleId)) {
      // Apple asks apps that offer Sign in with Apple to revoke the user's
      // tokens when the account is deleted. Revoking needs a fresh
      // authorization code, which only a new Apple sign-in hands out, so
      // Apple users always confirm with Apple first. That sign-in is also
      // recent enough for delete().
      final credential = await _reauthenticate(user, SignInMethod.apple);
      final code = credential.additionalUserInfo?.authorizationCode;
      if (code != null) {
        try {
          await _auth.revokeTokenWithAuthorizationCode(code);
        } catch (e) {
          // Needs the Apple key set up in Firebase (docs/firebase-setup.md).
          // Deleting the account matters more than the revocation.
          debugPrint('Apple token revocation failed: $e');
        }
      }
      await user.delete();
      return;
    }

    // Google is the only other provider the app offers.
    await deleteWithRecentLogin(
      delete: user.delete,
      reauthenticate: () => _reauthenticate(user, SignInMethod.google),
    );
  }
}
