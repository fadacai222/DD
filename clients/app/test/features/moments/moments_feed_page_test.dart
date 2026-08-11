import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:im_client/features/messaging/data/media_api_client.dart';
import 'package:im_client/features/moments/data/moments_api_client.dart';
import 'package:im_client/features/moments/domain/moment_models.dart';
import 'package:im_client/features/moments/presentation/moments_feed_page.dart';
import 'package:im_client/theme/app_theme.dart';

void main() {
  testWidgets('personal feed scopes requests to one author and hides own actions', (
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
  });

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

  testWidgets('expired media token refreshes instead of poisoning feed media', (
    tester,
  ) async {
    final mediaAuthorizations = <String>[];
    final api = MediaApiClient(
      httpClient: MockClient((request) async {
        final authorization = request.headers['authorization'] ?? '';
        mediaAuthorizations.add('${request.method} ${request.url.path} $authorization');
        if (authorization == 'Bearer stale-token') {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'UNAUTHORIZED',
                'message': 'expired',
              },
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
}

final class _FakeMomentsGateway implements MomentsGateway {
  _FakeMomentsGateway({MomentItem? initialItem})
    : item = initialItem ?? _initialMoment();

  MomentItem item;
  final List<bool> likeCalls = [];
  final List<String> comments = [];
  final List<String?> listAuthorIds = [];

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
  void close() {}
}

MomentItem _initialMoment({List<String> mediaIds = const []}) => MomentItem(
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
  comments: const [],
  likedByMe: false,
  createdAt: DateTime.utc(2026, 8, 10, 12),
);
