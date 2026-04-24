import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// How long a chat is muted.
enum MuteDuration { oneHour, eightHours, oneDay, forever }

extension MuteDurationLabel on MuteDuration {
  String get label {
    switch (this) {
      case MuteDuration.oneHour:
        return '1 hour';
      case MuteDuration.eightHours:
        return '8 hours';
      case MuteDuration.oneDay:
        return '24 hours';
      case MuteDuration.forever:
        return 'Forever';
    }
  }

  DateTime? get expiresAt {
    final now = DateTime.now();
    switch (this) {
      case MuteDuration.oneHour:
        return now.add(const Duration(hours: 1));
      case MuteDuration.eightHours:
        return now.add(const Duration(hours: 8));
      case MuteDuration.oneDay:
        return now.add(const Duration(hours: 24));
      case MuteDuration.forever:
        return null;
    }
  }
}

class NotificationRepository {
  // Singleton — one instance across the whole app
  static final NotificationRepository _instance =
      NotificationRepository._internal();
  factory NotificationRepository() => _instance;
  NotificationRepository._internal()
    : _db = FirebaseFirestore.instance,
      _auth = FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  DocumentReference<Map<String, dynamic>>? get _settingsRef {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    return _db
        .collection('users')
        .doc(uid)
        .collection('settings')
        .doc('notifications');
  }

  // ── Stream ─────────────────────────────────────────────────────────────────

  Stream<DocumentSnapshot<Map<String, dynamic>>?> settingsStream() {
    final ref = _settingsRef;
    if (ref == null) return Stream.value(null);
    return ref.snapshots();
  }

  // ── Global toggles ─────────────────────────────────────────────────────────

  Future<void> setNotifyMessages(bool value) =>
      _update({'notifyMessages': value});

  Future<void> setNotifyStories(bool value) =>
      _update({'notifyStories': value});

  Future<void> setNotifyMentions(bool value) =>
      _update({'notifyMentions': value});

  // ── Per-chat mute ──────────────────────────────────────────────────────────

  Future<void> muteChat(String chatId, MuteDuration duration) async {
    final ref = _settingsRef;
    if (ref == null) return;
    final expires = duration.expiresAt;
    final value = expires == null ? -1 : expires.millisecondsSinceEpoch;
    // Write as a real nested map so reads via settings['mutedChats'][chatId] work.
    await ref.set({
      'mutedChats': {chatId: value},
    }, SetOptions(merge: true));
    debugPrint('✅ muteChat: mutedChats[$chatId] = $value');
  }

  Future<void> unmuteChat(String chatId) async {
    final ref = _settingsRef;
    if (ref == null) return;
    // Read current doc, remove the key, write whole map back.
    final snap = await ref.get();
    final data = snap.data() ?? {};
    final mutedChats = Map<String, dynamic>.from(
      (data['mutedChats'] as Map<String, dynamic>?) ?? {},
    );
    mutedChats.remove(chatId);
    await ref.set({'mutedChats': mutedChats}, SetOptions(merge: true));
    debugPrint('✅ unmuteChat done, remaining: $mutedChats');
  }

  /// Reads the muted value for [chatId] from the nested 'mutedChats' map.
  dynamic _getMutedValue(Map<String, dynamic> settings, String chatId) {
    final mutedChats = settings['mutedChats'];
    if (mutedChats is Map) {
      return mutedChats[chatId];
    }
    return null;
  }

  bool isMuted(Map<String, dynamic>? settings, String chatId) {
    if (settings == null) return false;
    final value = _getMutedValue(settings, chatId);
    if (value == null) return false;
    if (value == -1) return true;
    if (value is int) {
      return DateTime.now().millisecondsSinceEpoch < value;
    }
    return false;
  }

  String? muteStatusLabel(Map<String, dynamic>? settings, String chatId) {
    if (settings == null) return null;
    final value = _getMutedValue(settings, chatId);
    if (value == null) return null;
    if (value == -1) return 'Muted forever';
    if (value is int) {
      final until = DateTime.fromMillisecondsSinceEpoch(value);
      if (DateTime.now().isBefore(until)) {
        final h = until.hour.toString().padLeft(2, '0');
        final m = until.minute.toString().padLeft(2, '0');
        final isToday = until.day == DateTime.now().day;
        return 'Muted until $h:$m${isToday ? '' : ' tomorrow'}';
      }
    }
    return null;
  }

  Future<void> _update(Map<String, dynamic> data) async {
    final ref = _settingsRef;
    if (ref == null) {
      debugPrint('❌ notifRepo: user not logged in');
      return;
    }
    try {
      await ref.set(data, SetOptions(merge: true));
      debugPrint('✅ notifRepo: saved $data');
    } catch (e) {
      debugPrint('❌ notifRepo: ERROR - $e');
    }
  }

  static Map<String, dynamic> defaults() => {
    'notifyMessages': true,
    'notifyStories': true,
    'notifyMentions': true,
    'mutedChats': <String, dynamic>{},
  };
}
