import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/data/contacts_api_client.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/messaging/presentation/desktop_mention_profile_dialog.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets(
    'desktop mention profile opens as a centered Telegram-style modal',
    (tester) async {
      tester.view.physicalSize = const Size(881, 657);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final gateway = _MentionProfileGateway();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showDesktopMentionProfileDialog(
                    context: context,
                    origin: Uri.parse('http://127.0.0.1:18473'),
                    accessToken: 'token',
                    userId: _user.id,
                    handle: _user.handle,
                    displayName: _user.displayName,
                    gateway: gateway,
                    onMessage: () async {},
                    onAudioCall: () async {},
                    onVideoCall: () async {},
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      final dialog = find.byKey(const Key('desktop-mention-profile-dialog'));
      expect(dialog, findsOneWidget);
      final dialogSize = tester.getSize(dialog);
      expect(dialogSize.width, closeTo(530, 1));
      expect(dialogSize.height, lessThanOrEqualTo(630));
      expect(dialogSize.height, greaterThan(580));

      final infoCardSize = tester.getSize(
        find.byKey(const Key('peer-profile-info-card')),
      );
      expect(infoCardSize.width, greaterThan(450));
      expect(
        find.byKey(const Key('peer-profile-dialog-close')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('peer-profile-quick-actions')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('peer-profile-desktop-more')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('peer-profile-more')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('peer-profile-dialog-close')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    },
  );
}

const _user = ContactUser(
  id: '018f0000-0000-7000-8000-000000000499',
  handle: 'alice_01',
  displayName: 'Alice',
  bio: 'Hello from DD',
);

final class _MentionProfileGateway implements ContactsGateway {
  @override
  Future<ContactSearchResult> getUserById({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => const ContactSearchResult(user: _user, relationship: 'CONTACT');

  @override
  Future<RelationshipPage<ContactItem>> listContacts({
    required Uri origin,
    required String accessToken,
  }) async => RelationshipPage<ContactItem>(
    items: [
      ContactItem(
        user: _user,
        remark: '',
        isStarred: false,
        tags: const [],
        createdAt: DateTime.utc(2026, 8, 12),
        updatedAt: DateTime.utc(2026, 8, 12),
      ),
    ],
    page: 1,
    pageSize: 1,
    totalItems: 1,
    totalPages: 1,
  );

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
