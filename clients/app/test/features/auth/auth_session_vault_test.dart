import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/auth/data/auth_session_vault.dart';

void main() {
  test('session save is a single bundled secure-storage write', () async {
    final storage = _MemorySecureStore();
    final vault = AuthSessionVault(storage: storage);

    await vault.save(
      origin: Uri.parse('http://127.0.0.1:18473'),
      refreshToken: 'refresh-1',
    );

    expect(storage.writeCalls, 1);
    expect(storage.deleteCalls, 0);
    final raw = storage.values['dd.auth.session.v2'];
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!) as Map<String, dynamic>;
    expect(decoded['refreshToken'], 'refresh-1');
    expect(decoded['loggedOut'], isFalse);
  });

  test(
    'logout uses a tombstone and never deletes the shared Windows file key',
    () async {
      final storage = _MemorySecureStore();
      final vault = AuthSessionVault(storage: storage);
      await vault.save(
        origin: Uri.parse('http://127.0.0.1:18473'),
        refreshToken: 'refresh-1',
      );

      await vault.clear();

      expect(storage.deleteCalls, 0);
      expect(await vault.read(), isNull);
      final decoded =
          jsonDecode(storage.values['dd.auth.session.v2']!)
              as Map<String, dynamic>;
      expect(decoded['loggedOut'], isTrue);
    },
  );

  test(
    'legacy two-key session migrates once into the bundled format',
    () async {
      final storage = _MemorySecureStore()
        ..values['dd.auth.origin'] = 'http://127.0.0.1:18473'
        ..values['dd.auth.refresh'] = 'legacy-refresh';
      final vault = AuthSessionVault(storage: storage);

      final session = await vault.read();

      expect(session?.refreshToken, 'legacy-refresh');
      expect(session?.origin.toString(), 'http://127.0.0.1:18473');
      expect(storage.values['dd.auth.session.v2'], isNotNull);
    },
  );
}

final class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};
  int writeCalls = 0;
  int deleteCalls = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeCalls++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCalls++;
    values.remove(key);
  }
}
