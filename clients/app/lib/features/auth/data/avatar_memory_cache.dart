import 'dart:collection';
import 'dart:typed_data';

final class AvatarMemoryCache {
  AvatarMemoryCache({
    this.maximumEntries = 256,
    this.maximumBytes = 48 * 1024 * 1024,
  }) : assert(maximumEntries > 0),
       assert(maximumBytes > 0);

  final int maximumEntries;
  final int maximumBytes;
  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();
  int _bytes = 0;

  int get length => _entries.length;
  int get bytes => _bytes;

  Uint8List? get(String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  void put(String key, Uint8List value) {
    if (key.isEmpty || value.isEmpty) return;
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.lengthInBytes;
    if (value.lengthInBytes > maximumBytes) return;
    _entries[key] = value;
    _bytes += value.lengthInBytes;
    _prune();
  }

  void removeWhere(bool Function(String key) predicate) {
    final keys = _entries.keys.where(predicate).toList(growable: false);
    for (final key in keys) {
      final value = _entries.remove(key);
      if (value != null) _bytes -= value.lengthInBytes;
    }
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void _prune() {
    while (_entries.length > maximumEntries || _bytes > maximumBytes) {
      final oldestKey = _entries.keys.first;
      final removed = _entries.remove(oldestKey);
      if (removed != null) _bytes -= removed.lengthInBytes;
    }
  }
}
