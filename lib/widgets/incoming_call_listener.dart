import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:first_app/UI/agora_call_screen.dart';
import 'package:flutter/material.dart';

class IncomingCallListener extends StatefulWidget {
  const IncomingCallListener({super.key, required this.child});

  final Widget child;

  @override
  State<IncomingCallListener> createState() => _IncomingCallListenerState();
}

class _IncomingCallListenerState extends State<IncomingCallListener> {
  bool _handlingDialog = false;
  String? _activeCallDocPath;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return widget.child;

    return Stack(
      children: [
        widget.child,
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collectionGroup('calls')
              .where('status', isEqualTo: 'ringing')
              .where('calleeId', isEqualTo: user.uid)
              .limit(1)
              .snapshots(),
          builder: (context, snapshot) {
            final docs = snapshot.data?.docs ?? const [];
            if (docs.isNotEmpty) {
              final doc = docs.first;
              if (!_handlingDialog && _activeCallDocPath != doc.reference.path) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _handleIncomingCall(doc);
                });
              }
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }

  Future<void> _handleIncomingCall(
    QueryDocumentSnapshot<Map<String, dynamic>> callDoc,
  ) async {
    _handlingDialog = true;
    _activeCallDocPath = callDoc.reference.path;
    final data = callDoc.data();
    final isVideoCall = data['isVideoCall'] as bool? ?? false;
    final title = (data['callerName'] as String?)?.trim();
    final channelId = (data['channelId'] as String?)?.trim();
    final selfId = FirebaseAuth.instance.currentUser?.uid;
    final navigator = Navigator.of(context, rootNavigator: true);

    final decision = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: callDoc.reference.snapshots(),
          builder: (context, snapshot) {
            final status = snapshot.data?.data()?['status'] as String? ?? 'ringing';
            if (status != 'ringing') {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop(status);
                }
              });
            }

            return AlertDialog(
              title: Text(isVideoCall ? 'Incoming video call' : 'Incoming voice call'),
              content: Text(
                '${title?.isNotEmpty == true ? title : 'Someone'} is calling...',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop('decline'),
                  child: const Text('Decline'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop('accept'),
                  child: const Text('Accept'),
                ),
              ],
            );
          },
        );
      },
    );

    if (decision == 'accept' && channelId != null && channelId.isNotEmpty) {
      await callDoc.reference.set({
        'status': 'accepted',
        'acceptedBy': selfId,
        'acceptedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => AgoraCallScreen(
            channelId: channelId,
            title: title?.isNotEmpty == true ? title! : 'Incoming call',
            isVideoCall: isVideoCall,
          ),
        ),
      );
      await callDoc.reference.set({
        'status': 'ended',
        'endedBy': selfId,
        'endedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } else if (decision == 'decline') {
      await callDoc.reference.set({
        'status': 'declined',
        'declinedBy': selfId,
        'declinedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    _handlingDialog = false;
    _activeCallDocPath = null;
  }
}
