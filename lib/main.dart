import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:first_app/UI/email_verification_screen.dart';
import 'package:first_app/UI/home_chats_screen.dart';
import 'package:first_app/UI/login_screen_view.dart';
import 'package:first_app/firebase_options.dart';
import 'package:first_app/services/auth_verification_prefs.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:first_app/services/local_notification_service.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // Native auto-init can still race on some devices; any type may be thrown.
    if (!e.toString().contains('duplicate-app')) rethrow;
  }

  // Initialise the local notification plugin once at startup
  await LocalNotificationService.instance.init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  Widget build(BuildContext context) {
    // Do not use userChanges() here: its first event can be delayed, leaving
    // StreamBuilder stuck in [waiting] with an endless loading screen.
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          // Start listening for notifications when user is logged in
          LocalNotificationService.instance.init();

          // Email/password users stay on [EmailVerificationScreen] until verified.
          if (shouldShowEmailVerificationGate(user)) {
            return EmailVerificationScreen(
              onRecheck: () async {
                await ChatRepository().syncCurrentUserProfileDocument();
                await clearMustVerifyEmailPending();
                if (!mounted) return;
                setState(() {});
              },
            );
          }
          return const HomeChatsScreen();
        }

        // Stop notifications on logout
        LocalNotificationService.instance.stop();
        return const LoginScreen();
      },
    );
  }
}

