import 'dart:async';

abstract interface class PushEndpointGateway {
  Future<void> registerEndpoint({
    required Uri origin,
    required String accessToken,
    required String provider,
    required String endpoint,
    required String appId,
    required String environment,
  });

  Future<void> deleteEndpoint({
    required Uri origin,
    required String accessToken,
    required String provider,
  });
}

final class PushEndpointSession {
  const PushEndpointSession({
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.deviceId,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String deviceId;

  bool sameIdentity(PushEndpointSession other) =>
      origin.origin == other.origin.origin &&
      userId == other.userId &&
      deviceId == other.deviceId;
}

final class PushEndpointRegistration {
  const PushEndpointRegistration({
    required this.provider,
    required this.endpoint,
    required this.appId,
    required this.environment,
  });

  final String provider;
  final String endpoint;
  final String appId;
  final String environment;
}

/// Serializes endpoint ownership changes so a token refresh cannot race an
/// account switch and accidentally register account A's token under account B.
final class PushEndpointLifecycle {
  PushEndpointLifecycle({required this.gateway});

  final PushEndpointGateway gateway;
  Future<void> _tail = Future<void>.value();
  PushEndpointSession? _session;
  String? _registeredProvider;
  int _generation = 0;

  PushEndpointSession? get session => _session;
  int get generation => _generation;

  Future<int> activateSession(PushEndpointSession next) => _serialized(() async {
    final previous = _session;
    if (previous != null && !previous.sameIdentity(next)) {
      await _deleteRegisteredEndpoint(previous);
    }
    _session = next;
    _generation++;
    return _generation;
  });

  Future<void> registerEndpoint({
    required int generation,
    required PushEndpointRegistration endpoint,
  }) => _serialized(() async {
    final session = _session;
    if (session == null || generation != _generation) return;
    final provider = endpoint.provider.trim().toUpperCase();
    if (provider.isEmpty || endpoint.endpoint.trim().isEmpty) return;

    final previousProvider = _registeredProvider;
    if (previousProvider != null && previousProvider != provider) {
      await gateway.deleteEndpoint(
        origin: session.origin,
        accessToken: session.accessToken,
        provider: previousProvider,
      );
      _registeredProvider = null;
    }

    // Re-registering the same provider is intentional: the server upsert moves
    // a refreshed token into ACTIVE state and replaces the old endpoint value.
    await gateway.registerEndpoint(
      origin: session.origin,
      accessToken: session.accessToken,
      provider: provider,
      endpoint: endpoint.endpoint.trim(),
      appId: endpoint.appId.trim(),
      environment: endpoint.environment.trim().toUpperCase(),
    );
    _registeredProvider = provider;
  });

  Future<void> disableEndpoint() => _serialized(() async {
    final session = _session;
    if (session == null) return;
    await _deleteRegisteredEndpoint(session);
  });

  Future<void> deactivateSession() => _serialized(() async {
    final session = _session;
    if (session != null) {
      await _deleteRegisteredEndpoint(session);
    }
    _session = null;
    _generation++;
  });

  /// Drops only local ownership after the server has already authoritatively
  /// revoked the device/session. This must never be used as a substitute for a
  /// failed normal endpoint DELETE while the session is still valid.
  Future<void> abandonSessionAfterAuthoritativeRevocation() =>
      _serialized(() async {
        _session = null;
        _registeredProvider = null;
        _generation++;
      });

  Future<void> _deleteRegisteredEndpoint(PushEndpointSession session) async {
    final provider = _registeredProvider;
    if (provider == null) return;
    await gateway.deleteEndpoint(
      origin: session.origin,
      accessToken: session.accessToken,
      provider: provider,
    );
    _registeredProvider = null;
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _tail;
    _tail = () async {
      try {
        await previous;
      } catch (_) {
        // A failed network operation must not permanently poison the queue.
      }
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }
}
