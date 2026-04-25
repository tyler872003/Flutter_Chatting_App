import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:first_app/services/agora_config.dart';
import 'package:flutter/material.dart';

class AgoraCallScreen extends StatefulWidget {
  const AgoraCallScreen({
    super.key,
    required this.channelId,
    required this.title,
    required this.isVideoCall,
  });

  final String channelId;
  final String title;
  final bool isVideoCall;

  @override
  State<AgoraCallScreen> createState() => _AgoraCallScreenState();
}

class _AgoraCallScreenState extends State<AgoraCallScreen> {
  final RtcEngine _engine = createAgoraRtcEngine();

  int? _remoteUid;
  bool _muted = false;
  bool _speakerOn = true;
  bool _cameraFront = true;
  bool _engineReady = false;
  String _statusText = 'Connecting...';
  String? _lastAgoraError;

  @override
  void initState() {
    super.initState();
    _setupAgora();
  }

  Future<void> _setupAgora() async {
    if (!AgoraConfig.isConfigured) return;

    await _engine.initialize(
      const RtcEngineContext(
        appId: AgoraConfig.appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );

    _engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (_, __) {
          if (!mounted) return;
          setState(() {
            _statusText = 'Connected';
          });
        },
        onUserJoined: (_, remoteUid, __) {
          if (!mounted) return;
          setState(() {
            _remoteUid = remoteUid;
            _statusText = 'On call';
          });
        },
        onUserOffline: (_, remoteUid, __) {
          if (!mounted) return;
          if (_remoteUid == remoteUid) {
            setState(() {
              _remoteUid = null;
              _statusText = 'Remote user left';
            });
          }
        },
        onError: (err, msg) {
          if (!mounted) return;
          final text = 'Agora error: $err ${msg.trim()}'.trim();
          setState(() {
            _lastAgoraError = text;
            _statusText = 'Call failed';
          });
        },
      ),
    );

    await _engine.enableAudio();
    await _engine.setEnableSpeakerphone(_speakerOn);

    if (widget.isVideoCall) {
      await _engine.enableVideo();
      await _engine.startPreview();
    } else {
      await _engine.disableVideo();
    }

    try {
      await _engine.joinChannel(
        token: AgoraConfig.token,
        channelId: widget.channelId,
        uid: 0,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastAgoraError = 'Join failed: $e';
        _statusText = 'Call failed';
      });
    }

    if (!mounted) return;
    setState(() => _engineReady = true);
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    await _engine.muteLocalAudioStream(next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerOn;
    await _engine.setEnableSpeakerphone(next);
    if (mounted) setState(() => _speakerOn = next);
  }

  Future<void> _switchCamera() async {
    await _engine.switchCamera();
    if (mounted) setState(() => _cameraFront = !_cameraFront);
  }

  Future<void> _endCall() async {
    await _engine.leaveChannel();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _engine.leaveChannel();
    _engine.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final missingConfig = !AgoraConfig.isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isVideoCall ? 'Video Call' : 'Voice Call'),
      ),
      body: SafeArea(
        child: missingConfig
            ? _ConfigMissingView(title: widget.title)
            : Column(
                children: [
                  Expanded(
                    child: widget.isVideoCall
                        ? _buildVideoLayout()
                        : _buildVoiceLayout(),
                  ),
                  _buildControls(),
                ],
              ),
      ),
    );
  }

  Widget _buildVideoLayout() {
    return Stack(
      children: [
        Positioned.fill(
          child: _remoteUid == null
              ? const Center(child: Text('Waiting for other user...'))
              : AgoraVideoView(
                  controller: VideoViewController.remote(
                    rtcEngine: _engine,
                    canvas: VideoCanvas(uid: _remoteUid),
                    connection: RtcConnection(channelId: widget.channelId),
                  ),
                ),
        ),
        Positioned(
          top: 16,
          right: 16,
          width: 110,
          height: 160,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _engineReady
                ? AgoraVideoView(
                    controller: VideoViewController(
                      rtcEngine: _engine,
                      canvas: const VideoCanvas(uid: 0),
                    ),
                  )
                : Container(
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceLayout() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircleAvatar(
            radius: 44,
            child: Icon(Icons.person, size: 48),
          ),
          const SizedBox(height: 14),
          Text(
            widget.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(_statusText),
          const SizedBox(height: 6),
          Text(_remoteUid == null ? 'Ringing...' : 'On call'),
          if (_lastAgoraError != null) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _lastAgoraError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Tip: your Agora temporary token may be expired. Generate a new token and retry.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CallAction(
            icon: _muted ? Icons.mic_off : Icons.mic,
            onTap: _toggleMute,
          ),
          _CallAction(
            icon: _speakerOn ? Icons.volume_up : Icons.hearing_disabled,
            onTap: _toggleSpeaker,
          ),
          if (widget.isVideoCall)
            _CallAction(
              icon: _cameraFront ? Icons.cameraswitch : Icons.cameraswitch_outlined,
              onTap: _switchCamera,
            ),
          _CallAction(
            icon: Icons.call_end,
            background: Colors.red,
            onTap: _endCall,
          ),
        ],
      ),
    );
  }
}

class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.icon,
    required this.onTap,
    this.background,
  });

  final IconData icon;
  final Future<void> Function() onTap;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 25,
      backgroundColor: background ?? Theme.of(context).colorScheme.primary,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }
}

class _ConfigMissingView extends StatelessWidget {
  const _ConfigMissingView({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, size: 42),
            const SizedBox(height: 12),
            Text(
              'Agora is not configured for "$title".',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Run with --dart-define=AGORA_APP_ID=YOUR_APP_ID',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            const Text(
              'Optional: --dart-define=AGORA_TEMP_TOKEN=YOUR_TEMP_TOKEN',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
