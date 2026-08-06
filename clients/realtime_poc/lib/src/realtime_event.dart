final class RealtimeEvent {
  const RealtimeEvent({
    required this.type,
    required this.requestId,
    required this.eventId,
    required this.payload,
    required this.error,
  });

  final String type;
  final String requestId;
  final int eventId;
  final Map<String, dynamic> payload;
  final RealtimeError? error;

  factory RealtimeEvent.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    final rawError = json['error'];

    return RealtimeEvent(
      type: json['type'] as String? ?? '',
      requestId: json['requestId'] as String? ?? '',
      eventId: (json['eventId'] as num?)?.toInt() ?? 0,
      payload: rawPayload is Map<String, dynamic>
          ? rawPayload
          : <String, dynamic>{},
      error: rawError is Map<String, dynamic>
          ? RealtimeError.fromJson(rawError)
          : null,
    );
  }
}

final class RealtimeError {
  const RealtimeError({required this.code, required this.message});

  final String code;
  final String message;

  factory RealtimeError.fromJson(Map<String, dynamic> json) {
    return RealtimeError(
      code: json['code'] as String? ?? 'UNKNOWN_ERROR',
      message: json['message'] as String? ?? 'Unknown realtime error',
    );
  }
}
