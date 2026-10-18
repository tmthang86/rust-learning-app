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

  @override
  Future<void> signIn(SignInMethod method) async {
    final AuthProvider provider = switch (method) {
      SignInMethod.google => GoogleAuthProvider(),
      SignInMethod.apple => AppleAuthProvider()..addScope('email')..addScope('name'),
    };
    if (kIsWeb) {
      await _auth.signInWithPopup(provider);
    } else {
      await _auth.signInWithProvider(provider);
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();
}
