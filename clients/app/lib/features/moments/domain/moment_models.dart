final class MomentUserPreview {
  const MomentUserPreview({
    required this.id,
    required this.handle,
    required this.displayName,
  });

  factory MomentUserPreview.fromJson(Map<String, dynamic> json) =>
      MomentUserPreview(
        id: json['id'] as String? ?? '',
        handle: json['handle'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
      );

  final String id;
  final String handle;
  final String displayName;
}

final class MomentComment {
  const MomentComment({
    required this.id,
    required this.author,
    required this.text,
    required this.createdAt,
    this.replyToCommentId,
  });

  factory MomentComment.fromJson(Map<String, dynamic> json) => MomentComment(
    id: json['id'] as String? ?? '',
    author: MomentUserPreview.fromJson(json['author'] as Map<String, dynamic>),
    text: json['text'] as String? ?? '',
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    replyToCommentId: json['replyToCommentId'] as String?,
  );

  final String id;
  final MomentUserPreview author;
  final String text;
  final DateTime createdAt;
  final String? replyToCommentId;
}

final class MomentItem {
  const MomentItem({
    required this.id,
    required this.author,
    required this.text,
    required this.visibility,
    required this.mediaIds,
    required this.likeUsers,
    required this.comments,
    required this.likedByMe,
    required this.createdAt,
  });

  factory MomentItem.fromJson(Map<String, dynamic> json) => MomentItem(
    id: json['id'] as String? ?? '',
    author: MomentUserPreview.fromJson(json['author'] as Map<String, dynamic>),
    text: json['text'] as String? ?? '',
    visibility: json['visibility'] as String? ?? 'ALL_CONTACTS',
    mediaIds: (json['mediaIds'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(growable: false),
    likeUsers: (json['likeUsers'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MomentUserPreview.fromJson)
        .toList(growable: false),
    comments: (json['comments'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MomentComment.fromJson)
        .toList(growable: false),
    likedByMe: json['likedByMe'] as bool? ?? false,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
  );

  final String id;
  final MomentUserPreview author;
  final String text;
  final String visibility;
  final List<String> mediaIds;
  final List<MomentUserPreview> likeUsers;
  final List<MomentComment> comments;
  final bool likedByMe;
  final DateTime createdAt;
}

final class MomentPreference {
  const MomentPreference({
    required this.target,
    required this.hideTarget,
    required this.hideFromTarget,
    required this.updatedAt,
  });

  factory MomentPreference.fromJson(Map<String, dynamic> json) =>
      MomentPreference(
        target: MomentUserPreview.fromJson(
          json['target'] as Map<String, dynamic>,
        ),
        hideTarget: json['hideTarget'] as bool? ?? false,
        hideFromTarget: json['hideFromTarget'] as bool? ?? false,
        updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      );

  final MomentUserPreview target;
  final bool hideTarget;
  final bool hideFromTarget;
  final DateTime updatedAt;
}
