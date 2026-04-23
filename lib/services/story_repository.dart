import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class StoryRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

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

  /// Deletes the current user's own expired stories from Firestore.
  /// Call on app start / home screen init to keep the collection clean.
  Future<void> deleteExpiredStories() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final expired =
          await _db
              .collection('stories')
              .where('userId', isEqualTo: user.uid)
              .where('expiresAt', isLessThan: Timestamp.now())
              .get();
      for (final doc in expired.docs) {
        await doc.reference.delete();
      }
    } catch (_) {
      // Non-critical — ignore if rules don't allow it yet
    }
  }
}
