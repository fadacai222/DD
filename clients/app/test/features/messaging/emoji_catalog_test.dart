import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/domain/emoji_catalog.dart';

void main() {
  test('emoji catalog exposes broad categorized Unicode coverage', () {
    expect(EmojiCatalog.categories.length, 8);
    expect(EmojiCatalog.all.length, greaterThan(900));
    expect(EmojiCatalog.all, contains('🇱🇰'));
    expect(EmojiCatalog.all, contains('👨‍👩‍👧‍👦'));
    expect(EmojiCatalog.all, contains('👩🏽‍💻'));
    expect(EmojiCatalog.all, contains('🏳️‍🌈'));

    for (final category in EmojiCatalog.categories) {
      expect(category.items, isNotEmpty, reason: category.label);
      expect(category.items.toSet().length, category.items.length);
    }
  });

  test('emoji catalog never exposes standalone skin modifiers', () {
    for (final modifier in const <String>['🏻', '🏼', '🏽', '🏾', '🏿']) {
      expect(EmojiCatalog.all, isNot(contains(modifier)));
    }
  });
}
