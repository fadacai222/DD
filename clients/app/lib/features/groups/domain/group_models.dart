import '../../../shared/identity/effective_display_name.dart' as identity;

final class GroupUserPreview {
  const GroupUserPreview({
    required this.id,
    required this.handle,
    required this.displayName,
  });

  factory GroupUserPreview.fromJson(Map<String, dynamic> json) =>
      GroupUserPreview(
        id: _requiredString(json, 'id'),
        handle: _requiredString(json, 'handle'),
        displayName: _requiredString(json, 'displayName'),
      );

  final String id;
  final String handle;
  final String displayName;

  String get effectiveDisplayName =>
      identity.effectiveDisplayName(displayName: displayName, handle: handle);
}

final class GroupInfo {
  const GroupInfo({
    required this.id,
    required this.name,
    required this.announcement,
    required this.joinMode,
    required this.status,
    required this.memberCount,
    this.avatarMediaId = '',
    this.avatarRevision = 0,
    required this.ownerUserId,
    required this.myRole,
    required this.myNickname,
    required this.createdAt,
    required this.updatedAt,
  });

  factory GroupInfo.fromJson(Map<String, dynamic> json) => GroupInfo(
    id: _requiredString(json, 'id'),
    name: _requiredString(json, 'name'),
    announcement: json['announcement']?.toString() ?? '',
    joinMode: _requiredString(json, 'joinMode'),
    status: _requiredString(json, 'status'),
    memberCount: _requiredInt(json, 'memberCount'),
    avatarMediaId: json['avatarMediaId']?.toString() ?? '',
    avatarRevision: json['avatarRevision'] is int
        ? json['avatarRevision'] as int
        : 0,
    ownerUserId: _requiredString(json, 'ownerUserId'),
    myRole: _requiredString(json, 'myRole'),
    myNickname: json['myNickname']?.toString() ?? '',
    createdAt: _requiredDate(json, 'createdAt'),
    updatedAt: _requiredDate(json, 'updatedAt'),
  );

  final String id;
  final String name;
  final String announcement;
  final String joinMode;
  final String status;
  final int memberCount;
  final String avatarMediaId;
  final int avatarRevision;
  final String ownerUserId;
  final String myRole;
  final String myNickname;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get canManage => myRole == 'OWNER' || myRole == 'ADMIN';
  bool get isOwner => myRole == 'OWNER';
}

final class GroupMemberItem {
  const GroupMemberItem({
    required this.user,
    required this.role,
    required this.nickname,
    required this.joinedAt,
  });

  factory GroupMemberItem.fromJson(Map<String, dynamic> json) {
    final user = json['user'];
    if (user is! Map) throw const FormatException('群成员用户信息格式错误。');
    return GroupMemberItem(
      user: GroupUserPreview.fromJson(_stringMap(user)),
      role: _requiredString(json, 'role'),
      nickname: json['nickname']?.toString() ?? '',
      joinedAt: _requiredDate(json, 'joinedAt'),
    );
  }

  final GroupUserPreview user;
  final String role;
  final String nickname;
  final DateTime joinedAt;

  String get effectiveName =>
      nickname.trim().isEmpty ? user.effectiveDisplayName : nickname.trim();
}

final class GroupJoinRequestItem {
  const GroupJoinRequestItem({
    required this.id,
    required this.groupId,
    required this.requester,
    required this.message,
    required this.status,
    required this.createdAt,
  });

  factory GroupJoinRequestItem.fromJson(Map<String, dynamic> json) {
    final requester = json['requester'];
    if (requester is! Map) throw const FormatException('入群申请用户信息格式错误。');
    return GroupJoinRequestItem(
      id: _requiredString(json, 'id'),
      groupId: _requiredString(json, 'groupId'),
      requester: GroupUserPreview.fromJson(_stringMap(requester)),
      message: json['message']?.toString() ?? '',
      status: _requiredString(json, 'status'),
      createdAt: _requiredDate(json, 'createdAt'),
    );
  }

  final String id;
  final String groupId;
  final GroupUserPreview requester;
  final String message;
  final String status;
  final DateTime createdAt;
}

Map<String, dynamic> _stringMap(Map<dynamic, dynamic> value) => value.map(
  (key, item) => MapEntry(key.toString(), item),
);

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim() ?? '';
  if (value.isEmpty) throw FormatException('$key is required');
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key must be an integer');
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final value = DateTime.tryParse(json[key]?.toString() ?? '');
  if (value == null) throw FormatException('$key must be a date-time');
  return value.toUtc();
}
