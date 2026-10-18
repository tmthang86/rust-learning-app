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

/// Why an account action didn't finish, in terms the UI can explain.
enum AccountErrorKind {
  /// The person closed the sign-in window.
  cancelled,

  /// The browser blocked the sign-in pop-up.
  popupBlocked,

  /// The email already has an account that uses the other sign-in method.
  otherProvider,

  /// Confirmed with a different account than the one signed in.
  wrongAccount,

  /// No connection, or the server took too long.
  network,

  /// Deleting may or may not have worked; it couldn't be checked.
  unconfirmed,

  notSignedIn,
  other,
}

class AccountException implements Exception {
  const AccountException(this.kind, [this.detail]);

  final AccountErrorKind kind;
  final Object? detail;

  @override
  String toString() => 'AccountException($kind, $detail)';
}

/// What a fresh sign-in returned, needed to finish deleting the account.
class ReauthProof {
  const ReauthProof({this.appleAuthorizationCode});

  /// Lets Firebase revoke the person's Apple tokens. Only Apple hands it
  /// out, and only on a fresh sign-in (not on the web).
  final String? appleAuthorizationCode;
}

/// Signing in and out. Lets the rest of the app ignore whether Firebase is
/// configured in this build.
///
/// Methods throw [AccountException] when they fail.
abstract class AccountService {
  /// False when accounts aren't set up in this build; the UI hides sign-in.
  bool get available;

  AccountUser? get currentUser;
  Stream<AccountUser?> get userChanges;

  /// Sign-in methods to offer on this platform.
  List<SignInMethod> get methods;

  Future<void> signIn(SignInMethod method);
  Future<void> signOut();

  /// Asks the signed-in person to sign in again with the same provider, to
  /// confirm account deletion. Call it straight from the button press, so
  /// a browser lets the sign-in pop-up open.
  Future<ReauthProof> reauthenticate();

  /// Permanently deletes the signed-in account (App Store guideline
  /// 5.1.1(v), Google Play account deletion). Call [reauthenticate] first.
  /// Revoking Apple tokens is best-effort.
  Future<void> deleteUser(ReauthProof proof);

  /// After [deleteUser] failed: whether the account is in fact still
  /// there, or null when that can't be told right now (offline).
  Future<bool?> accountStillExists();
}

/// Used when Firebase isn't configured: progress stays on the device.
class DisabledAccountService implements AccountService {
  const DisabledAccountService();

  static const _off = AccountException(AccountErrorKind.notSignedIn);

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
  Future<ReauthProof> reauthenticate() async => throw _off;
  @override
  Future<void> deleteUser(ReauthProof proof) async => throw _off;
  @override
  Future<bool?> accountStillExists() async => false;
}

/// Maps Firebase Auth error codes to what the UI explains.
AccountException accountExceptionFrom(Object e) {
  if (e is AccountException) return e;
  if (e is FirebaseAuthException) {
    final kind = switch (e.code) {
      'popup-closed-by-user' ||
      'cancelled-popup-request' ||
      'web-context-cancelled' ||
      'web-context-canceled' ||
      'canceled' => AccountErrorKind.cancelled,
      'popup-blocked' => AccountErrorKind.popupBlocked,
      'account-exists-with-different-credential' ||
      'credential-already-in-use' => AccountErrorKind.otherProvider,
      'user-mismatch' => AccountErrorKind.wrongAccount,
      'network-request-failed' => AccountErrorKind.network,
      _ => AccountErrorKind.other,
    };
    return AccountException(kind, e);
  }
  return AccountException(AccountErrorKind.other, e);
}

class FirebaseAccountService implements AccountService {
  FirebaseAccountService([FirebaseAuth? auth])
    : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  static const _appleId = 'apple.com';

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
    final apple =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    return [SignInMethod.google, if (apple) SignInMethod.apple];
  }

  static AuthProvider _provider(SignInMethod method) => switch (method) {
    SignInMethod.google => GoogleAuthProvider(),
    SignInMethod.apple =>
      AppleAuthProvider()
        ..addScope('email')
        ..addScope('name'),
  };

  @override
  Future<void> signIn(SignInMethod method) async {
    final provider = _provider(method);
    try {
      if (kIsWeb) {
        await _auth.signInWithPopup(provider);
      } else {
        await _auth.signInWithProvider(provider);
      }
    } catch (e) {
      throw accountExceptionFrom(e);
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<ReauthProof> reauthenticate() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AccountException(AccountErrorKind.notSignedIn);
    }
    final apple = user.providerData.any((p) => p.providerId == _appleId);
    // Google is the only other provider the app offers.
    final provider = _provider(
      apple ? SignInMethod.apple : SignInMethod.google,
    );
    try {
      // No await before this call: on the web the pop-up must open while
      // the browser still counts it as a response to the click.
      final credential = kIsWeb
          ? await user.reauthenticateWithPopup(provider)
          : await user.reauthenticateWithProvider(provider);
      return ReauthProof(
        appleAuthorizationCode: apple
            ? credential.additionalUserInfo?.authorizationCode
            : null,
      );
    } catch (e) {
      throw accountExceptionFrom(e);
    }
  }

  @override
  Future<void> deleteUser(ReauthProof proof) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AccountException(AccountErrorKind.notSignedIn);
    }
    final code = proof.appleAuthorizationCode;
    if (code != null) {
      try {
        // Apple asks apps with Sign in with Apple to revoke the user's
        // tokens on deletion. Needs the Apple key set up in Firebase
        // (docs/firebase-setup.md).
        await _auth.revokeTokenWithAuthorizationCode(code);
      } catch (e) {
        debugPrint('Apple token revocation failed: $e');
      }
    }
    try {
      await user.delete();
    } catch (e) {
      throw accountExceptionFrom(e);
    }
  }

  @override
  Future<bool?> accountStillExists() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      // Asks the server, not the cached user.
      await user.reload().timeout(const Duration(seconds: 10));
      return true;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' || e.code == 'user-token-expired') {
        return false;
      }
      return null;
    } catch (_) {
      return null; // offline or timed out: can't tell
    }
  }
}
