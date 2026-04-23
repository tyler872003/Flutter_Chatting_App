import 'package:first_app/services/notification_repository.dart';
import 'package:flutter/material.dart';

/// Shows a Telegram-style bottom sheet to mute/unmute [chatId].
///
/// Usage:
/// ```dart
/// await MuteDialog.show(context, chatId: chatId, settings: settingsMap);
/// ```
class MuteDialog {
  static Future<void> show(
    BuildContext context, {
    required String chatId,
    required Map<String, dynamic>? settings,
    required NotificationRepository repo,
  }) async {
    final isMuted = repo.isMuted(settings, chatId);

    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder:
          (ctx) => _MuteSheet(chatId: chatId, isMuted: isMuted, repo: repo),
    );
  }
}

class _MuteSheet extends StatelessWidget {
  const _MuteSheet({
    required this.chatId,
    required this.isMuted,
    required this.repo,
  });

  final String chatId;
  final bool isMuted;
  final NotificationRepository repo;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.notifications_off_outlined,
                    color: Colors.blueAccent,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    isMuted ? 'Unmute notifications' : 'Mute notifications',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 24),

            if (isMuted) ...[
              _SheetTile(
                icon: Icons.notifications_active_outlined,
                label: 'Unmute',
                color: Colors.green,
                onTap: () async {
                  await repo.unmuteChat(chatId);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ] else ...[
              for (final duration in MuteDuration.values)
                _SheetTile(
                  icon: _iconForDuration(duration),
                  label: 'Mute for ${duration.label}',
                  onTap: () async {
                    await repo.muteChat(chatId, duration);
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            duration == MuteDuration.forever
                                ? 'Notifications muted forever'
                                : 'Notifications muted for ${duration.label}',
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
            ],

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  IconData _iconForDuration(MuteDuration d) {
    switch (d) {
      case MuteDuration.oneHour:
        return Icons.hourglass_top_outlined;
      case MuteDuration.eightHours:
        return Icons.hourglass_bottom_outlined;
      case MuteDuration.oneDay:
        return Icons.bedtime_outlined;
      case MuteDuration.forever:
        return Icons.notifications_off_outlined;
    }
  }
}

class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color ?? Colors.blueAccent),
      title: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w500),
      ),
      onTap: onTap,
    );
  }
}
