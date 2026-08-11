import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/moments/application/moment_activity_controller.dart';
import 'package:im_client/features/moments/data/moments_api_client.dart';
import 'package:im_client/features/moments/domain/moment_models.dart';

void main() {
  test('loads durable unread count and refreshes only for Moments hints', () async {
    final gateway = _FakeMomentActivityGateway()..unreadCount = 2;
    final controller = MomentActivityController(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      gateway: gateway,
    );
    addTearDown(controller.dispose);

    await controller.refresh();
    expect(controller.unreadCount, 2);
    expect(gateway.summaryCalls, 1);

    controller.handleRealtimeReason('message');
    await Future<void>.delayed(Duration.zero);
    expect(gateway.summaryCalls, 1);

    gateway.unreadCount = 123;
    controller.handleRealtimeReason('moment-comment-created');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.unreadCount, 123);
    expect(gateway.summaryCalls, 2);
  });

  test('markRead clears immediately and keeps server result authoritative', () async {
    final gateway = _FakeMomentActivityGateway()..unreadCount = 5;
    final controller = MomentActivityController(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'token',
      gateway: gateway,
    );
    addTearDown(controller.dispose);

    await controller.refresh();
    expect(controller.unreadCount, 5);

    gateway.markReadResult = 1;
    final future = controller.markRead();
    expect(controller.unreadCount, 0);
    await future;

    expect(controller.unreadCount, 1);
    expect(gateway.markReadCalls, 1);
  });

  test('access token can be refreshed without recreating controller', () async {
    final gateway = _FakeMomentActivityGateway()..unreadCount = 1;
    final controller = MomentActivityController(
      origin: Uri.parse('http://127.0.0.1:18473'),
      accessToken: 'old-token',
      gateway: gateway,
    );
    addTearDown(controller.dispose);

    controller.updateAccessToken('new-token');
    await controller.refresh();

    expect(gateway.lastAccessToken, 'new-token');
  });
}

final class _FakeMomentActivityGateway implements MomentActivityGateway {
  int unreadCount = 0;
  int markReadResult = 0;
  int summaryCalls = 0;
  int markReadCalls = 0;
  String lastAccessToken = '';

  @override
  Future<MomentActivitySummary> getActivitySummary({
    required Uri origin,
    required String accessToken,
  }) async {
    summaryCalls++;
    lastAccessToken = accessToken;
    return MomentActivitySummary(unreadCount: unreadCount);
  }

  @override
  Future<MomentActivitySummary> markActivityRead({
    required Uri origin,
    required String accessToken,
  }) async {
    markReadCalls++;
    lastAccessToken = accessToken;
    await Future<void>.delayed(Duration.zero);
    return MomentActivitySummary(unreadCount: markReadResult);
  }
}
