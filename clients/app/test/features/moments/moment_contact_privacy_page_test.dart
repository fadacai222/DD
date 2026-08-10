import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/moments/data/moments_api_client.dart';
import 'package:im_client/features/moments/domain/moment_models.dart';
import 'package:im_client/features/moments/presentation/moment_contact_privacy_page.dart';

void main() {
  testWidgets('contact moments privacy loads and saves both long-term switches', (
    tester,
  ) async {
    final gateway = _PrivacyGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: MomentContactPrivacyPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          targetUserId: 'user-b',
          targetDisplayName: 'Bob',
          onUnauthorized: () async => 'fresh-token',
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('不看他的朋友圈'), findsOneWidget);
    expect(find.text('不让他看我的朋友圈'), findsOneWidget);

    await tester.tap(find.byKey(const Key('moment-contact-hide-target')));
    await tester.pumpAndSettle();
    expect(gateway.lastHideTarget, isTrue);
    expect(gateway.lastHideFromTarget, isFalse);

    await tester.tap(find.byKey(const Key('moment-contact-hide-from-target')));
    await tester.pumpAndSettle();
    expect(gateway.lastHideTarget, isTrue);
    expect(gateway.lastHideFromTarget, isTrue);
  });
}

final class _PrivacyGateway implements MomentsGateway {
  bool lastHideTarget = false;
  bool lastHideFromTarget = false;

  @override
  Future<List<MomentPreference>> listPreferences({
    required Uri origin,
    required String accessToken,
  }) async => const [];

  @override
  Future<MomentPreference> setPreference({
    required Uri origin,
    required String accessToken,
    required String userId,
    required bool hideTarget,
    required bool hideFromTarget,
  }) async {
    lastHideTarget = hideTarget;
    lastHideFromTarget = hideFromTarget;
    return MomentPreference(
      target: const MomentUserPreview(
        id: 'user-b',
        handle: 'bob_01',
        displayName: 'Bob',
      ),
      hideTarget: hideTarget,
      hideFromTarget: hideFromTarget,
      updatedAt: DateTime.utc(2026, 8, 11),
    );
  }

  @override
  Future<List<MomentItem>> listFeed({
    required Uri origin,
    required String accessToken,
    String? before,
    String? authorId,
    int limit = 30,
  }) async => const [];

  @override
  Future<MomentItem> createMoment({
    required Uri origin,
    required String accessToken,
    required String text,
    required List<String> mediaIds,
    required String visibility,
    required List<String> visibilityUserIds,
  }) => throw UnimplementedError();

  @override
  Future<MomentItem> getMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) => throw UnimplementedError();

  @override
  Future<MomentItem> setLike({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required bool liked,
  }) => throw UnimplementedError();

  @override
  Future<MomentItem> addComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String text,
    String? replyToCommentId,
  }) => throw UnimplementedError();

  @override
  Future<MomentItem> deleteComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String commentId,
  }) => throw UnimplementedError();

  @override
  void close() {}
}
