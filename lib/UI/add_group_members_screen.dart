import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:flutter/material.dart';

/// Screen that lists all users not already in the group and lets
/// the current user pick one or more to add as new members.
class AddGroupMembersScreen extends StatefulWidget {
  const AddGroupMembersScreen({
    super.key,
    required this.chatId,
    required this.currentParticipantIds,
  });

  final String chatId;

  /// UIDs already in the group — these are hidden from the picker list.
  final List<String> currentParticipantIds;

  @override
  State<AddGroupMembersScreen> createState() => _AddGroupMembersScreenState();
}

class _AddGroupMembersScreenState extends State<AddGroupMembersScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _selectedIds = {};
  bool _isAdding = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _addMembers() async {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one user to add.')),
      );
      return;
    }

    setState(() => _isAdding = true);
    try {
      await ChatRepository().addMembersToGroup(
        widget.chatId,
        _selectedIds.toList(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_selectedIds.length} member${_selectedIds.length == 1 ? '' : 's'} added!',
            ),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to add members: $e')));
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ChatRepository();
    final selfUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text(
          'Add Members',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_isAdding)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(
              onPressed: _selectedIds.isEmpty ? null : _addMembers,
              child: Text(
                _selectedIds.isEmpty
                    ? 'Add'
                    : 'Add (${_selectedIds.length})',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color:
                      _selectedIds.isEmpty ? Colors.grey : Colors.blueAccent,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged:
                  (v) => setState(
                    () => _searchQuery = v.trim().toLowerCase(),
                  ),
              decoration: InputDecoration(
                hintText: 'Search users...',
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Colors.grey.shade200,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Selected chips
          if (_selectedIds.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children:
                    _selectedIds.map((id) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          label: Text(id.substring(0, 6)),
                          deleteIcon: const Icon(Icons.close, size: 16),
                          onDeleted:
                              () => setState(() => _selectedIds.remove(id)),
                          backgroundColor: Colors.blue.shade50,
                          labelStyle: const TextStyle(
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    }).toList(),
              ),
            ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'People to add',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
            ),
          ),

          // User list
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: repo.usersExceptSelf(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                // Filter out self and users already in the group
                var docs = snapshot.data!.docs.where((d) {
                  if (d.id == selfUid) return false;
                  if (widget.currentParticipantIds.contains(d.id)) return false;
                  if (_searchQuery.isNotEmpty) {
                    final name =
                        (d.data()['displayName'] as String?)?.toLowerCase() ??
                        '';
                    final email =
                        (d.data()['email'] as String?)?.toLowerCase() ?? '';
                    return name.contains(_searchQuery) ||
                        email.contains(_searchQuery);
                  }
                  return true;
                }).toList();

                if (docs.isEmpty) {
                  return Center(
                    child: Text(
                      _searchQuery.isNotEmpty
                          ? 'No users found for "$_searchQuery".'
                          : 'All users are already in this group.',
                      style: const TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data();
                    final displayName = (data['displayName'] as String?)
                        ?.trim();
                    final title =
                        (displayName != null && displayName.isNotEmpty)
                            ? displayName
                            : 'User';
                    final email = data['email'] as String? ?? '';
                    final isSelected = _selectedIds.contains(doc.id);

                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selectedIds.add(doc.id);
                          } else {
                            _selectedIds.remove(doc.id);
                          }
                        });
                      },
                      activeColor: Colors.blueAccent,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        email,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      secondary:
                          isSelected
                              ? const CircleAvatar(
                                backgroundColor: Colors.blueAccent,
                                radius: 14,
                                child: Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              )
                              : const CircleAvatar(
                                backgroundColor: Colors.transparent,
                                radius: 14,
                                child: Icon(
                                  Icons.person_outline,
                                  color: Colors.grey,
                                ),
                              ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
