import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/security/dd_secure_storage.dart';
import 'package:im_client/features/messaging/application/media_transfer_controller.dart';
import 'package:im_client/features/messaging/data/media_transfer_history_store.dart';
import 'package:im_client/features/messaging/domain/media_transfer_state.dart';

void main() {
  test('restored active record becomes explicit interrupted failure', () async {
    final storage = _MemoryStore();
    final history = MediaTransferHistoryStore(userId: 'user-a', storage: storage);
    await history.save([
      {
        'id': 'old-upload',
        'kind': 'video',
        'direction': 'upload',
        'label': 'old.mp4',
        'conversationId': 'conversation-a',
        'phase': 'uploading',
        'transferredBytes': 30,
        'totalBytes': 100,
        'createdAt': '2026-08-11T01:00:00Z',
        'updatedAt': '2026-08-11T01:01:00Z',
        'attempts': 1,
      },
      {
        'id': 'done-download',
        'kind': 'file',
        'direction': 'download',
        'label': 'done.pdf',
        'phase': 'done',
        'transferredBytes': 100,
        'totalBytes': 100,
        'createdAt': '2026-08-11T00:00:00Z',
        'updatedAt': '2026-08-11T00:01:00Z',
        'completedAt': '2026-08-11T00:01:00Z',
        'attempts': 1,
      },
    ]);

    final controller = MediaTransferController(
      historyStore: history,
      maxConcurrent: 1,
    );
    addTearDown(controller.dispose);
    await controller.restoreHistory();

    final interrupted = controller.task('old-upload');
    expect(interrupted?.state.phase, MediaTransferPhase.failed);
    expect(interrupted?.state.errorMessage, contains('上次应用退出'));
    expect(interrupted?.state.transferredBytes, 30);
    expect(controller.task('done-download')?.state.phase, MediaTransferPhase.done);
  });
}

final class _MemoryStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
