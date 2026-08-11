import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/presentation/mention_rich_text.dart';

void main() {
  test('mention semantic color stays blue and brightens in dark mode', () {
    expect(ddMentionColor(Brightness.light), ddMentionLightColor);
    expect(ddMentionColor(Brightness.dark), ddMentionDarkColor);
    expect(ddMentionLightColor, const Color(0xFF1677FF));
    expect(ddMentionDarkColor, const Color(0xFF65B5FF));
  });

  Iterable<TextSpan> flattenTextSpans(TextSpan span) sync* {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) yield* flattenTextSpans(child);
    }
  }

  TextSpan mentionRootSpan(WidgetTester tester) {
    final richText = tester.widget<RichText>(
      find.descendant(
        of: find.byType(MentionRichText),
        matching: find.byType(RichText),
      ),
    );
    return richText.text as TextSpan;
  }

  testWidgets('renders UTF-16 mention span and taps stable userId', (
    tester,
  ) async {
    String? tappedUserId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MentionRichText(
            text: '😀 hi @Alice!',
            entities: const [
              MessageEntity(
                type: 'MENTION',
                offset: 6,
                length: 6,
                userId: 'stable-user-a',
                handle: 'alice',
              ),
            ],
            style: const TextStyle(color: Colors.black),
            mentionStyle: const TextStyle(color: Colors.blue),
            onMentionTap: (userId) => tappedUserId = userId,
          ),
        ),
      ),
    );

    final root = mentionRootSpan(tester);
    final mention = flattenTextSpans(
      root,
    ).firstWhere((span) => span.text == '@Alice');
    expect(mention.style?.color, Colors.blue);
    expect(mention.mouseCursor, SystemMouseCursors.click);

    (mention.recognizer! as TapGestureRecognizer).onTap!();
    expect(tappedUserId, 'stable-user-a');
  });

  testWidgets(
    'invalid, overlapping and mismatched entities stay plain and safe',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MentionRichText(
              text: 'hello @alice world',
              entities: const [
                MessageEntity(
                  type: 'MENTION',
                  offset: -1,
                  length: 6,
                  userId: 'bad-negative',
                  handle: 'alice',
                ),
                MessageEntity(
                  type: 'MENTION',
                  offset: 6,
                  length: 6,
                  userId: 'bad-mismatch',
                  handle: 'bob',
                ),
                MessageEntity(
                  type: 'MENTION',
                  offset: 7,
                  length: 5,
                  userId: 'bad-overlap',
                  handle: 'alice',
                ),
                MessageEntity(
                  type: 'MENTION',
                  offset: 999,
                  length: 4,
                  userId: 'bad-range',
                  handle: 'none',
                ),
              ],
              style: const TextStyle(color: Colors.black),
              mentionStyle: const TextStyle(color: Colors.blue),
              onMentionTap: (_) => taps++,
            ),
          ),
        ),
      );

      final root = mentionRootSpan(tester);
      final clickable = flattenTextSpans(
        root,
      ).where((span) => span.recognizer != null).toList();
      expect(clickable, isEmpty);
      expect(root.toPlainText(), 'hello @alice world');
      expect(taps, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('@all is highlighted but has no profile tap recognizer', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MentionRichText(
            text: '@all maintenance',
            entities: const [
              MessageEntity(
                type: 'MENTION_ALL',
                offset: 0,
                length: 4,
                handle: 'all',
              ),
            ],
            style: const TextStyle(color: Colors.black),
            mentionStyle: const TextStyle(color: Colors.blue),
            onMentionTap: (_) => taps++,
          ),
        ),
      ),
    );

    final root = mentionRootSpan(tester);
    final mention = flattenTextSpans(
      root,
    ).firstWhere((span) => span.text == '@all');
    expect(mention.style?.color, Colors.blue);
    expect(mention.recognizer, isNull);
    expect(taps, 0);
  });

  test('extracts HTTP links without swallowing sentence punctuation', () {
    final links = extractHttpUrls(
      '先看 https://example.com/a?q=1，然后看 http://example.org/test。',
    );
    expect(links.map((uri) => uri.toString()), <String>[
      'https://example.com/a?q=1',
      'http://example.org/test',
    ]);
  });

  testWidgets('HTTP link is blue and independently clickable beside mention', (
    tester,
  ) async {
    Uri? tappedLink;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MentionRichText(
            text: '@Alice 看 https://example.com/docs。',
            entities: const [
              MessageEntity(
                type: 'MENTION',
                offset: 0,
                length: 6,
                userId: 'stable-user-a',
                handle: 'alice',
              ),
            ],
            style: const TextStyle(color: Colors.black),
            mentionStyle: const TextStyle(color: Colors.purple),
            onMentionTap: (_) {},
            onLinkTap: (uri) => tappedLink = uri,
          ),
        ),
      ),
    );

    final root = mentionRootSpan(tester);
    final link = flattenTextSpans(
      root,
    ).firstWhere((span) => span.text == 'https://example.com/docs');
    expect(link.style?.color, ddMentionLightColor);
    expect(link.mouseCursor, SystemMouseCursors.click);
    (link.recognizer! as TapGestureRecognizer).onTap!();
    expect(tappedLink.toString(), 'https://example.com/docs');
    expect(root.toPlainText(), '@Alice 看 https://example.com/docs。');
  });

  testWidgets('unknown entity type does not affect message rendering', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MentionRichText(
            text: 'plain message',
            entities: const [
              MessageEntity(type: 'FUTURE', offset: 0, length: 5),
            ],
            style: const TextStyle(color: Colors.black),
            mentionStyle: const TextStyle(color: Colors.blue),
            onMentionTap: (_) {},
          ),
        ),
      ),
    );
    expect(mentionRootSpan(tester).toPlainText(), 'plain message');
    expect(tester.takeException(), isNull);
  });
}
