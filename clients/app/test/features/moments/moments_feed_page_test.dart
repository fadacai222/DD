import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';
import 'package:im_client/features/messaging/data/video_media_probe.dart';
import 'package:im_client/features/messaging/presentation/widgets/inline_video_preview.dart';
import 'package:im_client/features/moments/data/moments_api_client.dart';
import 'package:im_client/features/moments/domain/moment_models.dart';
import 'package:im_client/features/moments/presentation/moments_feed_page.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets(
    'personal feed scopes requests to one author and hides own actions',
    (tester) async {
      final gateway = _FakeMomentsGateway();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MomentsFeedPage(
            origin: Uri.parse('http://127.0.0.1:18473'),
            accessToken: 'token',
            currentUserId: 'user-a',
            currentUserDisplayName: 'Alice',
            authorId: 'user-b',
            authorDisplayName: 'Bob',
            onUnauthorized: () async => 'token',
            gateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(gateway.listAuthorIds, ['user-b']);
      expect(find.text('Bob的朋友圈'), findsOneWidget);
      expect(find.byKey(const Key('moments-publish')), findsNothing);
      expect(find.byKey(const Key('moments-privacy')), findsNothing);
      expect(find.byKey(const Key('moments-personal-header')), findsOneWidget);
      expect(find.byKey(const Key('moments-edit-cover')), findsNothing);
      expect(find.text('测试朋友圈正文'), findsOneWidget);
    },
  );

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
    expect(find.byKey(const Key('moments-privacy')), findsNothing);
    expect(find.text('测试朋友圈正文'), findsOneWidget);
    expect(find.text('Bob'), findsWidgets);
    expect(find.byKey(const Key('moment-moment-1')), findsOneWidget);
    expect(find.byKey(const Key('moments-edit-cover')), findsOneWidget);

    expect(find.byKey(const Key('moment-like-moment-1')), findsOneWidget);
    expect(find.byKey(const Key('moment-comment-moment-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('moment-like-moment-1')));
    await tester.pumpAndSettle();

    expect(gateway.likeCalls, [true]);
    expect(find.text('Alice'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('top activity focus opens recent likes and comments', (
    tester,
  ) async {
    final gateway = _FakeMomentsGateway()
      ..activitySummary = MomentActivitySummary(
        unreadCount: 2,
        items: [
          MomentActivityItem(
            id: 'activity-like',
            kind: 'LIKE',
            actor: const MomentUserPreview(
              id: 'user-like',
              handle: 'liker',
              displayName: '点赞的人',
            ),
            momentId: 'moment-1',
            createdAt: DateTime.utc(2026, 8, 12, 3, 58),
            read: false,
          ),
          MomentActivityItem(
            id: 'activity-comment',
            kind: 'COMMENT',
            actor: const MomentUserPreview(
              id: 'user-comment',
              handle: 'commenter',
              displayName: '评论的人',
            ),
            momentId: 'moment-1',
            commentId: 'comment-activity',
            commentText: '这条很有意思',
            createdAt: DateTime.utc(2026, 8, 12, 3, 57),
            read: false,
          ),
        ],
      );

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

    expect(find.byKey(const Key('moments-activity-focus')), findsOneWidget);
    expect(find.text('2 条新互动'), findsOneWidget);
    expect(find.textContaining('点赞的人'), findsOneWidget);

    await tester.tap(find.byKey(const Key('moments-activity-focus')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('moments-activity-sheet')), findsOneWidget);
    expect(find.text('互动消息'), findsOneWidget);
    expect(find.text('点赞的人'), findsWidgets);
    expect(find.text('赞了你的朋友圈'), findsOneWidget);
    expect(find.text('评论的人'), findsOneWidget);
    expect(find.text('评论了你：这条很有意思'), findsOneWidget);
    expect(gateway.markActivityReadCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired media token refreshes instead of poisoning feed media', (
    tester,
  ) async {
    final mediaAuthorizations = <String>[];
    final api = MediaApiClient(
      httpClient: MockClient((request) async {
        final authorization = request.headers['authorization'] ?? '';
        mediaAuthorizations.add(
          '${request.method} ${request.url.path} $authorization',
        );
        if (authorization == 'Bearer stale-token') {
          return http.Response(
            jsonEncode({
              'error': {'code': 'UNAUTHORIZED', 'message': 'expired'},
            }),
            401,
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/api/v1/media/media-1') {
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'media-1',
                'originalName': 'image.jpg',
                'mimeType': 'image/jpeg',
                'sizeBytes': 16,
                'purpose': 'MOMENT_IMAGE',
                'status': 'READY',
              },
            }),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/v1/media/media-1/download-url') {
          return http.Response(
            jsonEncode({
              'data': {
                'downloadUrl': 'https://media.invalid/image.jpg',
                'expiresAt': '2026-08-11T12:00:00Z',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(api.close);
    var refreshCalls = 0;
    final gateway = _FakeMomentsGateway(
      initialItem: _initialMoment(mediaIds: const ['media-1']),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MomentsFeedPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'stale-token',
          currentUserId: 'user-a',
          currentUserDisplayName: 'Alice',
          onUnauthorized: () async {
            refreshCalls++;
            return 'fresh-token';
          },
          gateway: gateway,
          mediaApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(refreshCalls, greaterThanOrEqualTo(1));
    expect(
      mediaAuthorizations,
      contains('GET /api/v1/media/media-1 Bearer fresh-token'),
    );
    expect(
      mediaAuthorizations,
      contains('POST /api/v1/media/media-1/download-url Bearer fresh-token'),
    );
  });

  testWidgets('failed media metadata is evicted so a later rebuild can retry', (
    tester,
  ) async {
    var mediaInfoCalls = 0;
    final api = MediaApiClient(
      httpClient: MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/api/v1/media/media-1') {
          mediaInfoCalls++;
          if (mediaInfoCalls == 1) {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'MEDIA_TEMPORARY_FAILURE',
                  'message': 'temporary',
                },
              }),
              503,
            );
          }
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'media-1',
                'originalName': 'image.jpg',
                'mimeType': 'image/jpeg',
                'sizeBytes': 16,
                'purpose': 'MOMENT_IMAGE',
                'status': 'READY',
              },
            }),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/v1/media/media-1/download-url') {
          return http.Response(
            jsonEncode({
              'data': {
                'downloadUrl': 'https://media.invalid/image.jpg',
                'expiresAt': '2026-08-11T12:00:00Z',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(api.close);
    final gateway = _FakeMomentsGateway(
      initialItem: _initialMoment(mediaIds: const ['media-1']),
    );

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
          mediaApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(mediaInfoCalls, 1);

    await tester.tap(find.byKey(const Key('moment-like-moment-1')));
    await tester.pumpAndSettle();

    expect(mediaInfoCalls, 2);
  });

  testWidgets('video moment uses poster preview and visible autoplay player', (
    tester,
  ) async {
    final api = MediaApiClient(
      httpClient: MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/api/v1/media/video-1') {
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'video-1',
                'originalName': 'moment.mp4',
                'mimeType': 'video/mp4',
                'sizeBytes': 1024,
                'purpose': 'MOMENT_VIDEO',
                'status': 'READY',
              },
            }),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/v1/media/video-1/download-url') {
          return http.Response(
            jsonEncode({
              'data': {
                'downloadUrl': 'https://media.invalid/moment.mp4',
                'expiresAt': '2026-08-12T12:00:00Z',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(api.close);
    final gateway = _FakeMomentsGateway(
      initialItem: _initialMoment(mediaIds: const ['video-1']),
    );
    var videoMetadataCalls = 0;
    final videoMetadata = Completer<VideoMediaMetadata>();

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
          mediaApi: api,
          videoMetadataLoader: (_) {
            videoMetadataCalls++;
            return videoMetadata.future;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(videoMetadataCalls, 1);
    expect(find.byKey(const Key('moment-video-video-1')), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    videoMetadata.complete(
      VideoMediaMetadata(
        width: 1920,
        height: 1080,
        durationMs: 27000,
        posterJpeg: _posterPng,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试朋友圈正文'), findsOneWidget);
    expect(find.text('点击播放'), findsNothing);
    final previewFinder = find.byType(InlineVideoPreview);
    expect(previewFinder, findsOneWidget);
    final preview = tester.widget<InlineVideoPreview>(previewFinder);
    expect(preview.posterBytes, _posterPng);
    expect(preview.declaredDuration, const Duration(seconds: 27));
    expect(preview.autoPlayWhenVisible, isTrue);
    expect(preview.openFullOnTap, isTrue);
    expect(preview.scrollListenable, isNotNull);
    final ratio = tester.widget<AspectRatio>(
      find
          .ancestor(of: previewFinder, matching: find.byType(AspectRatio))
          .first,
    );
    expect(ratio.aspectRatio, closeTo(16 / 9, 0.001));

    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
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

    await tester.tap(find.byKey(const Key('moment-comment-moment-1')));
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

  testWidgets('reply comment prefers reply target nickname over DDID', (
    tester,
  ) async {
    final gateway = _FakeMomentsGateway(
      initialItem: _initialMoment(
        comments: [
          MomentComment(
            id: 'comment-bob',
            author: const MomentUserPreview(
              id: 'user-b',
              handle: 'tisen05',
              displayName: '铁森',
            ),
            text: '有点意思',
            createdAt: DateTime.utc(2026, 8, 10, 12, 1),
          ),
        ],
      ),
    );
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

    await tester.tap(find.textContaining('有点意思'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('moment-comment-input')),
      '我也觉得有点意思',
    );
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(gateway.replyToCommentIds, ['comment-bob']);
    expect(find.textContaining('Alice 回复@铁森：我也觉得有点意思'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _FakeMomentsGateway
    implements MomentsGateway, MomentActivityGateway {
  _FakeMomentsGateway({MomentItem? initialItem})
    : item = initialItem ?? _initialMoment();

  MomentItem item;
  final List<bool> likeCalls = [];
  final List<String> comments = [];
  final List<String?> replyToCommentIds = [];
  final List<String?> listAuthorIds = [];
  MomentActivitySummary activitySummary = const MomentActivitySummary(
    unreadCount: 0,
  );
  int markActivityReadCalls = 0;

  @override
  Future<List<MomentItem>> listFeed({
    required Uri origin,
    required String accessToken,
    String? before,
    String? authorId,
    int limit = 30,
  }) async {
    listAuthorIds.add(authorId);
    return [item];
  }

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
    replyToCommentIds.add(replyToCommentId);
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
  Future<MomentProfile> getProfile({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async => MomentProfile(
    user: MomentUserPreview(
      id: userId,
      handle: userId == 'user-a' ? 'alice' : 'bob',
      displayName: userId == 'user-a' ? 'Alice' : 'Bob',
    ),
    coverMediaId: '',
    coverRevision: 0,
    canEdit: userId == 'user-a',
  );

  @override
  Future<MomentProfile> updateProfile({
    required Uri origin,
    required String accessToken,
    required String userId,
    required String coverMediaId,
  }) async => MomentProfile(
    user: MomentUserPreview(id: userId, handle: 'alice', displayName: 'Alice'),
    coverMediaId: coverMediaId,
    coverRevision: 1,
    canEdit: true,
  );

  @override
  Future<MomentActivitySummary> getActivitySummary({
    required Uri origin,
    required String accessToken,
  }) async => activitySummary;

  @override
  Future<MomentActivitySummary> markActivityRead({
    required Uri origin,
    required String accessToken,
  }) async {
    markActivityReadCalls++;
    activitySummary = MomentActivitySummary(
      unreadCount: 0,
      items: activitySummary.items
          .map((item) => item.copyWith(read: true))
          .toList(growable: false),
    );
    return activitySummary;
  }

  @override
  void close() {}
}

final _posterPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

MomentItem _initialMoment({
  List<String> mediaIds = const [],
  List<MomentComment> comments = const [],
}) => MomentItem(
  id: 'moment-1',
  author: const MomentUserPreview(
    id: 'user-b',
    handle: 'bob',
    displayName: 'Bob',
  ),
  text: '测试朋友圈正文',
  visibility: 'ALL_CONTACTS',
  mediaIds: mediaIds,
  likeUsers: const [],
  comments: comments,
  likedByMe: false,
  createdAt: DateTime.utc(2026, 8, 10, 12),
);
