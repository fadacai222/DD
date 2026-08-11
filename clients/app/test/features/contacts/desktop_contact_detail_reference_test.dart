import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/data/contacts_api_client.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/contacts/presentation/contacts_page.dart';

void main() {
  testWidgets('desktop contact detail follows the compact WeChat-style profile layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(881, 657);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var messageCount = 0;
    var audioCount = 0;
    var videoCount = 0;
    final gateway = _ReferenceContactsGateway(
      contact: _contact,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsPage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'access-token',
            currentUserId: 'alice',
            gateway: gateway,
            embedded: true,
            onOpenDirectChat: (_, _) async => messageCount++,
            onStartAudioCall: (_, _) async => audioCount++,
            onStartVideoCall: (_, _) async => videoCount++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('desktop-contact-bob')).last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('desktop-contact-detail')), findsOneWidget);
    expect(find.byKey(const Key('desktop-contact-more')), findsOneWidget);
    expect(find.text('朋友资料'), findsOneWidget);
    expect(find.text('更多信息'), findsOneWidget);
    expect(find.text('备注'), findsOneWidget);
    expect(find.text('小强货'), findsWidgets);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('朋友 · 同事'), findsOneWidget);
    expect(find.text('朋友圈'), findsOneWidget);
    expect(find.text('个性签名'), findsOneWidget);
    expect(find.text('不要暴躁，要温柔'), findsOneWidget);
    expect(find.text('添加时间'), findsOneWidget);
    expect(find.text('2026-08-08'), findsOneWidget);
    expect(find.text('DDID：tisen02'), findsOneWidget);

    expect(find.widgetWithText(FilledButton, '发消息'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '语音通话'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '视频通话'), findsNothing);

    await tester.tap(find.byKey(const Key('desktop-contact-message')));
    await tester.tap(find.byKey(const Key('desktop-contact-audio')));
    await tester.tap(find.byKey(const Key('desktop-contact-video')));
    await tester.pumpAndSettle();
    expect(messageCount, 1);
    expect(audioCount, 1);
    expect(videoCount, 1);

    await tester.tap(find.byKey(const Key('desktop-contact-more')));
    await tester.pumpAndSettle();
    expect(find.text('备注与标签'), findsOneWidget);
    expect(find.text('朋友圈权限'), findsOneWidget);
    expect(find.text('删除联系人'), findsOneWidget);
    expect(find.text('拉黑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

const _user = ContactUser(
  id: 'bob',
  handle: 'tisen02',
  displayName: '小强',
  bio: '不要暴躁，要温柔',
);

final _contact = ContactItem(
  user: _user,
  remark: '小强货',
  isStarred: true,
  tags: const ['朋友', '同事'],
  createdAt: DateTime.utc(2026, 8, 8, 3),
  updatedAt: DateTime.utc(2026, 8, 8, 3),
);

final class _ReferenceContactsGateway implements ContactsGateway {
  _ReferenceContactsGateway({required this.contact});

  final ContactItem contact;

  @override
  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  }) async => _page([contact]);

  @override
  Future<RelationshipPage<BlockedUserItem>> listBlocks({
    required Uri origin,
    required String accessToken,
  }) async => _page(const <BlockedUserItem>[]);

  @override
  Future<ContactSearchResult> searchByHandle({
    required Uri origin,
    required String accessToken,
    required String handle,
  }) async => const ContactSearchResult(user: _user, relationship: 'CONTACT');

  @override
  Future<ContactSearchResult> getUserById({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => const ContactSearchResult(user: _user, relationship: 'CONTACT');

  @override
  Future<ContactItem> addContact({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => contact;

  @override
  Future<ContactItem> updateContact({
    required Uri origin,
    required String accessToken,
    required String userId,
    String? remark,
    bool? isStarred,
    List<String>? tags,
  }) async => contact;

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
  }) async => BlockedUserItem(user: _user, createdAt: DateTime.utc(2026, 8, 8));

  @override
  Future<void> unblockUser({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {}

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
