import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/media_api_client.dart';
import '../domain/media_transfer_state.dart';

enum MediaTransferKind { image, video, file, gif, sticker }

final class MediaTransferAborted implements Exception {
  const MediaTransferAborted();
}

typedef MediaTransferOperation = Future<void> Function(
  MediaTransferExecution task,
);

final class MediaTransferTask {
  MediaTransferTask({
    required this.id,
    required this.kind,
    required this.label,
    required this.operation,
  });

  final String id;
  final MediaTransferKind kind;
  final String label;
  final MediaTransferOperation operation;
  MediaTransferState state = const MediaTransferState.queued();
  MediaUploadCancellation cancellation = MediaUploadCancellation();
  int attempts = 0;

  bool get isActive => !state.isTerminal;
}

final class MediaTransferExecution {
  MediaTransferExecution._(this._controller, this._task);

  final MediaTransferController _controller;
  final MediaTransferTask _task;

  String get id => _task.id;
  MediaUploadCancellation get cancellation => _task.cancellation;
  bool get isCancelled => cancellation.isCancelled;

  void update(MediaTransferState state) =>
      _controller._updateState(_task, state);

  void throwIfCancelled() {
    if (cancellation.isCancelled) throw const MediaTransferAborted();
  }
}

final class MediaTransferController extends ChangeNotifier {
  MediaTransferController({this.maxConcurrent = 3})
    : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final Map<String, MediaTransferTask> _tasks = <String, MediaTransferTask>{};
  final List<String> _queue = <String>[];
  final Set<String> _running = <String>{};
  Completer<void>? _idleCompleter;
  bool _disposed = false;

  List<MediaTransferTask> get tasks =>
      List<MediaTransferTask>.unmodifiable(_tasks.values);
  List<MediaTransferTask> get visibleTasks => List<MediaTransferTask>.unmodifiable(
    _tasks.values.where((task) =>
        task.state.phase != MediaTransferPhase.done || task.attempts == 0),
  );
  int get activeCount => _running.length;
  bool get isIdle => _running.isEmpty && _queue.isEmpty;

  MediaTransferTask? task(String id) => _tasks[id];

  bool enqueue({
    required String id,
    required MediaTransferKind kind,
    required String label,
    required MediaTransferOperation operation,
  }) {
    if (_disposed || id.trim().isEmpty || _tasks.containsKey(id)) return false;
    final task = MediaTransferTask(
      id: id,
      kind: kind,
      label: label,
      operation: operation,
    );
    _tasks[id] = task;
    _queue.add(id);
    _ensureBusyCompleter();
    notifyListeners();
    _drain();
    return true;
  }

  bool cancel(String id) {
    final task = _tasks[id];
    if (task == null || task.state.isTerminal) return false;
    task.cancellation.cancel();
    if (_queue.remove(id)) {
      task.state = task.state.copyWith(phase: MediaTransferPhase.canceled);
      notifyListeners();
      _completeIdleIfNeeded();
      _drain();
    }
    return true;
  }

  bool retry(String id) {
    final task = _tasks[id];
    if (task == null || task.state.phase != MediaTransferPhase.failed) {
      return false;
    }
    task.cancellation = MediaUploadCancellation();
    task.state = const MediaTransferState.queued();
    _queue.add(id);
    _ensureBusyCompleter();
    notifyListeners();
    _drain();
    return true;
  }

  void dismiss(String id) {
    final task = _tasks[id];
    if (task == null || !task.state.isTerminal || _running.contains(id)) return;
    _tasks.remove(id);
    _queue.remove(id);
    notifyListeners();
  }

  Future<void> waitForIdle() {
    if (isIdle) return Future<void>.value();
    _ensureBusyCompleter();
    return _idleCompleter!.future;
  }

  void _drain() {
    if (_disposed) return;
    while (_running.length < maxConcurrent && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      final task = _tasks[id];
      if (task == null || task.state.phase == MediaTransferPhase.canceled) {
        continue;
      }
      _running.add(id);
      unawaited(_run(task));
    }
    _completeIdleIfNeeded();
  }

  Future<void> _run(MediaTransferTask task) async {
    task.attempts++;
    try {
      final execution = MediaTransferExecution._(this, task);
      await task.operation(execution);
      execution.throwIfCancelled();
      _updateState(
        task,
        task.state.copyWith(phase: MediaTransferPhase.done, clearError: true),
      );
    } on MediaTransferAborted {
      _updateState(
        task,
        task.state.copyWith(phase: MediaTransferPhase.canceled, clearError: true),
      );
    } on MediaUploadCancelled {
      _updateState(
        task,
        task.state.copyWith(phase: MediaTransferPhase.canceled, clearError: true),
      );
    } catch (error) {
      if (task.cancellation.isCancelled) {
        _updateState(
          task,
          task.state.copyWith(phase: MediaTransferPhase.canceled, clearError: true),
        );
      } else {
        _updateState(
          task,
          task.state.copyWith(
            phase: MediaTransferPhase.failed,
            errorMessage: error.toString(),
          ),
        );
      }
    } finally {
      _running.remove(task.id);
      _drain();
    }
  }

  void _updateState(MediaTransferTask task, MediaTransferState state) {
    if (_disposed || _tasks[task.id] != task) return;
    task.state = state;
    notifyListeners();
  }

  void _ensureBusyCompleter() {
    if (_idleCompleter == null || _idleCompleter!.isCompleted) {
      _idleCompleter = Completer<void>();
    }
  }

  void _completeIdleIfNeeded() {
    if (!isIdle) return;
    final completer = _idleCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final task in _tasks.values) {
      if (!task.state.isTerminal) task.cancellation.cancel();
    }
    _queue.clear();
    _running.clear();
    _completeIdleIfNeeded();
    super.dispose();
  }
}
