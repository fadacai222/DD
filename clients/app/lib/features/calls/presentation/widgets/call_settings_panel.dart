import 'package:flutter/material.dart';

import '../../../../theme/app_theme.dart';
import '../call_debug_controller.dart';

class CallSettingsPanel extends StatefulWidget {
  const CallSettingsPanel({
    required this.controller,
    required this.apiUrlController,
    required this.roomController,
    required this.identityController,
    required this.nameController,
    super.key,
  });

  final CallDebugController controller;
  final TextEditingController apiUrlController;
  final TextEditingController roomController;
  final TextEditingController identityController;
  final TextEditingController nameController;

  @override
  State<CallSettingsPanel> createState() => _CallSettingsPanelState();
}

class _CallSettingsPanelState extends State<CallSettingsPanel> {
  bool _enableMicrophone = true;
  bool _enableCamera = true;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(DdRadii.control),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      Icons.video_call_outlined,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '音视频通话调试台',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '验证短期令牌、房间连接、麦克风、摄像头与远端订阅。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _InputField(
              keyValue: 'callApiUrlField',
              controller: widget.apiUrlController,
              label: 'Token API 地址',
              hint: 'http://127.0.0.1:18473',
              icon: Icons.dns_outlined,
              enabled: !controller.connected && !controller.busy,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            _InputField(
              keyValue: 'callRoomField',
              controller: widget.roomController,
              label: '房间号',
              hint: 'call-demo',
              icon: Icons.meeting_room_outlined,
              enabled: !controller.connected && !controller.busy,
            ),
            const SizedBox(height: 12),
            _InputField(
              keyValue: 'callIdentityField',
              controller: widget.identityController,
              label: '参与者身份',
              hint: 'windows-user-1',
              icon: Icons.badge_outlined,
              enabled: !controller.connected && !controller.busy,
            ),
            const SizedBox(height: 12),
            _InputField(
              keyValue: 'callDisplayNameField',
              controller: widget.nameController,
              label: '显示名称',
              hint: 'Windows 用户',
              icon: Icons.person_outline_rounded,
              enabled: !controller.connected && !controller.busy,
            ),
            const SizedBox(height: 8),
            Text(
              'Android 模拟器的 Token API 使用 http://10.0.2.2:18473。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('加入后开启麦克风'),
              value: _enableMicrophone,
              onChanged: controller.connected || controller.busy
                  ? null
                  : (value) => setState(() => _enableMicrophone = value),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('加入后开启摄像头'),
              value: _enableCamera,
              onChanged: controller.connected || controller.busy
                  ? null
                  : (value) => setState(() => _enableCamera = value),
            ),
            const SizedBox(height: 12),
            if (!controller.connected) ...[
              FilledButton.icon(
                key: const ValueKey('joinCallButton'),
                onPressed: controller.busy
                    ? null
                    : () => controller.join(
                        tokenApiBaseUrl: widget.apiUrlController.text,
                        roomName: widget.roomController.text,
                        participantIdentity: widget.identityController.text,
                        participantName: widget.nameController.text,
                        enableMicrophone: _enableMicrophone,
                        enableCamera: _enableCamera,
                      ),
                icon: const Icon(Icons.login_rounded),
                label: const Text('加入房间'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('callConnectivityCheckButton'),
                onPressed: controller.busy
                    ? null
                    : () => controller.runConnectivityDiagnostics(
                        tokenApiBaseUrl: widget.apiUrlController.text,
                        roomName: widget.roomController.text,
                        participantIdentity: widget.identityController.text,
                        participantName: widget.nameController.text,
                      ),
                icon: const Icon(Icons.network_check_rounded),
                label: const Text('检查 WebRTC / TURN'),
              ),
            ] else ...[
              FilledButton.tonalIcon(
                key: const ValueKey('toggleMicrophoneButton'),
                onPressed: controller.busy ? null : controller.toggleMicrophone,
                icon: Icon(
                  controller.microphoneEnabled
                      ? Icons.mic_rounded
                      : Icons.mic_off_rounded,
                ),
                label: Text(controller.microphoneEnabled ? '静音' : '开启麦克风'),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                key: const ValueKey('toggleCameraButton'),
                onPressed: controller.busy ? null : controller.toggleCamera,
                icon: Icon(
                  controller.cameraEnabled
                      ? Icons.videocam_rounded
                      : Icons.videocam_off_rounded,
                ),
                label: Text(controller.cameraEnabled ? '关闭摄像头' : '开启摄像头'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('switchCameraButton'),
                onPressed: controller.busy || !controller.cameraEnabled
                    ? null
                    : controller.switchCamera,
                icon: const Icon(Icons.cameraswitch_outlined),
                label: const Text('切换摄像头'),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const ValueKey('leaveCallButton'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: controller.busy ? null : controller.leave,
                icon: const Icon(Icons.call_end_rounded),
                label: const Text('挂断'),
              ),
            ],
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 12),
            _StatusRow(
              label: '连接状态',
              value: controller.connected ? '已连接' : '未连接',
            ),
            const SizedBox(height: 8),
            _StatusRow(label: '当前房间', value: controller.roomName ?? '—'),
            const SizedBox(height: 8),
            _StatusRow(
              label: '远端人数',
              value: '${controller.remoteParticipants.length}',
            ),
            if (controller.busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  const _InputField({
    required this.keyValue,
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.enabled,
    this.keyboardType,
  });

  final String keyValue;
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool enabled;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: ValueKey(keyValue),
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
