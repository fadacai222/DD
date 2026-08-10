import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/camera_capture_service.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/groups/data/groups_api_client.dart';
import 'package:im_client/features/groups/domain/group_models.dart';
import 'package:im_client/features/messaging/application/messaging_coordinator.dart';
import 'package:im_client/features/messaging/data/media_auto_download_store.dart';
import 'package:im_client/features/messaging/data/messaging_api_client.dart';
import 'package:im_client/features/messaging/data/messaging_local_store.dart';
import 'package:im_client/features/messaging/data/sticker_api_client.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/domain/sticker_models.dart';
import 'package:im_client/features/messaging/presentation/text_chat_page.dart';
import 'package:im_client/theme/app_theme.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  testWidgets('attachment sheet exposes one album entry for visual media', (
    tester,
  ) async {
    final harness = _Harness(_ChatGateway());
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const Key('chat-more')));
    await tester.pumpAndSettle();

    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('相册')),
      findsOneWidget,
    );
    expect(find.descendant(of: sheet, matching: find.text('图片')), findsNothing);
    expect(
      find.descendant(of: sheet, matching: find.text('GIF')),
      findsNothing,
    );
    expect(find.descendant(of: sheet, matching: find.text('视频')), findsNothing);
    expect(
      find.descendant(of: sheet, matching: find.text('文件')),
      findsOneWidget,
    );
    expect(find.descendant(of: sheet, matching: find.text('表情')), findsNothing);
  });

  testWidgets('capture action uses platform camera adapter and cancel is silent', (
    tester,
  ) async {
    final camera = _FakeCameraCapture();
    final harness = _Harness(_ChatGateway());
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
          cameraCapture: camera,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const Key('chat-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拍摄'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(camera.captureCalls, 1);
    expect(find.textContaining('拍摄失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('friend acceptance system message is centered and readable', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-system-friend-accepted',
          conversationId: 'conversation-1',
          sequence: 8,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'friend-accept-request-1',
          type: 'SYSTEM',
          content: const TextMessageContent(text: '我刚刚同意了你的好友请求'),
          createdAt: DateTime.utc(2026, 8, 9, 6),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 140));

    expect(find.text('我刚刚同意了你的好友请求'), findsOneWidget);
    expect(
      find.byKey(const Key('message-message-system-friend-accepted')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('own visual media does not render a green outer bubble', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-image-visual',
          conversationId: 'conversation-1',
          sequence: 7,
          senderUserId: 'user-a',
          senderDeviceId: 'device-a',
          clientMessageId: 'client-image-visual',
          type: 'IMAGE',
          content: const TextMessageContent(
            mediaId: '00000000-0000-0000-0000-000000000111',
            width: 640,
            height: 480,
            mimeType: 'image/jpeg',
            fileName: 'photo.jpg',
          ),
          createdAt: DateTime.utc(2026, 8, 10, 0, 12),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));

    final bubble = tester.widget<Container>(
      find.byKey(const Key('message-bubble-surface-message-image-visual')),
    );
    expect(bubble.decoration, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'own text message can be edited in place and shows updated marker',
    (tester) async {
      final gateway = _ChatGateway(
        history: [
          ChatMessage(
            id: 'message-editable',
            conversationId: 'conversation-1',
            sequence: 7,
            senderUserId: 'user-a',
            senderDeviceId: 'device-a',
            clientMessageId: 'client-editable-0001',
            type: 'TEXT',
            content: const TextMessageContent(text: 'old body'),
            createdAt: DateTime.utc(2026, 8, 10, 0, 10),
          ),
        ],
      );
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 140));

      await tester.longPress(find.byKey(const Key('message-message-editable')));
      await tester.pumpAndSettle();
      expect(find.text('编辑'), findsOneWidget);
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();

      expect(find.text('正在编辑消息'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-composer')))
            .controller!
            .text,
        'old body',
      );
      await tester.enterText(
        find.byKey(const Key('chat-composer')),
        'new body',
      );
      expect(find.text('更新'), findsOneWidget);
      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();

      expect(
        gateway.editedMessages,
        contains(('message-editable', 'new body', 0)),
      );
      expect(find.text('old body'), findsNothing);
      expect(find.text('new body'), findsOneWidget);
      expect(find.text('已更新'), findsOneWidget);
      expect(find.text('正在编辑消息'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('recalled messages disappear without any recall placeholder', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-recalled-hidden',
          conversationId: 'conversation-1',
          sequence: 6,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-recall-hidden',
          type: 'TEXT',
          content: const TextMessageContent(text: 'secret removed body'),
          createdAt: DateTime.utc(2026, 8, 9, 23, 50),
          recalledAt: DateTime.utc(2026, 8, 10),
        ),
        ChatMessage(
          id: 'message-visible-after-recall',
          conversationId: 'conversation-1',
          sequence: 7,
          senderUserId: 'user-a',
          senderDeviceId: 'device-a',
          clientMessageId: 'client-visible-after-recall',
          type: 'TEXT',
          content: const TextMessageContent(text: 'visible message'),
          createdAt: DateTime.utc(2026, 8, 10, 0, 5),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 140));

    expect(find.text('visible message'), findsOneWidget);
    expect(find.text('secret removed body'), findsNothing);
    expect(find.textContaining('已撤回'), findsNothing);
    expect(find.textContaining('撤回了一条'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('message list inserts one local-date separator per day', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 10).toUtc();
    final yesterday = DateTime(
      now.year,
      now.month,
      now.day - 1,
      23,
      59,
    ).toUtc();
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-yesterday',
          conversationId: 'conversation-1',
          sequence: 1,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-date-0001',
          type: 'SYSTEM',
          content: const TextMessageContent(text: 'old system'),
          createdAt: yesterday,
        ),
        ChatMessage(
          id: 'message-today-1',
          conversationId: 'conversation-1',
          sequence: 2,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-date-0002',
          type: 'TEXT',
          content: const TextMessageContent(text: 'today one'),
          createdAt: today,
        ),
        ChatMessage(
          id: 'message-today-2',
          conversationId: 'conversation-1',
          sequence: 3,
          senderUserId: 'user-a',
          senderDeviceId: 'device-a',
          clientMessageId: 'client-date-0003',
          type: 'TEXT',
          content: const TextMessageContent(text: 'today two'),
          createdAt: today.add(const Duration(minutes: 10)),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 140));

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('old system'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('own message shows peer read receipt when allowed', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      peerLastReadSequence: 7,
      history: [
        ChatMessage(
          id: 'message-read-1',
          conversationId: 'conversation-1',
          sequence: 7,
          senderUserId: 'user-a',
          senderDeviceId: 'device-a',
          clientMessageId: 'client-read-0001',
          type: 'TEXT',
          content: const TextMessageContent(text: 'read me'),
          createdAt: DateTime.utc(2026, 8, 8, 8),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(peerLastReadSequence: 7),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.byKey(const Key('message-status-message-read-1')),
      findsOneWidget,
    );
    expect(find.text('已读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden desktop chat does not mark incoming messages as read', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-unread-1',
          conversationId: 'conversation-1',
          sequence: 7,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-unread-0001',
          type: 'TEXT',
          content: const TextMessageContent(text: 'do not auto read'),
          createdAt: DateTime.utc(2026, 8, 8, 8),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);
    final conversation = _conversation(lastReadSequence: 0, unreadCount: 1);

    Widget page({required bool visible}) => MaterialApp(
      theme: AppTheme.light(),
      home: TextChatPage(
        coordinator: harness.coordinator,
        conversation: conversation,
        currentUserId: 'user-a',
        hostVisible: visible,
        embedded: true,
      ),
    );

    await tester.pumpWidget(page(visible: false));
    await tester.pump(const Duration(milliseconds: 150));
    expect(gateway.markedReads, isEmpty);

    await tester.pumpWidget(page(visible: true));
    await tester.pump(const Duration(milliseconds: 150));
    expect(gateway.markedReads, [('conversation-1', 7)]);
  });

  testWidgets('Android blank tap dismisses composer keyboard', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      final composer = find.byKey(const Key('chat-composer'));
      await tester.tap(composer);
      await tester.pump();
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);

      await tester.tap(find.byKey(const Key('chat-message-surface')));
      await tester.pump();
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android destructive local delete action is red', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway(
        history: [
          ChatMessage(
            id: 'message-menu-1',
            conversationId: 'conversation-1',
            sequence: 7,
            senderUserId: 'user-b',
            senderDeviceId: 'device-b',
            clientMessageId: 'client-menu-0001',
            type: 'TEXT',
            content: const TextMessageContent(text: 'menu me'),
            createdAt: DateTime.utc(2026, 8, 8, 8),
          ),
        ],
      );
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));

      await tester.longPress(find.text('menu me'));
      await tester.pumpAndSettle();

      final deleteText = tester.widget<Text>(find.text('仅本地删除'));
      expect(deleteText.style?.color, DdColors.danger);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android keeps Enter-to-send but hides desktop shortcut hint', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.text('Enter 发送 · Shift+Enter 换行'), findsNothing);
      final composer = find.byKey(const Key('chat-composer'));
      await tester.enterText(composer, 'android send');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump(const Duration(milliseconds: 120));
      expect(gateway.sentTexts, ['android send']);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('more button opens real chat details and scopes message search', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-search-detail',
          conversationId: 'conversation-1',
          sequence: 7,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-search-detail',
          type: 'TEXT',
          content: const TextMessageContent(text: 'detail needle'),
          createdAt: DateTime.utc(2026, 8, 10),
        ),
        ChatMessage(
          id: 'message-file-detail',
          conversationId: 'conversation-1',
          sequence: 8,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-file-detail',
          type: 'FILE',
          content: const TextMessageContent(
            mediaId: 'media-file-detail',
            fileName: 'design.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1024,
          ),
          createdAt: DateTime.utc(2026, 8, 10, 0, 1),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const Key('chat-details')));
    await tester.pumpAndSettle();
    expect(find.text('聊天详情'), findsOneWidget);
    expect(find.text('Bob'), findsWidgets);
    expect(find.text('查找聊天记录'), findsOneWidget);
    expect(find.text('聊天图片、视频与文件'), findsOneWidget);
    expect(
      find.byKey(const Key('chat-details-moment-privacy')),
      findsOneWidget,
    );
    expect(find.text('不看他的朋友圈 / 不让他看我的朋友圈'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-details-media')));
    await tester.pumpAndSettle();
    expect(find.text('聊天文件'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('design.pdf'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('conversation-media-file-message-file-detail')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('message-message-file-detail')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('chat-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-details-pin')));
    await tester.pumpAndSettle();
    expect(gateway.preferenceUpdates, isNotEmpty);
    expect(gateway.preferenceUpdates.last.$1, isTrue);

    await tester.tap(find.byKey(const Key('chat-details-mute')));
    await tester.pumpAndSettle();
    expect(gateway.preferenceUpdates.last.$2, isNotNull);
    expect(gateway.preferenceUpdates.last.$2!.year, 9998);

    await tester.tap(find.byKey(const Key('chat-details-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('chat-details-search-field')),
      'needle',
    );
    await tester.tap(find.byKey(const Key('chat-details-search-submit')));
    await tester.pumpAndSettle();

    expect(gateway.searchQueries, contains('needle'));
    expect(gateway.searchConversationIds, contains('conversation-1'));
    expect(find.text('detail needle'), findsOneWidget);
  });

  testWidgets(
    'blocked conversation locks composer and points to relationship profile',
    (tester) async {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(canWrite: false),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.textContaining('当前关系已被拉黑'), findsOneWidget);
      expect(
        find.byKey(const Key('restricted-blocked-conversation')),
        findsOneWidget,
      );
      expect(find.text('添加好友'), findsNothing);
      expect(find.byKey(const Key('chat-composer')), findsNothing);
      expect(find.byKey(const Key('chat-voice')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('message action sheet exposes forward save and pin actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway(
        history: [
          ChatMessage(
            id: 'message-actions-1',
            conversationId: 'conversation-1',
            sequence: 7,
            senderUserId: 'user-b',
            senderDeviceId: 'device-b',
            clientMessageId: 'client-actions-0001',
            type: 'TEXT',
            content: const TextMessageContent(text: 'telegram actions'),
            createdAt: DateTime.utc(2026, 8, 8, 8),
          ),
        ],
      );
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 120));

      await tester.longPress(find.text('telegram actions'));
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      expect(find.text('转发'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('置顶消息'), findsOneWidget);
      expect(find.text('仅本地删除'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('media payload text never exposes a meaningless copy action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway(
        history: [
          ChatMessage(
            id: 'media-copy-guard',
            conversationId: 'conversation-1',
            sequence: 8,
            senderUserId: 'user-b',
            senderDeviceId: 'device-b',
            clientMessageId: 'client-media-copy-guard',
            type: 'STICKER',
            content: const TextMessageContent(
              text: 'internal sticker payload must not be copied',
              mediaId: '00000000-0000-0000-0000-000000000203',
              width: 512,
              height: 512,
              mimeType: 'image/webp',
            ),
            createdAt: DateTime.utc(2026, 8, 8, 8),
          ),
        ],
      );
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(lastReadSequence: 8),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      await tester.longPress(find.byKey(const Key('message-media-copy-guard')));
      await tester.pump(const Duration(milliseconds: 420));

      expect(find.text('复制'), findsNothing);
      expect(find.text('回复'), findsOneWidget);
      expect(find.text('转发'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('reply reference jumps to loaded source and highlights it', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'message-source-1',
          conversationId: 'conversation-1',
          sequence: 1,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-source-0001',
          type: 'TEXT',
          content: const TextMessageContent(text: 'original message'),
          createdAt: DateTime.utc(2026, 8, 8, 8),
        ),
        ChatMessage(
          id: 'message-reply-1',
          conversationId: 'conversation-1',
          sequence: 2,
          senderUserId: 'user-a',
          senderDeviceId: 'device-a',
          clientMessageId: 'client-reply-0001',
          type: 'TEXT',
          content: const TextMessageContent(text: 'reply message'),
          replyToMessageId: 'message-source-1',
          createdAt: DateTime.utc(2026, 8, 8, 8, 1),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(lastReadSequence: 2),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const Key('reply-reference-message-source-1')));
    // ensureVisible animates for 240ms before the highlight state is applied.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));

    final highlighted = tester.widget<AnimatedContainer>(
      find.byKey(const Key('message-message-source-1')),
    );
    final decoration = highlighted.decoration as BoxDecoration?;
    expect(decoration?.color, DdColors.green.withValues(alpha: 0.12));
  });

  testWidgets('reply reference loads older pages before jumping to source', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      forcedPageSize: 2,
      history: [
        ChatMessage(
          id: 'deep-source',
          conversationId: 'conversation-1',
          sequence: 1,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'deep-source-client',
          type: 'TEXT',
          content: const TextMessageContent(text: 'deep original'),
          createdAt: DateTime.utc(2026, 8, 8, 8),
        ),
        ChatMessage(
          id: 'deep-filler-2',
          conversationId: 'conversation-1',
          sequence: 2,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'deep-filler-client2',
          type: 'TEXT',
          content: const TextMessageContent(text: 'older filler'),
          createdAt: DateTime.utc(2026, 8, 8, 8, 1),
        ),
        ChatMessage(
          id: 'deep-filler-3',
          conversationId: 'conversation-1',
          sequence: 3,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'deep-filler-client3',
          type: 'TEXT',
          content: const TextMessageContent(text: 'recent filler'),
          createdAt: DateTime.utc(2026, 8, 8, 8, 2),
        ),
        ChatMessage(
          id: 'deep-reply',
          conversationId: 'conversation-1',
          sequence: 4,
          senderUserId: 'user-a',
          senderDeviceId: 'device-a',
          clientMessageId: 'deep-reply-client1',
          type: 'TEXT',
          content: const TextMessageContent(text: 'reply to old message'),
          replyToMessageId: 'deep-source',
          createdAt: DateTime.utc(2026, 8, 8, 8, 3),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(lastReadSequence: 4),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 140));

    expect(find.byKey(const Key('message-deep-source')), findsNothing);
    expect(
      find.byKey(const Key('reply-reference-deep-source')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('reply-reference-deep-source')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));

    expect(gateway.listMessageCalls, greaterThanOrEqualTo(2));
    expect(find.byKey(const Key('message-deep-source')), findsOneWidget);
    final highlighted = tester.widget<AnimatedContainer>(
      find.byKey(const Key('message-deep-source')),
    );
    final decoration = highlighted.decoration as BoxDecoration?;
    expect(decoration?.color, DdColors.green.withValues(alpha: 0.12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('valid media messages never fall back to bracket type text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'media-image',
          conversationId: 'conversation-1',
          sequence: 1,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-media-image',
          type: 'IMAGE',
          content: const TextMessageContent(
            mediaId: '00000000-0000-0000-0000-000000000101',
            width: 800,
            height: 600,
          ),
          createdAt: DateTime.utc(2026, 8, 8, 8),
        ),
        ChatMessage(
          id: 'media-gif',
          conversationId: 'conversation-1',
          sequence: 2,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-media-gif1',
          type: 'GIF',
          content: const TextMessageContent(
            mediaId: '00000000-0000-0000-0000-000000000102',
            width: 480,
            height: 320,
          ),
          createdAt: DateTime.utc(2026, 8, 8, 8, 1),
        ),
        ChatMessage(
          id: 'media-sticker',
          conversationId: 'conversation-1',
          sequence: 3,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-media-sticker1',
          type: 'STICKER',
          content: const TextMessageContent(
            mediaId: '00000000-0000-0000-0000-000000000103',
            width: 512,
            height: 512,
          ),
          createdAt: DateTime.utc(2026, 8, 8, 8, 2),
        ),
        ChatMessage(
          id: 'media-file',
          conversationId: 'conversation-1',
          sequence: 4,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-media-file01',
          type: 'FILE',
          content: const TextMessageContent(
            mediaId: '00000000-0000-0000-0000-000000000104',
            fileName: 'guide.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1048576,
          ),
          createdAt: DateTime.utc(2026, 8, 8, 8, 3),
        ),
        ChatMessage(
          id: 'media-voice',
          conversationId: 'conversation-1',
          sequence: 5,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-media-voice1',
          type: 'VOICE',
          content: const TextMessageContent(
            mediaId: '00000000-0000-0000-0000-000000000105',
            durationMs: 4200,
          ),
          createdAt: DateTime.utc(2026, 8, 8, 8, 4),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(lastReadSequence: 5),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 180));

    for (final fallback in const [
      '[IMAGE]',
      '[GIF]',
      '[STICKER]',
      '[FILE]',
      '[VOICE]',
    ]) {
      expect(find.text(fallback), findsNothing);
    }
    expect(find.text('guide.pdf'), findsOneWidget);
    expect(find.text('1.0 MiB'), findsOneWidget);
    expect(find.text('5″'), findsOneWidget);

    await tester.tap(find.text('guide.pdf'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('打开文件'), findsOneWidget);
    expect(find.text('保存文件'), findsOneWidget);
    expect(find.text('系统分享'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned message bar is visible and jumps to pinned message', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'message-pinned-1',
      conversationId: 'conversation-1',
      sequence: 7,
      senderUserId: 'user-b',
      senderDeviceId: 'device-b',
      clientMessageId: 'client-pinned-0001',
      type: 'TEXT',
      content: const TextMessageContent(text: 'important pinned message'),
      createdAt: DateTime.utc(2026, 8, 8, 8),
    );
    final gateway = _ChatGateway(
      history: [message],
      pinnedMessages: [
        PinnedMessageItem(
          message: message,
          pinnedByUserId: 'user-b',
          pinnedAt: DateTime.utc(2026, 8, 8, 8, 1),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 160));

    expect(find.byKey(const Key('pinned-message-bar')), findsOneWidget);
    expect(find.text('important pinned message'), findsWidgets);

    await tester.tap(find.byKey(const Key('pinned-message-bar')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
    final highlighted = tester.widget<AnimatedContainer>(
      find.byKey(const Key('message-message-pinned-1')),
    );
    final decoration = highlighted.decoration as BoxDecoration?;
    expect(decoration?.color, DdColors.green.withValues(alpha: 0.12));
  });

  testWidgets('multiple pinned messages open manager and can unpin one', (
    tester,
  ) async {
    final first = ChatMessage(
      id: 'message-pinned-manager-1',
      conversationId: 'conversation-1',
      sequence: 7,
      senderUserId: 'user-b',
      senderDeviceId: 'device-b',
      clientMessageId: 'client-pinned-manager-0001',
      type: 'TEXT',
      content: const TextMessageContent(text: 'first pinned'),
      createdAt: DateTime.utc(2026, 8, 8, 8),
    );
    final second = ChatMessage(
      id: 'message-pinned-manager-2',
      conversationId: 'conversation-1',
      sequence: 8,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: 'client-pinned-manager-0002',
      type: 'TEXT',
      content: const TextMessageContent(text: 'second pinned'),
      createdAt: DateTime.utc(2026, 8, 8, 8, 2),
    );
    final gateway = _ChatGateway(
      history: [first, second],
      pinnedMessages: [
        PinnedMessageItem(
          message: second,
          pinnedByUserId: 'user-a',
          pinnedAt: DateTime.utc(2026, 8, 8, 8, 3),
        ),
        PinnedMessageItem(
          message: first,
          pinnedByUserId: 'user-b',
          pinnedAt: DateTime.utc(2026, 8, 8, 8, 1),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 180));

    expect(find.text('置顶消息 · 1/2'), findsOneWidget);
    expect(
      find.byKey(const Key('pinned-message-manager-icon')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('pinned-message-bar')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pinned-message-manager')), findsOneWidget);
    expect(find.text('first pinned'), findsWidgets);
    expect(find.text('second pinned'), findsWidgets);
    await tester.tap(
      find.byKey(const Key('pinned-manager-unpin-message-pinned-manager-1')),
    );
    await tester.pumpAndSettle();

    expect(gateway.unpinnedMessageIds, ['message-pinned-manager-1']);
    expect(find.text('置顶消息 · 1/2'), findsNothing);
    expect(find.byKey(const Key('pinned-message-manager')), findsNothing);
  });

  testWidgets(
    'saved messages mode is a writable self chat without call or save actions',
    (tester) async {
      final savedMessage = ChatMessage(
        id: 'saved-forward-1',
        conversationId: 'saved-conversation',
        sequence: 1,
        senderUserId: 'user-a',
        senderDeviceId: 'device-a',
        clientMessageId: 'saved-forward-client-1',
        type: 'TEXT',
        content: const TextMessageContent(text: '收藏进来的内容'),
        forwardedFromMessageId: 'source-message-1',
        createdAt: DateTime.utc(2026, 8, 9, 3),
      );
      final gateway = _ChatGateway(history: [savedMessage]);
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);
      final savedConversation = ConversationItem(
        id: 'saved-conversation',
        type: 'SELF',
        peer: const MessagingUserPreview(
          id: 'user-a',
          handle: 'alice',
          displayName: 'Alice',
        ),
        lastSequence: 1,
        lastReadSequence: 1,
        unreadCount: 0,
        preferences: const ConversationPreferences(isPinned: true),
        createdAt: DateTime.utc(2026, 8, 9),
        updatedAt: DateTime.utc(2026, 8, 9, 3),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: savedConversation,
            currentUserId: 'user-a',
            currentUserDisplayName: 'Alice',
            savedMessagesMode: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 180));

      expect(find.text('我的收藏'), findsOneWidget);
      expect(find.text('仅自己可见 · 跨设备同步'), findsOneWidget);
      expect(find.byKey(const Key('chat-composer')), findsOneWidget);
      expect(find.byKey(const Key('chat-audio-call-mobile')), findsNothing);
      expect(find.byKey(const Key('chat-video-call-mobile')), findsNothing);
      expect(find.text('收藏自原消息'), findsNothing);

      await tester.longPress(find.byKey(const Key('message-saved-forward-1')));
      await tester.pumpAndSettle();
      expect(find.text('收藏'), findsNothing);
      expect(find.text('转发'), findsOneWidget);
      expect(find.text('仅本地删除'), findsOneWidget);
    },
  );

  testWidgets('desktop composer footer stays anchored to bottom at 881x657', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _ChatGateway(history: const []);
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 140));

    final header = tester.getRect(find.byKey(const Key('chat-desktop-header')));
    final footer = tester.getRect(
      find.byKey(const Key('chat-composer-footer')),
    );
    expect(header.height, DdDesktopTokens.chatHeaderHeight);
    expect(header.top, closeTo(0, 0.1));
    expect(footer.bottom, closeTo(657, 0.1));
    expect(find.text('Enter 发送 · Shift+Enter 换行'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mention overlay supports keyboard selection without sending', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);
      final queries = <String>[];
      const suggestions = <ContactMentionSuggestion>[
        ContactMentionSuggestion(
          user: ContactUser(
            id: 'user-alice',
            handle: 'alice',
            displayName: 'Alice',
            bio: '',
          ),
          relationship: 'CONTACT',
        ),
        ContactMentionSuggestion(
          user: ContactUser(
            id: 'user-bob',
            handle: 'bob',
            displayName: 'Bob',
            bio: '',
          ),
          relationship: 'CONVERSATION_PEER',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
            mentionSuggestionLoader: (query) async {
              queries.add(query);
              return suggestions;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      final composer = find.byKey(const Key('chat-composer'));
      await tester.tap(composer);
      await tester.enterText(composer, '@al');
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pump();

      expect(queries, ['al']);
      final overlay = find.byKey(const Key('mention-suggestion-overlay'));
      expect(overlay, findsOneWidget);
      expect(
        find.descendant(of: overlay, matching: find.text('Alice')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: overlay, matching: find.text('Bob')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final field = tester.widget<TextField>(composer);
      expect(field.controller!.text, '@bob ');
      expect(field.focusNode?.hasFocus, isTrue);
      expect(gateway.sentTexts, isEmpty);
      expect(find.byKey(const Key('mention-suggestion-overlay')), findsNothing);

      await tester.enterText(composer, 'normal send');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 120));
      expect(gateway.sentTexts, ['normal send']);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android mention tap keeps composer focus and keyboard visible', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);
      const alice = ContactMentionSuggestion(
        user: ContactUser(
          id: 'user-alice',
          handle: 'alice',
          displayName: 'Alice',
          bio: '',
        ),
        relationship: 'CONTACT',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
            mentionSuggestionLoader: (_) async => const [alice],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));
      final composer = find.byKey(const Key('chat-composer'));
      await tester.tap(composer);
      await tester.enterText(composer, '@al');
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pump();

      await tester.tap(find.byKey(const Key('mention-suggestion-0')));
      await tester.pump();

      final field = tester.widget<TextField>(composer);
      expect(field.controller!.text, '@alice ');
      expect(field.focusNode?.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(find.byKey(const Key('mention-suggestion-overlay')), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('chat emoji button opens unified emoji custom and pack panel', (
    tester,
  ) async {
    final gateway = _ChatGateway();
    final harness = _Harness(gateway);
    final stickerGateway = _ChatStickerGateway(
      custom: [_chatCustomSticker('custom-chat')],
      packs: [_chatStickerPack('pack-chat')],
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
          stickerGateway: stickerGateway,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('chat-emoji')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sticker-tab-emoji')), findsOneWidget);
    expect(find.byKey(const Key('sticker-tab-custom')), findsOneWidget);
    expect(find.byKey(const Key('sticker-tab-pack-pack-chat')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom sticker selection sends stable DD media id as STICKER', (
    tester,
  ) async {
    final gateway = _ChatGateway();
    final harness = _Harness(gateway);
    final stickerGateway = _ChatStickerGateway(
      custom: [_chatCustomSticker('custom-send')],
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(),
          currentUserId: 'user-a',
          stickerGateway: stickerGateway,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('chat-emoji')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sticker-tab-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('custom-sticker-custom-send')));
    await tester.pump(const Duration(milliseconds: 180));

    expect(gateway.sentMedia, [('STICKER', 'media-custom-send', 512, 512)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows Enter sends while Shift+Enter keeps editing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final gateway = _ChatGateway();
      final harness = _Harness(gateway);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: TextChatPage(
            coordinator: harness.coordinator,
            conversation: _conversation(),
            currentUserId: 'user-a',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      final composer = find.byKey(const Key('chat-composer'));
      await tester.tap(composer);
      await tester.enterText(composer, 'first line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(gateway.sentTexts, isEmpty);
      final field = tester.widget<TextField>(composer);
      expect(field.controller!.text, contains('first line'));

      await tester.enterText(composer, 'send with enter');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 120));

      expect(gateway.sentTexts, ['send with enter']);
      final fieldAfterSend = tester.widget<TextField>(composer);
      expect(fieldAfterSend.focusNode?.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('disabled image auto-download waits for explicit user tap', (
    tester,
  ) async {
    final mediaStore = MediaAutoDownloadStore(
      userId: 'user-a',
      storage: _SecureMemoryStore(),
    );
    await mediaStore.save(
      const MediaAutoDownloadPreferences(images: false),
    );
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'manual-image-1',
          conversationId: 'conversation-1',
          sequence: 1,
          senderUserId: 'user-b',
          senderDeviceId: 'device-b',
          clientMessageId: 'client-manual-image-1',
          type: 'IMAGE',
          content: const TextMessageContent(
            mediaId: '00000000-0000-0000-0000-000000000301',
            width: 800,
            height: 600,
          ),
          createdAt: DateTime.utc(2026, 8, 11),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _conversation(lastReadSequence: 1),
          currentUserId: 'user-a',
          mediaPreferencesStore: mediaStore,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 180));

    expect(find.text('点击下载图片'), findsOneWidget);
    expect(
      find.byKey(
        const Key('manual-media-00000000-0000-0000-0000-000000000301'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('group chat shows group title, sender nickname and hides 1v1 call actions', (
    tester,
  ) async {
    final gateway = _ChatGateway(
      history: [
        ChatMessage(
          id: 'group-message-1',
          conversationId: 'group-1',
          sequence: 1,
          senderUserId: 'user-c',
          senderDeviceId: 'device-c',
          clientMessageId: 'group-client-0001',
          type: 'TEXT',
          content: const TextMessageContent(text: '大家好'),
          createdAt: DateTime.utc(2026, 8, 10, 12),
        ),
      ],
    );
    final harness = _Harness(gateway);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TextChatPage(
          coordinator: harness.coordinator,
          conversation: _groupConversation(),
          currentUserId: 'user-a',
          groupsGateway: _ChatGroupsGateway(),
          onStartCall: (_, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('研发群'), findsOneWidget);
    expect(find.text('3 位成员'), findsOneWidget);
    expect(find.text('小陈'), findsOneWidget);
    expect(find.text('大家好'), findsOneWidget);
    expect(find.byIcon(Icons.call_outlined), findsNothing);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

ConversationItem _groupConversation() => ConversationItem(
  id: 'group-1',
  type: 'GROUP',
  group: const MessagingGroupPreview(id: 'group-1', name: '研发群', memberCount: 3),
  lastSequence: 1,
  lastReadSequence: 0,
  unreadCount: 1,
  canWrite: true,
  preferences: const ConversationPreferences(isPinned: false),
  createdAt: DateTime.utc(2026, 8, 10),
  updatedAt: DateTime.utc(2026, 8, 10),
);

ConversationItem _conversation({
  int? peerLastReadSequence,
  int lastReadSequence = 7,
  int unreadCount = 0,
  bool canWrite = true,
  bool isPinned = false,
  DateTime? mutedUntil,
}) => ConversationItem(
  id: 'conversation-1',
  type: 'DIRECT',
  peer: const MessagingUserPreview(
    id: 'user-b',
    handle: 'bob',
    displayName: 'Bob',
  ),
  lastSequence: 7,
  lastReadSequence: lastReadSequence,
  peerLastReadSequence: peerLastReadSequence,
  unreadCount: unreadCount,
  canWrite: canWrite,
  preferences: ConversationPreferences(
    isPinned: isPinned,
    mutedUntil: mutedUntil,
  ),
  createdAt: DateTime.utc(2026, 8, 8),
  updatedAt: DateTime.utc(2026, 8, 8),
);

final class _FakeCameraCapture implements CameraCaptureGateway {
  int captureCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<XFile?> capturePhoto() async {
    captureCalls++;
    return null;
  }

  @override
  Future<void> openAppSettings() async {}
}

final class _SecureMemoryStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class _ChatGroupsGateway implements GroupsGateway {
  @override
  Future<List<GroupMemberItem>> listMembers({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async => [
    GroupMemberItem(
      user: const GroupUserPreview(id: 'user-a', handle: 'alice', displayName: 'Alice'),
      role: 'OWNER',
      nickname: '',
      joinedAt: DateTime.utc(2026, 8, 10),
    ),
    GroupMemberItem(
      user: const GroupUserPreview(id: 'user-b', handle: 'bob', displayName: 'Bob'),
      role: 'MEMBER',
      nickname: '',
      joinedAt: DateTime.utc(2026, 8, 10),
    ),
    GroupMemberItem(
      user: const GroupUserPreview(id: 'user-c', handle: 'chen', displayName: 'Chen'),
      role: 'MEMBER',
      nickname: '小陈',
      joinedAt: DateTime.utc(2026, 8, 10),
    ),
  ];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Harness {
  _Harness(_ChatGateway gateway)
    : realtime = RealtimeClient(
        baseUri: Uri.parse('http://127.0.0.1:19999'),
        clientId: 'device-a',
        channelFactory: (_) => throw StateError('not used'),
      ),
      store = _ChatStore() {
    coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-a',
      gateway: gateway,
      localStore: store,
      realtimeClient: realtime,
    );
  }

  final RealtimeClient realtime;
  final _ChatStore store;
  late final MessagingCoordinator coordinator;

  Future<void> dispose() async {
    coordinator.dispose();
    await realtime.dispose();
  }
}

final class _ChatStore implements MessagingLocalStore {
  MessagingLocalState state = const MessagingLocalState(
    syncCursor: 0,
    pending: [],
  );

  @override
  Future<void> clear() async {
    state = const MessagingLocalState(syncCursor: 0, pending: []);
  }

  @override
  Future<MessagingLocalState> load() async => state;

  @override
  Future<void> save({
    required int syncCursor,
    required List<PendingTextMessage> pending,
    required Map<String, String> drafts,
    required List<String> recentEmoji,
    required String stickerPanelTabKey,
    required List<String> heardVoiceMessageIds,
  }) async {
    state = MessagingLocalState(
      syncCursor: syncCursor,
      pending: List<PendingTextMessage>.from(pending),
      drafts: Map<String, String>.from(drafts),
      recentEmoji: List<String>.from(recentEmoji),
      stickerPanelTabKey: stickerPanelTabKey,
      heardVoiceMessageIds: List<String>.from(heardVoiceMessageIds),
    );
  }
}

final class _ChatGateway implements MessagingGateway {
  _ChatGateway({
    List<ChatMessage> history = const [],
    this.peerLastReadSequence,
    List<PinnedMessageItem> pinnedMessages = const [],
    this.forcedPageSize,
  }) : history = List<ChatMessage>.from(history),
       pinnedMessages = List<PinnedMessageItem>.from(pinnedMessages);

  final List<ChatMessage> history;
  final int? peerLastReadSequence;
  final List<PinnedMessageItem> pinnedMessages;
  final List<String> unpinnedMessageIds = [];
  final int? forcedPageSize;
  int listMessageCalls = 0;
  final List<String> sentTexts = [];
  final List<(String, String, int, int)> sentMedia = [];
  final List<(String, String, int)> editedMessages = [];
  final List<(String, int)> markedReads = [];
  final List<String?> searchConversationIds = [];
  final List<String> searchQueries = [];
  final List<(bool?, DateTime?, bool, bool?)> preferenceUpdates = [];
  final List<String> hiddenConversationIds = [];

  @override
  Future<List<ConversationItem>> listConversations({
    required Uri origin,
    required String accessToken,
  }) async => [_conversation(peerLastReadSequence: peerLastReadSequence)];

  @override
  Future<ConversationItem> getConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async => _conversation(peerLastReadSequence: peerLastReadSequence);

  @override
  Future<ConversationItem> ensureDirectConversation({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => _conversation();

  @override
  Future<ConversationItem> ensureSavedConversation({
    required Uri origin,
    required String accessToken,
  }) async => _conversation();

  @override
  Future<MessagePage> listMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    int beforeSequence = 0,
    int limit = 50,
  }) async {
    listMessageCalls++;
    if (forcedPageSize == null) {
      return MessagePage(items: history.reversed.toList(), hasMore: false);
    }
    final cutoff = beforeSequence > 0
        ? beforeSequence
        : (history.isEmpty
              ? 1
              : history
                        .map((message) => message.sequence)
                        .reduce((a, b) => a > b ? a : b) +
                    1);
    final eligible =
        history
            .where((message) => message.sequence < cutoff)
            .toList(growable: false)
          ..sort((a, b) => b.sequence.compareTo(a.sequence));
    final pageSize = forcedPageSize!.clamp(1, limit);
    final items = eligible.take(pageSize).toList(growable: false);
    final hasMore = eligible.length > items.length;
    final nextBeforeSequence = hasMore && items.isNotEmpty
        ? items.last.sequence
        : null;
    return MessagePage(
      items: items,
      hasMore: hasMore,
      nextBeforeSequence: nextBeforeSequence,
    );
  }

  @override
  Future<ChatMessage> sendText({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String text,
    String? replyToMessageId,
  }) async {
    sentTexts.add(text);
    final message = ChatMessage(
      id: 'sent-${sentTexts.length}',
      conversationId: conversationId,
      sequence: history.length + 1,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: 'TEXT',
      content: TextMessageContent(text: text),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.utc(2026, 8, 8, 8, sentTexts.length),
    );
    history.add(message);
    return message;
  }

  @override
  Future<ChatMessage> sendImage({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String mediaId,
    required int width,
    required int height,
    String? replyToMessageId,
  }) async {
    final message = ChatMessage(
      id: 'image-${history.length + 1}',
      conversationId: conversationId,
      sequence: history.length + 1,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: 'IMAGE',
      content: TextMessageContent(
        mediaId: mediaId,
        width: width,
        height: height,
      ),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.utc(2026, 8, 8, 9),
    );
    history.add(message);
    return message;
  }

  @override
  Future<ChatMessage> sendMedia({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required String clientMessageId,
    required String type,
    required String mediaId,
    String? posterMediaId,
    int? width,
    int? height,
    int? durationMs,
    String? replyToMessageId,
  }) async {
    sentMedia.add((type, mediaId, width ?? 0, height ?? 0));
    final message = ChatMessage(
      id: 'media-${history.length + 1}',
      conversationId: conversationId,
      sequence: history.length + 1,
      senderUserId: 'user-a',
      senderDeviceId: 'device-a',
      clientMessageId: clientMessageId,
      type: type,
      content: TextMessageContent(
        mediaId: mediaId,
        posterMediaId: posterMediaId,
        width: width,
        height: height,
        durationMs: durationMs,
      ),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.utc(2026, 8, 8, 9),
    );
    history.add(message);
    return message;
  }

  @override
  Future<ConversationItem> updatePreferences({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    bool? isPinned,
    DateTime? mutedUntil,
    bool clearMute = false,
    bool? isArchived,
  }) async {
    preferenceUpdates.add((isPinned, mutedUntil, clearMute, isArchived));
    return _conversation(
      isPinned: isPinned ?? false,
      mutedUntil: clearMute ? null : mutedUntil,
    );
  }

  @override
  Future<void> hideConversation({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async {
    hiddenConversationIds.add(conversationId);
  }

  @override
  Future<int> markRead({
    required Uri origin,
    required String accessToken,
    required String conversationId,
    required int sequence,
  }) async {
    markedReads.add((conversationId, sequence));
    return sequence;
  }

  @override
  Future<ChatMessage> editMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String text,
    required int expectedEditVersion,
  }) async {
    editedMessages.add((messageId, text, expectedEditVersion));
    final index = history.indexWhere((message) => message.id == messageId);
    final previous = history[index];
    final edited = ChatMessage(
      id: previous.id,
      conversationId: previous.conversationId,
      sequence: previous.sequence,
      senderUserId: previous.senderUserId,
      senderDeviceId: previous.senderDeviceId,
      clientMessageId: previous.clientMessageId,
      type: previous.type,
      content: TextMessageContent(text: text),
      replyToMessageId: previous.replyToMessageId,
      forwardedFromMessageId: previous.forwardedFromMessageId,
      createdAt: previous.createdAt,
      editedAt: DateTime.utc(2026, 8, 10, 0, 30),
      editVersion: previous.editVersion + 1,
      recalledAt: previous.recalledAt,
    );
    history[index] = edited;
    return edited;
  }

  @override
  Future<ChatMessage> recallMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async => history.firstWhere((message) => message.id == messageId);

  @override
  Future<void> deleteMessageLocally({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<List<SavedMessageItem>> listSavedMessages({
    required Uri origin,
    required String accessToken,
  }) async => const [];

  @override
  Future<void> saveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<void> unsaveMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<List<PinnedMessageItem>> listPinnedMessages({
    required Uri origin,
    required String accessToken,
    required String conversationId,
  }) async => pinnedMessages;

  @override
  Future<void> pinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {}

  @override
  Future<void> unpinMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
  }) async {
    unpinnedMessageIds.add(messageId);
    pinnedMessages.removeWhere((item) => item.message.id == messageId);
  }

  @override
  Future<ChatMessage> forwardMessage({
    required Uri origin,
    required String accessToken,
    required String messageId,
    required String targetConversationId,
    required String clientMessageId,
  }) => throw UnimplementedError();

  @override
  Future<List<MessageSearchHit>> searchMessages({
    required Uri origin,
    required String accessToken,
    required String query,
    String? conversationId,
  }) async {
    searchQueries.add(query);
    searchConversationIds.add(conversationId);
    return history
        .where(
          (message) =>
              message.type == 'TEXT' &&
              (message.content?.text ?? '').toLowerCase().contains(
                query.toLowerCase(),
              ) &&
              (conversationId == null ||
                  message.conversationId == conversationId),
        )
        .map((message) => MessageSearchHit(message: message))
        .toList(growable: false);
  }

  @override
  Future<SyncPage> sync({
    required Uri origin,
    required String accessToken,
    required int cursor,
    int limit = 200,
  }) async => SyncPage(items: const [], nextCursor: cursor, hasMore: false);

  @override
  void close() {}
}

CustomStickerItem _chatCustomSticker(String id) => CustomStickerItem(
  id: id,
  mediaId: 'media-$id',
  mimeType: 'image/gif',
  width: 512,
  height: 512,
  sizeBytes: 2048,
  sortOrder: 0,
  createdAt: DateTime.utc(2026, 8, 10, 7, 30),
);

StickerPackItemGroup _chatStickerPack(String id) => StickerPackItemGroup(
  id: id,
  setName: 'Animals_by_TestBot',
  title: 'Animals',
  coverMediaId: '',
  supportedStickerCount: 0,
  unsupportedStickerCount: 0,
  sortOrder: 0,
  items: const [],
  updatedAt: DateTime.utc(2026, 8, 10, 7, 30),
);

final class _ChatStickerGateway implements StickerGateway {
  _ChatStickerGateway({
    List<CustomStickerItem> custom = const [],
    List<StickerPackItemGroup> packs = const [],
  }) : _custom = List<CustomStickerItem>.from(custom),
       _packs = List<StickerPackItemGroup>.from(packs);

  final List<CustomStickerItem> _custom;
  final List<StickerPackItemGroup> _packs;

  @override
  Future<List<CustomStickerItem>> listCustomStickers({
    required Uri origin,
    required String accessToken,
  }) async => List<CustomStickerItem>.unmodifiable(_custom);

  @override
  Future<CustomStickerItem> createCustomSticker({
    required Uri origin,
    required String accessToken,
    required String mediaId,
    required int width,
    required int height,
  }) async {
    final item = _chatCustomSticker('created-${_custom.length}');
    _custom.add(item);
    return item;
  }

  @override
  Future<void> deleteCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  }) async => _custom.removeWhere((item) => stickerIds.contains(item.id));

  @override
  Future<void> reorderCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  }) async {}

  @override
  Future<List<StickerPackItemGroup>> listStickerPacks({
    required Uri origin,
    required String accessToken,
  }) async => List<StickerPackItemGroup>.unmodifiable(_packs);

  @override
  Future<StickerPackItemGroup> importTelegramPack({
    required Uri origin,
    required String accessToken,
    required String setName,
  }) async {
    final pack = _chatStickerPack('imported-${_packs.length}');
    _packs.add(pack);
    return pack;
  }

  @override
  Future<void> removeStickerPack({
    required Uri origin,
    required String accessToken,
    required String packId,
  }) async => _packs.removeWhere((pack) => pack.id == packId);

  @override
  void close() {}
}
