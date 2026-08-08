import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../domain/call_session.dart';
import 'call_debug_controller.dart';
import 'two_party_call_controller.dart';
import 'widgets/call_video_grid.dart';

/// 从聊天页进入的正式通话界面。
/// 底层仍复用已经通过 P0 验证的 CallSession + LiveKit 媒体链，
/// 但不再暴露测试身份、URL、房间名等调试控件。
class ChatCallPage extends StatelessWidget {
  const ChatCallPage({
    super.key,
    required this.controller,
    required this.mediaController,
    required this.peerName,
  });

  final TwoPartyCallController controller;
  final CallDebugController mediaController;
  final String peerName;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, mediaController]),
      builder: (context, _) {
        final call = controller.currentCall;
        final video = call?.kind == CallKind.video;
        return Scaffold(
          backgroundColor: const Color(0xFF171717),
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: call?.status == CallSessionStatus.accepted && video
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(14, 52, 14, 116),
                          child: CallVideoGrid(controller: mediaController),
                        )
                      : _AudioCallBody(
                          peerName: peerName,
                          status: _statusLabel(call),
                          error: controller.errorMessage,
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
                    controller: controller,
                    mediaController: mediaController,
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
    if (controller.errorMessage != null) return controller.errorMessage!;
    if (call == null) {
      return controller.signalingConnected ? '正在建立通话…' : '正在连接通话服务…';
    }
    return switch (call.status) {
      CallSessionStatus.ringing =>
        call.isIncomingFor(controller.identity)
            ? '邀请你进行${call.kind == CallKind.video ? '视频' : '语音'}通话'
            : '正在等待对方接听…',
      CallSessionStatus.accepted =>
        call.kind == CallKind.video ? '视频通话中' : '语音通话中',
      CallSessionStatus.rejected => '对方已拒绝',
      CallSessionStatus.ended => '通话已结束',
    };
  }
}

class _AudioCallBody extends StatelessWidget {
  const _AudioCallBody({
    required this.peerName,
    required this.status,
    required this.error,
  });

  final String peerName;
  final String status;
  final String? error;

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
            Container(
              width: 104,
              height: 104,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF445B72),
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Text(
                letter,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.w600,
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
              status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: error == null ? Colors.white60 : const Color(0xFFFF8C8C),
                fontSize: 13,
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
      return Center(
        child: _RoundCallButton(
          icon: Icons.close_rounded,
          label: '关闭',
          color: const Color(0xFF3A3A3A),
          onTap: () {
            controller.clearEndedCall();
            Navigator.maybePop(context);
          },
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundCallButton(
          icon: mediaController.microphoneEnabled
              ? Icons.mic_rounded
              : Icons.mic_off_rounded,
          label: mediaController.microphoneEnabled ? '静音' : '取消静音',
          color: const Color(0xFF333333),
          onTap: mediaController.toggleMicrophone,
        ),
        if (call.kind == CallKind.video) ...[
          const SizedBox(width: 24),
          _RoundCallButton(
            icon: mediaController.cameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            label: mediaController.cameraEnabled ? '关闭视频' : '开启视频',
            color: const Color(0xFF333333),
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
