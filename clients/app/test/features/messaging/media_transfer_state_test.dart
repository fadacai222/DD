import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/media_transfer_state.dart';
import 'package:im_client/features/messaging/presentation/widgets/media_transfer_progress.dart';

void main() {
  test('transfer state exposes real byte progress and cancellable phases', () {
    const state = MediaTransferState(
      phase: MediaTransferPhase.uploading,
      transferredBytes: 9 * 1024 * 1024,
      totalBytes: 48 * 1024 * 1024,
    );

    expect(state.progress, closeTo(9 / 48, 0.0001));
    expect(state.canCancel, isTrue);
    expect(state.isTerminal, isFalse);
    expect(
      state.copyWith(phase: MediaTransferPhase.committing).canCancel,
      isFalse,
    );
    expect(
      state.copyWith(phase: MediaTransferPhase.canceled).isTerminal,
      isTrue,
    );
  });

  testWidgets('circular transfer control calls real cancel callback', (
    tester,
  ) async {
    var canceled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: MediaTransferProgress(
            state: const MediaTransferState(
              phase: MediaTransferPhase.uploading,
              transferredBytes: 50,
              totalBytes: 100,
            ),
            onCancel: () => canceled = true,
          ),
        ),
      ),
    );

    final ring = tester.widget<CircularProgressIndicator>(
      find.byKey(const Key('media-transfer-progress-ring')),
    );
    expect(ring.value, 0.5);
    await tester.tap(find.byKey(const Key('media-transfer-cancel')));
    expect(canceled, isTrue);
  });
}
