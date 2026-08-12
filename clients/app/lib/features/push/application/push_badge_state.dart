final class PushBadgeState {
  const PushBadgeState(this.count);

  final int count;

  int get systemCount => count < 0 ? 0 : count;

  String? get displayLabel {
    final normalized = systemCount;
    if (normalized == 0) return null;
    if (normalized > 99) return '99+';
    return '$normalized';
  }
}
