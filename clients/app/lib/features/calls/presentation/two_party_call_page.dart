import 'package:flutter/material.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../../../theme/app_theme.dart';
import '../domain/call_session.dart';
import 'call_debug_controller.dart';
import 'two_party_call_controller.dart';
import 'widgets/call_video_grid.dart';

class TwoPartyCallPage extends StatefulWidget {
  const TwoPartyCallPage({super.key, this.mediaController, this.controller});

  final CallDebugController? mediaController;
  final TwoPartyCallController? controller;

  @override
  State<TwoPartyCallPage> createState() => _TwoPartyCallPageState();
}

class _TwoPartyCallPageState extends State<TwoPartyCallPage> {
  late final CallDebugController _mediaController;
  late final TwoPartyCallController _controller;
  late final TextEditingController _apiUrlController;
  late final TextEditingController _identityController;
  late final TextEditingController _nameController;
  late final TextEditingController _peerController;
  late final bool _ownsMediaController;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    final suffix = DateTime.now().millisecondsSinceEpoch.toString().substring(
      7,
    );
    _ownsMediaController = widget.mediaController == null;
    _mediaController = widget.mediaController ?? CallDebugController();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TwoPartyCallController(_mediaController);
    _apiUrlController = TextEditingController(text: 'http://127.0.0.1:18473');
    _identityController = TextEditingController(text: 'user-$suffix');
    _nameController = TextEditingController(text: '测试用户 $suffix');
    _peerController = TextEditingController();
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _identityController.dispose();
    _nameController.dispose();
    _peerController.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    if (_ownsMediaController) {
      _mediaController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('双端通话'),
            Text(
              '呼叫、响铃、接听、拒绝与同步挂断',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 18),
            child: Center(child: Text('P0 · v0.3.2')),
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([_controller, _mediaController]),
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final padding = constraints.maxWidth < 480 ? 12.0 : 18.0;
                final content = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildConnectionCard(),
                    const SizedBox(height: 14),
                    if (_controller.errorMessage != null) ...[
                      _buildErrorCard(_controller.errorMessage!),
                      const SizedBox(height: 14),
                    ],
                    Expanded(child: _buildCallArea()),
                  ],
                );

                return Padding(
                  padding: EdgeInsets.all(padding),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: content,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    final connected = _controller.signalingConnected;
    if (connected) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.person_rounded, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_controller.displayName} · ${_controller.identity}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              _StatusChip(state: _controller.signalingState),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '本机通话身份',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _StatusChip(state: _controller.signalingState),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 290,
                  child: TextField(
                    controller: _apiUrlController,
                    enabled: !connected && !_controller.busy,
                    decoration: const InputDecoration(
                      labelText: '服务地址',
                      hintText: 'http://127.0.0.1:18473',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _identityController,
                    enabled: !connected && !_controller.busy,
                    decoration: const InputDecoration(
                      labelText: '本机身份',
                      hintText: 'alice',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _nameController,
                    enabled: !connected && !_controller.busy,
                    decoration: const InputDecoration(
                      labelText: '显示名称',
                      hintText: 'Alice',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: connected || _controller.busy
                      ? null
                      : () => _controller.start(
                          apiBaseUrl: _apiUrlController.text,
                          participantIdentity: _identityController.text,
                          participantName: _nameController.text,
                        ),
                  icon: const Icon(Icons.power_settings_new_rounded),
                  label: const Text('上线接听'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallArea() {
    if (!_controller.signalingConnected) {
      return const _CenteredState(
        icon: Icons.notifications_active_outlined,
        title: '先上线接听',
        description: '两端都打开此页面，分别设置不同身份并点击“上线接听”。',
      );
    }

    final call = _controller.currentCall;
    if (call == null) return _buildDialer();
    if (call.status == CallSessionStatus.ringing) {
      return call.isIncomingFor(_controller.identity)
          ? _buildIncoming(call)
          : _buildOutgoing(call);
    }
    if (call.status == CallSessionStatus.accepted) {
      return _buildActiveCall(call);
    }
    return _buildEnded(call);
  }

  Widget _buildDialer() {
    return Card(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.person_search_outlined,
                  size: 62,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 18),
                Text(
                  '呼叫另一端',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '输入对方页面显示的“本机身份”。两端不能使用相同身份。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: _peerController,
                  enabled: !_controller.busy,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '对方身份',
                    hintText: 'bob',
                    prefixIcon: Icon(Icons.alternate_email_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _controller.busy
                            ? null
                            : () => _controller.placeCall(
                                calleeIdentity: _peerController.text,
                                kind: CallKind.audio,
                              ),
                        icon: const Icon(Icons.call_outlined),
                        label: const Text('语音呼叫'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _controller.busy
                            ? null
                            : () => _controller.placeCall(
                                calleeIdentity: _peerController.text,
                                kind: CallKind.video,
                              ),
                        icon: const Icon(Icons.videocam_outlined),
                        label: const Text('视频呼叫'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIncoming(CallSession call) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 320;
          final avatarRadius = compact ? 30.0 : 42.0;
          final gap = compact ? 12.0 : 20.0;
          return SingleChildScrollView(
            padding: EdgeInsets.all(compact ? 14 : 28),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: avatarRadius,
                    child: Icon(
                      call.kind == CallKind.video
                          ? Icons.videocam_rounded
                          : Icons.call_rounded,
                      size: avatarRadius,
                    ),
                  ),
                  SizedBox(height: gap),
                  Text(
                    call.callerName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${call.callerIdentity} 正在发起${_kindLabel(call.kind)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: compact ? 14 : 26),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 18,
                    runSpacing: 10,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _controller.busy ? null : _controller.reject,
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.errorContainer,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onErrorContainer,
                        ),
                        icon: const Icon(Icons.call_end_rounded),
                        label: const Text('拒绝'),
                      ),
                      FilledButton.icon(
                        onPressed: _controller.busy ? null : _controller.accept,
                        icon: const Icon(Icons.call_rounded),
                        label: const Text('接听'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildOutgoing(CallSession call) {
    return Card(
      child: _CenteredState(
        icon: call.kind == CallKind.video
            ? Icons.video_call_outlined
            : Icons.phone_in_talk_outlined,
        title: '正在呼叫 ${call.calleeIdentity}',
        description: '等待对方接听${_kindLabel(call.kind)}…',
        action: FilledButton.tonalIcon(
          onPressed: _controller.busy ? null : _controller.hangup,
          icon: const Icon(Icons.call_end_rounded),
          label: const Text('取消呼叫'),
        ),
      ),
    );
  }

  Widget _buildActiveCall(CallSession call) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: _controller.mediaJoinInProgress
                ? const _CenteredState(
                    icon: Icons.sync_rounded,
                    title: '正在建立媒体连接',
                    description: '已接听，正在领取受限 Token 并进入同一房间。',
                    loading: true,
                  )
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: CallVideoGrid(controller: _mediaController),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                Text(
                  '${_kindLabel(call.kind)} · ${_controller.peerIdentity}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                OutlinedButton.icon(
                  onPressed: _mediaController.busy
                      ? null
                      : _mediaController.toggleMicrophone,
                  icon: Icon(
                    _mediaController.microphoneEnabled
                        ? Icons.mic_rounded
                        : Icons.mic_off_rounded,
                  ),
                  label: Text(_mediaController.microphoneEnabled ? '静音' : '开麦'),
                ),
                if (call.kind == CallKind.video) ...[
                  OutlinedButton.icon(
                    onPressed: _mediaController.busy
                        ? null
                        : _mediaController.toggleCamera,
                    icon: Icon(
                      _mediaController.cameraEnabled
                          ? Icons.videocam_rounded
                          : Icons.videocam_off_rounded,
                    ),
                    label: Text(
                      _mediaController.cameraEnabled ? '关摄像头' : '开摄像头',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        _mediaController.busy || !_mediaController.cameraEnabled
                        ? null
                        : _mediaController.switchCamera,
                    icon: const Icon(Icons.cameraswitch_rounded),
                    label: const Text('切换摄像头'),
                  ),
                ],
                FilledButton.icon(
                  onPressed: _controller.busy ? null : _controller.hangup,
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  icon: const Icon(Icons.call_end_rounded),
                  label: const Text('挂断'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEnded(CallSession call) {
    final outgoing = call.isOutgoingFor(_controller.identity);
    final rejected = call.status == CallSessionStatus.rejected;
    final timedOut = call.endReason == 'timeout';
    final cancelled = call.endReason == 'cancelled';
    final title = switch ((rejected, timedOut, cancelled, outgoing)) {
      (true, _, _, true) => '对方已拒绝',
      (true, _, _, false) => '已拒绝通话',
      (_, true, _, true) => '无人接听',
      (_, true, _, false) => '未接来电',
      (_, _, true, false) => '对方已取消',
      _ => '通话已结束',
    };
    return Card(
      child: _CenteredState(
        icon: rejected || timedOut
            ? Icons.phone_disabled_outlined
            : Icons.call_end_outlined,
        title: title,
        description: _endReasonLabel(call.endReason),
        action: FilledButton.icon(
          onPressed: _controller.clearEndedCall,
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('返回拨号'),
        ),
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      borderRadius: BorderRadius.circular(DdRadii.control),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _kindLabel(CallKind kind) =>
      kind == CallKind.video ? '视频通话' : '语音通话';

  static String _endReasonLabel(String reason) {
    return switch (reason) {
      'rejected' => '对方没有接听这通电话。',
      'cancelled' => '呼叫方在接听前取消了通话。',
      'hangup' => '其中一端已挂断，双方媒体连接均会释放。',
      'timeout' => '45 秒内无人接听，呼叫已自动结束并释放忙线状态。',
      _ => '通话状态已经同步结束。',
    };
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});

  final RealtimeConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      RealtimeConnectionState.connected => ('信令在线', Colors.green),
      RealtimeConnectionState.connecting => ('连接中', Colors.orange),
      RealtimeConnectionState.disconnected => ('未上线', Colors.grey),
    };
    return Chip(
      avatar: Icon(Icons.circle, color: color, size: 12),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CenteredState extends StatelessWidget {
  const _CenteredState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 54,
                height: 54,
                child: CircularProgressIndicator(),
              )
            else
              Icon(
                icon,
                size: 62,
                color: Theme.of(context).colorScheme.primary,
              ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(description, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );
  }
}
