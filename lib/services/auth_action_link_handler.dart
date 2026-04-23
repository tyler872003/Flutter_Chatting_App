import 'package:firebase_auth/firebase_auth.dart';

/// Outcome after trying to handle a Firebase Auth email action URL.
typedef AuthActionLinkOutcome = ({bool handled, String? message});

/// Pulls a Firebase Auth action [Uri] out of pasted text (plain link, or email
/// body with the URL inside).
Uri? parseFirebaseEmailVerificationUri(String raw) {
  final decoded = raw.trim().replaceAll('&amp;', '&');
  Uri? withOob(Uri? u) {
    if (u == null) return null;
    if (u.queryParameters['oobCode'] != null && u.queryParameters['oobCode']!.isNotEmpty) {
      return u;
    }
    return null;
  }

  var u = withOob(Uri.tryParse(decoded));
  if (u != null) return u;

  final unwrapped = decoded.replaceAll(RegExp(r'^<|>$'), '').trim();
  u = withOob(Uri.tryParse(unwrapped));
  if (u != null) return u;

  final httpsRe = RegExp(
    r'https://[^\s<>"\[\]]+',
    caseSensitive: false,
  );
  for (final m in httpsRe.allMatches(decoded)) {
    u = withOob(Uri.tryParse(m.group(0)!));
    if (u != null) return u;
  }
  return null;
}

/// Parses Firebase Auth out-of-band links (e.g. verify email) and applies them.
Future<AuthActionLinkOutcome> handleIncomingFirebaseAuthLink(Uri uri) async {
  var u = uri;

  final nested = u.queryParameters['link'];
  if (nested != null && nested.isNotEmpty) {
    final inner = Uri.tryParse(Uri.decodeFull(nested));
    if (inner != null && inner.queryParameters['oobCode'] != null) {
      u = inner;
    }
  }

  final mode = u.queryParameters['mode'];
  final oobCode = u.queryParameters['oobCode'];
  if (oobCode == null || oobCode.isEmpty) {
    return (handled: false, message: null);
  }

  if (mode != 'verifyEmail') {
    return (handled: false, message: null);
  }

  try {
    await FirebaseAuth.instance.applyActionCode(oobCode);
    await FirebaseAuth.instance.currentUser?.reload();
    return (handled: true, message: 'Email verified. You can continue in the app.');
  } on FirebaseAuthException catch (e) {
    final code = e.code;
    if (code == 'expired-action-code') {
      return (
        handled: true,
        message: 'This link has expired. Use Resend on the verify screen.',
      );
    }
    if (code == 'invalid-action-code') {
      return (
        handled: true,
        message: 'This link is invalid or was already used.',
      );
    }
    return (handled: true, message: e.message ?? e.code);
  } catch (e) {
    return (handled: true, message: '$e');
  }
}
