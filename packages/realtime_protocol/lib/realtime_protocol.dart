const int ddRealtimeProtocolVersion = 1;

enum RealtimeType {
  hello('HELLO'),
  helloAck('HELLO_ACK'),
  eventAvailable('EVENT_AVAILABLE'),
  ping('PING'),
  pong('PONG'),
  error('ERROR');

  const RealtimeType(this.wireValue);
  final String wireValue;

  static RealtimeType parse(String value) {
    return values.firstWhere(
      (type) => type.wireValue == value,
      orElse: () => throw FormatException('Unsupported realtime type: $value'),
    );
  }
}

final class RealtimeEnvelope {
  const RealtimeEnvelope({
    required this.type,
    this.protocolVersion,
    this.deviceId,
    this.lastCursor,
    this.connectionId,
    this.serverTime,
    this.eventId,
    this.cursor,
    this.timestamp,
    this.code,
    this.message,
    this.requestId,
  });

  factory RealtimeEnvelope.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'];
    if (rawType is! String) {
      throw const FormatException('type is required');
    }
    final envelope = RealtimeEnvelope(
      type: RealtimeType.parse(rawType),
      protocolVersion: json['protocolVersion'] as int?,
      deviceId: json['deviceId'] as String?,
      lastCursor: json['lastCursor'] as String?,
      connectionId: json['connectionId'] as String?,
      serverTime: json['serverTime'] as String?,
      eventId: json['eventId'] as String?,
      cursor: json['cursor'] as String?,
      timestamp: json['timestamp'] as int?,
      code: json['code'] as String?,
      message: json['message'] as String?,
      requestId: json['requestId'] as String?,
    );
    envelope.validate();
    return envelope;
  }

  final RealtimeType type;
  final int? protocolVersion;
  final String? deviceId;
  final String? lastCursor;
  final String? connectionId;
  final String? serverTime;
  final String? eventId;
  final String? cursor;
  final int? timestamp;
  final String? code;
  final String? message;
  final String? requestId;

  void validate() {
    switch (type) {
      case RealtimeType.hello:
        if (protocolVersion != ddRealtimeProtocolVersion) {
          throw const FormatException('protocolVersion must be 1');
        }
        if (!_isDeviceId(deviceId)) {
          throw const FormatException('deviceId is invalid');
        }
        if (lastCursor != null && lastCursor!.length > 256) {
          throw const FormatException('lastCursor is too long');
        }
      case RealtimeType.helloAck:
        if (protocolVersion != ddRealtimeProtocolVersion) {
          throw const FormatException('protocolVersion must be 1');
        }
        if (connectionId == null || connectionId!.length < 8 || connectionId!.length > 128) {
          throw const FormatException('connectionId is invalid');
        }
        if (serverTime == null || DateTime.tryParse(serverTime!) == null) {
          throw const FormatException('serverTime must be a date-time');
        }
      case RealtimeType.eventAvailable:
        if (eventId == null || eventId!.isEmpty || eventId!.length > 128) {
          throw const FormatException('eventId is invalid');
        }
        if (cursor == null || cursor!.isEmpty || cursor!.length > 256) {
          throw const FormatException('cursor is invalid');
        }
      case RealtimeType.ping:
      case RealtimeType.pong:
        if (timestamp == null || timestamp! < 0) {
          throw const FormatException('timestamp must be non-negative');
        }
      case RealtimeType.error:
        if (!_isErrorCode(code)) {
          throw const FormatException('code is invalid');
        }
        if (message == null || message!.isEmpty || message!.length > 300) {
          throw const FormatException('message is invalid');
        }
    }
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{'type': type.wireValue};
    void put(String key, Object? value) {
      if (value != null) result[key] = value;
    }

    put('protocolVersion', protocolVersion);
    put('deviceId', deviceId);
    if (type == RealtimeType.hello) {
      result['lastCursor'] = lastCursor;
    }
    put('connectionId', connectionId);
    put('serverTime', serverTime);
    put('eventId', eventId);
    put('cursor', cursor);
    put('timestamp', timestamp);
    put('code', code);
    put('message', message);
    put('requestId', requestId);
    return result;
  }
}

bool _isDeviceId(String? value) {
  if (value == null) return false;
  return RegExp(r'^dev_[A-Za-z0-9_-]{8,128}$').hasMatch(value);
}

bool _isErrorCode(String? value) {
  if (value == null) return false;
  return RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(value);
}
