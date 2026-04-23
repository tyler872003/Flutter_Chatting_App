import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/firebase_options.dart';

/// Continue URL for email verification and password-reset links. Must match an
/// [authorized domain](https://console.firebase.google.com/project/_/authentication/settings)
/// (`{projectId}.firebaseapp.com` is added by default).
///
/// [handleCodeInApp] stays **false** so the link opens in the **system browser**
/// (Chrome, Safari). In-app mail webviews and App Links often block the flow;
/// the browser page at `__/auth/action` completes verification reliably.
ActionCodeSettings firebaseEmailActionCodeSettings() {
  final projectId = DefaultFirebaseOptions.android.projectId;
  return ActionCodeSettings(
    url: 'https://$projectId.firebaseapp.com/',
    handleCodeInApp: false,
  );
}
