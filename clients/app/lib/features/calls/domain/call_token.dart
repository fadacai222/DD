final class CallToken {
  const CallToken({
    required this.serverUrl,
    required this.participantToken,
    required this.expiresAt,
  });

  final Uri serverUrl;
  final String participantToken;
  final DateTime expiresAt;
}

abstract interface class CallTokenProvider {
  Future<CallToken> issue({
    required Uri apiBaseUri,
    required String roomName,
    required String participantIdentity,
    required String participantName,
  });

  void close();
}
