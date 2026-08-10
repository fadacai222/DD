import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../../theme/app_theme.dart';
import '../call_debug_controller.dart';

class CallVideoStage extends StatefulWidget {
  const CallVideoStage({required this.controller, super.key});

  final CallDebugController controller;

  @override
  State<CallVideoStage> createState() => _CallVideoStageState();
}

class _CallVideoStageState extends State<CallVideoStage> {
  bool _localPrimary = false;
  Offset? _pipOffset;

  @override
  Widget build(BuildContext context) {
    RemoteParticipant? remote;
    VideoTrack? remoteTrack;
    for (final participant in widget.controller.remoteParticipants) {
      final candidate = CallVideoGrid._remoteVideoTrack(participant);
      if (candidate != null) {
        remote = participant;
        remoteTrack = candidate;
        break;
      }
      remote ??= participant;
    }
    final localTrack = widget.controller.localVideoTrack;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stageSize = Size(constraints.maxWidth, constraints.maxHeight);
        final pipWidth = (constraints.maxWidth * 0.27).clamp(104.0, 168.0);
        final pipHeight = (pipWidth * 1.34).clamp(138.0, 224.0);
        final pipSize = Size(pipWidth, pipHeight);
        final primaryTrack = _localPrimary ? localTrack : remoteTrack;
        final pipTrack = _localPrimary ? remoteTrack : localTrack;
        final offset = CallVideoPipLayout.clamp(
          _pipOffset ??
              CallVideoPipLayout.initial(
                stageSize: stageSize,
                pipSize: pipSize,
              ),
          stageSize: stageSize,
          pipSize: pipSize,
        );

        return Semantics(
          label: _localPrimary ? '当前主画面：本机' : '当前主画面：对方',
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                key: Key(
                  _localPrimary
                      ? 'call-video-primary-local'
                      : 'call-video-primary-remote',
                ),
                color: const Color(0xFF161616),
                child: _videoView(
                  primaryTrack,
                  isLocal: _localPrimary,
                  active: true,
                ),
              ),
              if (remote != null && remote.isSpeaking && !_localPrimary)
                const Positioned(
                  left: 14,
                  top: 16,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xAA07C160),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(7),
                      child: Icon(
                        Icons.graphic_eq_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: offset.dx,
                top: offset.dy,
                width: pipWidth,
                height: pipHeight,
                child: SizedBox(
                  key: const Key('call-video-pip'),
                  width: pipWidth,
                  height: pipHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFF2B2B2B),
                              border: Border.all(
                                color:
                                    remote != null &&
                                        remote.isSpeaking &&
                                        _localPrimary
                                    ? const Color(0xFF07C160)
                                    : Colors.white24,
                                width: 1.5,
                              ),
                            ),
                            child: _videoView(
                              pipTrack,
                              isLocal: !_localPrimary,
                              active: true,
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: GestureDetector(
                          key: const Key('call-video-pip-hit-target'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              setState(() => _localPrimary = !_localPrimary),
                          onPanUpdate: (details) {
                            setState(() {
                              _pipOffset = CallVideoPipLayout.clamp(
                                (_pipOffset ?? offset) + details.delta,
                                stageSize: stageSize,
                                pipSize: pipSize,
                              );
                            });
                          },
                          onPanEnd: (_) {
                            setState(() {
                              _pipOffset = CallVideoPipLayout.snapHorizontal(
                                CallVideoPipLayout.clamp(
                                  _pipOffset ?? offset,
                                  stageSize: stageSize,
                                  pipSize: pipSize,
                                ),
                                stageSize: stageSize,
                                pipSize: pipSize,
                              );
                            });
                          },
                          child: const ColoredBox(color: Colors.transparent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _videoView(
    VideoTrack? track, {
    required bool isLocal,
    required bool active,
  }) {
    if (track == null) {
      return _VideoPlaceholder(active: active, isLocal: isLocal);
    }
    final preserveRemoteAspect =
        !isLocal && !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    return VideoTrackRenderer(
      track,
      fit: preserveRemoteAspect ? VideoViewFit.contain : VideoViewFit.cover,
      mirrorMode: isLocal ? VideoViewMirrorMode.auto : VideoViewMirrorMode.off,
    );
  }
}

final class CallVideoPipLayout {
  const CallVideoPipLayout._();

  static const double margin = 14;
  static const double bottomReserved = 104;

  static Rect bounds({required Size stageSize, required Size pipSize}) {
    final right = (stageSize.width - margin - pipSize.width).clamp(
      margin,
      double.infinity,
    );
    final bottom = (stageSize.height - bottomReserved - pipSize.height).clamp(
      margin,
      double.infinity,
    );
    return Rect.fromLTRB(margin, margin, right, bottom);
  }

  static Offset initial({required Size stageSize, required Size pipSize}) {
    final area = bounds(stageSize: stageSize, pipSize: pipSize);
    return Offset(area.right, area.bottom);
  }

  static Offset clamp(
    Offset value, {
    required Size stageSize,
    required Size pipSize,
  }) {
    final area = bounds(stageSize: stageSize, pipSize: pipSize);
    return Offset(
      value.dx.clamp(area.left, area.right),
      value.dy.clamp(area.top, area.bottom),
    );
  }

  static Offset snapHorizontal(
    Offset value, {
    required Size stageSize,
    required Size pipSize,
  }) {
    final clamped = clamp(value, stageSize: stageSize, pipSize: pipSize);
    final area = bounds(stageSize: stageSize, pipSize: pipSize);
    final pipCenter = clamped.dx + pipSize.width / 2;
    return Offset(
      pipCenter <= stageSize.width / 2 ? area.left : area.right,
      clamped.dy,
    );
  }
}

class CallVideoGrid extends StatelessWidget {
  const CallVideoGrid({required this.controller, super.key});

  final CallDebugController controller;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _ParticipantVideoTile(
        label: '本机',
        track: controller.localVideoTrack,
        isLocal: true,
        active: controller.connected,
      ),
      ...controller.remoteParticipants.map(
        (participant) => _ParticipantVideoTile(
          label: _participantLabel(participant),
          track: _remoteVideoTrack(participant),
          isSpeaking: participant.isSpeaking,
          active: true,
        ),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1050
            ? 3
            : constraints.maxWidth >= 640
            ? 2
            : 1;
        final tileWidth = (constraints.maxWidth - (columns - 1) * 12) / columns;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(2),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final tile in tiles)
                SizedBox(
                  width: tileWidth,
                  height: columns == 1 ? 230 : 260,
                  child: tile,
                ),
            ],
          ),
        );
      },
    );
  }

  static VideoTrack? _remoteVideoTrack(RemoteParticipant participant) {
    for (final publication in participant.videoTrackPublications) {
      final track = publication.track;
      if (track is VideoTrack && !publication.isScreenShare) {
        return track;
      }
    }
    return null;
  }

  static String _participantLabel(RemoteParticipant participant) {
    final name = participant.name.trim();
    return name.isEmpty
        ? participant.identity
        : '$name · ${participant.identity}';
  }
}

class _ParticipantVideoTile extends StatelessWidget {
  const _ParticipantVideoTile({
    required this.label,
    required this.track,
    required this.active,
    this.isLocal = false,
    this.isSpeaking = false,
  });

  final String label;
  final VideoTrack? track;
  final bool active;
  final bool isLocal;
  final bool isSpeaking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(DdRadii.surface),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: isSpeaking
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: isSpeaking ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(DdRadii.surface),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (track != null)
              VideoTrackRenderer(
                track!,
                fit:
                    !isLocal &&
                        !kIsWeb &&
                        defaultTargetPlatform == TargetPlatform.windows
                    ? VideoViewFit.contain
                    : VideoViewFit.cover,
                mirrorMode: isLocal
                    ? VideoViewMirrorMode.auto
                    : VideoViewMirrorMode.off,
              )
            else
              _VideoPlaceholder(active: active, isLocal: isLocal),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Row(
                children: [
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(DdRadii.pill),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isSpeaking) ...[
                    const SizedBox(width: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(7),
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          color: theme.colorScheme.onPrimary,
                          size: 17,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.active, required this.isLocal});

  final bool active;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 150 || constraints.maxHeight < 180;
        final iconSize = compact ? 30.0 : 46.0;
        final padding = compact ? 8.0 : 24.0;
        return Center(
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  active ? Icons.videocam_off_outlined : Icons.call_outlined,
                  size: iconSize,
                  color: theme.colorScheme.outline,
                ),
                SizedBox(height: compact ? 6 : 12),
                Text(
                  active
                      ? (compact ? '视频已关闭' : '摄像头已关闭')
                      : (compact ? '等待画面' : '加入房间后显示本地与远端画面'),
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style:
                      (compact
                              ? theme.textTheme.bodySmall
                              : theme.textTheme.bodyMedium)
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
