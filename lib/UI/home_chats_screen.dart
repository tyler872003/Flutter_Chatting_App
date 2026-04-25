import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/UI/blocked_users_screen.dart';
import 'package:first_app/UI/chat_room_screen.dart';
import 'package:first_app/UI/create_group_screen.dart';
import 'package:first_app/UI/notification_settings_screen.dart';
import 'package:first_app/UI/profile_settings_screen.dart';
import 'package:first_app/UI/view_story_screen.dart';
import 'package:first_app/services/auth_verification_prefs.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:first_app/services/notification_repository.dart';
import 'package:first_app/services/story_repository.dart';
import 'package:first_app/widgets/mute_dialog.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class HomeChatsScreen extends StatefulWidget {
  const HomeChatsScreen({super.key});

  @override
  State<HomeChatsScreen> createState() => _HomeChatsScreenState();
}

class _HomeChatsScreenState extends State<HomeChatsScreen> {
  String? _currentPhotoUrl;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  // Single shared stories stream — prevents double Firestore reads
  final _storyRepo = StoryRepository();
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _storiesStream =
      _storyRepo.activeStoriesStream().asBroadcastStream();

  final _notifRepo = NotificationRepository();

  @override
  void dispose() {
    _storyRepo.stopPeriodicCleanup();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _currentPhotoUrl = FirebaseAuth.instance.currentUser?.photoURL;
    _fetchCurrentPhotoUrl();
    ChatRepository().syncCurrentUserProfileDocument();
    // Start periodic cleanup — runs immediately then every 30 min
    _storyRepo.startPeriodicCleanup();
  }

  Future<void> _fetchCurrentPhotoUrl() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (mounted && doc.exists) {
      final photoUrl = doc.data()?['photoUrl'] as String?;
      if (photoUrl != null && photoUrl.isNotEmpty) {
        setState(() => _currentPhotoUrl = photoUrl);
      }
    }
  }

  Future<void> _openProfileSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileSettingsScreen()),
    );
    // Refresh photo in case user changed it
    _fetchCurrentPhotoUrl();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ChatRepository();
    final self = repo.currentUser;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const CreateGroupScreen()));
        },
        backgroundColor: Colors.blueAccent,
        child: const Icon(Icons.group_add, color: Colors.white),
      ),
      appBar: AppBar(
        elevation: 0,
        title: const Text(
          'Chats',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: GestureDetector(
            onTap: _openProfileSettings,
            child: _UserListAvatar(photoUrl: _currentPhotoUrl, radius: 20),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Profile Settings',
            onPressed: _openProfileSettings,
          ),
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notification Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const NotificationSettingsScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.shield),
            tooltip: 'Blocked Users',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () async {
              EmailRegistrationSession.clearPendingProfilePhoto();
              await clearMustVerifyEmailPending();
              await FirebaseAuth.instance.signOut();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: (value) {
                  setState(() => _searchQuery = value.trim().toLowerCase());
                },
                decoration: const InputDecoration(
                  hintText: 'Search',
                  border: InputBorder.none,
                  icon: Icon(Icons.search),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // FIX: Pass shared stream down to StoriesSection
          StoriesSection(storiesStream: _storiesStream),
          const SizedBox(height: 8),
          Expanded(
            // FIX: Use shared stories stream here too — no extra Firestore reads
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _storiesStream,
              builder: (context, activeStoriesSnapshot) {
                final activeStories = activeStoriesSnapshot.data?.docs ?? [];
                final storyMap =
                    <
                      String,
                      List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    >{};
                for (var doc in activeStories) {
                  final uid = doc.data()['userId'] as String;
                  storyMap.putIfAbsent(uid, () => []).add(doc);
                }

                // FIX: Separate stream for notification settings (subcollection)
                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>?>(
                  stream: _notifRepo.settingsStream(),
                  builder: (context, notifSnapshot) {
                    final notifSettings = notifSnapshot.data?.data();

                    return StreamBuilder<
                      DocumentSnapshot<Map<String, dynamic>>?
                    >(
                      stream: repo.currentUserStream(),
                      builder: (context, currentUserSnapshot) {
                        final blockedUsers = List<String>.from(
                          currentUserSnapshot.data?.data()?['blockedUsers'] ??
                              [],
                        );

                        if (_searchQuery.isNotEmpty) {
                          return StreamBuilder<
                            QuerySnapshot<Map<String, dynamic>>
                          >(
                            stream: repo.usersExceptSelf(),
                            builder: (context, userSnapshot) {
                              if (!userSnapshot.hasData) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }
                              final docs =
                                  userSnapshot.data!.docs.where((d) {
                                    if (d.id == self?.uid) return false;
                                    if (blockedUsers.contains(d.id)) {
                                      return false;
                                    }
                                    final data = d.data();
                                    final displayName =
                                        (data['displayName'] as String?)
                                            ?.toLowerCase() ??
                                        '';
                                    final email =
                                        (data['email'] as String?)
                                            ?.toLowerCase() ??
                                        '';
                                    return displayName.contains(_searchQuery) ||
                                        email.contains(_searchQuery);
                                  }).toList();

                              if (docs.isEmpty) {
                                return const Center(
                                  child: Text('No users found.'),
                                );
                              }

                              return ListView.builder(
                                itemCount: docs.length,
                                itemBuilder: (context, index) {
                                  final doc = docs[index];
                                  final data = doc.data();
                                  final displayName =
                                      (data['displayName'] as String?)?.trim();
                                  final title =
                                      (displayName != null &&
                                              displayName.isNotEmpty)
                                          ? displayName
                                          : 'User';
                                  final photoUrl = data['photoUrl'] as String?;
                                  final hasStory = storyMap.containsKey(doc.id);
                                  final userStories = storyMap[doc.id] ?? [];
                                  bool hasUnviewedStory = false;
                                  if (hasStory) {
                                    final uid =
                                        FirebaseAuth.instance.currentUser?.uid;
                                    if (uid != null) {
                                      for (var s in userStories) {
                                        final viewers = List<String>.from(
                                          s.data()['viewers'] ?? [],
                                        );
                                        if (!viewers.contains(uid)) {
                                          hasUnviewedStory = true;
                                          break;
                                        }
                                      }
                                    }
                                  }

                                  final chatId =
                                      self != null
                                          ? repo.chatIdForParticipants(
                                            self.uid,
                                            doc.id,
                                          )
                                          : doc.id;

                                  return _UserListTile(
                                    userId: doc.id,
                                    data: data,
                                    title: title,
                                    photoUrl: photoUrl,
                                    hasStory: hasStory,
                                    hasUnviewedStory: hasUnviewedStory,
                                    userStories: userStories,
                                    subtitle: data['email'] as String? ?? '',
                                    chatId: chatId,
                                    notifRepo: _notifRepo,
                                    notifSettings: notifSettings,
                                    onTap: () {
                                      if (self == null) return;
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder:
                                              (_) => ChatRoomScreen(
                                                chatId: chatId,
                                                otherUserId: doc.id,
                                                title: title,
                                                otherUserPhotoUrl: photoUrl,
                                              ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              );
                            },
                          );
                        }

                        return StreamBuilder<
                          List<QueryDocumentSnapshot<Map<String, dynamic>>>
                        >(
                          stream: repo.groupChatsStream(),
                          builder: (context, groupSnapshot) {
                            return StreamBuilder<
                              List<QueryDocumentSnapshot<Map<String, dynamic>>>
                            >(
                              stream: repo.directChatsStream(),
                              builder: (context, directSnapshot) {
                                if (groupSnapshot.hasError) {
                                  return Center(
                                    child: Text(
                                      'Error: ${groupSnapshot.error}',
                                    ),
                                  );
                                }
                                if (directSnapshot.hasError) {
                                  return Center(
                                    child: Text(
                                      'Error: ${directSnapshot.error}',
                                    ),
                                  );
                                }

                                final groups = groupSnapshot.data ?? [];
                                final directChats = directSnapshot.data ?? [];

                                // FIX: Batch-load all other user IDs at once
                                // instead of a FutureBuilder per list item
                                final otherUserIds =
                                    directChats
                                        .map((chat) {
                                          final participants =
                                              List<String>.from(
                                                chat.data()['participants'] ??
                                                    [],
                                              );
                                          participants.remove(self?.uid);
                                          return participants.isNotEmpty
                                              ? participants.first
                                              : null;
                                        })
                                        .where(
                                          (id) =>
                                              id != null &&
                                              !blockedUsers.contains(id),
                                        )
                                        .cast<String>()
                                        .toList();

                                return FutureBuilder<
                                  Map<String, Map<String, dynamic>>
                                >(
                                  future: repo.fetchUsersByIds(otherUserIds),
                                  builder: (context, usersSnapshot) {
                                    final usersMap = usersSnapshot.data ?? {};

                                    return ListView(
                                      children: [
                                        if (groups.isNotEmpty) ...[
                                          const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 16.0,
                                              vertical: 8.0,
                                            ),
                                            child: Text(
                                              'Your Groups',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          ...groups.map((g) {
                                            final data = g.data();
                                            final title =
                                                data['groupName'] as String? ??
                                                'Group';
                                            return ListTile(
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                    vertical: 4,
                                                  ),
                                              leading: const CircleAvatar(
                                                radius: 28,
                                                backgroundColor:
                                                    Colors.blueAccent,
                                                child: Icon(
                                                  Icons.group,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              title: Text(
                                                title,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              subtitle: Text(
                                                data['lastMessage']
                                                        as String? ??
                                                    'Tap to chat',
                                                style: TextStyle(
                                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                  fontSize: 14,
                                                ),
                                              ),
                                              onTap: () {
                                                Navigator.of(context).push(
                                                  MaterialPageRoute<void>(
                                                    builder:
                                                        (_) => ChatRoomScreen(
                                                          chatId: g.id,
                                                          otherUserId: '',
                                                          title: title,
                                                          otherUserPhotoUrl:
                                                              null,
                                                        ),
                                                  ),
                                                );
                                              },
                                            );
                                          }),
                                        ],
                                        if (directChats.isNotEmpty) ...[
                                          const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 16.0,
                                              vertical: 8.0,
                                            ),
                                            child: Text(
                                              'Direct Messages',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ),
                                          ...directChats.map((chatDoc) {
                                            final chatData = chatDoc.data();
                                            final participants =
                                                List<String>.from(
                                                  chatData['participants'] ??
                                                      [],
                                                );
                                            participants.remove(self?.uid);
                                            final otherUserId =
                                                participants.isNotEmpty
                                                    ? participants.first
                                                    : '';

                                            if (otherUserId.isEmpty ||
                                                blockedUsers.contains(
                                                  otherUserId,
                                                )) {
                                              return const SizedBox.shrink();
                                            }

                                            // FIX: Use pre-fetched user data
                                            // — no more per-item FutureBuilder
                                            final userData =
                                                usersMap[otherUserId];
                                            if (userData == null) {
                                              return const SizedBox.shrink();
                                            }

                                            final displayName =
                                                (userData['displayName']
                                                        as String?)
                                                    ?.trim();
                                            final title =
                                                (displayName != null &&
                                                        displayName.isNotEmpty)
                                                    ? displayName
                                                    : 'User';
                                            final photoUrl =
                                                userData['photoUrl'] as String?;
                                            final lastMessage =
                                                chatData['lastMessage']
                                                    as String? ??
                                                'Tap to chat';

                                            final hasStory = storyMap
                                                .containsKey(otherUserId);
                                            final userStories =
                                                storyMap[otherUserId] ?? [];
                                            bool hasUnviewedStory = false;
                                            if (hasStory) {
                                              final uid =
                                                  FirebaseAuth
                                                      .instance
                                                      .currentUser
                                                      ?.uid;
                                              if (uid != null) {
                                                for (var s in userStories) {
                                                  final viewers =
                                                      List<String>.from(
                                                        s.data()['viewers'] ??
                                                            [],
                                                      );
                                                  if (!viewers.contains(uid)) {
                                                    hasUnviewedStory = true;
                                                    break;
                                                  }
                                                }
                                              }
                                            }

                                            return _UserListTile(
                                              userId: otherUserId,
                                              data: userData,
                                              title: title,
                                              photoUrl: photoUrl,
                                              hasStory: hasStory,
                                              hasUnviewedStory:
                                                  hasUnviewedStory,
                                              userStories: userStories,
                                              subtitle: lastMessage,
                                              chatId: chatDoc.id,
                                              notifRepo: _notifRepo,
                                              notifSettings: notifSettings,
                                              onTap: () {
                                                if (self == null) return;
                                                Navigator.of(context).push(
                                                  MaterialPageRoute<void>(
                                                    builder:
                                                        (_) => ChatRoomScreen(
                                                          chatId: chatDoc.id,
                                                          otherUserId:
                                                              otherUserId,
                                                          title: title,
                                                          otherUserPhotoUrl:
                                                              photoUrl,
                                                        ),
                                                  ),
                                                );
                                              },
                                            );
                                          }),
                                        ] else if (groups.isEmpty) ...[
                                          const Center(
                                            child: Padding(
                                              padding: EdgeInsets.all(32.0),
                                              child: Text(
                                                'No chats yet.\nUse the search bar above to find people and start chatting!',
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                );
                              },
                            );
                          },
                        );
                      },
                    ); // currentUserStream StreamBuilder
                  }, // notifSnapshot builder
                ); // notifRepo settingsStream StreamBuilder
              },
            ), // storiesStream Expanded
          ),
        ],
      ),
    );
  }
}

// FIX: Extracted reusable tile widget to avoid code duplication
class _UserListTile extends StatelessWidget {
  const _UserListTile({
    required this.userId,
    required this.data,
    required this.title,
    required this.photoUrl,
    required this.hasStory,
    required this.hasUnviewedStory,
    required this.userStories,
    required this.subtitle,
    required this.onTap,
    required this.chatId,
    required this.notifRepo,
    required this.notifSettings,
  });

  final String userId;
  final Map<String, dynamic> data;
  final String title;
  final String? photoUrl;
  final bool hasStory;
  final bool hasUnviewedStory;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> userStories;
  final String subtitle;
  final VoidCallback onTap;
  final String chatId;
  final NotificationRepository notifRepo;
  final Map<String, dynamic>? notifSettings;

  @override
  Widget build(BuildContext context) {
    final isMuted = notifRepo.isMuted(notifSettings, chatId);
    final muteLabel = notifRepo.muteStatusLabel(notifSettings, chatId);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: GestureDetector(
        onTap:
            hasStory
                ? () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) =>
                              ViewStoryScreen(user: data, stories: userStories),
                    ),
                  );
                }
                : null,
        child: Container(
          padding: hasStory ? const EdgeInsets.all(2) : EdgeInsets.zero,
          decoration:
              hasStory
                  ? BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          hasUnviewedStory
                              ? Colors.blueAccent
                              : Colors.grey.shade400,
                      width: 2.5,
                    ),
                  )
                  : null,
          child: _UserListAvatar(photoUrl: photoUrl, radius: 26),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),
          if (isMuted)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(
                Icons.notifications_off_outlined,
                size: 16,
                color: Colors.grey,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            subtitle,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (muteLabel != null)
            Text(
              muteLabel,
              style: const TextStyle(color: Colors.blueAccent, fontSize: 12),
            ),
        ],
      ),
      onTap: onTap,
      onLongPress:
          () => MuteDialog.show(
            context,
            chatId: chatId,
            settings: notifSettings,
            repo: notifRepo,
          ),
    );
  }
}

class _UserListAvatar extends StatelessWidget {
  const _UserListAvatar({this.photoUrl, this.radius = 20});

  final String? photoUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = photoUrl?.trim();
    ImageProvider? imageProvider;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('data:image')) {
        try {
          final base64String = url.split(',').last;
          imageProvider = MemoryImage(base64Decode(base64String));
        } catch (_) {}
      } else {
        imageProvider = NetworkImage(url);
      }
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      backgroundImage: imageProvider,
      child:
          imageProvider == null
              ? Icon(
                  Icons.person,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  size: radius,
                )
              : null,
    );
  }
}

class StoriesSection extends StatelessWidget {
  const StoriesSection({super.key, required this.storiesStream});

  // FIX: Accept shared stream instead of creating a new one
  final Stream<QuerySnapshot<Map<String, dynamic>>> storiesStream;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: storiesStream,
        builder: (context, snapshot) {
          final stories = snapshot.data?.docs ?? [];
          final grouped =
              <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
          for (final doc in stories) {
            final uid = doc.data()['userId'] as String;
            grouped.putIfAbsent(uid, () => []).add(doc);
          }

          return ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: grouped.keys.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return const AddStoryItem();
              final uid = grouped.keys.elementAt(index - 1);
              final userStories = grouped[uid]!;
              return StoryItemWidget(userId: uid, stories: userStories);
            },
          );
        },
      ),
    );
  }
}

class AddStoryItem extends StatefulWidget {
  const AddStoryItem({super.key});

  @override
  State<AddStoryItem> createState() => _AddStoryItemState();
}

class _AddStoryItemState extends State<AddStoryItem> {
  bool _isUploading = false;

  Future<void> _addStory() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 50,
      maxWidth: 720,
      maxHeight: 1280,
    );
    if (image == null) return;

    setState(() => _isUploading = true);
    try {
      final bytes = await image.readAsBytes();

      // Firestore document limit is ~1 MB; base64 adds ~33% overhead.
      // Keep the encoded string under 700 KB to stay safe.
      final base64Data = base64Encode(bytes);
      if (base64Data.length > 700 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Image is too large. Please pick a smaller photo.',
              ),
            ),
          );
        }
        return;
      }

      await StoryRepository().postStory(base64Data);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Story posted! It will expire in 24 hours.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error adding story: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future:
          FirebaseFirestore.instance
              .collection('users')
              .doc(FirebaseAuth.instance.currentUser?.uid)
              .get(),
      builder: (context, snapshot) {
        String? photoUrl;
        if (snapshot.hasData) {
          photoUrl =
              (snapshot.data!.data() as Map<String, dynamic>?)?['photoUrl']
                  as String?;
        }
        return GestureDetector(
          onTap: _isUploading ? null : _addStory,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    _UserListAvatar(photoUrl: photoUrl, radius: 28),
                    if (_isUploading)
                      const Positioned.fill(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.blueAccent,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(
                          Icons.add,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Add Story',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class StoryItemWidget extends StatelessWidget {
  final String userId;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> stories;

  const StoryItemWidget({
    super.key,
    required this.userId,
    required this.stories,
  });

  Future<void> _confirmDelete(
    BuildContext context,
    String storyId,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Story'),
            content: const Text(
              'Are you sure you want to delete this story?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );
    if (confirm == true) {
      await StoryRepository().deleteMyStory(storyId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Story deleted.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('users').doc(userId).get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 80,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final userData = snapshot.data!.data() as Map<String, dynamic>? ?? {};
        final displayName = userData['displayName'] as String? ?? 'User';
        final photoUrl = userData['photoUrl'] as String?;
        final isMe = userId == FirebaseAuth.instance.currentUser?.uid;
        final title = isMe ? 'Your Story' : displayName.split(' ').first;
        bool hasUnviewedStory = false;
        final currentUid = FirebaseAuth.instance.currentUser?.uid;
        if (currentUid != null) {
          for (var s in stories) {
            final viewers = List<String>.from(s.data()['viewers'] ?? []);
            if (!viewers.contains(currentUid)) {
              hasUnviewedStory = true;
              break;
            }
          }
        }

        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder:
                    (_) => ViewStoryScreen(user: userData, stories: stories),
              ),
            );
          },
          // Long-press on YOUR OWN story shows delete option
          onLongPress:
              isMe
                  ? () => showModalBottomSheet<void>(
                    context: context,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    builder:
                        (ctx) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 40,
                                height: 4,
                                margin: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade300,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.auto_stories,
                                      color: Colors.blueAccent,
                                    ),
                                    SizedBox(width: 12),
                                    Text(
                                      'Your Story',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Divider(height: 24),
                              // Delete each story in the list
                              ...stories.map(
                                (s) => ListTile(
                                  leading: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                  ),
                                  title: const Text(
                                    'Delete this story',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _confirmDelete(context, s.id);
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                  )
                  : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          hasUnviewedStory
                              ? Colors.blueAccent
                              : Colors.grey.shade400,
                      width: 2,
                    ),
                  ),
                  child: _UserListAvatar(photoUrl: photoUrl, radius: 26),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: 64,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
