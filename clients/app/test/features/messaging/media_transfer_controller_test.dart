import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/application/media_transfer_controller.dart';
import 'package:im_client/features/messaging/domain/media_transfer_state.dart';

void main() {
  test('controller limits concurrency and starts queued task when slot frees', () async {
    final controller = MediaTransferController(maxConcurrent: 2);
    addTearDown(controller.dispose);
    final gates = <String, Completer<void>>{};
    final started = <String>[];

    for (final id in const ['a', 'b', 'c']) {
      gates[id] = Completer<void>();
      controller.enqueue(
        id: id,
        kind: MediaTransferKind.file,
        label: id,
        operation: (task) async {
          started.add(id);
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.uploading,
              transferredBytes: 1,
              totalBytes: 10,
            ),
          );
          await gates[id]!.future;
        },
      );
    }

    await Future<void>.delayed(Duration.zero);
    expect(started, ['a', 'b']);
    expect(controller.task('c')?.state.phase, MediaTransferPhase.queued);

    gates['a']!.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a', 'b', 'c']);

    gates['b']!.complete();
    gates['c']!.complete();
    await controller.waitForIdle();
    expect(controller.activeCount, 0);
  });

  test('canceling one task does not cancel another task', () async {
    final controller = MediaTransferController(maxConcurrent: 2);
    addTearDown(controller.dispose);
    final otherGate = Completer<void>();

    controller.enqueue(
      id: 'cancel-me',
      kind: MediaTransferKind.video,
      label: 'cancel',
      operation: (task) async {
        task.update(
          const MediaTransferState(phase: MediaTransferPhase.uploading),
        );
        while (!task.cancellation.isCancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        throw const MediaTransferAborted();
      },
    );
    controller.enqueue(
      id: 'keep-going',
      kind: MediaTransferKind.file,
      label: 'other',
      operation: (task) async {
        task.update(
          const MediaTransferState(phase: MediaTransferPhase.uploading),
        );
        await otherGate.future;
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    controller.cancel('cancel-me');
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(controller.task('cancel-me')?.state.phase, MediaTransferPhase.canceled);
    expect(controller.task('keep-going')?.state.phase, MediaTransferPhase.uploading);

    otherGate.complete();
    await controller.waitForIdle();
  });

  test('running task can pause and resume without losing its operation', () async {
    final controller = MediaTransferController(maxConcurrent: 1);
    addTearDown(controller.dispose);
    var attempts = 0;

    controller.enqueue(
      id: 'pause-me',
      kind: MediaTransferKind.file,
      label: 'archive.zip',
      conversationId: 'conversation-a',
      operation: (task) async {
        attempts++;
        task.update(
          const MediaTransferState(
            phase: MediaTransferPhase.uploading,
            transferredBytes: 10,
            totalBytes: 100,
          ),
        );
        if (attempts == 1) {
          while (!task.isCancelled) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          throw const MediaTransferAborted();
        }
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(controller.pause('pause-me'), isTrue);
    await controller.waitForIdle();
    expect(controller.task('pause-me')?.state.phase, MediaTransferPhase.paused);
    expect(controller.tasksForConversation('conversation-a'), hasLength(1));

    expect(controller.resume('pause-me'), isTrue);
    await controller.waitForIdle();
    expect(attempts, 2);
    expect(controller.task('pause-me')?.state.phase, MediaTransferPhase.done);
  });

  test('clear all inactive preserves active transfers', () async {
    final controller = MediaTransferController(maxConcurrent: 1);
    addTearDown(controller.dispose);
    final gate = Completer<void>();

    controller.enqueue(
      id: 'active',
      kind: MediaTransferKind.video,
      label: 'movie.mp4',
      operation: (task) async {
        task.update(const MediaTransferState(phase: MediaTransferPhase.uploading));
        await gate.future;
      },
    );
    controller.enqueue(
      id: 'failed',
      kind: MediaTransferKind.file,
      label: 'broken.bin',
      operation: (_) async => throw StateError('broken'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    controller.cancel('failed');

    expect(controller.clearInactive(), 1);
    expect(controller.task('active'), isNotNull);
    expect(controller.task('failed'), isNull);

    gate.complete();
    await controller.waitForIdle();
  });

  test('failed task keeps operation and can retry independently', () async {
    final controller = MediaTransferController(maxConcurrent: 1);
    addTearDown(controller.dispose);
    var attempts = 0;

    controller.enqueue(
      id: 'retry-me',
      kind: MediaTransferKind.image,
      label: 'photo.jpg',
      operation: (task) async {
        attempts++;
        task.update(
          const MediaTransferState(phase: MediaTransferPhase.uploading),
        );
        if (attempts == 1) throw StateError('temporary');
      },
    );
    await controller.waitForIdle();
    expect(controller.task('retry-me')?.state.phase, MediaTransferPhase.failed);

    expect(controller.retry('retry-me'), isTrue);
    await controller.waitForIdle();
    expect(attempts, 2);
    expect(controller.task('retry-me')?.state.phase, MediaTransferPhase.done);
  });
}
