import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:first_app/UI/add_group_members_screen.dart';
import 'package:first_app/UI/agora_call_screen.dart';
import 'package:first_app/UI/call_history_screen.dart';
import 'package:first_app/UI/chat_media_files_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/services/app_theme_service.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:first_app/services/local_notification_service.dart';
import 'package:first_app/services/notification_repository.dart';
import 'package:first_app/widgets/mute_dialog.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class ChatRoomScreen extends StatefulWidget {
  const ChatRoomScreen({
    super.key,
    required this.chatId,
    required this.otherUserId,
    required this.title,
    this.otherUserPhotoUrl,
  });

  final String chatId;
  final String otherUserId;
  final String title;
  final String? otherUserPhotoUrl;

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final _controller = TextEditingController();
  final _repo = ChatRepository();
  final _notifRepo = NotificationRepository();
  bool _ready = false;
  Timer? _clockTicker;

  bool _isRecording = false;
  final _audioRecorder = AudioRecorder();

  bool _isBlocked = false;

  @override
  void initState() {
    super.initState();
    // Suppress notifications while this chat is open
    activeChatId = widget.chatId;
    // Rebuild immediately when the user changes the app theme color
    AppThemeService.instance.addListener(_onThemeChanged);
    _clockTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _prepare();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _prepare() async {
    final self = FirebaseAuth.instance.currentUser;
    if (self == null) return;
    if (widget.otherUserId.isNotEmpty) {
      await _repo.ensureChatDocument(
        chatId: widget.chatId,
        participants: [self.uid, widget.otherUserId],
      );
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    // Clear active chat so notifications resume for this chat
    if (activeChatId == widget.chatId) activeChatId = null;
    AppThemeService.instance.removeListener(_onThemeChanged);
    _clockTicker?.cancel();
    _controller.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  DocumentReference<Map<String, dynamic>> get _activeCallRef => FirebaseFirestore
      .instance
      .collection('chats')
      .doc(widget.chatId)
      .collection('calls')
      .doc('active');

  Future<void> _startCall({required bool isVideoCall, bool announce = false}) async {
    final selfId = FirebaseAuth.instance.currentUser?.uid;
    final self = FirebaseAuth.instance.currentUser;
    final navigator = Navigator.of(context);
    try {
      if (announce && selfId != null) {
        await _activeCallRef
            .set({
              'status': 'ringing',
              'channelId': widget.chatId,
              'callerId': selfId,
              'callerName':
                  (self?.displayName?.trim().isNotEmpty ?? false)
                      ? self!.displayName!.trim()
                      : (self?.email ?? 'Unknown'),
              'chatId': widget.chatId,
              'calleeId': widget.otherUserId,
              'isVideoCall': isVideoCall,
              'createdAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 8));

        final callOutcome = await _waitForCallOutcome();
        if (callOutcome != 'accepted') {
          await _sendCallOutcomeMessage(
            outcome: callOutcome,
            isVideoCall: isVideoCall,
          );
          if (callOutcome == 'declined') {
            _showError('Call declined');
          } else if (callOutcome == 'missed') {
            _showError('Missed call');
          } else if (callOutcome == 'cancelled') {
            _showError('Call cancelled');
          }
          return;
        }
      }

      final callStartedAt = DateTime.now();
      await _repo.sendMessage(
        chatId: widget.chatId,
        text: isVideoCall ? 'video' : 'voice',
        messageType: 'call_started',
      );

      await navigator.push(
        MaterialPageRoute<void>(
          builder:
              (_) => AgoraCallScreen(
                channelId: widget.chatId,
                title: widget.title,
                isVideoCall: isVideoCall,
              ),
        ),
      );

      final durationSeconds = DateTime.now().difference(callStartedAt).inSeconds;
      await _repo.sendMessage(
        chatId: widget.chatId,
        text: isVideoCall ? 'video' : 'voice',
        messageType: 'call_ended',
        extraData: {'durationSeconds': durationSeconds},
      );

      // Mark the call as ended once the call screen is closed.
      if (selfId != null) {
        await _activeCallRef.set({
          'status': 'ended',
          'endedBy': selfId,
          'endedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      _showError('Call setup failed: $e');
      // Fallback so tapping call always opens the call UI.
      await navigator.push(
        MaterialPageRoute<void>(
          builder:
              (_) => AgoraCallScreen(
                channelId: widget.chatId,
                title: widget.title,
                isVideoCall: isVideoCall,
              ),
        ),
      );
    }
  }

  Future<void> _sendCallOutcomeMessage({
    required String outcome,
    required bool isVideoCall,
  }) async {
    String label;
    if (outcome == 'declined') {
      label = isVideoCall ? 'Declined video call' : 'Declined voice call';
    } else if (outcome == 'missed') {
      label = isVideoCall ? 'Missed video call' : 'Missed voice call';
    } else if (outcome == 'cancelled') {
      label = isVideoCall ? 'Cancelled video call' : 'Cancelled voice call';
    } else {
      return;
    }

    await _repo.sendMessage(
      chatId: widget.chatId,
      text: label,
      messageType: 'call_event',
    );
  }

  Future<String> _waitForCallOutcome() async {
    String result = 'missed';
    Timer? timeoutTimer;
    if (!mounted) return result;

    final dialogResult = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final dialogNav = Navigator.of(dialogContext);
        timeoutTimer = Timer(const Duration(seconds: 30), () async {
          await _activeCallRef.set({
            'status': 'missed',
            'missedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          if (dialogNav.canPop()) {
            dialogNav.pop('missed');
          }
        });

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _activeCallRef.snapshots(),
          builder: (context, snapshot) {
            final status = snapshot.data?.data()?['status'] as String? ?? 'ringing';
            if (status != 'ringing') {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (dialogNav.canPop()) {
                  dialogNav.pop(status);
                }
              });
            }

            return AlertDialog(
              title: Text(
                isClosedStatus(status)
                    ? 'Call ${status == 'declined' ? 'declined' : 'ended'}'
                    : 'Calling ${widget.title}',
              ),
              content: Text(
                isClosedStatus(status)
                    ? 'The call was $status.'
                    : 'Waiting for answer...',
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _activeCallRef.set({
                      'status': 'cancelled',
                      'cancelledAt': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));
                    if (dialogNav.canPop()) {
                      dialogNav.pop('cancelled');
                    }
                  },
                  child: const Text('Cancel call'),
                ),
              ],
            );
          },
        );
      },
    );
    timeoutTimer?.cancel();

    if (dialogResult != null && dialogResult.isNotEmpty) {
      result = dialogResult;
    }
    return result;
  }

  bool isClosedStatus(String status) {
    return status == 'declined' ||
        status == 'cancelled' ||
        status == 'missed' ||
        status == 'ended';
  }

  String _formatCallDuration(int totalSeconds) {
    if (totalSeconds < 0) totalSeconds = 0;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${_twoDigits(minutes)}:${_twoDigits(seconds)}';
  }

  /// Shows a confirmation dialog then removes the current user from the group.
  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Leave Group'),
            content: const Text(
              'Are you sure you want to leave this group? You will no longer receive messages from it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Leave',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await _repo.leaveGroupChat(widget.chatId);
      if (mounted) Navigator.of(context).pop(); // go back to home
    } catch (e) {
      if (mounted) _showError('Failed to leave group: $e');
    }
  }

  Future<void> _confirmAndDeleteMessage({
    required String messageId,
    required bool mine,
  }) async {
    if (!mine) return;
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete message'),
          content: const Text('Do you want to delete this message?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) return;
    try {
      await _repo.deleteMessage(chatId: widget.chatId, messageId: messageId);
      _showError('Message deleted');
    } catch (e) {
      _showError('Failed to delete message: $e');
    }
  }

  Future<void> _sendText() async {
    final text = _controller.text;
    _controller.clear();
    try {
      await _repo.sendMessage(
        chatId: widget.chatId,
        text: text,
        messageType: 'text',
      );
    } catch (e) {
      _showError('Failed to send: $e');
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: source,
      imageQuality: 30,
      maxWidth: 600,
    );
    if (image == null) return;
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty) return;
    final base64String = base64Encode(bytes);

    if (base64String.length > 700 * 1024) {
      _showError('Image too large. Must be < 700KB.');
      return;
    }

    try {
      await _repo.sendMessage(
        chatId: widget.chatId,
        messageType: 'image',
        base64Data: 'data:image/jpeg;base64,$base64String',
      );
    } catch (e) {
      _showError('Failed to send image: $e');
    }
  }

  Future<void> _pickFile() async {
    final result = await fp.FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.size > 700 * 1024) {
      _showError('File must be less than 700KB');
      return;
    }

    Uint8List? bytes;
    if (file.bytes != null) {
      bytes = file.bytes;
    } else if (file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }

    if (bytes == null || bytes.isEmpty) return;
    final base64String = base64Encode(bytes);

    try {
      await _repo.sendMessage(
        chatId: widget.chatId,
        messageType: 'file',
        base64Data: base64String,
        fileName: file.name,
      );
    } catch (e) {
      _showError('Failed to send file: $e');
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      if (path != null) {
        final bytes = await File(path).readAsBytes();
        final base64String = base64Encode(bytes);
        if (base64String.length > 700 * 1024) {
          _showError('Audio too large (max ~700KB). Try a shorter clip.');
          return;
        }
        try {
          await _repo.sendMessage(
            chatId: widget.chatId,
            messageType: 'audio',
            base64Data: base64String,
          );
        } catch (e) {
          _showError('Failed to send audio: $e');
        }
      }
    } else {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 32000),
          path: path,
        );
        setState(() => _isRecording = true);
      } else {
        _showError('Microphone permission denied');
      }
    }
  }

  ImageProvider? _getImageProvider(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final trimmed = url.trim();
    if (trimmed.startsWith('data:image')) {
      try {
        final base64String = trimmed.split(',').last;
        return MemoryImage(base64Decode(base64String));
      } catch (_) {
        return null;
      }
    }
    return NetworkImage(trimmed);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  DateTime _messageTime(Map<String, dynamic> data) {
    final ts = data['createdAt'] as Timestamp?;
    return ts?.toDate() ?? DateTime.now();
  }

  String _twoDigits(int v) => v.toString().padLeft(2, '0');

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = _twoDigits(dt.minute);
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  String _monthName(int month) {
    const names = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return names[month - 1];
  }

  String _formatDayLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(messageDay).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${dt.day} ${_monthName(dt.month)} ${dt.year}';
  }

  Widget _buildMessageContent(Map<String, dynamic> data, bool mine) {
    final type = data['messageType'] as String? ?? 'text';
    final text = data['text'] as String? ?? '';
    final base64Data = data['base64Data'] as String?;

    if (type == 'image' && base64Data != null) {
      final imgProvider = _getImageProvider(base64Data);
      if (imgProvider != null) {
        return Image(image: imgProvider, width: 200, fit: BoxFit.contain);
      }
      return const Icon(Icons.broken_image, size: 50);
    } else if (type == 'audio' && base64Data != null) {
      return _AudioBubble(base64Data: base64Data, isMine: mine);
    } else if (type == 'file' && base64Data != null) {
      final fileName = data['fileName'] as String? ?? 'Document';
      final cs = Theme.of(context).colorScheme;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file,
            color: mine ? cs.onPrimary : cs.primary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              fileName,
              style: TextStyle(
                color: mine ? cs.onPrimary : cs.onSurface,
                decoration: TextDecoration.underline,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (type == 'call_event') {
      final cs = Theme.of(context).colorScheme;
      final lower = text.toLowerCase();
      final icon =
          lower.contains('missed')
              ? Icons.call_missed
              : lower.contains('declined')
              ? Icons.call_end
              : Icons.phone_disabled;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: mine ? cs.onPrimary : cs.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: mine ? cs.onPrimary : cs.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    } else if (type == 'call_started') {
      final cs = Theme.of(context).colorScheme;
      final isVideo = text == 'video';
      final label = mine
          ? (isVideo ? 'Outgoing video call' : 'Outgoing voice call')
          : (isVideo ? 'Incoming video call' : 'Incoming voice call');
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isVideo ? Icons.videocam : Icons.call,
            size: 16,
            color: mine ? cs.onPrimary : cs.primary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: mine ? cs.onPrimary : cs.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    } else if (type == 'call_ended') {
      final cs = Theme.of(context).colorScheme;
      final isVideo = text == 'video';
      final secs = (data['durationSeconds'] as num?)?.toInt() ?? 0;
      final label = isVideo
          ? 'Video call • ${_formatCallDuration(secs)}'
          : 'Voice call • ${_formatCallDuration(secs)}';
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule,
            size: 16,
            color: mine ? cs.onPrimary : cs.primary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: mine ? cs.onPrimary : cs.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    }

    // Default text
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        color: mine ? cs.onPrimary : cs.onSurface,
        fontSize: 16,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageProvider = _getImageProvider(widget.otherUserPhotoUrl);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              backgroundImage: imageProvider,
              child:
                  imageProvider == null
                      ? Icon(
                          Icons.person,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                          size: 20,
                        )
                      : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Active now',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.call, color: Colors.blue),
            tooltip: 'Voice call',
            onPressed: () => _startCall(isVideoCall: false, announce: true),
          ),
          IconButton(
            icon: const Icon(Icons.videocam, color: Colors.blue),
            tooltip: 'Video call',
            onPressed: () => _startCall(isVideoCall: true, announce: true),
          ),
          IconButton(
            icon: const Icon(Icons.history, color: Colors.blue),
            tooltip: 'Call history',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder:
                      (_) => CallHistoryScreen(
                        chatId: widget.chatId,
                        title: widget.title,
                      ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.perm_media, color: Colors.blue),
            tooltip: 'Media & Files',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder:
                      (_) => ChatMediaFilesScreen(
                        chatId: widget.chatId,
                        title: '${widget.title} • Media',
                      ),
                ),
              );
            },
          ),
          // ── Group chat menu (Leave / Mute) ───────────────────────────
          if (widget.otherUserId.isEmpty)
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>?>(
              stream: _notifRepo.settingsStream(),
              builder: (context, notifSnapshot) {
                final notifSettings = notifSnapshot.data?.data();
                final isMuted = _notifRepo.isMuted(
                  notifSettings,
                  widget.chatId,
                );
                return PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'mute') {
                      await MuteDialog.show(
                        context,
                        chatId: widget.chatId,
                        settings: notifSettings,
                        repo: _notifRepo,
                      );
                    } else if (value == 'add_members') {
                      // Fetch current participants before opening the screen
                      final snap = await _repo
                          .chatDocument(widget.chatId)
                          .get();
                      final participants = List<String>.from(
                        snap.data()?['participants'] ?? [],
                      );
                      if (!mounted) return;
                      // ignore: use_build_context_synchronously
                      final nav = Navigator.of(context);
                      nav.push(
                        MaterialPageRoute<void>(
                          builder:
                              (_) => AddGroupMembersScreen(
                                chatId: widget.chatId,
                                currentParticipantIds: participants,
                              ),
                        ),
                      );
                    } else if (value == 'leave') {
                      await _leaveGroup();
                    }
                  },
                  itemBuilder:
                      (_) => [
                        PopupMenuItem<String>(
                          value: 'mute',
                          child: Row(
                            children: [
                              Icon(
                                isMuted
                                    ? Icons.notifications_active_outlined
                                    : Icons.notifications_off_outlined,
                                color: Colors.blueAccent,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(isMuted ? 'Unmute' : 'Mute'),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'add_members',
                          child: Row(
                            children: [
                              Icon(
                                Icons.person_add_outlined,
                                color: Colors.blueAccent,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Text('Add Members'),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'leave',
                          child: Row(
                            children: [
                              Icon(
                                Icons.exit_to_app,
                                color: Colors.red,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Leave Group',
                                style: TextStyle(color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                );
              },
            ),
          // ── Direct chat menu (Block / Mute) ──────────────────────────
          if (widget.otherUserId.isNotEmpty)
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>?>(
              stream: _repo.currentUserStream(),
              builder: (context, snapshot) {
                final data = snapshot.data?.data();
                final blockedUsers = List<String>.from(
                  data?['blockedUsers'] ?? [],
                );
                final isBlocked = blockedUsers.contains(widget.otherUserId);

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _isBlocked != isBlocked) {
                    setState(() => _isBlocked = isBlocked);
                  }
                });

                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>?>(
                  stream: _notifRepo.settingsStream(),
                  builder: (context, notifSnapshot) {
                    final notifSettings = notifSnapshot.data?.data();
                    final isMuted = _notifRepo.isMuted(
                      notifSettings,
                      widget.chatId,
                    );

                    return PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'block') {
                          await _repo.blockUser(widget.otherUserId);
                          if (mounted) _showError('User blocked');
                        } else if (value == 'unblock') {
                          await _repo.unblockUser(widget.otherUserId);
                          if (mounted) _showError('User unblocked');
                        } else if (value == 'mute') {
                          await MuteDialog.show(
                            context,
                            chatId: widget.chatId,
                            settings: notifSettings,
                            repo: _notifRepo,
                          );
                        }
                      },
                      itemBuilder: (BuildContext context) {
                        return [
                          PopupMenuItem<String>(
                            value: 'mute',
                            child: Row(
                              children: [
                                Icon(
                                  isMuted
                                      ? Icons.notifications_active_outlined
                                      : Icons.notifications_off_outlined,
                                  color: Colors.blueAccent,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(isMuted ? 'Unmute' : 'Mute'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: isBlocked ? 'unblock' : 'block',
                            child: Row(
                              children: [
                                Icon(
                                  isBlocked ? Icons.lock_open : Icons.block,
                                  color: isBlocked ? Colors.green : Colors.red,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  isBlocked ? 'Unblock User' : 'Block User',
                                  style: TextStyle(
                                    color:
                                        isBlocked ? Colors.green : Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ];
                      },
                    );
                  },
                );
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child:
                !_ready
                    ? const Center(child: CircularProgressIndicator())
                    : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _repo.messages(widget.chatId),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(child: Text('${snapshot.error}'));
                        }
                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        final docs = snapshot.data!.docs;
                        if (docs.isEmpty) {
                          return const Center(child: Text('Say hello.'));
                        }

                        final selfId = FirebaseAuth.instance.currentUser?.uid;

                        return ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final doc = docs[index];
                            final data = doc.data();
                            final messageId = doc.id;
                            final senderId = data['senderId'] as String? ?? '';
                            final mine = senderId == selfId;
                            final sentAt = _messageTime(data);
                            final olderMessage =
                                index + 1 < docs.length
                                    ? docs[index + 1].data()
                                    : null;
                            final showDayHeader =
                                olderMessage == null ||
                                !_isSameDay(
                                  sentAt,
                                  _messageTime(olderMessage),
                                );

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Column(
                                crossAxisAlignment:
                                    mine
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                children: [
                                  if (showDayHeader)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 8.0,
                                      ),
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerHighest,
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            _formatDayLabel(sentAt),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color:
                                                  Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (!mine && widget.otherUserId.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 42.0,
                                        bottom: 4.0,
                                      ),
                                      child: Text(
                                        (data['senderEmail'] as String? ?? '')
                                            .split('@')
                                            .first,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ),
                                  Row(
                                    mainAxisAlignment:
                                        mine
                                            ? MainAxisAlignment.end
                                            : MainAxisAlignment.start,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      if (!mine)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8.0,
                                          ),
                                          child: CircleAvatar(
                                            radius: 14,
                                            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                            backgroundImage: imageProvider,
                                            child:
                                                imageProvider == null
                                                    ? Icon(
                                                        Icons.person,
                                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                        size: 16,
                                                      )
                                                    : null,
                                          ),
                                        ),
                                      Flexible(
                                        child: GestureDetector(
                                          onLongPress:
                                              mine
                                                  ? () =>
                                                      _confirmAndDeleteMessage(
                                                        messageId: messageId,
                                                        mine: mine,
                                                      )
                                                  : null,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 10,
                                            ),
                                            decoration: BoxDecoration(
                                              color:
                                                  mine
                                                      ? Theme.of(context).colorScheme.primary
                                                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                                              borderRadius: BorderRadius.only(
                                                topLeft: const Radius.circular(
                                                  18,
                                                ),
                                                topRight: const Radius.circular(
                                                  18,
                                                ),
                                                bottomLeft: Radius.circular(
                                                  mine ? 18 : 4,
                                                ),
                                                bottomRight: Radius.circular(
                                                  mine ? 4 : 18,
                                                ),
                                              ),
                                            ),
                                            child: _buildMessageContent(
                                              data,
                                              mine,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Padding(
                                    padding: EdgeInsets.only(
                                      top: 4,
                                      left: mine ? 0 : 42,
                                      right: mine ? 0 : 4,
                                    ),
                                    child: Text(
                                      _formatTime(sentAt),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color:
                                            Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
          ),
          SafeArea(
            child:
                _isBlocked
                    ? Container(
                      color: Colors.grey.shade100,
                      padding: const EdgeInsets.all(16),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'You blocked this user.',
                            style: TextStyle(
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed:
                                () => _repo.unblockUser(widget.otherUserId),
                            child: const Text(
                              'Unblock',
                              style: TextStyle(color: Colors.blueAccent),
                            ),
                          ),
                        ],
                      ),
                    )
                    : Container(
                      color: Theme.of(context).colorScheme.surface,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.add_circle,
                              color: Colors.blue,
                            ),
                            onPressed: _pickFile,
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.camera_alt,
                              color: Colors.blue,
                            ),
                            onPressed: () => _pickImage(ImageSource.camera),
                          ),
                          IconButton(
                            icon: const Icon(Icons.photo, color: Colors.blue),
                            onPressed: () => _pickImage(ImageSource.gallery),
                          ),
                          IconButton(
                            icon: Icon(
                              _isRecording ? Icons.stop_circle : Icons.mic,
                              color: _isRecording ? Colors.red : Colors.blue,
                            ),
                            onPressed: _toggleRecording,
                          ),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: TextField(
                                controller: _controller,
                                minLines: 1,
                                maxLines: 4,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _sendText(),
                                decoration: InputDecoration(
                                  hintText: 'Message',
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  suffixIcon: IconButton(
                                    icon: const Icon(
                                      Icons.send,
                                      color: Colors.blue,
                                    ),
                                    onPressed: _sendText,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
          ),
        ],
      ),
    );
  }
}

class _AudioBubble extends StatefulWidget {
  final String base64Data;
  final bool isMine;
  const _AudioBubble({required this.base64Data, required this.isMine});

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    try {
      _player.setSource(BytesSource(base64Decode(widget.base64Data)));
      _player.onPlayerStateChanged.listen((state) {
        if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
      });
      _player.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      });
      _player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            _isPlaying ? Icons.pause : Icons.play_arrow,
            color: widget.isMine
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
          onPressed: () {
            if (_isPlaying) {
              _player.pause();
            } else {
              _player.resume();
            }
          },
        ),
        SizedBox(
          width: 100,
          child: Slider(
            value: _position.inMilliseconds.toDouble(),
            min: 0,
            max:
                _duration.inMilliseconds > 0
                    ? _duration.inMilliseconds.toDouble()
                    : 1.0,
            onChanged: (val) {
              _player.seek(Duration(milliseconds: val.toInt()));
            },
            activeColor: widget.isMine
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.primary,
            inactiveColor: widget.isMine
                ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.4)
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
