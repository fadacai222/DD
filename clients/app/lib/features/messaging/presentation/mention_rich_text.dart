import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../domain/messaging_models.dart';

const Color ddMentionLightColor = Color(0xFF1677FF);
const Color ddMentionDarkColor = Color(0xFF65B5FF);

Color ddMentionColor(Brightness brightness) => brightness == Brightness.dark
    ? ddMentionDarkColor
    : ddMentionLightColor;

final RegExp _httpUrlPattern = RegExp(
  r'https?://[^\s<>()，。！？；：、]+',
  caseSensitive: false,
);

List<Uri> extractHttpUrls(String text) {
  final result = <Uri>[];
  for (final match in _httpUrlPattern.allMatches(text)) {
    final raw = _trimUrlTail(match.group(0) ?? '');
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) continue;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') continue;
    result.add(uri);
  }
  return List.unmodifiable(result);
}

String _trimUrlTail(String raw) => raw.replaceFirst(
  RegExp(r'[\.,!?:;，。！？：；\]\}]+$'),
  '',
);

class MentionRichText extends StatefulWidget {
  const MentionRichText({
    super.key,
    required this.text,
    required this.entities,
    required this.style,
    required this.mentionStyle,
    required this.onMentionTap,
    this.onLinkTap,
    this.linkStyle,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final List<MessageEntity> entities;
  final TextStyle style;
  final TextStyle mentionStyle;
  final ValueChanged<String> onMentionTap;
  final ValueChanged<Uri>? onLinkTap;
  final TextStyle? linkStyle;
  final TextAlign textAlign;

  @override
  State<MentionRichText> createState() => _MentionRichTextState();
}

class _MentionRichTextState extends State<MentionRichText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final spans = <InlineSpan>[];
    final sorted = widget.entities.toList(growable: false)
      ..sort((left, right) {
        final offset = left.offset.compareTo(right.offset);
        return offset != 0 ? offset : left.length.compareTo(right.length);
      });
    var cursor = 0;

    for (final entity in sorted) {
      if (!_isSafeMention(entity, cursor)) continue;
      final end = entity.offset + entity.length;
      final snippet = widget.text.substring(entity.offset, end);
      final handle = entity.handle?.trim() ?? '';
      final userId = entity.userId?.trim() ?? '';
      if (!snippet.startsWith('@')) continue;
      if (handle.isNotEmpty &&
          snippet.substring(1).toLowerCase() != handle.toLowerCase()) {
        continue;
      }
      if (entity.isMention && userId.isEmpty) continue;
      if (entity.isMentionAll && snippet.toLowerCase() != '@all') continue;
      if (entity.offset > cursor) {
        _appendPlainTextWithLinks(spans, cursor, entity.offset);
      }
      TapGestureRecognizer? recognizer;
      if (entity.isMention) {
        recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onMentionTap(userId);
        _recognizers.add(recognizer);
      }
      spans.add(
        TextSpan(
          text: snippet,
          style: widget.mentionStyle,
          recognizer: recognizer,
          mouseCursor: recognizer == null ? null : SystemMouseCursors.click,
        ),
      );
      cursor = end;
    }

    if (cursor < widget.text.length) {
      _appendPlainTextWithLinks(spans, cursor, widget.text.length);
    }
    if (spans.isEmpty) _appendPlainTextWithLinks(spans, 0, widget.text.length);

    return Text.rich(
      TextSpan(style: widget.style, children: spans),
      textAlign: widget.textAlign,
    );
  }

  void _appendPlainTextWithLinks(
    List<InlineSpan> spans,
    int start,
    int end,
  ) {
    if (end <= start) return;
    final segment = widget.text.substring(start, end);
    var cursor = 0;
    for (final match in _httpUrlPattern.allMatches(segment)) {
      final raw = match.group(0) ?? '';
      final display = _trimUrlTail(raw);
      if (display.isEmpty) continue;
      final uri = Uri.tryParse(display);
      if (uri == null || uri.host.isEmpty) continue;
      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') continue;
      if (match.start > cursor) {
        spans.add(TextSpan(text: segment.substring(cursor, match.start)));
      }
      final recognizer = widget.onLinkTap == null
          ? null
          : (TapGestureRecognizer()..onTap = () => widget.onLinkTap!(uri));
      if (recognizer != null) _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: display,
          style:
              widget.linkStyle ??
              TextStyle(
                color: ddMentionColor(Theme.of(context).brightness),
                decoration: TextDecoration.none,
              ),
          recognizer: recognizer,
          mouseCursor: recognizer == null ? null : SystemMouseCursors.click,
        ),
      );
      final trimmedCount = raw.length - display.length;
      if (trimmedCount > 0) {
        spans.add(TextSpan(text: raw.substring(display.length)));
      }
      cursor = match.end;
    }
    if (cursor < segment.length) {
      spans.add(TextSpan(text: segment.substring(cursor)));
    }
  }

  bool _isSafeMention(MessageEntity entity, int cursor) {
    if (!entity.isMentionLike || entity.offset < cursor || entity.offset < 0) {
      return false;
    }
    if (entity.length <= 0) return false;
    final end = entity.offset + entity.length;
    return end >= entity.offset && end <= widget.text.length;
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }
}
