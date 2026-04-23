import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/services/auth_verification_prefs.dart';

/// Thrown when another account already owns this nickname (case-insensitive).
class NicknameTakenException implements Exception {
  @override
  String toString() => 'Nickname taken';
}

/// Firestore paths: `users/{uid}`, `nicknames/{lowercaseNick}`, `chats/{chatId}`,
/// `chats/{chatId}/messages/{id}`.
///
/// Configure rules so clients can read `nicknames` for availability checks if
/// needed, and create/update only when `request.resource.data.uid == request.auth.uid`.
class ChatRepository {
  ChatRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  User? get currentUser => _auth.currentUser;

  String chatIdForParticipants(String uidA, String uidB) {
    final sorted = [uidA, uidB]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  /// Normalized document id for [nicknames] (lowercase trimmed).
  static String nicknameDocKey(String nickname) => nickname.trim().toLowerCase();

  /// Public nickname: 3–20 chars, letters, digits, underscore only.
  static bool isValidNicknameFormat(String raw) {
    final t = raw.trim();
    return RegExp(r'^[a-zA-Z0-9_]{3,20}$').hasMatch(t);
  }

  /// Reserves `nicknames/{nicknameDocKey(nickname)}` for [uid].
  ///
  /// Call right after [createUserWithEmailAndPassword] while still signed in.
  /// Throws [NicknameTakenException] if the key belongs to another user.
  Future<void> claimNickname({
    required String uid,
    required String nickname,
  }) async {
    final display = nickname.trim();
    final key = nicknameDocKey(display);
    final nickRef = _db.collection('nicknames').doc(key);
    var taken = false;
    await _db.runTransaction((txn) async {
      final snap = await txn.get(nickRef);
      if (snap.exists) {
        final existing = snap.data()?['uid'] as String?;
        if (existing != null && existing != uid) {
          taken = true;
          return;
        }
      }
      txn.set(nickRef, {
        'uid': uid,
        'displayName': display,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    if (taken) throw NicknameTakenException();
  }

  /// Removes a nickname claim if it still points at [uid] (rollback helper).
  Future<void> releaseNicknameIfOwnedBy(String nicknameKey, String uid) async {
    final ref = _db.collection('nicknames').doc(nicknameKey);
    final snap = await ref.get();
    if (snap.exists && snap.data()?['uid'] == uid) {
      await ref.delete();
    }
  }

  Future<void> ensureUserDocument({
    required String uid,
    required String email,
    String? photoUrl,
    String? displayName,
  }) async {
    final cur = _auth.currentUser;
    if (cur != null &&
        cur.uid == uid &&
        !cur.emailVerified &&
        cur.providerData.any((p) => p.providerId == 'password')) {
      return;
    }
    final data = <String, dynamic>{
      'email': email,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (photoUrl != null) {
      data['photoUrl'] = photoUrl;
    }
    if (displayName != null && displayName.trim().isNotEmpty) {
      data['displayName'] = displayName.trim();
    }
    return _db.collection('users').doc(uid).set(data, SetOptions(merge: true));
  }

  /// Resolves profile photo and merges into `users/{uid}`. Does nothing until 
  /// [User.emailVerified] is true so unverified accounts are not written to Firestore.
  Future<void> syncCurrentUserProfileDocument() async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (!user.emailVerified) return;

    final pending = EmailRegistrationSession.pendingProfilePhotoBytes;
    if (pending != null) {
      try {
        await user.getIdToken();
        await updateProfilePhoto(pending);
        EmailRegistrationSession.clearPendingProfilePhoto();
      } catch (_) {
        // Leave pending so a later sync or another **Verified** tap can retry.
      }
    }

    final doc = await _db.collection('users').doc(user.uid).get();
    String? photoUrl = doc.data()?['photoUrl'] as String?;
    photoUrl ??= user.photoURL;

    await ensureUserDocument(
      uid: user.uid,
      email: user.email ?? '',
      photoUrl: photoUrl,
      displayName: user.displayName,
    );
  }

  /// Updates the profile photo for the current user in Firestore as a base64 string.
  Future<String> updateProfilePhoto(Uint8List bytes) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not logged in');

    final base64String = base64Encode(bytes);
    final photoUrl = 'data:image/jpeg;base64,$base64String';

    try {
      await user.updatePhotoURL(photoUrl);
    } catch (_) {}

    await ensureUserDocument(
      uid: user.uid,
      email: user.email ?? '',
      photoUrl: photoUrl,
      displayName: user.displayName,
    );
    
    return photoUrl;
  }

  Future<void> ensureChatDocument({
    required String chatId,
    required List<String> participants,
  }) {
    return _db.collection('chats').doc(chatId).set(
      {
        'participants': participants,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> usersExceptSelf() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      return _db.collection('users').limit(0).snapshots();
    }
    return _db.collection('users').snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> messages(String chatId) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();
  }

  Future<void> sendMessage({
    required String chatId,
    String text = '',
    String messageType = 'text',
    String? base64Data,
    String? fileName,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty && base64Data == null) return;

    final batch = _db.batch();
    final chatRef = _db.collection('chats').doc(chatId);
    final messageRef = chatRef.collection('messages').doc();

    final messageData = <String, dynamic>{
      'text': trimmed,
      'senderId': user.uid,
      'senderEmail': user.email,
      'messageType': messageType,
      'createdAt': FieldValue.serverTimestamp(),
    };
    if (base64Data != null) messageData['base64Data'] = base64Data;
    if (fileName != null) messageData['fileName'] = fileName;

    batch.set(messageRef, messageData);

    String lastMsg = trimmed;
    if (messageType == 'image') lastMsg = '📷 Image';
    if (messageType == 'audio') lastMsg = '🎤 Voice message';
    if (messageType == 'file') lastMsg = '📎 File';

    batch.set(
      chatRef,
      {
        'lastMessage': lastMsg,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  String _messagePreviewFromData(Map<String, dynamic> data) {
    final type = (data['messageType'] as String?) ?? 'text';
    final text = (data['text'] as String?)?.trim() ?? '';
    if (type == 'image') return '📷 Image';
    if (type == 'audio') return '🎤 Voice message';
    if (type == 'file') return '📎 File';
    return text.isEmpty ? 'Message' : text;
  }

  Future<void> deleteMessage({
    required String chatId,
    required String messageId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final chatRef = _db.collection('chats').doc(chatId);
    final messageRef = chatRef.collection('messages').doc(messageId);
    final snap = await messageRef.get();
    if (!snap.exists) return;

    final data = snap.data() ?? <String, dynamic>{};
    final senderId = data['senderId'] as String?;
    if (senderId != user.uid) {
      throw Exception('You can only delete your own messages.');
    }

    await messageRef.delete();

    final latest = await chatRef
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .limit(1)
        .get();

    final lastMessage = latest.docs.isEmpty
        ? ''
        : _messagePreviewFromData(latest.docs.first.data());

    await chatRef.set({
      'lastMessage': lastMessage,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<String> createGroupChat(String groupName, List<String> participantIds) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not logged in');

    final chatRef = _db.collection('chats').doc();
    
    // Ensure current user is in participants
    if (!participantIds.contains(user.uid)) {
      participantIds.add(user.uid);
    }

    await chatRef.set({
      'isGroup': true,
      'groupName': groupName,
      'admin': user.uid,
      'participants': participantIds,
      'updatedAt': FieldValue.serverTimestamp(),
      'lastMessage': 'Group created',
    });

    return chatRef.id;
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> groupChatsStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      return Stream.value([]);
    }
    // Query by participants and sort in memory to avoid composite index requirements
    return _db
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots()
        .map((snapshot) {
      final docs = snapshot.docs.where((doc) => doc.data()['isGroup'] == true).toList();
      docs.sort((a, b) {
        final timeA = (a.data()['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        final timeB = (b.data()['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        return timeB.compareTo(timeA); // Descending
      });
      return docs;
    });
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> directChatsStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      return Stream.value([]);
    }
    return _db
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots()
        .map((snapshot) {
      final docs = snapshot.docs.where((doc) => doc.data()['isGroup'] != true).toList();
      docs.sort((a, b) {
        final timeA = (a.data()['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        final timeB = (b.data()['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        return timeB.compareTo(timeA); // Descending
      });
      return docs;
    });
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>?> currentUserStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream.value(null);
    return _db.collection('users').doc(uid).snapshots();
  }

  Future<void> blockUser(String blockedUid) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).set({
      'blockedUsers': FieldValue.arrayUnion([blockedUid]),
    }, SetOptions(merge: true));
  }

  Future<void> unblockUser(String blockedUid) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).set({
      'blockedUsers': FieldValue.arrayRemove([blockedUid]),
    }, SetOptions(merge: true));
  }
}
