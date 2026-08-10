import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../contacts/domain/contact_models.dart';

final class MentionTrigger {
  const MentionTrigger({
    required this.start,
    required this.cursor,
    required this.tokenEnd,
    required this.query,
  });

  final int start;
  final int cursor;
  final int tokenEnd;
  final String query;
}

MentionTrigger? detectMentionTrigger(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final composing = value.composing;
  if (composing.isValid && !composing.isCollapsed) return null;

  final text = value.text;
  final cursor = selection.baseOffset;
  if (cursor < 0 || cursor > text.length) return null;

  final lowerBound = (cursor - 33).clamp(0, cursor);
  var at = -1;
  for (var index = cursor - 1; index >= lowerBound; index--) {
    final code = text.codeUnitAt(index);
    if (code == 0x40) {
      at = index;
      break;
    }
    if (!_isHandleCodeUnit(code)) return null;
  }
  if (at < 0) return null;

  if (at > 0) {
    final previous = text.codeUnitAt(at - 1);
    if (previous == 0x40 || _isHandleCodeUnit(previous)) return null;
  }

  final query = text.substring(at + 1, cursor);
  if (query.length > 32) return null;
  if (query.isNotEmpty) {
    if (!_isAsciiLetter(query.codeUnitAt(0))) return null;
    for (var index = 1; index < query.length; index++) {
      if (!_isHandleCodeUnit(query.codeUnitAt(index))) return null;
    }
  }

  var tokenEnd = cursor;
  while (tokenEnd < text.length &&
      _isHandleCodeUnit(text.codeUnitAt(tokenEnd))) {
    tokenEnd++;
  }
  return MentionTrigger(
    start: at,
    cursor: cursor,
    tokenEnd: tokenEnd,
    query: query.toLowerCase(),
  );
}

TextEditingValue applyMentionSuggestion({
  required TextEditingValue value,
  required MentionTrigger trigger,
  required ContactMentionSuggestion suggestion,
}) {
  final text = value.text;
  if (trigger.start < 0 ||
      trigger.tokenEnd < trigger.start ||
      trigger.tokenEnd > text.length) {
    return value;
  }

  final handle = suggestion.user.handle.trim();
  if (handle.isEmpty) return value;
  final hasTrailingWhitespace =
      trigger.tokenEnd < text.length &&
      _isWhitespaceCodeUnit(text.codeUnitAt(trigger.tokenEnd));
  final replacement = '@$handle${hasTrailingWhitespace ? '' : ' '}';
  final updated = text.replaceRange(
    trigger.start,
    trigger.tokenEnd,
    replacement,
  );
  var cursor = trigger.start + replacement.length;
  if (hasTrailingWhitespace) cursor++;
  if (cursor > updated.length) cursor = updated.length;
  return TextEditingValue(
    text: updated,
    selection: TextSelection.collapsed(offset: cursor),
    composing: TextRange.empty,
  );
}

final class MentionComposerController extends ChangeNotifier {
  MentionComposerController({
    required this.loader,
    this.debounce = const Duration(milliseconds: 220),
  });

  final Future<List<ContactMentionSuggestion>> Function(String query) loader;
  final Duration debounce;
  final Map<String, List<ContactMentionSuggestion>> _cache =
      <String, List<ContactMentionSuggestion>>{};

  Timer? _debounceTimer;
  int _requestSerial = 0;
  MentionTrigger? _trigger;
  List<ContactMentionSuggestion> _suggestions =
      const <ContactMentionSuggestion>[];
  int _selectedIndex = 0;
  bool _loading = false;

  MentionTrigger? get trigger => _trigger;
  List<ContactMentionSuggestion> get suggestions => _suggestions;
  int get selectedIndex => _selectedIndex;
  bool get loading => _loading;
  bool get visible => _trigger != null && (_loading || _suggestions.isNotEmpty);

  ContactMentionSuggestion? get selectedSuggestion {
    if (_suggestions.isEmpty || _selectedIndex < 0) return null;
    if (_selectedIndex >= _suggestions.length) return null;
    return _suggestions[_selectedIndex];
  }

  void update(TextEditingValue value) {
    final next = detectMentionTrigger(value);
    if (next == null || next.query.length < 2) {
      _setIdle(next);
      return;
    }

    final previous = _trigger;
    _trigger = next;
    if (previous?.query == next.query &&
        previous?.start == next.start &&
        (_loading || _suggestions.isNotEmpty)) {
      return;
    }

    _debounceTimer?.cancel();
    final cached = _cache[next.query];
    if (cached != null) {
      _loading = false;
      _suggestions = cached;
      _selectedIndex = 0;
      notifyListeners();
      return;
    }

    _loading = true;
    _suggestions = const <ContactMentionSuggestion>[];
    _selectedIndex = 0;
    final serial = ++_requestSerial;
    notifyListeners();
    _debounceTimer = Timer(debounce, () => _load(next, serial));
  }

  void moveSelection(int delta) {
    if (_suggestions.isEmpty || delta == 0) return;
    final length = _suggestions.length;
    _selectedIndex = (_selectedIndex + delta) % length;
    if (_selectedIndex < 0) _selectedIndex += length;
    notifyListeners();
  }

  void selectIndex(int index) {
    if (index < 0 || index >= _suggestions.length || index == _selectedIndex) {
      return;
    }
    _selectedIndex = index;
    notifyListeners();
  }

  void close() {
    _setIdle(null);
  }

  void _setIdle(MentionTrigger? trigger) {
    _debounceTimer?.cancel();
    _requestSerial++;
    final changed = _trigger != trigger || _loading || _suggestions.isNotEmpty;
    _trigger = trigger;
    _loading = false;
    _suggestions = const <ContactMentionSuggestion>[];
    _selectedIndex = 0;
    if (changed) notifyListeners();
  }

  Future<void> _load(MentionTrigger requestTrigger, int serial) async {
    try {
      final loaded = List<ContactMentionSuggestion>.unmodifiable(
        await loader(requestTrigger.query),
      );
      if (serial != _requestSerial ||
          _trigger?.query != requestTrigger.query ||
          _trigger?.start != requestTrigger.start) {
        return;
      }
      _cache[requestTrigger.query] = loaded;
      _suggestions = loaded;
      _selectedIndex = 0;
      _loading = false;
      notifyListeners();
    } catch (_) {
      if (serial != _requestSerial ||
          _trigger?.query != requestTrigger.query ||
          _trigger?.start != requestTrigger.start) {
        return;
      }
      _suggestions = const <ContactMentionSuggestion>[];
      _selectedIndex = 0;
      _loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _requestSerial++;
    super.dispose();
  }
}

bool _isAsciiLetter(int code) =>
    code >= 0x41 && code <= 0x5A || code >= 0x61 && code <= 0x7A;

bool _isHandleCodeUnit(int code) =>
    _isAsciiLetter(code) || code >= 0x30 && code <= 0x39 || code == 0x5F;

bool _isWhitespaceCodeUnit(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;
