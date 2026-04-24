import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:first_app/UI/add_group_members_screen.dart';
import 'package:first_app/UI/chat_media_files_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
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

  bool _isRecording = false;
  final _audioRecorder = AudioRecorder();

  bool _isBlocked = false;

  @override
  void initState() {
    super.initState();
    // Suppress notifications while this chat is open
    activeChatId = widget.chatId;
    _prepare();
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
    _controller.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file,
            color: mine ? Colors.white : Colors.blue,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              fileName,
              style: TextStyle(
                color: mine ? Colors.white : Colors.black,
                decoration: TextDecoration.underline,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // Default text
    return Text(
      text,
      style: TextStyle(color: mine ? Colors.white : Colors.black, fontSize: 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageProvider = _getImageProvider(widget.otherUserPhotoUrl);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.blue),
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.grey.shade300,
              backgroundImage: imageProvider,
              child:
                  imageProvider == null
                      ? const Icon(Icons.person, color: Colors.white, size: 20)
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
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'Active now',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
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

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Column(
                                crossAxisAlignment:
                                    mine
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                children: [
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
                                            backgroundColor:
                                                Colors.grey.shade300,
                                            backgroundImage: imageProvider,
                                            child:
                                                imageProvider == null
                                                    ? const Icon(
                                                      Icons.person,
                                                      color: Colors.white,
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
                                                      ? Colors.blue
                                                      : Colors.grey.shade200,
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
                      color: Colors.white,
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
                                color: Colors.grey.shade200,
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
            color: widget.isMine ? Colors.white : Colors.black,
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
            activeColor: widget.isMine ? Colors.white : Colors.blue,
            inactiveColor:
                widget.isMine ? Colors.white54 : Colors.grey.shade400,
          ),
        ),
      ],
    );
  }
}
