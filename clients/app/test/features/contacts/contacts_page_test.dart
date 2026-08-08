import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/data/contacts_api_client.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/contacts/presentation/contacts_page.dart';

void main() {
  testWidgets('contacts page fits narrow Android viewport and sends request', (
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

    expect(find.text('联系人'), findsWidgets);
    expect(tester.takeException(), isNull);

    // The mobile address book now opens on Contacts by default; adding a
    // friend remains an explicit action/tab.
    await tester.tap(find.widgetWithText(Tab, '添加朋友'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('contacts-search-handle')),
      'bob_01',
    );
    await tester.tap(find.byKey(const Key('contacts-search-button')));
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    expect(find.byKey(const Key('contacts-send-request')), findsOneWidget);

    await tester.tap(find.byKey(const Key('contacts-send-request')));
    await tester.pumpAndSettle();

    expect(gateway.sentHandles, ['bob_01']);
    expect(find.text('好友申请已处理。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incoming request can be accepted and appears in contacts', (
    tester,
  ) async {
    final gateway = _FakeContactsGateway(withIncomingRequest: true);
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

    await tester.tap(find.widgetWithText(Tab, '新的朋友'));
    await tester.pumpAndSettle();
    expect(find.text('接受'), findsOneWidget);

    await tester.tap(find.text('接受'));
    await tester.pumpAndSettle();

    expect(gateway.acceptedRequestIds, [_pendingRequest.id]);
    expect(find.text('已接受好友申请。'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, '联系人'));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

final _pendingRequest = ContactRequestItem(
  id: '018f0000-0000-7000-8000-000000000303',
  sender: _bob,
  receiver: _alice,
  message: 'add me',
  status: 'PENDING',
  createdAt: DateTime.utc(2026, 8, 8, 3),
  expiresAt: DateTime.utc(2026, 9, 7, 3),
);

final class _FakeContactsGateway implements ContactsGateway {
  _FakeContactsGateway({this.withIncomingRequest = false});

  final bool withIncomingRequest;
  final List<String> sentHandles = [];
  final List<String> acceptedRequestIds = [];
  bool _accepted = false;

  @override
  Future<ContactSearchResult> searchByHandle({
    required Uri origin,
    required String accessToken,
    required String handle,
  }) async => const ContactSearchResult(user: _bob, relationship: 'NONE');

  @override
  Future<ContactRequestItem> sendRequest({
    required Uri origin,
    required String accessToken,
    required String targetHandle,
    String message = '',
  }) async {
    sentHandles.add(targetHandle);
    return ContactRequestItem(
      id: '018f0000-0000-7000-8000-000000000304',
      sender: _alice,
      receiver: _bob,
      message: message,
      status: 'PENDING',
      createdAt: DateTime.utc(2026, 8, 8, 3),
      expiresAt: DateTime.utc(2026, 9, 7, 3),
    );
  }

  @override
  Future<RelationshipPage<ContactRequestItem>> listRequests({
    required Uri origin,
    required String accessToken,
    required String direction,
  }) async {
    final items = direction == 'incoming' && withIncomingRequest && !_accepted
        ? [_pendingRequest]
        : <ContactRequestItem>[];
    return _page(items);
  }

  @override
  Future<ContactRequestItem> acceptRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) async {
    acceptedRequestIds.add(requestId);
    _accepted = true;
    return ContactRequestItem(
      id: _pendingRequest.id,
      sender: _pendingRequest.sender,
      receiver: _pendingRequest.receiver,
      message: _pendingRequest.message,
      status: 'ACCEPTED',
      createdAt: _pendingRequest.createdAt,
      expiresAt: _pendingRequest.expiresAt,
      resolvedAt: DateTime.utc(2026, 8, 8, 3, 1),
      conversationId: '018f0000-0000-7000-8000-000000000305',
    );
  }

  @override
  Future<ContactRequestItem> rejectRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) async => _pendingRequest;

  @override
  Future<ContactRequestItem> cancelRequest({
    required Uri origin,
    required String accessToken,
    required String requestId,
  }) async => _pendingRequest;

  @override
  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  }) async => _page(
    _accepted
        ? [
            ContactItem(
              user: _bob,
              remark: '',
              isStarred: false,
              tags: const [],
              createdAt: DateTime.utc(2026, 8, 8, 3),
              updatedAt: DateTime.utc(2026, 8, 8, 3),
            ),
          ]
        : <ContactItem>[],
  );

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
  }) async {}

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

  @override
  void close() {}
}

RelationshipPage<T> _page<T>(List<T> items) => RelationshipPage<T>(
  items: items,
  page: 1,
  pageSize: 100,
  totalItems: items.length,
  totalPages: items.isEmpty ? 0 : 1,
);
