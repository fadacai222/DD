import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/contacts/domain/contact_models.dart';
import 'package:im_client/features/messaging/presentation/mention_composer_controller.dart';

void main() {
  const alice = ContactMentionSuggestion(
    user: ContactUser(
      id: 'user-alice',
      handle: 'alice',
      displayName: 'Alice',
      bio: '',
    ),
    relationship: 'CONTACT',
  );

  group('detectMentionTrigger', () {
    test('detects @ and @ali near caret', () {
      var value = const TextEditingValue(
        text: '你好 @',
        selection: TextSelection.collapsed(offset: 4),
      );
      var trigger = detectMentionTrigger(value)!;
      expect(trigger.start, 3);
      expect(trigger.query, '');

      value = const TextEditingValue(
        text: '你好 @ali',
        selection: TextSelection.collapsed(offset: 7),
      );
      trigger = detectMentionTrigger(value)!;
      expect(trigger.start, 3);
      expect(trigger.query, 'ali');
      expect(trigger.tokenEnd, 7);
    });

    test('rejects email, @@, invalid token and active IME composing', () {
      for (final value in <TextEditingValue>[
        const TextEditingValue(
          text: 'hello@example',
          selection: TextSelection.collapsed(offset: 13),
        ),
        const TextEditingValue(
          text: '@@alice',
          selection: TextSelection.collapsed(offset: 7),
        ),
        const TextEditingValue(
          text: '@al-ice',
          selection: TextSelection.collapsed(offset: 7),
        ),
        const TextEditingValue(
          text: '@ali',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 1, end: 4),
        ),
      ]) {
        expect(detectMentionTrigger(value), isNull, reason: value.text);
      }
    });

    test('caret in existing token replaces full token', () {
      const value = TextEditingValue(
        text: 'hi @alixe world',
        selection: TextSelection.collapsed(offset: 6),
      );
      final trigger = detectMentionTrigger(value)!;
      expect(trigger.query, 'al');
      expect(trigger.tokenEnd, 9);
      final updated = applyMentionSuggestion(
        value: value,
        trigger: trigger,
        suggestion: alice,
      );
      expect(updated.text, 'hi @alice world');
      expect(updated.selection.baseOffset, 10);
    });
  });

  test('debounces, caches and ignores stale responses', () async {
    final requests = <String>[];
    final completers = <String, Completer<List<ContactMentionSuggestion>>>{};
    final controller = MentionComposerController(
      debounce: const Duration(milliseconds: 10),
      loader: (query) {
        requests.add(query);
        return (completers[query] ??=
                Completer<List<ContactMentionSuggestion>>())
            .future;
      },
    );
    addTearDown(controller.dispose);

    controller.update(
      const TextEditingValue(
        text: '@al',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, ['al']);

    controller.update(
      const TextEditingValue(
        text: '@ali',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, ['al', 'ali']);

    completers['al']!.complete([alice]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.suggestions, isEmpty);

    completers['ali']!.complete([alice]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.suggestions, [alice]);
    expect(controller.visible, isTrue);

    controller.close();
    controller.update(
      const TextEditingValue(
        text: '@ali',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(controller.suggestions, [alice]);
    expect(requests, ['al', 'ali']);
  });

  test('selection wraps and short query does not request', () async {
    var calls = 0;
    final bob = ContactMentionSuggestion(
      user: const ContactUser(
        id: 'user-bob',
        handle: 'bob',
        displayName: 'Bob',
        bio: '',
      ),
      relationship: 'NONE',
    );
    final controller = MentionComposerController(
      debounce: Duration.zero,
      loader: (_) async {
        calls++;
        return [alice, bob];
      },
    );
    addTearDown(controller.dispose);

    controller.update(
      const TextEditingValue(
        text: '@a',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);

    controller.update(
      const TextEditingValue(
        text: '@al',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(controller.selectedSuggestion, alice);
    controller.moveSelection(-1);
    expect(controller.selectedSuggestion, bob);
    controller.moveSelection(1);
    expect(controller.selectedSuggestion, alice);
  });
}
