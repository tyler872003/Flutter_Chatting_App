import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:first_app/services/chat_repository.dart';
import 'package:flutter/material.dart';

class BlockedUsersScreen extends StatelessWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = ChatRepository();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Blocked Users', style: TextStyle(color: Colors.black)),
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>?>(
        stream: repo.currentUserStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data?.data();
          if (data == null) {
            return const Center(child: Text('No user data.'));
          }

          final blockedUsers = List<String>.from(data['blockedUsers'] ?? []);

          if (blockedUsers.isEmpty) {
            return const Center(
              child: Text('You have not blocked anyone.', style: TextStyle(color: Colors.grey)),
            );
          }

          // Fetch details for all blocked users
          return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
            future: FirebaseFirestore.instance
                .collection('users')
                .where(FieldPath.documentId, whereIn: blockedUsers)
                .get(),
            builder: (context, usersSnapshot) {
              if (!usersSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = usersSnapshot.data!.docs;

              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final userData = doc.data();
                  final displayName = (userData['displayName'] as String?)?.trim() ?? 'User';

                  return ListTile(
                    title: Text(displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Blocked'),
                    trailing: TextButton(
                      onPressed: () async {
                        try {
                          await repo.unblockUser(doc.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Unblocked $displayName')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Failed to unblock: $e')),
                            );
                          }
                        }
                      },
                      child: const Text('Unblock', style: TextStyle(color: Colors.blueAccent)),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
