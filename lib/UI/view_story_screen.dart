import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:story_view/story_view.dart';

import 'package:firebase_auth/firebase_auth.dart';

class ViewStoryScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> stories;

  const ViewStoryScreen({
    super.key,
    required this.user,
    required this.stories,
  });

  @override
  State<ViewStoryScreen> createState() => _ViewStoryScreenState();
}

class _ViewStoryScreenState extends State<ViewStoryScreen> {
  final StoryController _controller = StoryController();
  late List<StoryItem> _storyItems;

  @override
  void initState() {
    super.initState();
    _storyItems = widget.stories.map((doc) {
      final data = doc.data();
      final base64String = data['base64Data'] as String? ?? '';
      
      return StoryItem(
        Container(
          color: Colors.black,
          child: Center(
            child: Image.memory(
              base64Decode(base64String),
              fit: BoxFit.contain,
            ),
          ),
        ),
        duration: const Duration(seconds: 5),
      );
    }).toList();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final photoUrl = widget.user['photoUrl'] as String?;
    final displayName = widget.user['displayName'] as String? ?? 'User';
    final imageProvider = _getImageProvider(photoUrl);

    return Scaffold(
      body: Stack(
        children: [
          StoryView(
            controller: _controller,
            storyItems: _storyItems,
            onStoryShow: (s, index) {
              if (index != -1 && index < widget.stories.length) {
                final doc = widget.stories[index];
                final uid = FirebaseAuth.instance.currentUser?.uid;
                if (uid != null) {
                  FirebaseFirestore.instance.collection('stories').doc(doc.id).update({
                    'viewers': FieldValue.arrayUnion([uid])
                  }).catchError((_) {}); // ignore errors if we lack permission
                }
              }
            },
            onComplete: () {
              if (mounted) Navigator.pop(context);
            },
            onVerticalSwipeComplete: (direction) {
              if (direction == Direction.down) {
                if (mounted) Navigator.pop(context);
              }
            },
            progressPosition: ProgressPosition.top,
            repeat: false,
            inline: false,
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 24.0, left: 16.0),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: imageProvider,
                    child: imageProvider == null
                        ? const Icon(Icons.person, color: Colors.white, size: 24)
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () {
                      Navigator.pop(context);
                    },
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
