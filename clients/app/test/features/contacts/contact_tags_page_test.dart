import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/contacts/presentation/contact_tags_page.dart';

void main() {
  testWidgets(
    'contact tags page groups existing tags instead of showing placeholder',
    (tester) async {
      ContactItem? opened;
      final contacts = [
        ContactItem(
          user: _alice,
          remark: 'Alice A',
          isStarred: false,
          tags: const ['work', 'friends'],
          createdAt: DateTime.utc(2026, 8, 9),
          updatedAt: DateTime.utc(2026, 8, 9),
        ),
        ContactItem(
          user: _bob,
          remark: '',
          isStarred: false,
          tags: const ['work'],
          createdAt: DateTime.utc(2026, 8, 9),
          updatedAt: DateTime.utc(2026, 8, 9),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: ContactTagsPage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'token',
            contacts: contacts,
            onOpenContact: (contact) async => opened = contact,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const Key('contact-tag-friends')), findsOneWidget);
      expect(find.byKey(const Key('contact-tag-work')), findsOneWidget);
      expect(find.textContaining('2 位联系人'), findsOneWidget);
      expect(find.byKey(const Key('contact-tags-search')), findsOneWidget);
      expect(find.text('标签功能正在接入。'), findsNothing);

      await tester.tap(find.byKey(const Key('contact-tag-work')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('tag-contact-${_bob.id}')), findsOneWidget);
      await tester.tap(find.byKey(Key('tag-contact-${_bob.id}')));
      await tester.pump();
      expect(opened?.user.id, _bob.id);
      expect(tester.takeException(), isNull);
    },
  );
}

const _alice = ContactUser(
  id: '018f0000-0000-7000-8000-000000000411',
  handle: 'alice_tag',
  displayName: 'Alice',
  bio: '',
);

const _bob = ContactUser(
  id: '018f0000-0000-7000-8000-000000000412',
  handle: 'bob_tag',
  displayName: 'Bob',
  bio: '',
);
