import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/data/contacts_api_client.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/contacts/presentation/peer_profile_page.dart';

void main() {
  testWidgets(
    'contact profile is inset, manageable and delete keeps chat action',
    (tester) async {
      final gateway = _ProfileContactsGateway(relationship: 'CONTACT');
      var messageOpens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PeerProfilePage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'token',
            userId: _bob.id,
            handle: _bob.handle,
            displayName: _bob.displayName,
            contact: gateway.contact,
            gateway: gateway,
            onMessage: () async => messageOpens++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('DDID：bob_01'), findsOneWidget);
      expect(find.byKey(const Key('peer-profile-message')), findsOneWidget);
      expect(find.byKey(const Key('peer-profile-more')), findsOneWidget);

      await tester.tap(find.byKey(const Key('peer-profile-more')));
      await tester.pumpAndSettle();
      expect(find.text('备注与标签'), findsOneWidget);
      expect(find.text('删除联系人'), findsOneWidget);
      expect(find.text('拉黑'), findsOneWidget);

      await tester.tap(find.text('删除联系人'));
      await tester.pumpAndSettle();
      expect(find.text('删除联系人？'), findsOneWidget);
      expect(find.textContaining('不会阻止双方继续发消息'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(gateway.deletedUserIds, [_bob.id]);
      await tester.ensureVisible(
        find.byKey(const Key('peer-profile-add-contact'), skipOffstage: false),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('peer-profile-add-contact')), findsOneWidget);
      expect(
        find.byKey(const Key('peer-profile-message'), skipOffstage: false),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('peer-profile-message'), skipOffstage: false),
      );
      await tester.tap(find.byKey(const Key('peer-profile-message')));
      expect(messageOpens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('contact remark and tags use lightweight underline fields', (
    tester,
  ) async {
    final gateway = _ProfileContactsGateway(relationship: 'CONTACT');
    await tester.pumpWidget(
      MaterialApp(
        home: PeerProfilePage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          userId: _bob.id,
          handle: _bob.handle,
          displayName: _bob.displayName,
          contact: gateway.contact,
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('peer-profile-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备注与标签'));
    await tester.pumpAndSettle();

    final remark = tester.widget<TextField>(
      find.byKey(const Key('peer-profile-edit-remark')),
    );
    final tags = tester.widget<TextField>(
      find.byKey(const Key('peer-profile-edit-tags')),
    );
    expect(remark.decoration?.border, isA<UnderlineInputBorder>());
    expect(tags.decoration?.border, isA<UnderlineInputBorder>());
    expect(remark.decoration?.border, isNot(isA<OutlineInputBorder>()));
    expect(tags.decoration?.border, isNot(isA<OutlineInputBorder>()));
  });

  testWidgets('contact profile exposes a first-class moments entry', (
    tester,
  ) async {
    final gateway = _ProfileContactsGateway(relationship: 'CONTACT');
    var momentsOpens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PeerProfilePage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          userId: _bob.id,
          handle: _bob.handle,
          displayName: _bob.displayName,
          contact: gateway.contact,
          gateway: gateway,
          onOpenMoments: () async => momentsOpens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('peer-profile-moments'));
    expect(entry, findsOneWidget);
    await tester.scrollUntilVisible(entry, 120);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(momentsOpens, 1);
  });

  testWidgets('contact profile exposes moments privacy entry', (tester) async {
    final gateway = _ProfileContactsGateway(relationship: 'CONTACT');
    var privacyOpens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PeerProfilePage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          userId: _bob.id,
          handle: _bob.handle,
          displayName: _bob.displayName,
          contact: gateway.contact,
          gateway: gateway,
          onOpenMomentPrivacy: () async => privacyOpens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('peer-profile-moment-privacy'));
    expect(entry, findsOneWidget);
    await tester.scrollUntilVisible(entry, 120);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    expect(privacyOpens, 1);
  });

  testWidgets('non-contact can chat and add contact without approval', (
    tester,
  ) async {
    final gateway = _ProfileContactsGateway(relationship: 'NONE');
    var messageOpens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PeerProfilePage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          userId: _bob.id,
          handle: _bob.handle,
          displayName: _bob.displayName,
          gateway: gateway,
          onMessage: () async => messageOpens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('可直接聊天'), findsWidgets);
    expect(
      find.byKey(const Key('peer-profile-message'), skipOffstage: false),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const Key('peer-profile-add-contact'), skipOffstage: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('peer-profile-add-contact')), findsOneWidget);
    expect(find.textContaining('好友申请'), findsNothing);

    await tester.tap(find.byKey(const Key('peer-profile-message')));
    expect(messageOpens, 1);
    await tester.tap(find.byKey(const Key('peer-profile-add-contact')));
    await tester.pumpAndSettle();
    expect(gateway.addedUserIds, [_bob.id]);
    expect(find.text('已在联系人中'), findsWidgets);
  });

  testWidgets('incoming pending request can be accepted from profile', (
    tester,
  ) async {
    final gateway = _ProfileContactsGateway(
      relationship: 'PENDING_INCOMING',
      includeIncomingRequest: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PeerProfilePage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          userId: _bob.id,
          handle: _bob.handle,
          displayName: _bob.displayName,
          gateway: gateway,
          onMessage: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('peer-profile-accept-request'), skipOffstage: false),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('peer-profile-accept-request')),
      findsOneWidget,
    );
    expect(find.text('通过好友申请'), findsOneWidget);
    expect(find.byKey(const Key('peer-profile-add-contact')), findsNothing);

    await tester.tap(find.byKey(const Key('peer-profile-accept-request')));
    await tester.pumpAndSettle();

    expect(gateway.acceptedRequestIds, ['request-bob']);
    expect(find.text('已在联系人中'), findsWidgets);
    expect(find.byKey(const Key('peer-profile-accept-request')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile remains bounded on 360x640 and 881x657', (tester) async {
    for (final size in <Size>[const Size(360, 640), const Size(881, 657)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final gateway = _ProfileContactsGateway(relationship: 'CONTACT');
      await tester.pumpWidget(
        MaterialApp(
          home: PeerProfilePage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'token',
            userId: _bob.id,
            handle: _bob.handle,
            displayName: _bob.displayName,
            gateway: gateway,
            onMessage: () async {},
            onAudioCall: () async {},
            onVideoCall: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('peer-profile-info-card')), findsOneWidget);
      expect(
        find.byKey(const Key('peer-profile-quick-actions')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('peer-profile-relationship-chip')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: '$size');
      final scrollRect = tester.getRect(
        find.byKey(const Key('peer-profile-scroll')),
      );
      expect(scrollRect.left, greaterThanOrEqualTo(0), reason: '$size');
      expect(scrollRect.right, lessThanOrEqualTo(size.width), reason: '$size');
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets(
    'embedded desktop profile measures the pane instead of the whole window',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final gateway = _ProfileContactsGateway(relationship: 'CONTACT');

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: 340,
              height: 720,
              child: PeerProfilePage(
                origin: Uri.parse('http://127.0.0.1:18473'),
                accessToken: 'token',
                userId: _bob.id,
                handle: _bob.handle,
                displayName: _bob.displayName,
                gateway: gateway,
                embedded: true,
                onMessage: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final infoCard = tester.getSize(
        find.byKey(const Key('peer-profile-info-card')),
      );
      expect(infoCard.width, greaterThan(280));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy stable-id 404 falls back to exact handle for a real contact',
    (tester) async {
      final gateway = _ProfileContactsGateway(
        relationship: 'CONTACT',
        getUserError: const ContactsApiException(
          statusCode: 404,
          code: 'NOT_FOUND',
          message: 'Not found',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PeerProfilePage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'token',
            userId: _bob.id,
            handle: _bob.handle,
            displayName: _bob.displayName,
            contact: gateway.contact,
            gateway: gateway,
            onMessage: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(gateway.searchedHandles, [_bob.handle]);
      expect(find.text('该用户当前不可用'), findsNothing);
      expect(find.text('已在联系人中'), findsWidgets);
      expect(find.byKey(const Key('peer-profile-message')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unavailable stable user disables all communication actions', (
    tester,
  ) async {
    final gateway = _ProfileContactsGateway(
      relationship: 'NONE',
      getUserError: const ContactsApiException(
        statusCode: 404,
        code: 'CONTACT_NOT_FOUND',
        message: 'Not found',
      ),
      searchByHandleError: const ContactsApiException(
        statusCode: 404,
        code: 'CONTACT_NOT_FOUND',
        message: 'Not found',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PeerProfilePage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          userId: _bob.id,
          handle: _bob.handle,
          displayName: _bob.displayName,
          gateway: gateway,
          onMessage: () async {},
          onAudioCall: () async {},
          onVideoCall: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('该用户当前不可用'), findsWidgets);
    expect(find.byKey(const Key('peer-profile-message')), findsNothing);
    expect(find.byKey(const Key('peer-profile-audio-call')), findsNothing);
    expect(find.byKey(const Key('peer-profile-video-call')), findsNothing);
    expect(find.byKey(const Key('peer-profile-add-contact')), findsNothing);
    expect(find.byKey(const Key('peer-profile-more')), findsNothing);
    expect(find.text('重新加载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocked-by-peer profile gives explicit feedback and no chat', (
    tester,
  ) async {
    final gateway = _ProfileContactsGateway(relationship: 'BLOCKED_BY_PEER');
    await tester.pumpWidget(
      MaterialApp(
        home: PeerProfilePage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          userId: _bob.id,
          handle: _bob.handle,
          displayName: _bob.displayName,
          gateway: gateway,
          onMessage: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('对方已将你拉黑'), findsWidgets);
    expect(find.textContaining('您无法添加'), findsOneWidget);
    expect(find.byKey(const Key('peer-profile-message')), findsNothing);
    expect(find.byKey(const Key('peer-profile-add-contact')), findsNothing);
  });
}

const _bob = ContactUser(
  id: '018f0000-0000-7000-8000-000000000401',
  handle: 'bob_01',
  displayName: 'Bob',
  bio: 'Hello DD',
);

final class _ProfileContactsGateway implements ContactsGateway {
  _ProfileContactsGateway({
    required this.relationship,
    this.getUserError,
    this.searchByHandleError,
    this.includeIncomingRequest = false,
  });

  String relationship;
  final Object? getUserError;
  final Object? searchByHandleError;
  final bool includeIncomingRequest;
  ContactItem contact = ContactItem(
    user: _bob,
    remark: '',
    isStarred: false,
    tags: const ['friends'],
    createdAt: DateTime.utc(2026, 8, 9),
    updatedAt: DateTime.utc(2026, 8, 9),
  );
  final List<String> addedUserIds = [];
  final List<String> deletedUserIds = [];
  final List<String> acceptedRequestIds = [];
  final List<String> searchedHandles = [];

  @override
  Future<ContactSearchResult> searchByHandle({
    required Uri origin,
    required String accessToken,
    required String handle,
  }) async {
    searchedHandles.add(handle);
    final error = searchByHandleError;
    if (error != null) throw error;
    return ContactSearchResult(user: _bob, relationship: relationship);
  }

  @override
  Future<ContactSearchResult> getUserById({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final error = getUserError;
    if (error != null) throw error;
    return ContactSearchResult(user: _bob, relationship: relationship);
  }

  @override
  Future<ContactItem> addContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    addedUserIds.add(userId);
    relationship = 'CONTACT';
    return contact;
  }

  @override
  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  }) async =>
      _page(relationship == 'CONTACT' ? [contact] : const <ContactItem>[]);

  @override
  Future<ContactItem> updateContact({
    required Uri origin,
    required String accessToken,
    required String userId,
    String? remark,
    bool? isStarred,
    List<String>? tags,
  }) async {
    contact = ContactItem(
      user: contact.user,
      remark: remark ?? contact.remark,
      isStarred: isStarred ?? contact.isStarred,
      tags: tags ?? contact.tags,
      createdAt: contact.createdAt,
      updatedAt: DateTime.utc(2026, 8, 9, 1),
    );
    return contact;
  }

  @override
  Future<void> deleteContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    deletedUserIds.add(userId);
    relationship = 'NONE';
  }

  @override
  Future<BlockedUserItem> blockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    relationship = 'BLOCKED_BY_ME';
    return BlockedUserItem(user: _bob, createdAt: DateTime.utc(2026, 8, 9));
  }

  @override
  Future<void> unblockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => relationship = 'NONE';

  @override
  Future<RelationshipPage<BlockedUserItem>> listBlocks({
    required Uri origin,
    required String accessToken,
  }) async => _page(const <BlockedUserItem>[]);

  @override
  Future<ContactRequestItem> sendRequest({
    required Uri origin,
    required String accessToken,
    required String targetHandle,
    String message = '',
  }) => throw UnsupportedError('legacy contact request');

  @override
  Future<RelationshipPage<ContactRequestItem>> listRequests({
    required Uri origin,
    required String accessToken,
    required String direction,
  }) async => _page(
    includeIncomingRequest && direction == 'incoming'
        ? <ContactRequestItem>[_incomingRequest]
        : const <ContactRequestItem>[],
  );

  @override
  Future<ContactRequestItem> acceptRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) async {
    acceptedRequestIds.add(requestId);
    relationship = 'CONTACT';
    return ContactRequestItem(
      id: _incomingRequest.id,
      sender: _incomingRequest.sender,
      receiver: _incomingRequest.receiver,
      message: _incomingRequest.message,
      status: 'ACCEPTED',
      createdAt: _incomingRequest.createdAt,
      expiresAt: _incomingRequest.expiresAt,
      resolvedAt: DateTime.utc(2026, 8, 10, 7, 15),
      conversationId: '018f0000-0000-7000-8000-000000000499',
    );
  }

  @override
  Future<ContactRequestItem> rejectRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) => throw UnsupportedError('legacy contact request');

  @override
  Future<ContactRequestItem> cancelRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) => throw UnsupportedError('legacy contact request');

  @override
  void close() {}
}

final _incomingRequest = ContactRequestItem(
  id: 'request-bob',
  sender: _bob,
  receiver: const ContactUser(
    id: '018f0000-0000-7000-8000-000000000402',
    handle: 'alice_01',
    displayName: 'Alice',
    bio: '',
  ),
  message: '你好',
  status: 'PENDING',
  createdAt: DateTime.utc(2026, 8, 10, 7),
  expiresAt: DateTime.utc(2026, 9, 9, 7),
);

RelationshipPage<T> _page<T>(List<T> items) => RelationshipPage<T>(
  items: items,
  page: 1,
  pageSize: 100,
  totalItems: items.length,
  totalPages: items.isEmpty ? 0 : 1,
);
