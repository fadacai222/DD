import 'package:im_client/features/calls/domain/call_token.dart';

final class FakeCallTokenProvider implements CallTokenProvider {
  int issueCalls = 0;
  int closeCalls = 0;

  @override
  Future<CallToken> issue({
    required Uri apiBaseUri,
    required String roomName,
    required String participantIdentity,
    required String participantName,
  }) async {
    issueCalls++;
    return CallToken(
      serverUrl: Uri.parse('ws://127.0.0.1:7880'),
      participantToken: 'fake-token',
      expiresAt: DateTime.utc(2026, 8, 7, 0, 15),
    );
  }

  @override
  void close() {
    closeCalls++;
  }
}
