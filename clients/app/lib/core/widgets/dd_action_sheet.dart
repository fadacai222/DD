import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

final class DdActionSheetItem<T> {
  const DdActionSheetItem({
    required this.value,
    required this.icon,
    required this.label,
    this.subtitle,
    this.destructive = false,
    this.enabled = true,
  });

  final T value;
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool destructive;
  final bool enabled;
}

Future<T?> showDdActionSheet<T>(
  BuildContext context, {
  required List<DdActionSheetItem<T>> items,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    builder: (sheetContext) => Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(sheetContext).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < items.length; index++) ...[
                _ActionSheetRow<T>(item: items[index]),
                if (index != items.length - 1)
                  const Divider(height: 1, indent: 52),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _ActionSheetRow<T> extends StatelessWidget {
  const _ActionSheetRow({required this.item});

  final DdActionSheetItem<T> item;

  @override
  Widget build(BuildContext context) {
    final color = item.destructive
        ? DdColors.danger
        : Theme.of(context).colorScheme.onSurface;
    final effectiveColor = item.enabled ? color : DdColors.textTertiary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.enabled ? () => Navigator.pop(context, item.value) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(item.icon, size: 21, color: effectiveColor),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.2,
                          color: effectiveColor,
                        ),
                      ),
                      if (item.subtitle case final subtitle?) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontSize: 11,
                            color: DdColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
