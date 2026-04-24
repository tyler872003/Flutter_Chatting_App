import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kMustVerifyEmailUid = 'must_verify_email_uid';

/// In-memory session flag: set right after [createUserWithEmailAndPassword]
/// so [AuthGate] shows the verification screen before prefs I/O completes.
class EmailRegistrationSession {
  EmailRegistrationSession._();

  static String? _uid;

  /// Prevents [AuthGate] from routing to home during the auth-state race
  /// that happens between createUser and our session setup.
  static bool _passwordRegistrationInFlight = false;

  static void beginPasswordRegistration() =>
      _passwordRegistrationInFlight = true;

  static void endPasswordRegistration() =>
      _passwordRegistrationInFlight = false;

  static bool get isPasswordRegistrationInFlight =>
      _passwordRegistrationInFlight;

  /// Picked at register; uploaded only after [User.emailVerified] is true.
  static Uint8List? pendingProfilePhotoBytes;
  static String pendingProfilePhotoContentType = 'image/jpeg';

  static void mark(String uid) => _uid = uid;

  static void clear() => _uid = null;

  static bool matches(String uid) => _uid != null && _uid == uid;

  static void setPendingProfilePhoto(
    Uint8List bytes, {
    required String contentType,
  }) {
    pendingProfilePhotoBytes = bytes;
    pendingProfilePhotoContentType = contentType;
  }

  static void clearPendingProfilePhoto() {
    pendingProfilePhotoBytes = null;
    pendingProfilePhotoContentType = 'image/jpeg';
  }
}

/// Persisted hint — cleared on sign-in, successful verification, or sign-out.
Future<void> setMustVerifyEmailPending(String uid) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_kMustVerifyEmailUid, uid);
}

Future<void> clearMustVerifyEmailPending() async {
  EmailRegistrationSession.clear();
  final p = await SharedPreferences.getInstance();
  await p.remove(_kMustVerifyEmailUid);
}

/// Whether to block the app with [EmailVerificationScreen].
///
/// Any email/password account with [User.emailVerified] == false is blocked.
/// OAuth-only accounts (no password provider) are not gated.
bool shouldShowEmailVerificationGate(User user) {
  if (user.emailVerified) return false;
  if (EmailRegistrationSession.isPasswordRegistrationInFlight) return true;
  return user.providerData.any((p) => p.providerId == 'password');
}
