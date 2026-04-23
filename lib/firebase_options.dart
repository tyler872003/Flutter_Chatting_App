// Generated from `android/app/google-services.json` for Android.
// Re-run `flutterfire configure` if you add apps or change the Firebase project.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

/// Default [FirebaseOptions] for Android. Other platforms are not supported.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return android;
    }
    throw UnsupportedError(
      'This project targets Android only. Run on an Android device or emulator, '
      'or run `flutterfire configure` and add other platforms if you need them.',
    );
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDeEg9TBIwNrwYqZEYbaIJ-P-I9szzbI88',
    appId: '1:523230196876:android:75b24af3ddcd79896137a9',
    messagingSenderId: '523230196876',
    projectId: 'example-ead6c',
    storageBucket: 'example-ead6c.firebasestorage.app',
  );
}
