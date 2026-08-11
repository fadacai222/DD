enum MediaTransferPhase {
  queued,
  preparing,
  uploading,
  paused,
  committing,
  done,
  failed,
  canceled,
}

final class MediaTransferState {
  const MediaTransferState({
    required this.phase,
    this.transferredBytes = 0,
    this.totalBytes,
    this.errorMessage,
  });

  const MediaTransferState.queued()
    : phase = MediaTransferPhase.queued,
      transferredBytes = 0,
      totalBytes = null,
      errorMessage = null;

  final MediaTransferPhase phase;
  final int transferredBytes;
  final int? totalBytes;
  final String? errorMessage;

  bool get isTerminal =>
      phase == MediaTransferPhase.done ||
      phase == MediaTransferPhase.failed ||
      phase == MediaTransferPhase.canceled;

  bool get canCancel =>
      phase == MediaTransferPhase.queued ||
      phase == MediaTransferPhase.preparing ||
      phase == MediaTransferPhase.uploading;

  bool get canResume =>
      phase == MediaTransferPhase.paused || phase == MediaTransferPhase.failed;

  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (transferredBytes / total).clamp(0.0, 1.0);
  }

  MediaTransferState copyWith({
    MediaTransferPhase? phase,
    int? transferredBytes,
    int? totalBytes,
    bool clearTotalBytes = false,
    String? errorMessage,
    bool clearError = false,
  }) => MediaTransferState(
    phase: phase ?? this.phase,
    transferredBytes: transferredBytes ?? this.transferredBytes,
    totalBytes: clearTotalBytes ? null : totalBytes ?? this.totalBytes,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}
