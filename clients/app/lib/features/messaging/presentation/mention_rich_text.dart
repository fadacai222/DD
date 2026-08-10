import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../domain/messaging_models.dart';

const Color ddMentionLightColor = Color(0xFF1677FF);
const Color ddMentionDarkColor = Color(0xFF65B5FF);

Color ddMentionColor(Brightness brightness) => brightness == Brightness.dark
    ? ddMentionDarkColor
    : ddMentionLightColor;

class MentionRichText extends StatefulWidget {
  const MentionRichText({
    super.key,
    required this.text,
    required this.entities,
    required this.style,
    required this.mentionStyle,
    required this.onMentionTap,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final List<MessageEntity> entities;
  final TextStyle style;
  final TextStyle mentionStyle;
  final ValueChanged<String> onMentionTap;
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
        spans.add(TextSpan(text: widget.text.substring(cursor, entity.offset)));
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
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: widget.text));

    return Text.rich(
      TextSpan(style: widget.style, children: spans),
      textAlign: widget.textAlign,
    );
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
