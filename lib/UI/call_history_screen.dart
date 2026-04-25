import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:flutter/material.dart';

class CallHistoryScreen extends StatelessWidget {
  const CallHistoryScreen({
    super.key,
    required this.chatId,
    required this.title,
  });

  final String chatId;
  final String title;

  bool _isCallType(String type) {
    return type == 'call_started' || type == 'call_ended' || type == 'call_event';
  }

  String _twoDigits(int v) => v.toString().padLeft(2, '0');

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = _twoDigits(dt.minute);
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  String _formatDuration(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${_twoDigits(minutes)}:${_twoDigits(seconds)}';
  }

  ({IconData icon, String label}) _formatEntry(
    Map<String, dynamic> data,
    bool mine,
  ) {
    final type = data['messageType'] as String? ?? 'text';
    final text = data['text'] as String? ?? '';

    if (type == 'call_started') {
      final isVideo = text == 'video';
      return (
        icon: isVideo ? Icons.videocam : Icons.call,
        label: mine
            ? (isVideo ? 'Outgoing video call' : 'Outgoing voice call')
            : (isVideo ? 'Incoming video call' : 'Incoming voice call'),
      );
    }

    if (type == 'call_ended') {
      final isVideo = text == 'video';
      final secs = (data['durationSeconds'] as num?)?.toInt() ?? 0;
      return (
        icon: Icons.schedule,
        label:
            '${isVideo ? 'Video call' : 'Voice call'} • ${_formatDuration(secs)}',
      );
    }

    final lower = text.toLowerCase();
    final icon = lower.contains('missed')
        ? Icons.call_missed
        : lower.contains('declined')
        ? Icons.call_end
        : Icons.phone_disabled;
    return (icon: icon, label: text);
  }

  @override
  Widget build(BuildContext context) {
    final selfId = FirebaseAuth.instance.currentUser?.uid;
    final repo = ChatRepository();

    return Scaffold(
      appBar: AppBar(title: Text('$title • Calls')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: repo.messages(chatId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final callDocs = snapshot.data!.docs.where((doc) {
            final type = doc.data()['messageType'] as String? ?? 'text';
            return _isCallType(type);
          }).toList();

          if (callDocs.isEmpty) {
            return const Center(child: Text('No call history yet.'));
          }

          return ListView.separated(
            itemCount: callDocs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final data = callDocs[index].data();
              final mine = (data['senderId'] as String? ?? '') == selfId;
              final ts = data['createdAt'] as Timestamp?;
              final when = ts?.toDate() ?? DateTime.now();
              final entry = _formatEntry(data, mine);

              return ListTile(
                leading: Icon(entry.icon),
                title: Text(entry.label),
                subtitle: Text(_formatTime(when)),
              );
            },
          );
        },
      ),
    );
  }
}
