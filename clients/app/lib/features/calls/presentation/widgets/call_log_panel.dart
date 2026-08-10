import 'package:flutter/material.dart';

import '../../../../theme/app_theme.dart';
import '../../domain/call_log_entry.dart';

class CallLogPanel extends StatelessWidget {
  const CallLogPanel({
    required this.logs,
    required this.onClear,
    this.compact = false,
    super.key,
  });

  final List<CallLogEntry> logs;
  final VoidCallback onClear;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = logs.isEmpty
        ? const _EmptyCallLog()
        : SelectionArea(
            child: ListView.separated(
              reverse: true,
              padding: const EdgeInsets.all(14),
              itemCount: logs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                return _CallLogTile(entry: logs[logs.length - index - 1]);
              },
            ),
          );

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
            child: Row(
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  color: theme.colorScheme.primary,
                  size: 21,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '通话日志',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${logs.length}/150',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  tooltip: '清空日志',
                  onPressed: logs.isEmpty ? null : onClear,
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (compact)
            SizedBox(height: 300, child: body)
          else
            Expanded(child: body),
        ],
      ),
    );
  }
}

class _EmptyCallLog extends StatelessWidget {
  const _EmptyCallLog();

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
              Icons.wifi_calling_3_outlined,
              size: 38,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 10),
            const Text('加入房间后将在这里显示连接与媒体事件。'),
          ],
        ),
      ),
    );
  }
}

class _CallLogTile extends StatelessWidget {
  const _CallLogTile({required this.entry});

  final CallLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (entry.level) {
      CallLogLevel.info => (
        Icons.info_outline_rounded,
        theme.colorScheme.primary,
      ),
      CallLogLevel.success => (
        Icons.check_circle_outline_rounded,
        const Color(0xFF16835F),
      ),
      CallLogLevel.warning => (
        Icons.warning_amber_rounded,
        const Color(0xFF9B6400),
      ),
      CallLogLevel.error => (
        Icons.error_outline_rounded,
        theme.colorScheme.error,
      ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(DdRadii.surface),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatTime(entry.timestamp),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.message,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
