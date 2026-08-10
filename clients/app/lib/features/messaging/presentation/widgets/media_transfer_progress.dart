import 'package:flutter/material.dart';

import '../../../../theme/app_theme.dart';
import '../../domain/media_transfer_state.dart';

class MediaTransferProgress extends StatelessWidget {
  const MediaTransferProgress({
    super.key,
    required this.state,
    required this.onCancel,
    this.size = 34,
  });

  final MediaTransferState state;
  final VoidCallback? onCancel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final progress = state.progress;
    final cancellable = state.canCancel && onCancel != null;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.square(
            dimension: size,
            child: CircularProgressIndicator(
              key: const Key('media-transfer-progress-ring'),
              value: progress,
              strokeWidth: 2.8,
              backgroundColor: DdColors.divider,
              color: DdColors.greenPressed,
            ),
          ),
          if (cancellable)
            IconButton(
              key: const Key('media-transfer-cancel'),
              tooltip: '取消传输',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tightFor(width: size, height: size),
              onPressed: onCancel,
              icon: Icon(
                Icons.close_rounded,
                size: size * 0.52,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            )
          else if (state.phase == MediaTransferPhase.failed)
            const Icon(Icons.error_outline_rounded, color: DdColors.danger)
          else if (state.phase == MediaTransferPhase.done)
            const Icon(Icons.check_rounded, color: DdColors.greenPressed),
        ],
      ),
    );
  }
}
