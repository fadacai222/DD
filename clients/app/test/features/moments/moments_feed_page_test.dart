import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/moments/data/moments_api_client.dart';
import 'package:im_client/features/moments/domain/moment_models.dart';
import 'package:im_client/features/moments/presentation/moments_feed_page.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets('feed renders moment and toggles like through server gateway', (
    tester,
  ) async {
    final gateway = _FakeMomentsGateway();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MomentsFeedPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          currentUserId: 'user-a',
          currentUserDisplayName: 'Alice',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('朋友圈'), findsOneWidget);
    expect(find.text('测试朋友圈正文'), findsOneWidget);
    expect(find.text('Bob'), findsWidgets);
    expect(find.byKey(const Key('moment-moment-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('moment-actions-moment-1')));
    await tester.pumpAndSettle();
    expect(find.text('赞'), findsOneWidget);
    await tester.tap(find.text('赞'));
    await tester.pumpAndSettle();

    expect(gateway.likeCalls, [true]);
    expect(find.text('Alice'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comment action sends text and refreshes interaction box', (
    tester,
  ) async {
    final gateway = _FakeMomentsGateway();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MomentsFeedPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          currentUserId: 'user-a',
          currentUserDisplayName: 'Alice',
          onUnauthorized: () async => 'token',
          gateway: gateway,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('moment-actions-moment-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('moment-comment-input')),
      '评论内容',
    );
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(gateway.comments, ['评论内容']);
    expect(find.textContaining('评论内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _FakeMomentsGateway implements MomentsGateway {
  _FakeMomentsGateway() : item = _initialMoment();

  MomentItem item;
  final List<bool> likeCalls = [];
  final List<String> comments = [];

  @override
  Future<List<MomentItem>> listFeed({
    required Uri origin,
    required String accessToken,
    String? before,
    int limit = 30,
  }) async => [item];

  @override
  Future<MomentItem> setLike({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required bool liked,
  }) async {
    likeCalls.add(liked);
    item = MomentItem(
      id: item.id,
      author: item.author,
      text: item.text,
      visibility: item.visibility,
      mediaIds: item.mediaIds,
      likeUsers: liked
          ? const [
              MomentUserPreview(
                id: 'user-a',
                handle: 'alice',
                displayName: 'Alice',
              ),
            ]
          : const [],
      comments: item.comments,
      likedByMe: liked,
      createdAt: item.createdAt,
    );
    return item;
  }

  @override
  Future<MomentItem> addComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String text,
    String? replyToCommentId,
  }) async {
    comments.add(text);
    item = MomentItem(
      id: item.id,
      author: item.author,
      text: item.text,
      visibility: item.visibility,
      mediaIds: item.mediaIds,
      likeUsers: item.likeUsers,
      comments: [
        ...item.comments,
        MomentComment(
          id: 'comment-${comments.length}',
          author: const MomentUserPreview(
            id: 'user-a',
            handle: 'alice',
            displayName: 'Alice',
          ),
          text: text,
          createdAt: DateTime.utc(2026, 8, 10, 12, 1),
          replyToCommentId: replyToCommentId,
        ),
      ],
      likedByMe: item.likedByMe,
      createdAt: item.createdAt,
    );
    return item;
  }

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
  Future<void> deleteMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) async {}

  @override
  Future<MomentItem> deleteComment({
    required Uri origin,
    required String accessToken,
    required String momentId,
    required String commentId,
  }) async => item;

  @override
  Future<MomentItem> getMoment({
    required Uri origin,
    required String accessToken,
    required String momentId,
  }) async => item;

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
  }) => throw UnimplementedError();

  @override
  void close() {}
}

MomentItem _initialMoment() => MomentItem(
  id: 'moment-1',
  author: const MomentUserPreview(
    id: 'user-b',
    handle: 'bob',
    displayName: 'Bob',
  ),
  text: '测试朋友圈正文',
  visibility: 'ALL_CONTACTS',
  mediaIds: const [],
  likeUsers: const [],
  comments: const [],
  likedByMe: false,
  createdAt: DateTime.utc(2026, 8, 10, 12),
);
