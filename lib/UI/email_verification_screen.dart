import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/services/auth_action_link_handler.dart';
import 'package:first_app/services/auth_verification_prefs.dart';
import 'package:first_app/services/auth_verification_settings.dart';
import 'package:flutter/material.dart';

/// After **register** or **sign-in** with an unverified email/password account,
/// the user stays here until [User.emailVerified] is true ([AuthGate]).
class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key, required this.onRecheck});

  /// Call after [User.reload] when [emailVerified] is true so [AuthGate] rebuilds.
  final Future<void> Function() onRecheck;

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  bool _busy = false;
  final _pasteController = TextEditingController();

  User get _user => FirebaseAuth.instance.currentUser!;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    try {
      await _user.sendEmailVerification(firebaseEmailActionCodeSettings());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification email sent.')),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? e.code)),
      );
    }
  }

  Future<void> _applyPastedLink() async {
    final uri = parseFirebaseEmailVerificationUri(_pasteController.text);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No verification link found. Long-press the link or button in the email, '
            'choose Copy link address, then paste here.',
          ),
        ),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await handleIncomingFirebaseAuthLink(uri);
      if (!mounted) return;
      if (result.message != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message!)),
        );
      }
      await FirebaseAuth.instance.currentUser?.reload();
      final verified =
          FirebaseAuth.instance.currentUser?.emailVerified ?? false;
      if (verified) {
        await widget.onRecheck();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reloads the user from Firebase and continues to home if [emailVerified].
  Future<void> _checkVerified() async {
    setState(() => _busy = true);
    try {
      await _user.reload();
      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      final verified =
          FirebaseAuth.instance.currentUser?.emailVerified ?? false;
      if (!mounted) return;
      if (verified) {
        await widget.onRecheck();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Not verified yet. Open the link in Chrome/your browser, or paste the link below, then tap Verified again.',
            ),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? e.code)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = _user.email ?? 'your email';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your email'),
        actions: [
          IconButton(
            tooltip: 'Resend email',
            onPressed: _busy ? null : _resend,
            icon: const Icon(Icons.forward_to_inbox_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text(
                email,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Unverified accounts may be deleted after 2 hours (server cleanup).',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                '1) Open the verification email.\n'
                '2) Tap the link and choose Open in Chrome (or your browser) if the mail app asks.\n'
                '3) Wait until the browser shows that your email is verified.\n'
                '4) Return here and tap the button below.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _checkVerified,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('I verified — continue'),
              ),
              const SizedBox(height: 32),
              Text(
                'If the link will not open',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Long-press the verification link in the email → Copy link address. '
                'Paste it into the box below, then tap Apply link.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pasteController,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  hintText: 'https://…firebaseapp.com/__/auth/action?…',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _applyPastedLink,
                icon: const Icon(Icons.link),
                label: const Text('Apply pasted link'),
              ),
              const SizedBox(height: 48),
              TextButton(
                onPressed: () async {
                  EmailRegistrationSession.clearPendingProfilePhoto();
                  await clearMustVerifyEmailPending();
                  await FirebaseAuth.instance.signOut();
                },
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
