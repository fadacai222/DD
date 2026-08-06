import 'package:flutter/material.dart';

import '../realtime_debug_controller.dart';
import 'connection_status_badge.dart';

class RealtimeSettingsPanel extends StatelessWidget {
  const RealtimeSettingsPanel({
    required this.controller,
    required this.serverUrlController,
    super.key,
  });

  final RealtimeDebugController controller;
  final TextEditingController serverUrlController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBusy = controller.isBusy;

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
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      Icons.hub_outlined,
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
                        '实时通信调试台',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '验证健康检查、WebSocket 握手、事件推送与断线重连。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            TextField(
              key: const ValueKey('serverUrlField'),
              controller: serverUrlController,
              enabled: !isBusy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://127.0.0.1:18473',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              onSubmitted: (_) {
                if (!isBusy) {
                  controller.connect(serverUrlController.text);
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Android 模拟器访问本机服务时通常使用 http://10.0.2.2:18473。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('healthButton'),
                  onPressed: isBusy
                      ? null
                      : () => controller.checkHealth(serverUrlController.text),
                  icon: const Icon(Icons.monitor_heart_outlined),
                  label: const Text('健康检查'),
                ),
                FilledButton.icon(
                  key: const ValueKey('connectButton'),
                  onPressed: isBusy
                      ? null
                      : () => controller.connect(serverUrlController.text),
                  icon: const Icon(Icons.power_rounded),
                  label: const Text('连接'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('disconnectButton'),
                  onPressed: isBusy || !controller.isConnected
                      ? null
                      : controller.disconnect,
                  icon: const Icon(Icons.power_off_rounded),
                  label: const Text('断开'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('pingButton'),
                  onPressed: isBusy || !controller.isConnected
                      ? null
                      : controller.sendPing,
                  icon: const Icon(Icons.network_ping_rounded),
                  label: const Text('发送 Ping'),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const Divider(),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '连接状态',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ConnectionStatusBadge(state: controller.connectionState),
              ],
            ),
            const SizedBox(height: 14),
            _InfoRow(label: '客户端 ID', value: controller.clientId),
            const SizedBox(height: 8),
            _InfoRow(
              label: '活动服务',
              value: controller.activeServer?.origin ?? '—',
            ),
            const SizedBox(height: 8),
            _InfoRow(label: '健康状态', value: controller.healthSummary ?? '尚未检查'),
            if (isBusy) ...[
              const SizedBox(height: 18),
              const LinearProgressIndicator(
                key: ValueKey('busyIndicator'),
                minHeight: 3,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
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
          child: SelectableText(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
