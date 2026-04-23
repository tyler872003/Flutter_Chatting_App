import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatMediaFilesScreen extends StatefulWidget {
  const ChatMediaFilesScreen({
    super.key,
    required this.chatId,
    required this.title,
  });

  final String chatId;
  final String title;

  @override
  State<ChatMediaFilesScreen> createState() => _ChatMediaFilesScreenState();
}

class _ChatMediaFilesScreenState extends State<ChatMediaFilesScreen> {
  final _searchController = TextEditingController();
  String _q = '';
  bool _newestFirst = true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  ImageProvider? _imageProviderFromMessageBase64(String? base64Data) {
    if (base64Data == null) return null;
    final trimmed = base64Data.trim();
    if (!trimmed.startsWith('data:image')) return null;
    try {
      final b64 = trimmed.split(',').last;
      return MemoryImage(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }

  bool _matchesQuery({
    required String queryLower,
    required Map<String, dynamic> m,
  }) {
    if (queryLower.isEmpty) return true;
    final text = (m['text'] as String?)?.toLowerCase() ?? '';
    final fileName = (m['fileName'] as String?)?.toLowerCase() ?? '';
    final type = (m['messageType'] as String?)?.toLowerCase() ?? '';
    return text.contains(queryLower) ||
        fileName.contains(queryLower) ||
        type.contains(queryLower);
  }

  bool _looksLikeVideoFileName(String? fileName) {
    if (fileName == null || fileName.trim().isEmpty) return false;
    final lower = fileName.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.avi');
  }

  List<String> _extractLinks(String text) {
    final regex = RegExp(
      r'(https?:\/\/[^\s]+|www\.[^\s]+)',
      caseSensitive: false,
    );
    final matches = regex.allMatches(text);
    return matches.map((m) => m.group(0)!).toList();
  }

  DateTime _messageTime(Map<String, dynamic> data) {
    final ts = data['createdAt'];
    if (ts is Timestamp) return ts.toDate();
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _openExternalLink(String rawLink) async {
    var link = rawLink.trim();
    if (!link.startsWith('http://') && !link.startsWith('https://')) {
      link = 'https://$link';
    }

    final uri = Uri.tryParse(link);
    if (uri == null) {
      _showSnack('Invalid link');
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _showSnack('Could not open link');
  }

  Future<void> _openFileFromMessage(Map<String, dynamic> m) async {
    final base64Data = (m['base64Data'] as String?)?.trim();
    if (base64Data == null || base64Data.isEmpty) {
      _showSnack('File data is empty');
      return;
    }

    try {
      final bytes = base64Decode(base64Data);
      final tempDir = await getTemporaryDirectory();
      final fileName = (m['fileName'] as String?)?.trim().isNotEmpty == true
          ? (m['fileName'] as String).trim()
          : 'file_${DateTime.now().millisecondsSinceEpoch}';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done) {
        _showSnack('Saved file but could not open on this device.');
      }
    } catch (_) {
      _showSnack('Failed to open file');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: _newestFirst ? 'Newest first' : 'Oldest first',
              onPressed: () => setState(() => _newestFirst = !_newestFirst),
              icon: Icon(
                _newestFirst ? Icons.arrow_downward : Icons.arrow_upward,
              ),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Photos'),
              Tab(text: 'Files'),
              Tab(text: 'Videos'),
              Tab(text: 'Audio'),
              Tab(text: 'Links'),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                  decoration: const InputDecoration(
                    hintText: 'Search media & files',
                    border: InputBorder.none,
                    icon: Icon(Icons.search, color: Colors.grey),
                  ),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: ChatRepository().messages(widget.chatId),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text('Error: ${snapshot.error}'));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = snapshot.data!.docs;
                  final messages = docs.map((d) => d.data()).toList();
                  final queryLower = _q;

                  final photos = <Map<String, dynamic>>[];
                  final files = <Map<String, dynamic>>[];
                  final videos = <Map<String, dynamic>>[];
                  final audio = <Map<String, dynamic>>[];
                  final links = <String>[];

                  for (final m in messages) {
                    final type = m['messageType'] as String? ?? 'text';
                    if (!_matchesQuery(queryLower: queryLower, m: m)) continue;
                    if (type == 'image') {
                      photos.add(m);
                    } else if (type == 'video') {
                      videos.add(m);
                    } else if (type == 'file') {
                      if (_looksLikeVideoFileName(m['fileName'] as String?)) {
                        videos.add(m);
                      } else {
                        files.add(m);
                      }
                    } else if (type == 'audio') {
                      audio.add(m);
                    }

                    final text = (m['text'] as String?) ?? '';
                    links.addAll(_extractLinks(text));
                  }

                  int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
                    final left = _messageTime(a);
                    final right = _messageTime(b);
                    return _newestFirst
                        ? right.compareTo(left)
                        : left.compareTo(right);
                  }

                  photos.sort(cmp);
                  files.sort(cmp);
                  videos.sort(cmp);
                  audio.sort(cmp);

                  final uniqueLinks = links.toSet().toList();
                  uniqueLinks.sort((a, b) => _newestFirst ? -1 : 1);

                  return TabBarView(
                    children: [
                      _PhotosTab(
                        items: photos,
                        imageProviderFor: _imageProviderFromMessageBase64,
                      ),
                      _FilesTab(items: files, onOpenFile: _openFileFromMessage),
                      _VideosTab(items: videos, onOpenVideoFile: _openFileFromMessage),
                      _AudioTab(items: audio),
                      _LinksTab(
                        items: uniqueLinks,
                        onOpenLink: _openExternalLink,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotosTab extends StatelessWidget {
  const _PhotosTab({
    required this.items,
    required this.imageProviderFor,
  });

  final List<Map<String, dynamic>> items;
  final ImageProvider? Function(String? base64Data) imageProviderFor;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No photos found.'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final m = items[index];
        final base64Data = m['base64Data'] as String?;
        final provider = imageProviderFor(base64Data);
        if (provider == null) {
          return Container(
            color: Colors.grey.shade200,
            child: const Center(child: Icon(Icons.broken_image)),
          );
        }

        return InkWell(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _FullImageScreen(imageProvider: provider),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image(
              image: provider,
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }
}

class _FilesTab extends StatelessWidget {
  const _FilesTab({
    required this.items,
    required this.onOpenFile,
  });

  final List<Map<String, dynamic>> items;
  final Future<void> Function(Map<String, dynamic> message) onOpenFile;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No files found.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final m = items[index];
        final fileName = m['fileName'] as String? ?? 'Document';
        final subtitle = (m['text'] as String?)?.trim();
        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFE3F2FD),
            child: Icon(Icons.insert_drive_file, color: Colors.blue),
          ),
          title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle),
          trailing: const Icon(Icons.download_outlined),
          onTap: () => onOpenFile(m),
        );
      },
    );
  }
}

class _VideosTab extends StatelessWidget {
  const _VideosTab({
    required this.items,
    required this.onOpenVideoFile,
  });

  final List<Map<String, dynamic>> items;
  final Future<void> Function(Map<String, dynamic> message) onOpenVideoFile;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No videos found.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final m = items[index];
        final fileName = m['fileName'] as String? ?? 'Video';
        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFE8EAF6),
            child: Icon(Icons.videocam, color: Colors.indigo),
          ),
          title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('Tap to open'),
          onTap: () => onOpenVideoFile(m),
        );
      },
    );
  }
}

class _AudioTab extends StatelessWidget {
  const _AudioTab({required this.items});

  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No audio found.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final m = items[index];
        final subtitle = (m['text'] as String?)?.trim();
        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFFFEBEE),
            child: Icon(Icons.mic, color: Colors.red),
          ),
          title: const Text('Voice message'),
          subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle),
        );
      },
    );
  }
}

class _LinksTab extends StatelessWidget {
  const _LinksTab({
    required this.items,
    required this.onOpenLink,
  });

  final List<String> items;
  final Future<void> Function(String link) onOpenLink;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No links found.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final link = items[index];
        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFE0F7FA),
            child: Icon(Icons.link, color: Colors.teal),
          ),
          title: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('Tap to open'),
          onTap: () => onOpenLink(link),
        );
      },
    );
  }
}

class _FullImageScreen extends StatelessWidget {
  const _FullImageScreen({required this.imageProvider});

  final ImageProvider imageProvider;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: Center(
        child: InteractiveViewer(
          child: Image(image: imageProvider),
        ),
      ),
    );
  }
}

