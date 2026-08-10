import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/presentation/widgets/group_avatar_mosaic.dart';

void main() {
  for (final count in [1, 2, 3, 4, 6]) {
    testWidgets('group avatar renders deterministic mosaic for $count members', (
      tester,
    ) async {
      final built = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: GroupAvatarMosaic(
              origin: Uri.parse('http://127.0.0.1:18473'),
              accessToken: 'token',
              groupName: '研发群',
              members: List.generate(count, _member),
              memberBuilder: (context, member, size, index) {
                built.add(member.id);
                return ColoredBox(color: Colors.primaries[index]);
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final expected = count.clamp(0, 4);
      expect(built.length, expected);
      for (var index = 0; index < expected; index++) {
        final slot = find.byKey(Key('group-avatar-member-$index'));
        expect(slot, findsOneWidget);
        final size = tester.getSize(slot);
        expect(size.width, greaterThan(0));
        expect(size.height, greaterThan(0));
      }
      expect(
        find.byKey(const Key('group-avatar-member-4')),
        findsNothing,
      );
    });
  }

  testWidgets('group avatar falls back to group initial without members', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GroupAvatarMosaic(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'token',
            groupName: '研发群',
            members: const [],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('研'), findsOneWidget);
    expect(find.byKey(const Key('group-avatar-member-0')), findsNothing);
  });
}

MessagingUserPreview _member(int index) => MessagingUserPreview(
  id: 'user-$index',
  handle: 'user_$index',
  displayName: '用户$index',
);
