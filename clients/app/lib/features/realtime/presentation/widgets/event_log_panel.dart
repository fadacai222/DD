import 'package:flutter/material.dart';

import '../../../../theme/app_theme.dart';
import '../../domain/debug_log_entry.dart';

class EventLogPanel extends StatelessWidget {
  const EventLogPanel({
    required this.logs,
    required this.onClear,
    this.compact = false,
    super.key,
  });

  final List<DebugLogEntry> logs;
  final VoidCallback onClear;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 10, 12),
            child: Row(
              children: [
                Icon(
                  Icons.terminal_rounded,
                  color: theme.colorScheme.primary,
                  size: 21,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '事件日志',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${logs.length}/200',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  key: const ValueKey('clearLogsButton'),
                  tooltip: '清空日志',
                  onPressed: logs.isEmpty ? null : onClear,
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (compact)
            SizedBox(height: 380, child: _buildLogBody())
          else
            Expanded(child: _buildLogBody()),
        ],
      ),
    );
  }

  Widget _buildLogBody() {
    if (logs.isEmpty) {
      return const _EmptyLogState();
    }

    return SelectionArea(
      child: ListView.separated(
        key: const ValueKey('eventLogList'),
        reverse: true,
        padding: const EdgeInsets.all(14),
        itemCount: logs.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = logs[logs.length - index - 1];
          return _LogEntryTile(entry: entry);
        },
      ),
    );
  }
}

class _EmptyLogState extends StatelessWidget {
  const _EmptyLogState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.data_object_rounded,
              size: 38,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有事件',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '先检查服务状态，再建立 WebSocket 连接。',
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

class _LogEntryTile extends StatelessWidget {
  const _LogEntryTile({required this.entry});

  final DebugLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (entry.level) {
      DebugLogLevel.info => (
        Icons.info_outline_rounded,
        theme.colorScheme.primary,
      ),
      DebugLogLevel.success => (
        Icons.check_circle_outline_rounded,
        const Color(0xFF16835F),
      ),
      DebugLogLevel.warning => (
        Icons.warning_amber_rounded,
        const Color(0xFF9B6400),
      ),
      DebugLogLevel.error => (
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
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    String threeDigits(int number) => number.toString().padLeft(3, '0');

    return '${twoDigits(local.hour)}:${twoDigits(local.minute)}:'
        '${twoDigits(local.second)}.${threeDigits(local.millisecond)}';
  }
}
