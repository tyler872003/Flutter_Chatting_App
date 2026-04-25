import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/services/app_theme_service.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  final _repo = ChatRepository();
  final _nicknameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _photoUrl;
  Uint8List? _newPhotoBytes;
  bool _busy = false;
  bool _nicknameSaved = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    _nicknameController.text = user.displayName ?? '';

    // Photos are stored as base64 in Firestore — Firebase Auth photoURL
    // often can't hold large base64 strings, so always read from Firestore.
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final firestoreUrl = doc.data()?['photoUrl'] as String?;
    final url = (firestoreUrl != null && firestoreUrl.isNotEmpty)
        ? firestoreUrl
        : user.photoURL;
    if (mounted) setState(() => _photoUrl = url);
  }

  // ─── Profile Photo ────────────────────────────────────────────────────────

  Future<void> _pickPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (mounted) setState(() => _newPhotoBytes = bytes);
  }

  Future<void> _savePhoto() async {
    if (_newPhotoBytes == null) return;
    setState(() => _busy = true);
    try {
      final url = await _repo.updateProfilePhoto(_newPhotoBytes!);
      if (mounted) {
        setState(() {
          _photoUrl = url;
          _newPhotoBytes = null;
        });
        _showSnack('Profile photo updated ✓');
      }
    } catch (e) {
      if (mounted) _showSnack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deletePhoto() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Profile Photo'),
        content: const Text('Remove your profile photo? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await _repo.deleteProfilePhoto();
      if (mounted) {
        setState(() {
          _photoUrl = null;
          _newPhotoBytes = null;
        });
        _showSnack('Profile photo removed');
      }
    } catch (e) {
      if (mounted) _showSnack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─── Nickname ─────────────────────────────────────────────────────────────

  Future<void> _saveNickname() async {
    if (!_formKey.currentState!.validate()) return;
    final newNick = _nicknameController.text.trim();
    final currentNick =
        FirebaseAuth.instance.currentUser?.displayName?.trim() ?? '';
    if (newNick == currentNick) {
      _showSnack('That is already your nickname.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _repo.changeNickname(newNick);
      if (mounted) {
        setState(() => _nicknameSaved = true);
        _showSnack('Nickname changed to "$newNick" ✓');
        Future.delayed(
          const Duration(seconds: 2),
          () {
            if (mounted) setState(() => _nicknameSaved = false);
          },
        );
      }
    } on NicknameTakenException {
      if (mounted) _showSnack('"$newNick" is already taken. Try another.');
    } catch (e) {
      if (mounted) _showSnack('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showPhotoSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.camera);
              },
            ),
            if (_photoUrl != null || _newPhotoBytes != null)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Colors.red,
                ),
                title: const Text(
                  'Delete photo',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  if (_newPhotoBytes != null) {
                    setState(() => _newPhotoBytes = null);
                  } else {
                    _deletePhoto();
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  /// Returns the [ImageProvider] for the avatar based on the current state.
  ImageProvider? _buildAvatarImage() {
    if (_newPhotoBytes != null) return MemoryImage(_newPhotoBytes!);
    if (_photoUrl == null || _photoUrl!.isEmpty) return null;
    if (_photoUrl!.startsWith('data:image')) {
      try {
        // Try the URI data API first (most reliable)
        final uriBytes = Uri.parse(_photoUrl!).data?.contentAsBytes();
        if (uriBytes != null && uriBytes.isNotEmpty) {
          return MemoryImage(uriBytes);
        }
        // Fallback: split on comma and base64-decode manually
        final base64Str = _photoUrl!.split(',').last;
        return MemoryImage(base64Decode(base64Str));
      } catch (_) {
        return null;
      }
    }
    return null;
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasPhoto = _newPhotoBytes != null || (_photoUrl?.isNotEmpty == true);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile Settings'),
        centerTitle: true,
        elevation: 0,
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(24),
              children: [
                // ── Avatar Section ─────────────────────────────────────────
                Center(
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _showPhotoSheet,
                        child: Stack(
                          alignment: Alignment.bottomRight,
                          children: [
                            CircleAvatar(
                              radius: 56,
                              backgroundColor: cs.surfaceContainerHighest,
                              backgroundImage: _buildAvatarImage(),
                              child: !hasPhoto
                                  ? Icon(
                                      Icons.person,
                                      size: 56,
                                      color: cs.onSurfaceVariant,
                                    )
                                  : null,
                            ),
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.scaffoldBackgroundColor,
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                Icons.camera_alt,
                                size: 16,
                                color: cs.onPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap to change photo',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      if (_newPhotoBytes != null) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _savePhoto,
                          icon: const Icon(Icons.check),
                          label: const Text('Save new photo'),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 32),
                _SectionHeader(label: 'Account'),

                // ── Nickname ───────────────────────────────────────────────
                Card(
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Nickname',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Unique · 3–20 characters · letters, numbers, _',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _nicknameController,
                            decoration: InputDecoration(
                              hintText: 'your_nickname',
                              prefixIcon: const Icon(Icons.alternate_email),
                              suffixIcon: _nicknameSaved
                                  ? Icon(
                                      Icons.check_circle,
                                      color: cs.primary,
                                    )
                                  : null,
                              border: const OutlineInputBorder(),
                            ),
                            validator: (v) {
                              final s = v?.trim() ?? '';
                              if (s.isEmpty) return 'Enter a nickname';
                              if (!ChatRepository.isValidNicknameFormat(s)) {
                                return 'Use 3–20 letters, numbers, or _';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonal(
                              onPressed: _saveNickname,
                              child: const Text('Save Nickname'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                _SectionHeader(label: 'App Theme'),

                // ── Color Theme Picker ─────────────────────────────────────
                Card(
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Accent Color',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Changes the color of buttons, highlights, and icons across the app.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ListenableBuilder(
                          listenable: AppThemeService.instance,
                          builder: (_, __) {
                            final current = AppThemeService.instance.seedColor;
                            return Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: AppThemeService.presets.map((p) {
                                final isSelected =
                                    current.toARGB32() == p.color.toARGB32();
                                return Tooltip(
                                  message: p.label,
                                  child: GestureDetector(
                                    onTap: () =>
                                        AppThemeService.instance.setSeedColor(
                                      p.color,
                                    ),
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 200),
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: p.color,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isSelected
                                              ? Colors.white
                                              : Colors.transparent,
                                          width: 3,
                                        ),
                                        boxShadow: isSelected
                                            ? [
                                                BoxShadow(
                                                  color: p.color
                                                      .withValues(alpha: 0.6),
                                                  blurRadius: 8,
                                                  spreadRadius: 2,
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: isSelected
                                          ? const Icon(
                                              Icons.check,
                                              color: Colors.white,
                                              size: 20,
                                            )
                                          : null,
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),
              ],
            ),

            // ── Loading overlay ────────────────────────────────────────────
            if (_busy)
              Container(
                color: Colors.black26,
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.4,
            ),
      ),
    );
  }
}
