final class AccountPrivacy {
  const AccountPrivacy({
    required this.allowEmailSearch,
    required this.allowStrangerMessages,
    required this.showOnlineStatus,
    required this.readReceiptsEnabled,
    required this.notificationPreviewEnabled,
  });

  factory AccountPrivacy.fromJson(Map<String, dynamic> json) => AccountPrivacy(
    allowEmailSearch: json['allowEmailSearch'] == true,
    allowStrangerMessages: json['allowStrangerMessages'] == true,
    showOnlineStatus: json['showOnlineStatus'] == true,
    readReceiptsEnabled: json['readReceiptsEnabled'] == true,
    notificationPreviewEnabled: json['notificationPreviewEnabled'] == true,
  );

  final bool allowEmailSearch;
  final bool allowStrangerMessages;
  final bool showOnlineStatus;
  final bool readReceiptsEnabled;
  final bool notificationPreviewEnabled;

  Map<String, dynamic> toJson() => {
    'allowEmailSearch': allowEmailSearch,
    'allowStrangerMessages': allowStrangerMessages,
    'showOnlineStatus': showOnlineStatus,
    'readReceiptsEnabled': readReceiptsEnabled,
    'notificationPreviewEnabled': notificationPreviewEnabled,
  };
}

final class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.email,
    required this.handle,
    required this.displayName,
    required this.bio,
  });

  factory AccountProfile.fromJson(Map<String, dynamic> json) => AccountProfile(
    id: json['id'] as String,
    email: json['email'] as String,
    handle: json['handle'] as String,
    displayName: json['displayName'] as String,
    bio: json['bio'] is String ? json['bio'] as String : '',
  );

  final String id;
  final String email;
  final String handle;
  final String displayName;
  final String bio;
}

final class AccountMe {
  const AccountMe({required this.profile, required this.privacy});

  factory AccountMe.fromJson(Map<String, dynamic> json) => AccountMe(
    profile: AccountProfile.fromJson(json['profile'] as Map<String, dynamic>),
    privacy: AccountPrivacy.fromJson(json['privacy'] as Map<String, dynamic>),
  );

  final AccountProfile profile;
  final AccountPrivacy privacy;
}

final class AccountDevice {
  const AccountDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.appVersion,
    required this.createdAt,
    required this.lastSeenAt,
    required this.current,
    required this.revoked,
  });

  factory AccountDevice.fromJson(Map<String, dynamic> json) => AccountDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: json['platform'] as String,
    appVersion: json['appVersion'] is String
        ? json['appVersion'] as String
        : '',
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    lastSeenAt: DateTime.parse(json['lastSeenAt'] as String).toUtc(),
    current: json['current'] == true,
    revoked: json['revokedAt'] != null,
  );

  final String id;
  final String name;
  final String platform;
  final String appVersion;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final bool current;
  final bool revoked;
}
