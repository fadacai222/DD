import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/data/contacts_api_client.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/groups/data/groups_api_client.dart';
import 'package:im_client/features/groups/domain/group_models.dart';
import 'package:im_client/features/groups/presentation/create_group_page.dart';

void main() {
  testWidgets('creates a group from selected contacts', (tester) async {
    final groups = _CreateGroupsGateway();
    final contacts = _CreateContactsGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: CreateGroupPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          groupsGateway: groups,
          contactsGateway: contacts,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('create-group-name')), '项目群');
    await tester.tap(find.byKey(const Key('create-group-contact-user-a')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('create-group-submit')));
    await tester.pumpAndSettle();

    expect(groups.createdName, '项目群');
    expect(groups.createdMembers, ['user-a']);
  });

  testWidgets('requires at least one contact before creation', (tester) async {
    final groups = _CreateGroupsGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: CreateGroupPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          groupsGateway: groups,
          contactsGateway: _CreateContactsGateway(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('create-group-name')), '项目群');
    await tester.tap(find.byKey(const Key('create-group-submit')));
    await tester.pump();

    expect(find.text('至少选择 1 位联系人。'), findsOneWidget);
    expect(groups.createdMembers, isEmpty);
  });
}

final class _CreateGroupsGateway implements GroupsGateway {
  String? createdName;
  List<String> createdMembers = const [];

  @override
  Future<GroupInfo> createGroup({
    required Uri origin,
    required String accessToken,
    required String name,
    required List<String> memberIds,
  }) async {
    createdName = name;
    createdMembers = List<String>.from(memberIds);
    return GroupInfo(
      id: 'group-1',
      name: name,
      announcement: '',
      joinMode: 'INVITE_ONLY',
      status: 'ACTIVE',
      memberCount: memberIds.length + 1,
      ownerUserId: 'me',
      myRole: 'OWNER',
      myNickname: '',
      createdAt: DateTime.utc(2026, 8, 10),
      updatedAt: DateTime.utc(2026, 8, 10),
    );
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CreateContactsGateway implements ContactsGateway {
  @override
  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  }) async => RelationshipPage<ContactItem>(
    items: [
      ContactItem(
        user: const ContactUser(
          id: 'user-a',
          handle: 'alice01',
          displayName: 'Alice',
          bio: '',
        ),
        remark: '',
        isStarred: false,
        tags: const [],
        createdAt: DateTime.utc(2026, 8, 10),
        updatedAt: DateTime.utc(2026, 8, 10),
      ),
    ],
    page: 1,
    pageSize: 100,
    totalItems: 1,
    totalPages: 1,
  );

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
