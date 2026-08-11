import 'package:flutter/foundation.dart';

import '../security/dd_secure_storage.dart';

const int mediaCacheBudget512MiB = 512 * 1024 * 1024;
const int mediaCacheBudget1GiB = 1024 * 1024 * 1024;
const int mediaCacheBudget2GiB = 2 * 1024 * 1024 * 1024;
const int mediaCacheBudget5GiB = 5 * 1024 * 1024 * 1024;
const int defaultMediaCacheBudgetBytes = mediaCacheBudget2GiB;

const List<int> supportedMediaCacheBudgets = <int>[
  mediaCacheBudget512MiB,
  mediaCacheBudget1GiB,
  mediaCacheBudget2GiB,
  mediaCacheBudget5GiB,
];

final class MediaCacheBudgetRegistry {
  MediaCacheBudgetRegistry._();

  static int _bytes = defaultMediaCacheBudgetBytes;

  static int get bytes => _bytes;

  static void setBytes(int value) {
    _bytes = supportedMediaCacheBudgets.contains(value)
        ? value
        : defaultMediaCacheBudgetBytes;
  }
}

final class MediaCacheBudgetStore extends ChangeNotifier {
  MediaCacheBudgetStore({
    required String userId,
    SecureKeyValueStore? storage,
  }) : _userId = userId.trim(),
       _storage = storage ?? DdSecureStorage.shared;

  static final Map<String, MediaCacheBudgetStore> _shared =
      <String, MediaCacheBudgetStore>{};

  static MediaCacheBudgetStore shared(String userId) {
    final id = userId.trim();
    return _shared.putIfAbsent(id, () => MediaCacheBudgetStore(userId: id));
  }

  final String _userId;
  final SecureKeyValueStore _storage;
  bool _loaded = false;
  int _bytes = defaultMediaCacheBudgetBytes;

  String get _key => 'dd.media.cache-budget.v1.$_userId';
  int get bytes => _bytes;

  Future<int> load() async {
    if (_loaded) return _bytes;
    var next = defaultMediaCacheBudgetBytes;
    if (_userId.isNotEmpty) {
      final raw = await _storage.read(_key);
      final parsed = int.tryParse(raw ?? '');
      if (parsed != null && supportedMediaCacheBudgets.contains(parsed)) {
        next = parsed;
      }
    }
    _loaded = true;
    _bytes = next;
    MediaCacheBudgetRegistry.setBytes(next);
    notifyListeners();
    return next;
  }

  Future<void> save(int bytes) async {
    if (!supportedMediaCacheBudgets.contains(bytes)) {
      throw ArgumentError.value(bytes, 'bytes', 'Unsupported cache budget');
    }
    if (_userId.isNotEmpty) {
      await _storage.write(_key, bytes.toString());
    }
    _loaded = true;
    _bytes = bytes;
    MediaCacheBudgetRegistry.setBytes(bytes);
    notifyListeners();
  }
}
