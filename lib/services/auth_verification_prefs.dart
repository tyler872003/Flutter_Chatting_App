import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kMustVerifyEmailUid = 'must_verify_email_uid';

/// In-memory only: set **synchronously** right after [createUserWithEmailAndPassword]
/// so [AuthGate] can show the verification screen before prefs I/O completes.
class EmailRegistrationSession {
  EmailRegistrationSession._();

  static String? _uid;

  /// True from before [createUserWithEmailAndPassword] until prefs + session are set.
  /// Stops [authStateChanges] from opening home before [mark]/prefs run.
  static bool _passwordRegistrationInFlight = false;

  static void beginPasswordRegistration() => _passwordRegistrationInFlight = true;

  static void endPasswordRegistration() => _passwordRegistrationInFlight = false;

  static bool get isPasswordRegistrationInFlight => _passwordRegistrationInFlight;

  /// Picked at register; uploaded to Storage only after [User.emailVerified] is true.
  static Uint8List? pendingProfilePhotoBytes;
  static String pendingProfilePhotoContentType = 'image/jpeg';

  static void mark(String uid) => _uid = uid;

  static void clear() => _uid = null;

  static bool matches(String uid) => _uid != null && _uid == uid;

  static void setPendingProfilePhoto(Uint8List bytes, {required String contentType}) {
    pendingProfilePhotoBytes = bytes;
    pendingProfilePhotoContentType = contentType;
  }

  static void clearPendingProfilePhoto() {
    pendingProfilePhotoBytes = null;
    pendingProfilePhotoContentType = 'image/jpeg';
  }
}

/// Persisted hint for the same session; [shouldShowEmailVerificationGate] no
/// longer depends on this (unverified password users are always gated).
/// Cleared on sign-in, successful verification, or sign out.
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
/// Any **email/password** account with [User.emailVerified] == false must
/// verify before home (register **or** sign-in). OAuth-only accounts without a
/// password provider are not gated here.
bool shouldShowEmailVerificationGate(User user) {
  if (user.emailVerified) return false;
  if (EmailRegistrationSession.isPasswordRegistrationInFlight) return true;

  final usesEmailPassword =
      user.providerData.any((p) => p.providerId == 'password');
  if (!usesEmailPassword) return false;

  return true;
}
