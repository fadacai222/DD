import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/sound/app_sound_service.dart';
import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../domain/call_session.dart';
import 'call_debug_controller.dart';
import 'two_party_call_controller.dart';
import 'widgets/call_video_grid.dart';

class ChatCallPage extends StatefulWidget {
  const ChatCallPage({
    super.key,
    required this.controller,
    required this.mediaController,
    required this.peerName,
    required this.peerId,
    required this.origin,
    required this.accessToken,
    this.onFinished,
    this.soundService,
  });

  final TwoPartyCallController controller;
  final CallDebugController mediaController;
  final String peerName;
  final String peerId;
  final Uri origin;
  final String accessToken;
  final Future<void> Function(CallSession call, Duration duration)? onFinished;
  final AppSoundService? soundService;

  @override
  State<ChatCallPage> createState() => _ChatCallPageState();
}

class _ChatCallPageState extends State<ChatCallPage> {
  Timer? _durationTimer;
  Timer? _autoCloseTimer;
  Duration _elapsed = Duration.zero;
  String? _finishedCallId;
  String? _lastSoundSignature;

  AppSoundService get _sounds => widget.soundService ?? AppSoundService.shared;

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleCallState);
    if (_android) {
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]),
      );
    }
    _handleCallState();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleCallState);
    _durationTimer?.cancel();
    _autoCloseTimer?.cancel();
    unawaited(_sounds.stopCallSounds());
    if (_android) {
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
      );
    }
    super.dispose();
  }

  void _handleCallState() {
    if (!mounted) return;
    final call = widget.controller.currentCall;
    _syncCallSounds(call);
    if (call?.status == CallSessionStatus.accepted) {
      _ensureDurationTimer();
      _updateElapsed(call!);
    } else {
      _durationTimer?.cancel();
      _durationTimer = null;
    }

    if (call != null &&
        (call.status == CallSessionStatus.ended ||
            call.status == CallSessionStatus.rejected)) {
      _scheduleFinished(call);
    }
    setState(() {});
  }

  void _syncCallSounds(CallSession? call) {
    final signature = call == null ? 'none' : '${call.id}:${call.status.name}';
    if (_lastSoundSignature == signature) return;
    _lastSoundSignature = signature;
    if (call == null) {
      unawaited(_sounds.stopCallSounds());
      return;
    }
    switch (call.status) {
      case CallSessionStatus.ringing:
        if (call.isIncomingFor(widget.controller.identity)) {
          unawaited(_sounds.playIncomingRingtone());
        } else {
          unawaited(_sounds.playOutgoingRingback());
        }
      case CallSessionStatus.accepted:
        unawaited(_sounds.playCallConnected());
      case CallSessionStatus.rejected:
      case CallSessionStatus.ended:
        unawaited(_sounds.playCallEnded());
    }
  }

  void _ensureDurationTimer() {
    if (_durationTimer != null) return;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final call = widget.controller.currentCall;
      if (!mounted || call?.status != CallSessionStatus.accepted) return;
      setState(() => _updateElapsed(call!));
    });
  }

  void _updateElapsed(CallSession call) {
    final acceptedAt = call.acceptedAt;
    if (acceptedAt == null) {
      _elapsed = Duration.zero;
      return;
    }
    final end = call.endedAt ?? DateTime.now().toUtc();
    final duration = end.difference(acceptedAt.toUtc());
    _elapsed = duration.isNegative ? Duration.zero : duration;
  }

  void _scheduleFinished(CallSession call) {
    if (_finishedCallId == call.id) return;
    _finishedCallId = call.id;
    _updateElapsed(call);
    if (call.acceptedAt != null && widget.onFinished != null) {
      unawaited(widget.onFinished!(call, _elapsed));
    }
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(const Duration(seconds: 1), () {
      widget.controller.clearEndedCall();
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.controller, widget.mediaController]),
      builder: (context, _) {
        final call = widget.controller.currentCall;
        final video = call?.kind == CallKind.video;
        final accepted = call?.status == CallSessionStatus.accepted;
        return Scaffold(
          backgroundColor: const Color(0xFF111111),
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (accepted && video)
                  CallVideoStage(controller: widget.mediaController)
                else
                  _AudioCallBody(
                    peerName: widget.peerName,
                    peerId: widget.peerId,
                    origin: widget.origin,
                    accessToken: widget.accessToken,
                    status: _statusLabel(call),
                    error: widget.controller.errorMessage,
                    elapsed: accepted ? _formatDuration(_elapsed) : null,
                  ),
                if (accepted && video)
                  Positioned(
                    left: 72,
                    right: 72,
                    top: 16,
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.38),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Text(
                            _formatDuration(_elapsed),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontFeatures: <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 8,
                  top: 6,
                  child: IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    color: Colors.white70,
                  ),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 22,
                  child: _CallControls(
                    controller: widget.controller,
                    mediaController: widget.mediaController,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _statusLabel(CallSession? call) {
    if (widget.controller.errorMessage != null) {
      return widget.controller.errorMessage!;
    }
    if (call == null) {
      return widget.controller.signalingConnected ? '正在建立通话…' : '正在连接通话服务…';
    }
    return switch (call.status) {
      CallSessionStatus.ringing =>
        call.isIncomingFor(widget.controller.identity)
            ? '邀请你进行${call.kind == CallKind.video ? '视频' : '语音'}通话'
            : '正在等待对方接听…',
      CallSessionStatus.accepted =>
        call.kind == CallKind.video ? '视频通话中' : '语音通话中',
      CallSessionStatus.rejected =>
        call.isIncomingFor(widget.controller.identity) ? '已拒绝' : '对方已拒绝',
      CallSessionStatus.ended => '通话已结束',
    };
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds.clamp(0, 24 * 60 * 60 - 1);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _AudioCallBody extends StatelessWidget {
  const _AudioCallBody({
    required this.peerName,
    required this.peerId,
    required this.origin,
    required this.accessToken,
    required this.status,
    required this.error,
    required this.elapsed,
  });

  final String peerName;
  final String peerId;
  final Uri origin;
  final String accessToken;
  final String status;
  final String? error;
  final String? elapsed;

  @override
  Widget build(BuildContext context) {
    final letter = peerName.trim().isEmpty
        ? '?'
        : peerName.trim().characters.first;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 130),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: ProfileAvatar(
                  origin: origin,
                  accessToken: accessToken,
                  userId: peerId,
                  displayName: peerName.isEmpty ? letter : peerName,
                  size: 104,
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              peerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              elapsed ?? status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: error == null ? Colors.white60 : const Color(0xFFFF8C8C),
                fontSize: 13,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls({
    required this.controller,
    required this.mediaController,
  });

  final TwoPartyCallController controller;
  final CallDebugController mediaController;

  @override
  Widget build(BuildContext context) {
    final call = controller.currentCall;
    if (call == null) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white70,
          ),
        ),
      );
    }

    if (call.status == CallSessionStatus.ringing &&
        call.isIncomingFor(controller.identity)) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoundCallButton(
            icon: Icons.call_end_rounded,
            label: '拒绝',
            color: DdColors.danger,
            onTap: controller.busy ? null : controller.reject,
          ),
          const SizedBox(width: 58),
          _RoundCallButton(
            icon: call.kind == CallKind.video
                ? Icons.videocam_rounded
                : Icons.call_rounded,
            label: '接听',
            color: DdColors.green,
            onTap: controller.busy ? null : controller.accept,
          ),
        ],
      );
    }

    if (call.status == CallSessionStatus.ringing) {
      return Center(
        child: _RoundCallButton(
          icon: Icons.call_end_rounded,
          label: '取消',
          color: DdColors.danger,
          onTap: controller.busy ? null : controller.hangup,
        ),
      );
    }

    if (call.status != CallSessionStatus.accepted) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundCallButton(
          icon: mediaController.microphoneEnabled
              ? Icons.mic_rounded
              : Icons.mic_off_rounded,
          label: mediaController.microphoneEnabled ? '静音' : '取消静音',
          color: const Color(0xB3333333),
          onTap: mediaController.toggleMicrophone,
        ),
        if (call.kind == CallKind.video) ...[
          const SizedBox(width: 24),
          _RoundCallButton(
            icon: mediaController.cameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            label: mediaController.cameraEnabled ? '关闭视频' : '开启视频',
            color: const Color(0xB3333333),
            onTap: mediaController.toggleCamera,
          ),
        ],
        const SizedBox(width: 24),
        _RoundCallButton(
          icon: Icons.call_end_rounded,
          label: '挂断',
          color: DdColors.danger,
          onTap: controller.busy ? null : controller.hangup,
        ),
      ],
    );
  }
}

class _RoundCallButton extends StatelessWidget {
  const _RoundCallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final FutureOr<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: onTap == null ? color.withValues(alpha: 0.38) : color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap == null ? null : () => onTap!(),
            child: SizedBox(
              width: 58,
              height: 58,
              child: Icon(icon, color: Colors.white, size: 27),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}
