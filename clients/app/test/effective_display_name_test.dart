import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/groups/domain/group_models.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/shared/identity/effective_display_name.dart';

void main() {
  test('contact remark wins and empty remark falls back', () {
    const user = ContactUser(
      id: 'user-bob',
      handle: 'bob',
      displayName: 'Bob',
      bio: '',
    );
    final now = DateTime.utc(2026, 8, 14);
    final remarked = ContactItem(
      user: user,
      remark: 'Boss',
      isStarred: false,
      tags: const [],
      createdAt: now,
      updatedAt: now,
    );
    final plain = ContactItem(
      user: user,
      remark: '   ',
      isStarred: false,
      tags: const [],
      createdAt: now,
      updatedAt: now,
    );

    expect(remarked.effectiveDisplayName, 'Boss');
    expect(plain.effectiveDisplayName, 'Bob');
  });

  test('viewer-resolved search name keeps legacy public fallback', () {
    const user = ContactUser(
      id: 'user-bob',
      handle: 'bob',
      displayName: 'Bob',
      bio: '',
    );
    const resolved = ContactSearchResult(
      user: user,
      relationship: 'CONTACT',
      viewerDisplayName: 'Boss',
    );
    const legacy = ContactSearchResult(user: user, relationship: 'CONTACT');

    expect(resolved.effectiveDisplayName, 'Boss');
    expect(legacy.effectiveDisplayName, 'Bob');
  });

  test('group nickname wins over viewer-resolved contact remark', () {
    final member = GroupMemberItem(
      user: const GroupUserPreview(
        id: 'user-bob',
        handle: 'bob',
        displayName: 'Boss',
      ),
      role: 'MEMBER',
      nickname: 'Bobby',
      joinedAt: DateTime.utc(2026, 8, 14),
    );

    expect(member.effectiveName, 'Bobby');
  });

  test('messaging preview uses viewer-resolved name and handle fallback', () {
    const resolved = MessagingUserPreview(
      id: 'user-bob',
      handle: 'bob',
      displayName: 'Boss',
    );
    const fallback = MessagingUserPreview(
      id: 'user-bob',
      handle: 'bob',
      displayName: '   ',
    );

    expect(resolved.effectiveDisplayName, 'Boss');
    expect(fallback.effectiveDisplayName, 'bob');
    expect(
      effectiveDisplayName(displayName: 'Bob', handle: 'bob', remark: 'Boss'),
      'Boss',
    );
  });
}
