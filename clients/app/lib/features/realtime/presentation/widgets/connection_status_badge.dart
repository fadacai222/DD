import 'package:flutter/material.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../../../../theme/app_theme.dart';

class ConnectionStatusBadge extends StatelessWidget {
  const ConnectionStatusBadge({required this.state, super.key});

  final RealtimeConnectionState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (label, icon, foreground, background) = switch (state) {
      RealtimeConnectionState.disconnected => (
        '未连接',
        Icons.link_off_rounded,
        colorScheme.onSurfaceVariant,
        colorScheme.surfaceContainerHighest,
      ),
      RealtimeConnectionState.connecting => (
        '连接中',
        Icons.sync_rounded,
        colorScheme.onTertiaryContainer,
        colorScheme.tertiaryContainer,
      ),
      RealtimeConnectionState.connected => (
        '已连接',
        Icons.check_circle_outline_rounded,
        colorScheme.onPrimaryContainer,
        colorScheme.primaryContainer,
      ),
    };

    return Semantics(
      label: '实时连接状态：$label',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(DdRadii.pill),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foreground, size: 17),
              const SizedBox(width: 7),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
