import 'messaging_models.dart';

final class VoiceMessageSelector {
  const VoiceMessageSelector({
    required this.currentUserId,
    required this.isHeard,
  });

  final String currentUserId;
  final bool Function(String messageId) isHeard;

  bool isUnheardRemoteVoice(ChatMessage message) {
    final mediaId = message.content?.mediaId?.trim() ?? '';
    return message.type.toUpperCase() == 'VOICE' &&
        message.senderUserId != currentUserId &&
        !message.isRecalled &&
        mediaId.isNotEmpty &&
        !isHeard(message.id);
  }

  ChatMessage? nextUnheardRemoteVoice(
    ChatMessage current,
    Iterable<ChatMessage> messages,
  ) {
    final ordered = messages
        .where(
          (message) =>
              message.conversationId == current.conversationId &&
              message.sequence > current.sequence,
        )
        .toList(growable: false)
      ..sort((left, right) => left.sequence.compareTo(right.sequence));

    for (final message in ordered) {
      if (message.type.toUpperCase() != 'VOICE' ||
          message.senderUserId == currentUserId) {
        continue;
      }
      return isUnheardRemoteVoice(message) ? message : null;
    }
    return null;
  }
}
