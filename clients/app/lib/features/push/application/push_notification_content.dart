import '../../../core/notifications/notification_avatar_url_policy.dart';

final class PushNotificationContent {
  const PushNotificationContent({
    required this.senderName,
    required this.preview,
    required this.conversationId,
    required this.senderUserId,
    required this.avatarUrl,
    required this.navigationData,
    required this.previewMode,
    required this.badgeCount,
    required this.conversationType,
  });

  static PushNotificationContent? fromData(Map<String, dynamic> data) {
    final previewMode =
        data['previewMode']?.toString().trim().toUpperCase() ?? '';
    final hidden = previewMode == 'HIDDEN';
    var senderName = data['title']?.toString().trim() ?? '';
    var preview = data['body']?.toString().trim() ?? '';
    var senderUserId = data['senderUserId']?.toString().trim() ?? '';

    final navigationData = <String, dynamic>{};
    for (final entry in data.entries) {
      navigationData[entry.key] = entry.value;
    }

    Uri? avatarUrl;
    if (hidden) {
      // Defense in depth: even a malformed provider payload must not make a
      // HIDDEN notification reveal sender/title/body/avatar in an app-rendered path.
      senderName = 'DD';
      preview = '你收到了一条新消息';
      senderUserId = '';
      navigationData.remove('avatarUrl');
      navigationData.remove('senderUserId');
      navigationData.remove('senderName');
      navigationData.remove('conversationTitle');
      navigationData['title'] = senderName;
      navigationData['body'] = preview;
    } else {
      final rawAvatarUrl = data['avatarUrl']?.toString().trim() ?? '';
      if (rawAvatarUrl.isNotEmpty) {
        final parsed = Uri.tryParse(rawAvatarUrl);
        if (parsed != null && isAllowedNotificationAvatarUrl(parsed)) {
          avatarUrl = parsed;
        }
      }
    }

    if (senderName.isEmpty && preview.isEmpty) return null;
    final rawBadge = data['badge'];
    final badgeCount = switch (rawBadge) {
      final num value => value.toInt(),
      final String value => int.tryParse(value.trim()),
      _ => null,
    };

    return PushNotificationContent(
      senderName: senderName,
      preview: preview,
      conversationId: data['conversationId']?.toString().trim() ?? '',
      senderUserId: senderUserId,
      avatarUrl: avatarUrl,
      navigationData: navigationData,
      previewMode: previewMode,
      badgeCount: badgeCount == null || badgeCount < 0 ? null : badgeCount,
      conversationType:
          data['conversationType']?.toString().trim().toUpperCase() ?? '',
    );
  }

  final String senderName;
  final String preview;
  final String conversationId;
  final String senderUserId;
  final Uri? avatarUrl;
  final Map<String, dynamic> navigationData;
  final String previewMode;
  final int? badgeCount;
  final String conversationType;

  bool get isCall {
    final eventType = navigationData['eventType']?.toString().trim().toUpperCase();
    return eventType == 'CALL_RINGING' || eventType == 'GROUP_CALL_STARTED';
  }
}
