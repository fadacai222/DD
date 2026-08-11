import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../theme/app_theme.dart';
import '../data/group_call_api_client.dart';
import '../domain/group_call_models.dart';

int groupCallGridColumns(int participantCount, double width) {
  if (participantCount <= 1) return 1;
  if (participantCount <= 4) return 2;
  if (width >= 1050) return 4;
  return 3;
}

class GroupCallPage extends StatefulWidget {
  const GroupCallPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.groupName,
    required this.join,
    this.gateway,
  });

  final Uri origin;
  final String accessToken;
  final String groupName;
  final GroupCallJoinInfo join;
  final GroupCallGateway? gateway;

  @override
  State<GroupCallPage> createState() => _GroupCallPageState();
}

class _GroupCallPageState extends State<GroupCallPage>
    with WidgetsBindingObserver {
  late final Room _room;
  late final GroupCallGateway _gateway;
  late final bool _ownsGateway;
  EventsListener<RoomEvent>? _listener;
  bool _connecting = true;
  bool _leaving = false;
  bool _micEnabled = true;
  bool _cameraEnabled = false;
  bool _speakerEnabled = true;
  String? _error;
  DateTime? _connectedAt;
  Timer? _durationTimer;
  Timer? _membershipTimer;
  bool _membershipCheckBusy = false;
  Duration _elapsed = Duration.zero;

  bool get _videoCall => widget.join.call.isVideo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? GroupCallApiClient();
    _room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
      ),
    );
    _listener = _room.createListener()
      ..on<RoomDisconnectedEvent>((event) {
        if (!mounted || _leaving) return;
        setState(() => _error = '群通话连接已断开，可返回群聊后重新加入。');
      })
      ..on<RoomReconnectingEvent>((_) {
        if (mounted && !_leaving) {
          setState(() => _error = '网络波动，正在自动恢复群通话…');
        }
      })
      ..on<RoomReconnectedEvent>((_) {
        if (mounted && !_leaving) setState(() => _error = null);
      })
      ..on<ParticipantConnectedEvent>((_) => _refreshRoom())
      ..on<ParticipantDisconnectedEvent>((_) => _refreshRoom())
      ..on<TrackSubscribedEvent>((_) => _refreshRoom())
      ..on<TrackUnsubscribedEvent>((_) => _refreshRoom())
      ..on<TrackMutedEvent>((_) => _refreshRoom())
      ..on<TrackUnmutedEvent>((_) => _refreshRoom());
    unawaited(_connect());
  }

  Future<void> _connect() async {
    try {
      await _room.connect(widget.join.liveKitUrl, widget.join.token);
      final local = _room.localParticipant;
      if (local == null) throw StateError('LiveKit local participant unavailable');
      await local.setMicrophoneEnabled(true);
      if (_videoCall) {
        await local.setCameraEnabled(true);
        _cameraEnabled = true;
      }
      _connectedAt = DateTime.now();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _connectedAt == null) return;
        setState(() => _elapsed = DateTime.now().difference(_connectedAt!));
      });
      _membershipTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_verifyMembership()),
      );
      if (mounted) setState(() => _connecting = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = '加入群通话失败：$error';
        });
      }
    }
  }

  void _refreshRoom() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _cameraEnabled) {
      unawaited(_room.localParticipant?.setCameraEnabled(false));
    } else if (state == AppLifecycleState.resumed &&
        _cameraEnabled &&
        _videoCall) {
      unawaited(_room.localParticipant?.setCameraEnabled(true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _durationTimer?.cancel();
    _membershipTimer?.cancel();
    _listener?.dispose();
    unawaited(_room.disconnect());
    unawaited(_room.dispose());
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_leaving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_leaving) unawaited(_leave(closePage: true));
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF101314),
        appBar: AppBar(
          backgroundColor: const Color(0xFF101314),
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
          titleSpacing: 16,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.groupName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              Text(
                '${_videoCall ? '群视频通话' : '群语音通话'} · ${_formatDuration(_elapsed)}',
                style: const TextStyle(fontSize: 11, color: Colors.white60),
              ),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: InkWell(
                  key: const Key('group-call-member-list'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: _showParticipants,
                  child: _statusChip(
                    '$_participantCount/${widget.join.call.maxParticipants} 人',
                    color: DdColors.green,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (_error != null)
                Material(
                  color: DdColors.danger.withValues(alpha: 0.14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Colors.redAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: _connecting
                    ? const Center(
                        child: CircularProgressIndicator(color: Colors.white70),
                      )
                    : _participantGrid(),
              ),
              _controls(),
            ],
          ),
        ),
      ),
    );
  }

  int get _participantCount => 1 + _room.remoteParticipants.length;

  Widget _participantGrid() {
    final participants = <Participant>[
      ?_room.localParticipant,
      ..._room.remoteParticipants.values,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = groupCallGridColumns(participants.length, constraints.maxWidth);
        return GridView.builder(
          key: const Key('group-call-participant-grid'),
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: _videoCall ? 0.78 : 1,
          ),
          itemCount: participants.length,
          itemBuilder: (context, index) => _participantTile(
            participants[index],
            local: participants[index] is LocalParticipant,
          ),
        );
      },
    );
  }

  Widget _participantTile(Participant participant, {required bool local}) {
    final videoTrack = _videoTrack(participant);
    final displayName = participant.name.trim().isEmpty
        ? (local ? '我' : participant.identity)
        : participant.name.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: const Color(0xFF1D2224),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_videoCall && videoTrack != null)
              VideoTrackRenderer(videoTrack, fit: VideoViewFit.cover)
            else
              Center(
                child: CircleAvatar(
                  radius: 34,
                  backgroundColor: const Color(0xFF426B82),
                  child: Text(
                    displayName.characters.firstOrNull ?? '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 27,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 7,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      local ? '$displayName（我）' : displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        shadows: <Shadow>[Shadow(color: Colors.black87, blurRadius: 4)],
                      ),
                    ),
                  ),
                  if (_microphoneMuted(participant))
                    const Icon(Icons.mic_off_rounded, size: 15, color: Colors.white60),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  VideoTrack? _videoTrack(Participant participant) {
    for (final publication in participant.videoTrackPublications) {
      if (publication.muted || !publication.subscribed) continue;
      final track = publication.track;
      if (track is VideoTrack) return track;
    }
    return null;
  }

  bool _microphoneMuted(Participant participant) {
    final publications = participant.audioTrackPublications;
    if (publications.isEmpty) return true;
    return publications.every((publication) => publication.muted);
  }

  Future<void> _showParticipants() async {
    if (!mounted) return;
    final participants = <Participant>[
      ?_room.localParticipant,
      ..._room.remoteParticipants.values,
    ];
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
        itemCount: participants.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final participant = participants[index];
          final local = participant is LocalParticipant;
          final name = participant.name.trim().isEmpty
              ? (local ? '我' : participant.identity)
              : participant.name.trim();
          return ListTile(
            leading: CircleAvatar(
              child: Text(name.characters.firstOrNull ?? '?'),
            ),
            title: Text(local ? '$name（我）' : name),
            subtitle: Text(participant.isSpeaking ? '正在讲话' : '已加入'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _microphoneMuted(participant)
                      ? Icons.mic_off_rounded
                      : Icons.mic_rounded,
                  size: 18,
                ),
                if (_videoCall) ...[
                  const SizedBox(width: 8),
                  Icon(
                    _videoTrack(participant) == null
                        ? Icons.videocam_off_rounded
                        : Icons.videocam_rounded,
                    size: 18,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _verifyMembership() async {
    if (_membershipCheckBusy || _leaving || !mounted) return;
    _membershipCheckBusy = true;
    try {
      final active = await _gateway.active(
        origin: widget.origin,
        accessToken: widget.accessToken,
        groupId: widget.join.call.groupId,
      );
      if (active == null || active.id != widget.join.call.id || !active.isActive) {
        await _forceExit('群通话已结束。');
      }
    } on GroupCallApiException catch (error) {
      if (error.statusCode == 403 || error.statusCode == 404) {
        await _forceExit(
          error.statusCode == 403 ? '你已不在此群，已退出群通话。' : '群通话已结束。',
        );
      }
    } catch (_) {
      // LiveKit owns reconnect behavior. A temporary REST failure must not
      // tear down an otherwise healthy media session.
    } finally {
      _membershipCheckBusy = false;
    }
  }

  Future<void> _forceExit(String message) async {
    if (_leaving || !mounted) return;
    _leaving = true;
    _membershipTimer?.cancel();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _room.disconnect();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _controls() => Material(
    color: const Color(0xFF171B1C),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _callButton(
            key: const Key('group-call-mic'),
            label: _micEnabled ? '静音' : '取消静音',
            icon: _micEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
            onPressed: _toggleMic,
          ),
          if (_videoCall) ...[
            const SizedBox(width: 16),
            _callButton(
              key: const Key('group-call-camera'),
              label: _cameraEnabled ? '关闭摄像头' : '打开摄像头',
              icon: _cameraEnabled ? Icons.videocam_rounded : Icons.videocam_off_rounded,
              onPressed: _toggleCamera,
            ),
          ],
          const SizedBox(width: 16),
          _callButton(
            key: const Key('group-call-speaker'),
            label: _speakerEnabled ? '扬声器' : '听筒',
            icon: _speakerEnabled ? Icons.volume_up_rounded : Icons.hearing_rounded,
            onPressed: _toggleSpeaker,
          ),
          const SizedBox(width: 16),
          _callButton(
            key: const Key('group-call-leave'),
            label: '离开',
            icon: Icons.call_end_rounded,
            color: DdColors.danger,
            onPressed: _leaving ? null : () => _leave(closePage: true),
          ),
        ],
      ),
    ),
  );

  Widget _callButton({
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    Color color = const Color(0xFF2B3234),
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton.filled(
        key: key,
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: const Size(50, 50),
        ),
        icon: Icon(icon),
      ),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.white60, fontSize: 10)),
    ],
  );

  Widget _statusChip(String text, {required Color color}) => DecoratedBox(
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(text, style: TextStyle(color: color, fontSize: 11)),
    ),
  );

  Future<void> _toggleMic() async {
    final next = !_micEnabled;
    try {
      await _room.localParticipant?.setMicrophoneEnabled(next);
      if (mounted) setState(() => _micEnabled = next);
    } catch (_) {
      if (mounted) _show('麦克风切换失败。');
    }
  }

  Future<void> _toggleCamera() async {
    final next = !_cameraEnabled;
    try {
      await _room.localParticipant?.setCameraEnabled(next);
      if (mounted) setState(() => _cameraEnabled = next);
    } catch (_) {
      if (mounted) _show('摄像头切换失败。');
    }
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerEnabled;
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(next);
      if (mounted) setState(() => _speakerEnabled = next);
    } catch (_) {
      if (mounted) _show('音频输出切换失败。');
    }
  }

  Future<void> _leave({required bool closePage}) async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      await _gateway.leave(
        origin: widget.origin,
        accessToken: widget.accessToken,
        groupId: widget.join.call.groupId,
        callId: widget.join.call.id,
      );
    } catch (_) {
      // Local leave must still work if server notification fails.
    }
    try {
      await _room.disconnect();
    } catch (_) {}
    if (!mounted) return;
    if (closePage) {
      Navigator.of(context).pop();
    } else {
      setState(() => _leaving = false);
    }
  }

  String _formatDuration(Duration value) {
    final seconds = value.inSeconds.clamp(0, 24 * 60 * 60 - 1);
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final rest = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
    }
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  void _show(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

extension on Characters {
  String? get firstOrNull => isEmpty ? null : first;
}
