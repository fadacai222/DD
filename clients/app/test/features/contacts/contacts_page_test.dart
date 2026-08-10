import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/data/contacts_api_client.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/contacts/presentation/contacts_page.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets('DDID search adds a unilateral contact without approval UI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _FakeContactsGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'access-token',
          currentUserId: _alice.id,
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新的朋友'), findsNothing);
    expect(find.text('申请理由（可选）'), findsNothing);
    await tester.tap(find.widgetWithText(Tab, '添加联系人'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('contacts-search-handle')),
      'bob_01',
    );
    await tester.tap(find.byKey(const Key('contacts-search-button')));
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    expect(find.byKey(const Key('contacts-add-contact')), findsOneWidget);
    await tester.tap(find.byKey(const Key('contacts-add-contact')));
    await tester.pumpAndSettle();

    expect(gateway.addedUserIds, [_bob.id]);
    expect(find.text('已添加到联系人。'), findsOneWidget);
    expect(find.textContaining('已在联系人中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile contacts keep full-width header, grouping and real tags',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final gateway = _FakeContactsGateway(
        initialContacts: [
          _contact(_bob, tags: const ['work']),
          _contact(_zhao, tags: const ['friends']),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContactsPage(
              origin: Uri.parse('http://127.0.0.1:18473'),
              accessToken: 'access-token',
              currentUserId: _alice.id,
              gateway: gateway,
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final titleCenter = tester.getCenter(
        find.byKey(const Key('contacts-mobile-title')),
      );
      final addCenter = tester.getCenter(
        find.byKey(const Key('contacts-add-friend')),
      );
      expect(titleCenter.dx, closeTo(180, 2));
      expect(addCenter.dx, greaterThan(320));
      expect(find.byKey(const Key('contact-section-B')), findsOneWidget);
      expect(find.byKey(const Key('contact-section-#')), findsOneWidget);

      await tester.tap(find.text('标签'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contact-tag-friends')), findsOneWidget);
      expect(find.byKey(const Key('contact-tag-work')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile group directory delegates to the real group list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var openGroupsCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsPage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'access-token',
            currentUserId: _alice.id,
            gateway: _FakeContactsGateway(),
            embedded: true,
            onOpenGroups: () async => openGroupsCount++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('群聊'));
    await tester.pumpAndSettle();

    expect(openGroupsCount, 1);
    expect(find.text('群聊功能正在接入。'), findsNothing);
  });

  testWidgets('desktop group directory is a first-class address-book entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var openGroupsCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsPage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'access-token',
            currentUserId: _alice.id,
            gateway: _FakeContactsGateway(),
            embedded: true,
            onOpenGroups: () async => openGroupsCount++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('desktop-groups-directory')), findsOneWidget);
    await tester.tap(find.byKey(const Key('desktop-groups-directory')));
    await tester.pumpAndSettle();
    expect(openGroupsCount, 1);
  });

  testWidgets('desktop contact detail exposes a primary message action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _FakeContactsGateway(initialContacts: [_contact(_bob)]);
    String? openedUserId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsPage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'access-token',
            currentUserId: _alice.id,
            gateway: gateway,
            embedded: true,
            onOpenDirectChat: (peerId, _) async => openedUserId = peerId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('desktop-contacts-sidebar'))).width,
      DdDesktopTokens.sidebarWidth,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(Key('desktop-contact-${_bob.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop-contact-message')), findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);

    await tester.tap(find.byKey(const Key('desktop-contact-message')));
    await tester.pumpAndSettle();
    expect(openedUserId, _bob.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocked-by-peer result explains that contact cannot be added', (
    tester,
  ) async {
    final gateway = _FakeContactsGateway(searchRelationship: 'BLOCKED_BY_PEER');
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'access-token',
          currentUserId: _alice.id,
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '添加联系人'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('contacts-search-handle')),
      'bob_01',
    );
    await tester.tap(find.byKey(const Key('contacts-search-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('对方已将你拉黑'), findsOneWidget);
    expect(find.text('您无法添加'), findsOneWidget);
    expect(find.byKey(const Key('contacts-add-contact')), findsNothing);
  });

  testWidgets('refresh token reloads contacts without leaving address book', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = _FakeContactsGateway();
    Widget build(int refreshToken) => MaterialApp(
      home: Scaffold(
        body: ContactsPage(
          key: const ValueKey('contacts-refresh-test'),
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'access-token',
          currentUserId: _alice.id,
          gateway: gateway,
          embedded: true,
          refreshRequestToken: refreshToken,
        ),
      ),
    );

    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    final before = gateway.listContactsCalls;
    await tester.pumpWidget(build(1));
    await tester.pumpAndSettle();

    expect(gateway.listContactsCalls, greaterThan(before));
    expect(find.text('联系人'), findsWidgets);
  });
}

const _alice = ContactUser(
  id: '018f0000-0000-7000-8000-000000000301',
  handle: 'alice_01',
  displayName: 'Alice',
  bio: '',
);
const _bob = ContactUser(
  id: '018f0000-0000-7000-8000-000000000302',
  handle: 'bob_01',
  displayName: 'Bob',
  bio: '',
);
const _zhao = ContactUser(
  id: '018f0000-0000-7000-8000-000000000306',
  handle: 'zhao_06',
  displayName: '赵六',
  bio: '',
);

ContactItem _contact(ContactUser user, {List<String> tags = const []}) =>
    ContactItem(
      user: user,
      remark: '',
      isStarred: false,
      tags: tags,
      createdAt: DateTime.utc(2026, 8, 8, 3),
      updatedAt: DateTime.utc(2026, 8, 8, 3),
    );

final class _FakeContactsGateway implements ContactsGateway {
  _FakeContactsGateway({
    this.initialContacts = const [],
    this.searchRelationship = 'NONE',
  }) : _contacts = List<ContactItem>.from(initialContacts);

  final List<ContactItem> initialContacts;
  final String searchRelationship;
  final List<String> addedUserIds = [];
  final List<ContactItem> _contacts;
  int listContactsCalls = 0;

  @override
  Future<ContactSearchResult> searchByHandle({
    required Uri origin,
    required String accessToken,
    required String handle,
  }) async => ContactSearchResult(user: _bob, relationship: searchRelationship);

  @override
  Future<ContactSearchResult> getUserById({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => ContactSearchResult(user: _bob, relationship: searchRelationship);

  @override
  Future<ContactItem> addContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    addedUserIds.add(userId);
    final item = _contact(_bob);
    if (!_contacts.any((contact) => contact.user.id == userId)) {
      _contacts.add(item);
    }
    return item;
  }

  @override
  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  }) async {
    listContactsCalls++;
    return _page(_contacts);
  }

  @override
  Future<ContactItem> updateContact({
    required Uri origin,
    required String accessToken,
    required String userId,
    String? remark,
    bool? isStarred,
    List<String>? tags,
  }) async => ContactItem(
    user: _bob,
    remark: remark ?? '',
    isStarred: isStarred ?? false,
    tags: tags ?? const [],
    createdAt: DateTime.utc(2026, 8, 8, 3),
    updatedAt: DateTime.utc(2026, 8, 8, 3),
  );

  @override
  Future<void> deleteContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => _contacts.removeWhere((contact) => contact.user.id == userId);

  @override
  Future<BlockedUserItem> blockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async =>
      BlockedUserItem(user: _bob, createdAt: DateTime.utc(2026, 8, 8, 3));

  @override
  Future<RelationshipPage<BlockedUserItem>> listBlocks({
    required Uri origin,
    required String accessToken,
  }) async => _page(const <BlockedUserItem>[]);

  @override
  Future<void> unblockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {}

  // Legacy request APIs remain in the gateway for wire compatibility with old
  // clients, but the current Telegram-style UI no longer exposes approval.
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
  }) async => _page(const <ContactRequestItem>[]);

  @override
  Future<ContactRequestItem> acceptRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) => throw UnsupportedError('legacy contact request');

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

RelationshipPage<T> _page<T>(List<T> items) => RelationshipPage<T>(
  items: List<T>.from(items),
  page: 1,
  pageSize: 100,
  totalItems: items.length,
  totalPages: items.isEmpty ? 0 : 1,
);
