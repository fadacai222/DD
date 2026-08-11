import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/moments/data/moments_api_client.dart';
import 'package:im_client/features/moments/domain/moment_models.dart';
import 'package:im_client/features/moments/presentation/moment_publish_page.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets('text-only moment publishes with all-contact default visibility', (
    tester,
  ) async {
    final gateway = _PublishGateway();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _PublishLauncher(gateway: gateway),
      ),
    );

    await tester.tap(find.text('打开发表页'));
    await tester.pumpAndSettle();
    expect(find.text('发表朋友圈'), findsOneWidget);
    expect(find.text('所有联系人'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('moment-publish-text')),
      '今晚正式上线测试',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('moment-publish-submit')));
    await tester.pumpAndSettle();

    expect(gateway.createdText, '今晚正式上线测试');
    expect(gateway.visibility, 'ALL_CONTACTS');
    expect(gateway.visibilityUserIds, isEmpty);
    expect(find.text('打开发表页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('publish page exposes image and video entry points', (
    tester,
  ) async {
    final gateway = _PublishGateway();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MomentPublishPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('moment-publish-add-media')), findsOneWidget);
    expect(find.byKey(const Key('moment-publish-add-video')), findsOneWidget);
    expect(find.byKey(const Key('moment-publish-visibility')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _PublishLauncher extends StatelessWidget {
  const _PublishLauncher({required this.gateway});

  final MomentsGateway gateway;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (_) => MomentPublishPage(
                origin: Uri.parse('http://127.0.0.1:18473'),
                accessToken: 'token',
                onUnauthorized: () async => 'token',
                gateway: gateway,
              ),
            ),
          ),
          child: const Text('打开发表页'),
        ),
      ),
    );
  }
}

final class _PublishGateway implements MomentsGateway {
  String? createdText;
  String? visibility;
  List<String> visibilityUserIds = const [];

  @override
  Future<MomentItem> createMoment({
    required Uri origin,
    required String accessToken,
    required String text,
    required List<String> mediaIds,
    required String visibility,
    required List<String> visibilityUserIds,
  }) async {
    createdText = text;
    this.visibility = visibility;
    this.visibilityUserIds = List<String>.from(visibilityUserIds);
    return MomentItem(
      id: 'moment-created',
      author: const MomentUserPreview(
        id: 'user-a',
        handle: 'alice',
        displayName: 'Alice',
      ),
      text: text,
      visibility: visibility,
      mediaIds: mediaIds,
      likeUsers: const [],
      comments: const [],
      likedByMe: false,
      createdAt: DateTime.utc(2026, 8, 10, 12),
    );
  }

  @override
  Future<MomentItem> addComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String text,
    String? replyToCommentId,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) => throw UnimplementedError();

  @override
  Future<MomentItem> deleteComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String commentId,
  }) => throw UnimplementedError();

  @override
  Future<MomentItem> getMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) => throw UnimplementedError();

  @override
  Future<List<MomentItem>> listFeed({
    required Uri origin,
    required String accessToken,
    String? before,
    String? authorId,
    int limit = 30,
  }) async => const [];

  @override
  Future<List<MomentPreference>> listPreferences({
    required Uri origin,
    required String accessToken,
  }) async => const [];

  @override
  Future<MomentItem> setLike({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required bool liked,
  }) => throw UnimplementedError();

  @override
  Future<MomentPreference> setPreference({
    required Uri origin,
    required String accessToken,
    required String userId,
    required bool hideTarget,
    required bool hideFromTarget,
  }) => throw UnimplementedError();

  @override
  Future<MomentProfile> getProfile({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => MomentProfile(
    user: MomentUserPreview(id: userId, handle: 'user', displayName: 'User'),
    coverMediaId: '',
    coverRevision: 0,
    canEdit: true,
  );

  @override
  Future<MomentProfile> updateProfile({
    required Uri origin,
    required String accessToken,
    required String userId,
    required String coverMediaId,
  }) async => MomentProfile(
    user: MomentUserPreview(id: userId, handle: 'user', displayName: 'User'),
    coverMediaId: coverMediaId,
    coverRevision: 1,
    canEdit: true,
  );

  @override
  void close() {}
}
