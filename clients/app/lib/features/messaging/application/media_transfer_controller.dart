import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/media_api_client.dart';
import '../data/media_transfer_history_store.dart';
import '../domain/media_transfer_state.dart';

enum MediaTransferKind { image, video, file, voice, gif, sticker }

enum MediaTransferDirection { upload, download }

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
    required this.direction,
    required this.label,
    required this.operation,
    required this.createdAt,
    this.conversationId,
    this.openAction,
    this.saveAction,
    this.shareAction,
  }) : updatedAt = createdAt;

  final String id;
  final MediaTransferKind kind;
  final MediaTransferDirection direction;
  final String label;
  final String? conversationId;
  final MediaTransferOperation operation;
  final Future<void> Function()? openAction;
  final Future<void> Function()? saveAction;
  final Future<void> Function()? shareAction;
  final DateTime createdAt;

  MediaTransferState state = const MediaTransferState.queued();
  MediaUploadCancellation cancellation = MediaUploadCancellation();
  DateTime updatedAt;
  DateTime? completedAt;
  double bytesPerSecond = 0;
  int attempts = 0;
  bool pauseRequested = false;
  bool retrySupported = true;
  VoidCallback? abortCurrentAttempt;
  DateTime? _sampleAt;
  int _sampleBytes = 0;

  bool get isActive => switch (state.phase) {
    MediaTransferPhase.queued ||
    MediaTransferPhase.preparing ||
    MediaTransferPhase.uploading ||
    MediaTransferPhase.committing => true,
    _ => false,
  };

  bool get isPaused => state.phase == MediaTransferPhase.paused;
  bool get canRetry =>
      retrySupported && state.phase == MediaTransferPhase.failed;
  bool get canResume => state.phase == MediaTransferPhase.paused;
}

final class MediaTransferExecution {
  MediaTransferExecution._(this._controller, this._task);

  final MediaTransferController _controller;
  final MediaTransferTask _task;

  String get id => _task.id;
  MediaUploadCancellation get cancellation => _task.cancellation;
  bool get isCancelled => cancellation.isCancelled;
  bool get pauseRequested => _task.pauseRequested;

  void setAbortHandler(VoidCallback? handler) {
    _task.abortCurrentAttempt = handler;
    if (handler != null && cancellation.isCancelled) handler();
  }

  void update(MediaTransferState state) =>
      _controller._updateState(_task, state);

  void throwIfCancelled() {
    if (cancellation.isCancelled) throw const MediaTransferAborted();
  }
}

final class MediaTransferController extends ChangeNotifier {
  MediaTransferController({
    this.maxConcurrent = 3,
    this.historyStore,
  }) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final MediaTransferHistoryStore? historyStore;
  final Map<String, MediaTransferTask> _tasks = <String, MediaTransferTask>{};
  final List<String> _queue = <String>[];
  final Set<String> _running = <String>{};
  Completer<void>? _idleCompleter;
  Timer? _persistTimer;
  bool _historyLoaded = false;
  bool _disposed = false;

  List<MediaTransferTask> get tasks =>
      List<MediaTransferTask>.unmodifiable(_tasks.values);
  List<MediaTransferTask> get visibleTasks => List<MediaTransferTask>.unmodifiable(
    _tasks.values.where((task) =>
        task.state.phase != MediaTransferPhase.done),
  );
  int get activeCount => _running.length;
  bool get isIdle => _running.isEmpty && _queue.isEmpty;

  MediaTransferTask? task(String id) => _tasks[id];

  List<MediaTransferTask> tasksForConversation(
    String conversationId, {
    bool includeCompleted = false,
  }) => List<MediaTransferTask>.unmodifiable(
    _tasks.values.where(
      (task) =>
          task.conversationId == conversationId &&
          (includeCompleted || task.state.phase != MediaTransferPhase.done),
    ),
  );

  Future<void> restoreHistory() async {
    if (_historyLoaded || historyStore == null || _disposed) return;
    _historyLoaded = true;
    final records = await historyStore!.load();
    for (final record in records) {
      final id = record['id']?.toString().trim() ?? '';
      if (id.isEmpty || _tasks.containsKey(id)) continue;
      final kind = _parseKind(record['kind']?.toString());
      final direction = _parseDirection(record['direction']?.toString());
      final recordedPhase = _parsePhase(record['phase']?.toString());
      if (kind == null || direction == null || recordedPhase == null) continue;
      final createdAt =
          DateTime.tryParse(record['createdAt']?.toString() ?? '')?.toUtc() ??
          DateTime.now().toUtc();
      final task = MediaTransferTask(
        id: id,
        kind: kind,
        direction: direction,
        label: record['label']?.toString() ?? id,
        conversationId: record['conversationId']?.toString(),
        operation: (_) async {
          throw const FormatException('应用已重启，请从原消息重新发起传输。');
        },
        createdAt: createdAt,
      );
      final wasInterrupted = switch (recordedPhase) {
        MediaTransferPhase.queued ||
        MediaTransferPhase.preparing ||
        MediaTransferPhase.uploading ||
        MediaTransferPhase.paused ||
        MediaTransferPhase.committing => true,
        _ => false,
      };
      task.retrySupported = false;
      task.state = MediaTransferState(
        phase: wasInterrupted ? MediaTransferPhase.failed : recordedPhase,
        transferredBytes: (record['transferredBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (record['totalBytes'] as num?)?.toInt(),
        errorMessage: wasInterrupted
            ? '上次应用退出时任务仍在传输，请从原消息重新发起。'
            : record['errorMessage']?.toString(),
      );
      task.updatedAt =
          DateTime.tryParse(record['updatedAt']?.toString() ?? '')?.toUtc() ??
          createdAt;
      task.completedAt = DateTime.tryParse(
        record['completedAt']?.toString() ?? '',
      )?.toUtc();
      task.attempts = (record['attempts'] as num?)?.toInt() ?? 1;
      _tasks[id] = task;
    }
    if (_tasks.isNotEmpty) _changed();
  }

  bool enqueue({
    required String id,
    required MediaTransferKind kind,
    required String label,
    required MediaTransferOperation operation,
    MediaTransferDirection direction = MediaTransferDirection.upload,
    String? conversationId,
    Future<void> Function()? openAction,
    Future<void> Function()? saveAction,
    Future<void> Function()? shareAction,
  }) {
    if (_disposed || id.trim().isEmpty || _tasks.containsKey(id)) return false;
    final now = DateTime.now().toUtc();
    final task = MediaTransferTask(
      id: id,
      kind: kind,
      direction: direction,
      label: label,
      conversationId: conversationId,
      operation: operation,
      createdAt: now,
      openAction: openAction,
      saveAction: saveAction,
      shareAction: shareAction,
    );
    _tasks[id] = task;
    _queue.add(id);
    _ensureBusyCompleter();
    _changed();
    _drain();
    return true;
  }

  bool cancel(String id) {
    final task = _tasks[id];
    if (task == null || task.state.isTerminal) return false;
    task.pauseRequested = false;
    task.abortCurrentAttempt?.call();
    task.cancellation.cancel();
    if (_queue.remove(id) || task.isPaused) {
      _setTerminalState(task, MediaTransferPhase.canceled);
      _completeIdleIfNeeded();
      _drain();
    }
    return true;
  }

  bool pause(String id) {
    final task = _tasks[id];
    if (task == null || !task.isActive) return false;
    task.pauseRequested = true;
    task.abortCurrentAttempt?.call();
    task.cancellation.cancel();
    if (_queue.remove(id)) {
      _updateState(
        task,
        task.state.copyWith(
          phase: MediaTransferPhase.paused,
          clearError: true,
        ),
      );
      _completeIdleIfNeeded();
      _drain();
    }
    return true;
  }

  bool resume(String id) {
    final task = _tasks[id];
    if (task == null || !task.canResume) return false;
    _prepareForAnotherAttempt(task);
    return true;
  }

  bool retry(String id) {
    final task = _tasks[id];
    if (task == null || !task.canRetry) return false;
    _prepareForAnotherAttempt(task);
    return true;
  }

  void _prepareForAnotherAttempt(MediaTransferTask task) {
    task.pauseRequested = false;
    task.abortCurrentAttempt = null;
    task.cancellation = MediaUploadCancellation();
    task.bytesPerSecond = 0;
    task._sampleAt = null;
    task._sampleBytes = 0;
    task.completedAt = null;
    task.state = const MediaTransferState.queued();
    task.updatedAt = DateTime.now().toUtc();
    _queue.add(task.id);
    _ensureBusyCompleter();
    _changed();
    _drain();
  }

  void dismiss(String id) {
    final task = _tasks[id];
    if (task == null || task.isActive || _running.contains(id)) return;
    _tasks.remove(id);
    _queue.remove(id);
    _changed();
  }

  int clearCompleted() {
    final ids = _tasks.values
        .where((task) => task.state.phase == MediaTransferPhase.done)
        .map((task) => task.id)
        .toList(growable: false);
    for (final id in ids) {
      _tasks.remove(id);
      _queue.remove(id);
    }
    if (ids.isNotEmpty) _changed();
    return ids.length;
  }

  int clearInactive() {
    final ids = _tasks.values
        .where((task) => !task.isActive && !_running.contains(task.id))
        .map((task) => task.id)
        .toList(growable: false);
    for (final id in ids) {
      _tasks.remove(id);
      _queue.remove(id);
    }
    if (ids.isNotEmpty) _changed();
    return ids.length;
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
      if (task == null ||
          task.state.phase == MediaTransferPhase.canceled ||
          task.state.phase == MediaTransferPhase.paused) {
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
      _setTerminalState(task, MediaTransferPhase.done);
    } on MediaTransferAborted {
      _handleAbort(task);
    } on MediaUploadCancelled {
      _handleAbort(task);
    } catch (error) {
      if (task.cancellation.isCancelled) {
        _handleAbort(task);
      } else {
        _updateState(
          task,
          task.state.copyWith(
            phase: MediaTransferPhase.failed,
            errorMessage: error.toString(),
          ),
        );
        task.completedAt = DateTime.now().toUtc();
      }
    } finally {
      task.abortCurrentAttempt = null;
      _running.remove(task.id);
      _drain();
    }
  }

  void _handleAbort(MediaTransferTask task) {
    if (task.pauseRequested) {
      task.pauseRequested = false;
      _updateState(
        task,
        task.state.copyWith(
          phase: MediaTransferPhase.paused,
          clearError: true,
        ),
      );
      return;
    }
    _setTerminalState(task, MediaTransferPhase.canceled);
  }

  void _setTerminalState(
    MediaTransferTask task,
    MediaTransferPhase phase,
  ) {
    _updateState(
      task,
      task.state.copyWith(phase: phase, clearError: true),
    );
    task.completedAt = DateTime.now().toUtc();
    task.bytesPerSecond = 0;
  }

  void _updateState(MediaTransferTask task, MediaTransferState state) {
    if (_disposed || _tasks[task.id] != task) return;
    final now = DateTime.now().toUtc();
    final previousAt = task._sampleAt;
    final previousBytes = task._sampleBytes;
    if (state.transferredBytes > previousBytes) {
      if (previousAt != null) {
        final elapsedMicros = now.difference(previousAt).inMicroseconds;
        if (elapsedMicros > 0) {
          final instant =
              (state.transferredBytes - previousBytes) * 1000000 /
              elapsedMicros;
          task.bytesPerSecond = task.bytesPerSecond <= 0
              ? instant
              : (task.bytesPerSecond * 0.65) + (instant * 0.35);
        }
      }
      task._sampleAt = now;
      task._sampleBytes = state.transferredBytes;
    }
    task.state = state;
    task.updatedAt = now;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    notifyListeners();
    _schedulePersist();
  }

  void _schedulePersist() {
    if (historyStore == null || _disposed) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 180), () {
      unawaited(_persistHistory());
    });
  }

  Future<void> _persistHistory() async {
    final store = historyStore;
    if (store == null) return;
    final ordered = _tasks.values.toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    final records = ordered.take(200).map((task) => <String, Object?>{
      'id': task.id,
      'kind': task.kind.name,
      'direction': task.direction.name,
      'label': task.label,
      'conversationId': task.conversationId,
      'phase': task.state.phase.name,
      'transferredBytes': task.state.transferredBytes,
      'totalBytes': task.state.totalBytes,
      'errorMessage': task.state.errorMessage,
      'createdAt': task.createdAt.toIso8601String(),
      'updatedAt': task.updatedAt.toIso8601String(),
      'completedAt': task.completedAt?.toIso8601String(),
      'attempts': task.attempts,
    }).toList(growable: false);
    try {
      await store.save(records);
    } catch (_) {
      // Transfer persistence is best-effort and must never fail live transfers.
    }
  }

  MediaTransferKind? _parseKind(String? raw) {
    for (final value in MediaTransferKind.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  MediaTransferDirection? _parseDirection(String? raw) {
    for (final value in MediaTransferDirection.values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  MediaTransferPhase? _parsePhase(String? raw) {
    for (final value in MediaTransferPhase.values) {
      if (value.name == raw) return value;
    }
    return null;
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
    _persistTimer?.cancel();
    unawaited(_persistHistory());
    _disposed = true;
    for (final task in _tasks.values) {
      if (task.isActive) task.cancellation.cancel();
    }
    _queue.clear();
    _running.clear();
    _completeIdleIfNeeded();
    super.dispose();
  }
}
