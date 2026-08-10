final class MediaCacheLeaseRegistry {
  MediaCacheLeaseRegistry._();

  static final MediaCacheLeaseRegistry shared = MediaCacheLeaseRegistry._();

  final Map<String, int> _leases = <String, int>{};

  bool isLeased(String path) => (_leases[path] ?? 0) > 0;

  MediaCacheLease acquire(String path) {
    _acquire(path);
    return MediaCacheLease._(this, path);
  }

  T withLeaseSync<T>(String path, T Function() action) {
    _acquire(path);
    try {
      return action();
    } finally {
      _release(path);
    }
  }

  Future<T> withLease<T>(String path, Future<T> Function() action) async {
    _acquire(path);
    try {
      return await action();
    } finally {
      _release(path);
    }
  }

  void _acquire(String path) {
    if (path.isEmpty) return;
    _leases[path] = (_leases[path] ?? 0) + 1;
  }

  void _release(String path) {
    if (path.isEmpty) return;
    final count = _leases[path] ?? 0;
    if (count <= 1) {
      _leases.remove(path);
    } else {
      _leases[path] = count - 1;
    }
  }
}

final class MediaCacheLease {
  MediaCacheLease._(this._registry, this.path);

  final MediaCacheLeaseRegistry _registry;
  final String path;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _registry._release(path);
  }
}
