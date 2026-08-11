final class GroupCallUser {
  const GroupCallUser({
    required this.id,
    required this.handle,
    required this.displayName,
  });

  factory GroupCallUser.fromJson(Map<String, dynamic> json) => GroupCallUser(
    id: json['id']?.toString() ?? '',
    handle: json['handle']?.toString() ?? '',
    displayName: json['displayName']?.toString() ?? '',
  );

  final String id;
  final String handle;
  final String displayName;
}

final class GroupCallParticipantInfo {
  const GroupCallParticipantInfo({
    required this.user,
    required this.joinedAt,
  });

  factory GroupCallParticipantInfo.fromJson(Map<String, dynamic> json) =>
      GroupCallParticipantInfo(
        user: GroupCallUser.fromJson(json['user'] as Map<String, dynamic>),
        joinedAt: DateTime.parse(json['joinedAt'] as String).toUtc(),
      );

  final GroupCallUser user;
  final DateTime joinedAt;
}

final class GroupCallInfo {
  const GroupCallInfo({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.status,
    required this.startedBy,
    required this.startedAt,
    required this.maxParticipants,
    required this.participants,
  });

  factory GroupCallInfo.fromJson(Map<String, dynamic> json) => GroupCallInfo(
    id: json['id']?.toString() ?? '',
    groupId: json['groupId']?.toString() ?? '',
    kind: (json['kind']?.toString() ?? 'AUDIO').toUpperCase(),
    status: (json['status']?.toString() ?? 'ACTIVE').toUpperCase(),
    startedBy: GroupCallUser.fromJson(
      json['startedBy'] as Map<String, dynamic>,
    ),
    startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
    maxParticipants: (json['maxParticipants'] as num?)?.toInt() ?? 32,
    participants: (json['participants'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GroupCallParticipantInfo.fromJson)
        .toList(growable: false),
  );

  final String id;
  final String groupId;
  final String kind;
  final String status;
  final GroupCallUser startedBy;
  final DateTime startedAt;
  final int maxParticipants;
  final List<GroupCallParticipantInfo> participants;

  bool get isVideo => kind == 'VIDEO';
  bool get isActive => status == 'ACTIVE';
}

final class GroupCallJoinInfo {
  const GroupCallJoinInfo({
    required this.call,
    required this.liveKitUrl,
    required this.token,
  });

  factory GroupCallJoinInfo.fromJson(Map<String, dynamic> json) =>
      GroupCallJoinInfo(
        call: GroupCallInfo.fromJson(json['call'] as Map<String, dynamic>),
        liveKitUrl: json['livekitUrl']?.toString() ?? '',
        token: json['token']?.toString() ?? '',
      );

  final GroupCallInfo call;
  final String liveKitUrl;
  final String token;
}
