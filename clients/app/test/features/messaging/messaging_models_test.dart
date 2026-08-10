import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';

void main() {
  test(
    'TEXT message decodes mention entities and tolerates malformed entries',
    () {
      final content = TextMessageContent.fromJson({
        'text': '😀 hi @Alice and @ghost',
        'entities': [
          {
            'type': 'MENTION',
            'offset': 6,
            'length': 6,
            'userId': 'user-alice',
            'handle': 'alice',
          },
          {'type': 'FUTURE_ENTITY', 'offset': 17, 'length': 6},
          {'type': 'MENTION', 'offset': 'bad', 'length': 2},
          'not-an-object',
        ],
      });

      expect(content.entities, hasLength(2));
      expect(content.entities.first.isMention, isTrue);
      expect(content.entities.first.userId, 'user-alice');
      expect(content.entities.last.type, 'FUTURE_ENTITY');
      expect(content.mentionedUserIds, {'user-alice'});
    },
  );

  test(
    'mention-all entity targets every recipient without a forged user id',
    () {
      final content = TextMessageContent.fromJson({
        'text': '@all maintenance',
        'entities': [
          {'type': 'MENTION_ALL', 'offset': 0, 'length': 4, 'handle': 'all'},
        ],
      });

      expect(content.entities.single.isMentionAll, isTrue);
      expect(content.entities.single.userId, isNull);
      expect(content.mentionsUser('user-a'), isTrue);
      expect(content.mentionsUser('user-b'), isTrue);
      expect(content.mentionedUserIds, isEmpty);
    },
  );

  test('legacy TEXT content without entities decodes to empty list', () {
    final content = TextMessageContent.fromJson({'text': 'legacy'});
    expect(content.entities, isEmpty);
    expect(content.mentionedUserIds, isEmpty);
  });

  test('VIDEO message preserves poster metadata and edit fields', () {
    final message = ChatMessage.fromJson({
      'id': 'message-video-1',
      'conversationId': 'conversation-1',
      'sequence': 9,
      'senderUserId': 'user-a',
      'senderDeviceId': 'device-a',
      'clientMessageId': 'client-video-0001',
      'type': 'VIDEO',
      'content': {
        'mediaId': 'media-video-1',
        'posterMediaId': 'media-poster-1',
        'width': 1920,
        'height': 1080,
        'durationMs': 3210,
        'fileName': 'clip.mp4',
        'mimeType': 'video/mp4',
        'sizeBytes': 1048576,
      },
      'createdAt': '2026-08-10T03:00:00Z',
      'editedAt': '2026-08-10T03:01:00Z',
      'editVersion': 2,
    });

    expect(message.type, 'VIDEO');
    expect(message.content?.mediaId, 'media-video-1');
    expect(message.content?.posterMediaId, 'media-poster-1');
    expect(message.content?.hasVideoPoster, isTrue);
    expect(message.content?.durationMs, 3210);
    expect(message.content?.mimeType, 'video/mp4');
    expect(message.isEdited, isTrue);
    expect(message.editVersion, 2);
  });

  test('GROUP conversation decodes stable group preview', () {
    final conversation = ConversationItem.fromJson({
      'id': 'group-1',
      'type': 'GROUP',
      'group': {
        'id': 'group-1',
        'name': '研发群',
        'memberCount': 12,
        'avatarMembers': [
          {'id': 'u1', 'handle': 'alice', 'displayName': 'Alice'},
          {'id': 'u2', 'handle': 'bob', 'displayName': 'Bob'},
          {'id': 'u3', 'handle': 'carol', 'displayName': 'Carol'},
          {'id': 'u4', 'handle': 'dave', 'displayName': 'Dave'},
          {'id': 'u5', 'handle': 'eve', 'displayName': 'Eve'},
        ],
      },
      'lastSequence': 9,
      'lastReadSequence': 7,
      'unreadCount': 2,
      'canWrite': true,
      'preferences': {'isPinned': false, 'mutedUntil': null, 'archivedAt': null},
      'createdAt': '2026-08-10T03:00:00Z',
      'updatedAt': '2026-08-10T03:01:00Z',
    });

    expect(conversation.type, 'GROUP');
    expect(conversation.peer, isNull);
    expect(conversation.group?.name, '研发群');
    expect(conversation.group?.memberCount, 12);
    expect(conversation.group?.avatarMembers.length, 4);
    expect(conversation.group?.avatarMembers.first.displayName, 'Alice');
    expect(conversation.group?.avatarMembers.last.displayName, 'Dave');
    expect(conversation.canWrite, isTrue);
  });

  test('pending VIDEO survives persistence and is classified as media', () {
    final pending = PendingTextMessage.fromJson({
      'clientMessageId': 'pending-video-0001',
      'conversationId': 'conversation-1',
      'type': 'VIDEO',
      'mediaId': 'media-video-1',
      'posterMediaId': 'media-poster-1',
      'width': 1080,
      'height': 1920,
      'durationMs': 8450,
      'fileName': 'portrait.mp4',
      'mimeType': 'video/mp4',
      'sizeBytes': 2048000,
      'createdAt': '2026-08-10T03:00:00Z',
    });

    expect(pending.isVideo, isTrue);
    expect(pending.isMedia, isTrue);
    expect(pending.posterMediaId, 'media-poster-1');
    expect(pending.durationMs, 8450);
  });
}
