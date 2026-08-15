import '../../../shared/identity/effective_display_name.dart' as identity;

final class ContactUser {
  const ContactUser({
    required this.id,
    required this.handle,
    required this.displayName,
    required this.bio,
  });

  factory ContactUser.fromJson(Map<String, dynamic> json) => ContactUser(
    id: json['id'] as String,
    handle: json['handle'] as String,
    displayName: json['displayName'] as String,
    bio: (json['bio'] as String?) ?? '',
  );

  final String id;
  final String handle;
  final String displayName;
  final String bio;

  String get effectiveDisplayName =>
      identity.effectiveDisplayName(displayName: displayName, handle: handle);
}

final class ContactMentionSuggestion {
  const ContactMentionSuggestion({
    required this.user,
    required this.relationship,
    this.viewerDisplayName = '',
  });

  factory ContactMentionSuggestion.fromJson(Map<String, dynamic> json) =>
      ContactMentionSuggestion(
        user: ContactUser.fromJson(json['user'] as Map<String, dynamic>),
        relationship: (json['relationship'] as String?) ?? 'NONE',
        viewerDisplayName: json['effectiveDisplayName']?.toString() ?? '',
      );

  final ContactUser user;
  final String relationship;
  final String viewerDisplayName;

  String get effectiveDisplayName => identity.effectiveDisplayName(
    displayName: viewerDisplayName.trim().isEmpty
        ? user.displayName
        : viewerDisplayName,
    handle: user.handle,
  );
}

final class ContactSearchResult {
  const ContactSearchResult({
    required this.user,
    required this.relationship,
    this.viewerDisplayName = '',
  });

  factory ContactSearchResult.fromJson(Map<String, dynamic> json) =>
      ContactSearchResult(
        user: ContactUser.fromJson(json['user'] as Map<String, dynamic>),
        relationship: json['relationship'] as String,
        viewerDisplayName: json['effectiveDisplayName']?.toString() ?? '',
      );

  final ContactUser user;
  final String relationship;
  final String viewerDisplayName;

  String get effectiveDisplayName => identity.effectiveDisplayName(
    displayName: viewerDisplayName.trim().isEmpty
        ? user.displayName
        : viewerDisplayName,
    handle: user.handle,
  );
}

final class ContactRequestItem {
  const ContactRequestItem({
    required this.id,
    required this.sender,
    required this.receiver,
    required this.message,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.resolvedAt,
    this.conversationId,
  });

  factory ContactRequestItem.fromJson(Map<String, dynamic> json) =>
      ContactRequestItem(
        id: json['id'] as String,
        sender: ContactUser.fromJson(json['sender'] as Map<String, dynamic>),
        receiver: ContactUser.fromJson(
          json['receiver'] as Map<String, dynamic>,
        ),
        message: (json['message'] as String?) ?? '',
        status: json['status'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        resolvedAt: json['resolvedAt'] == null
            ? null
            : DateTime.parse(json['resolvedAt'] as String),
        conversationId: json['conversationId'] as String?,
      );

  final String id;
  final ContactUser sender;
  final ContactUser receiver;
  final String message;
  final String status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? resolvedAt;
  final String? conversationId;
}

final class ContactItem {
  const ContactItem({
    required this.user,
    required this.remark,
    required this.isStarred,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ContactItem.fromJson(Map<String, dynamic> json) => ContactItem(
    user: ContactUser.fromJson(json['user'] as Map<String, dynamic>),
    remark: (json['remark'] as String?) ?? '',
    isStarred: (json['isStarred'] as bool?) ?? false,
    tags: ((json['tags'] as List?) ?? const [])
        .map((value) => value as String)
        .toList(growable: false),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  final ContactUser user;
  final String remark;
  final bool isStarred;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get effectiveDisplayName => identity.effectiveDisplayName(
    displayName: user.displayName,
    handle: user.handle,
    remark: remark,
  );
}

final class BlockedUserItem {
  const BlockedUserItem({required this.user, required this.createdAt});

  factory BlockedUserItem.fromJson(Map<String, dynamic> json) =>
      BlockedUserItem(
        user: ContactUser.fromJson(json['user'] as Map<String, dynamic>),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  final ContactUser user;
  final DateTime createdAt;
}

final class RelationshipPage<T> {
  const RelationshipPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.totalItems,
    required this.totalPages,
  });

  final List<T> items;
  final int page;
  final int pageSize;
  final int totalItems;
  final int totalPages;
}
