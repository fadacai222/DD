enum CallKind { audio, video }

enum CallSessionStatus { ringing, accepted, rejected, ended }

final class CallSession {
  const CallSession({
    required this.id,
    required this.roomName,
    required this.callerIdentity,
    required this.callerName,
    required this.calleeIdentity,
    required this.kind,
    required this.status,
    required this.createdAt,
    required this.acceptedAt,
    required this.endedAt,
    required this.endReason,
  });

  factory CallSession.fromJson(Map<String, dynamic> json) {
    return CallSession(
      id: _requiredString(json, 'id'),
      roomName: _requiredString(json, 'room_name'),
      callerIdentity: _requiredString(json, 'caller_identity'),
      callerName: _requiredString(json, 'caller_name'),
      calleeIdentity: _requiredString(json, 'callee_identity'),
      kind: _parseKind(_requiredString(json, 'kind')),
      status: _parseStatus(_requiredString(json, 'status')),
      createdAt: DateTime.parse(_requiredString(json, 'created_at')),
      acceptedAt: _optionalDateTime(json['accepted_at']),
      endedAt: _optionalDateTime(json['ended_at']),
      endReason: json['end_reason'] as String? ?? '',
    );
  }

  final String id;
  final String roomName;
  final String callerIdentity;
  final String callerName;
  final String calleeIdentity;
  final CallKind kind;
  final CallSessionStatus status;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final String endReason;

  bool get isActive =>
      status == CallSessionStatus.ringing ||
      status == CallSessionStatus.accepted;

  bool isIncomingFor(String identity) =>
      calleeIdentity == identity && status == CallSessionStatus.ringing;

  bool isOutgoingFor(String identity) => callerIdentity == identity;

  String peerIdentityFor(String identity) =>
      callerIdentity == identity ? calleeIdentity : callerIdentity;

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be a non-empty string');
    }
    return value;
  }

  static DateTime? _optionalDateTime(Object? raw) {
    if (raw == null) return null;
    if (raw is! String || raw.isEmpty) {
      throw const FormatException('Optional date must be an ISO-8601 string');
    }
    return DateTime.parse(raw);
  }

  static CallKind _parseKind(String raw) {
    return switch (raw) {
      'audio' => CallKind.audio,
      'video' => CallKind.video,
      _ => throw FormatException('Unknown call kind: $raw'),
    };
  }

  static CallSessionStatus _parseStatus(String raw) {
    return switch (raw) {
      'ringing' => CallSessionStatus.ringing,
      'accepted' => CallSessionStatus.accepted,
      'rejected' => CallSessionStatus.rejected,
      'ended' => CallSessionStatus.ended,
      _ => throw FormatException('Unknown call status: $raw'),
    };
  }
}
