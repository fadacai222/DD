enum PushNavigationTarget { conversation, call, moments, generic, ignored }

final class PushNavigationIntent {
  const PushNavigationIntent({
    required this.target,
    this.conversationId = '',
    this.resourceId = '',
    this.eventType = '',
  });

  factory PushNavigationIntent.fromData(
    Map<String, dynamic> data, {
    required String currentUserId,
  }) {
    final recipientUserId = data['recipientUserId']?.toString().trim() ?? '';
    final normalizedCurrentUserId = currentUserId.trim();
    if (normalizedCurrentUserId.isEmpty) {
      return const PushNavigationIntent(target: PushNavigationTarget.ignored);
    }
    if (recipientUserId.isNotEmpty &&
        normalizedCurrentUserId.isNotEmpty &&
        recipientUserId != normalizedCurrentUserId) {
      return const PushNavigationIntent(target: PushNavigationTarget.ignored);
    }

    final eventType = data['eventType']?.toString().trim().toUpperCase() ?? '';
    final conversationId = data['conversationId']?.toString().trim() ?? '';
    final resourceId = data['resourceId']?.toString().trim() ?? '';

    if (eventType == 'CALL_RINGING') {
      return PushNavigationIntent(
        target: PushNavigationTarget.call,
        conversationId: conversationId,
        resourceId: resourceId,
        eventType: eventType,
      );
    }
    if (eventType.startsWith('MOMENT_')) {
      return PushNavigationIntent(
        target: PushNavigationTarget.moments,
        resourceId: resourceId,
        eventType: eventType,
      );
    }
    if (conversationId.isNotEmpty) {
      return PushNavigationIntent(
        target: PushNavigationTarget.conversation,
        conversationId: conversationId,
        resourceId: resourceId,
        eventType: eventType,
      );
    }
    return PushNavigationIntent(
      target: PushNavigationTarget.generic,
      resourceId: resourceId,
      eventType: eventType,
    );
  }

  final PushNavigationTarget target;
  final String conversationId;
  final String resourceId;
  final String eventType;
}
