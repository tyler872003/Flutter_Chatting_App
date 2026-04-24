import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class StoryRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Periodic cleanup timer — started by startPeriodicCleanup(), stopped by stopPeriodicCleanup()
  Timer? _cleanupTimer;

  Future<void> postStory(String base64Data) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = Timestamp.now();
    final expiresAt = Timestamp.fromDate(
      now.toDate().add(const Duration(hours: 24)),
    );

    await _db.collection('stories').add({
      'userId': user.uid,
      'base64Data': base64Data,
      'createdAt': now,
      'expiresAt': expiresAt,
      'viewers': <String>[],
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> activeStoriesStream() {
    return _db
        .collection('stories')
        .where('expiresAt', isGreaterThan: Timestamp.now())
        .orderBy('expiresAt')
        .snapshots();
  }

  /// Deletes ALL expired stories from ALL users.
  /// Each user can only delete their own documents per Firestore rules,
  /// so we filter to the current user's expired stories.
  /// For other users' expired stories, Firestore rules must allow it —
  /// or use a Cloud Function. As a workaround we delete any story where
  /// expiresAt is in the past (the stream already hides them from UI).
  Future<void> deleteExpiredStories() async {
    try {
      final expired =
          await _db
              .collection('stories')
              .where('expiresAt', isLessThan: Timestamp.now())
              .get();

      // Delete in parallel for speed
      await Future.wait(expired.docs.map((doc) => doc.reference.delete()));

      if (expired.docs.isNotEmpty) {
        debugPrint('🗑️ Deleted ${expired.docs.length} expired stories');
      }
    } catch (e) {
      debugPrint('⚠️ deleteExpiredStories: $e');
    }
  }

  /// Starts a periodic timer that cleans up expired stories every 30 minutes
  /// while the app is open. Call from HomeChatsScreen.initState().
  void startPeriodicCleanup() {
    _cleanupTimer?.cancel();
    // Run once immediately, then every 30 minutes
    deleteExpiredStories();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      deleteExpiredStories();
    });
    debugPrint('⏱️ Story cleanup timer started');
  }

  /// Stops the periodic cleanup. Call from HomeChatsScreen.dispose().
  void stopPeriodicCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// Lets the current user delete one of their own stories manually.
  Future<void> deleteMyStory(String storyId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await _db.collection('stories').doc(storyId).delete();
  }
}

