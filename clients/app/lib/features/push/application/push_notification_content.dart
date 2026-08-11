import '../../../core/notifications/notification_avatar_url_policy.dart';

final class PushNotificationContent {
  const PushNotificationContent({
    required this.senderName,
    required this.preview,
    required this.conversationId,
    required this.senderUserId,
    required this.avatarUrl,
    required this.navigationData,
  });

  static PushNotificationContent? fromData(Map<String, dynamic> data) {
    final senderName = data['title']?.toString().trim() ?? '';
    final preview = data['body']?.toString().trim() ?? '';
    if (senderName.isEmpty && preview.isEmpty) return null;

    final navigationData = <String, dynamic>{};
    for (final entry in data.entries) {
      navigationData[entry.key] = entry.value;
    }
    Uri? avatarUrl;
    final rawAvatarUrl = data['avatarUrl']?.toString().trim() ?? '';
    if (rawAvatarUrl.isNotEmpty) {
      final parsed = Uri.tryParse(rawAvatarUrl);
      if (parsed != null && isAllowedNotificationAvatarUrl(parsed)) {
        avatarUrl = parsed;
      }
    }
    return PushNotificationContent(
      senderName: senderName,
      preview: preview,
      conversationId: data['conversationId']?.toString().trim() ?? '',
      senderUserId: data['senderUserId']?.toString().trim() ?? '',
      avatarUrl: avatarUrl,
      navigationData: navigationData,
    );
  }

  final String senderName;
  final String preview;
  final String conversationId;
  final String senderUserId;
  final Uri? avatarUrl;
  final Map<String, dynamic> navigationData;
}
