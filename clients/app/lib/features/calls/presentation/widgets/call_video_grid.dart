import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../call_debug_controller.dart';

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
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: isSpeaking
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: isSpeaking ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (track != null)
              VideoTrackRenderer(
                track!,
                fit: VideoViewFit.cover,
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
                        borderRadius: BorderRadius.circular(7),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.videocam_off_outlined : Icons.call_outlined,
              size: 46,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              active ? (isLocal ? '本机摄像头未开启' : '对方暂未发布视频') : '加入房间后显示本地与远端画面',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
