import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/groups/data/groups_api_client.dart';
import 'package:im_client/features/groups/domain/group_models.dart';
import 'package:im_client/features/groups/presentation/group_details_page.dart';
import 'package:im_client/features/messaging/application/messaging_coordinator.dart';
import 'package:realtime_poc/realtime_poc.dart';

void main() {
  testWidgets('owner sees management controls and dissolve instead of leave', (
    tester,
  ) async {
    final harness = _GroupDetailsHarness(role: 'OWNER');
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDetailsPage(
          coordinator: harness.coordinator,
          groupId: 'group-1',
          currentUserId: 'user-a',
          gateway: harness.groups,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('研发群'), findsWidgets);
    expect(find.text('3 位成员 · 群主'), findsOneWidget);
    expect(find.byKey(const Key('group-details-invite')), findsOneWidget);
    expect(
      tester.widget<InkWell>(
        find.byKey(const Key('group-details-avatar')),
      ).onTap,
      isNotNull,
    );
    expect(find.byKey(const Key('group-details-name')), findsOneWidget);
    expect(find.byKey(const Key('group-details-announcement')), findsOneWidget);
    expect(find.byKey(const Key('group-details-join-mode')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-details-dissolve')),
      360,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('group-details-dissolve')), findsOneWidget);
    expect(find.byKey(const Key('group-details-leave')), findsNothing);
    expect(find.text('待处理入群申请'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary member sees self nickname and leave without admin controls', (
    tester,
  ) async {
    final harness = _GroupDetailsHarness(role: 'MEMBER');
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupDetailsPage(
          coordinator: harness.coordinator,
          groupId: 'group-1',
          currentUserId: 'user-a',
          gateway: harness.groups,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 位成员 · 成员'), findsOneWidget);
    expect(find.byKey(const Key('group-details-invite')), findsNothing);
    expect(
      tester.widget<InkWell>(
        find.byKey(const Key('group-details-avatar')),
      ).onTap,
      isNull,
    );
    expect(find.byKey(const Key('group-details-nickname')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-details-leave')),
      360,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('group-details-leave')), findsOneWidget);
    expect(find.byKey(const Key('group-details-dissolve')), findsNothing);
    expect(find.text('待处理入群申请'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

final class _GroupDetailsHarness {
  _GroupDetailsHarness({required String role})
    : groups = _GroupDetailsGateway(role: role),
      realtime = RealtimeClient(
        baseUri: Uri.parse('http://127.0.0.1:19999'),
        clientId: 'device-a',
        channelFactory: (_) => throw StateError('not used'),
      ) {
    coordinator = MessagingCoordinator(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      currentUserId: 'user-a',
      deviceId: 'device-a',
      realtimeClient: realtime,
    );
  }

  final _GroupDetailsGateway groups;
  final RealtimeClient realtime;
  late final MessagingCoordinator coordinator;

  Future<void> dispose() async {
    coordinator.dispose();
    await realtime.dispose();
  }
}

final class _GroupDetailsGateway implements GroupsGateway {
  _GroupDetailsGateway({required this.role});

  final String role;

  @override
  Future<GroupInfo> getGroup({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async => GroupInfo(
    id: groupId,
    name: '研发群',
    announcement: '本周五发布',
    joinMode: 'APPROVAL',
    status: 'ACTIVE',
    memberCount: 3,
    ownerUserId: role == 'OWNER' ? 'user-a' : 'user-owner',
    myRole: role,
    myNickname: '测试昵称',
    createdAt: DateTime.utc(2026, 8, 10),
    updatedAt: DateTime.utc(2026, 8, 10),
  );

  @override
  Future<List<GroupMemberItem>> listMembers({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async => [
    GroupMemberItem(
      user: const GroupUserPreview(
        id: 'user-a',
        handle: 'alice',
        displayName: 'Alice',
      ),
      role: role,
      nickname: '测试昵称',
      joinedAt: DateTime.utc(2026, 8, 10),
    ),
    GroupMemberItem(
      user: const GroupUserPreview(
        id: 'user-b',
        handle: 'bob',
        displayName: 'Bob',
      ),
      role: 'MEMBER',
      nickname: '',
      joinedAt: DateTime.utc(2026, 8, 10),
    ),
    GroupMemberItem(
      user: const GroupUserPreview(
        id: 'user-c',
        handle: 'chen',
        displayName: 'Chen',
      ),
      role: 'MEMBER',
      nickname: '',
      joinedAt: DateTime.utc(2026, 8, 10),
    ),
  ];

  @override
  Future<List<GroupJoinRequestItem>> listJoinRequests({
    required Uri origin,
    required String accessToken,
    required String groupId,
  }) async => role == 'MEMBER'
      ? const []
      : [
          GroupJoinRequestItem(
            id: 'request-1',
            groupId: groupId,
            requester: const GroupUserPreview(
              id: 'user-d',
              handle: 'dave',
              displayName: 'Dave',
            ),
            message: '申请加入',
            status: 'PENDING',
            createdAt: DateTime.utc(2026, 8, 10),
          ),
        ];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
