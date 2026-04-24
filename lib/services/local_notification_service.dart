import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/services/notification_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The chatId of the screen the user is currently looking at.
/// Set this to [widget.chatId] in ChatRoomScreen.initState and clear it in dispose.
/// When set, incoming messages for this chat are suppressed (no banner shown).
String? activeChatId;

/// Singleton service that:
/// 1. Initialises flutter_local_notifications
/// 2. Listens to every chat the current user is a participant of
/// 3. Shows a banner for new messages — unless the chat is muted or open
class LocalNotificationService {
  LocalNotificationService._();
  static final LocalNotificationService instance = LocalNotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _notifRepo = NotificationRepository();
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  // Track the latest message timestamp per chat so we only alert on NEW ones.
  final Map<String, DateTime> _lastSeen = {};

  // Active Firestore listeners — cancelled on stop()
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _initialised = false;

  // ── Public API ─────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(initSettings);

    // Request notification permission on Android 13+
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    debugPrint('✅ LocalNotificationService: initialised');
    _startListening();
  }

  void stop() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _lastSeen.clear();
    _initialised = false;
    debugPrint('🛑 LocalNotificationService: stopped');
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _startListening() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    // Listen to all chats where this user is a participant
    final chatsSub = _db
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots()
        .listen((snapshot) {
          for (final chatDoc in snapshot.docs) {
            _ensureMessageListener(chatDoc.id, uid);
          }
        });

    _subs.add(chatsSub);
  }

  // Keep track of which chats already have a message listener
  final Set<String> _watchedChats = {};

  void _ensureMessageListener(String chatId, String uid) {
    if (_watchedChats.contains(chatId)) return;
    _watchedChats.add(chatId);

    // Seed lastSeen so the FIRST snapshot doesn't fire for old messages
    _lastSeen[chatId] = DateTime.now();

    final msgSub = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) async {
          if (snapshot.docs.isEmpty) return;
          final doc = snapshot.docs.first;
          final data = doc.data();

          // Ignore messages sent by the current user
          final senderId = data['senderId'] as String?;
          if (senderId == uid) return;

          // Parse timestamp
          final ts = data['createdAt'];
          DateTime? msgTime;
          if (ts is Timestamp) msgTime = ts.toDate();
          if (msgTime == null) return;

          // Only fire for messages newer than what we last saw
          final prev = _lastSeen[chatId];
          if (prev != null && !msgTime.isAfter(prev)) return;
          _lastSeen[chatId] = msgTime;

          // Suppress if this chat is currently open
          if (activeChatId == chatId) return;

          // Suppress if chat is muted
          final settingsSnap = await _notifRepo.settingsStream().first;
          final settings = settingsSnap?.data();
          if (_notifRepo.isMuted(settings, chatId)) return;

          // Build notification content
          final senderEmail = data['senderEmail'] as String? ?? 'Someone';
          final senderName = senderEmail.split('@').first;
          final msgType = data['messageType'] as String? ?? 'text';
          final body = switch (msgType) {
            'image' => '📷 Sent a photo',
            'audio' => '🎤 Sent a voice message',
            'file' => '📎 Sent a file',
            _ => (data['text'] as String?)?.trim() ?? 'New message',
          };

          await _showNotification(
            id: chatId.hashCode,
            title: senderName,
            body: body,
          );
        });

    _subs.add(msgSub);
  }

  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'chat_messages',
      'Chat Messages',
      channelDescription: 'Notifications for new chat messages',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );

    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(id, title, body, details);
    debugPrint('🔔 Notification shown: [$title] $body');
  }
}
