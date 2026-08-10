import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/sticker_api_client.dart';
import 'package:im_client/features/messaging/domain/sticker_models.dart';
import 'package:im_client/features/messaging/presentation/sticker_library_sheet.dart';

void main() {
  testWidgets('sheet exposes emoji custom and dynamic pack tabs', (
    tester,
  ) async {
    final gateway = _FakeStickerGateway(
      custom: [_custom('custom-1')],
      packs: [_pack('pack-1', 'Animals')],
    );
    await _openSheet(tester, gateway);

    expect(find.byKey(const Key('sticker-tab-emoji')), findsOneWidget);
    expect(find.byKey(const Key('sticker-tab-custom')), findsOneWidget);
    expect(find.byKey(const Key('sticker-tab-pack-pack-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sticker-tab-custom')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sticker-custom-add')), findsOneWidget);
    expect(find.byKey(const Key('custom-sticker-custom-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sticker-tab-pack-pack-1')));
    await tester.pumpAndSettle();
    expect(find.text('Animals'), findsOneWidget);
    expect(find.byKey(const Key('pack-sticker-item-pack-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import adds a pack tab and remove makes it disappear immediately',
    (tester) async {
      final gateway = _FakeStickerGateway();
      await _openSheet(tester, gateway);

      await tester.tap(find.byKey(const Key('sticker-import-pack')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('telegram-sticker-link-input')),
        'https://t.me/addstickers/Animals_by_TestBot',
      );
      await tester.tap(
        find.byKey(const Key('telegram-sticker-import-confirm')),
      );
      await tester.pumpAndSettle();

      expect(gateway.importedSetNames, ['Animals_by_TestBot']);
      expect(
        find.byKey(const Key('sticker-tab-pack-imported-pack')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('sticker-remove-pack')));
      await tester.pumpAndSettle();
      expect(find.text('移除贴纸包？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pumpAndSettle();

      expect(gateway.removedPackIds, ['imported-pack']);
      expect(
        find.byKey(const Key('sticker-tab-pack-imported-pack')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('custom sticker manager supports organize multi-select delete', (
    tester,
  ) async {
    final gateway = _FakeStickerGateway(
      custom: [_custom('custom-a'), _custom('custom-b')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CustomStickerManagerPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          gateway: gateway,
          initialItems: gateway.custom,
          mediaBytesLoader: _mediaBytes,
          onAddCustomSticker: (_) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('整理'), findsOneWidget);
    await tester.tap(find.byKey(const Key('custom-sticker-organize')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('custom-sticker-manager-custom-a')));
    await tester.tap(find.byKey(const Key('custom-sticker-manager-custom-b')));
    await tester.pump();
    expect(find.text('删除 (2)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('custom-sticker-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(gateway.deletedStickerIds, ['custom-a', 'custom-b']);
    expect(
      find.byKey(const Key('custom-sticker-manager-custom-a')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('custom-sticker-manager-custom-b')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large custom sticker grid scrolls without overflow', (
    tester,
  ) async {
    final items = List<CustomStickerItem>.generate(
      200,
      (index) => _custom('bulk-$index'),
    );
    final gateway = _FakeStickerGateway(custom: items);
    await tester.pumpWidget(
      MaterialApp(
        home: CustomStickerManagerPage(
          origin: Uri.parse('http://127.0.0.1:18473'),
          accessToken: 'token',
          gateway: gateway,
          initialItems: items,
          mediaBytesLoader: _mediaBytes,
          onAddCustomSticker: (_) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('custom-sticker-manager-grid')),
      const Offset(0, -900),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openSheet(WidgetTester tester, StickerGateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            key: const Key('open-sticker-sheet'),
            onPressed: () => showModalBottomSheet<StickerPanelResult>(
              context: context,
              isScrollControlled: true,
              builder: (_) => StickerLibrarySheet(
                origin: Uri.parse('http://127.0.0.1:18473'),
                accessToken: 'token',
                emoji: const ['😀', '😂'],
                recentEmoji: const ['😀'],
                mediaBytesLoader: _mediaBytes,
                onAddCustomSticker: (_) async => null,
                gateway: gateway,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-sticker-sheet')));
  await tester.pumpAndSettle();
}

Future<Uint8List> _mediaBytes(String _) async => Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);

CustomStickerItem _custom(String id) => CustomStickerItem(
  id: id,
  mediaId: 'media-$id',
  mimeType: 'image/gif',
  width: 512,
  height: 512,
  sizeBytes: 1024,
  sortOrder: 0,
  createdAt: DateTime.utc(2026, 8, 10, 7, 30),
);

StickerPackItemGroup _pack(String id, String title) => StickerPackItemGroup(
  id: id,
  setName: '${title}_by_TestBot',
  title: title,
  coverMediaId: 'cover-$id',
  supportedStickerCount: 1,
  unsupportedStickerCount: 0,
  sortOrder: 0,
  items: [
    StickerPackItem(
      id: 'item-$id',
      mediaId: 'media-$id',
      emoji: '🙂',
      mimeType: 'image/webp',
      width: 512,
      height: 512,
      sizeBytes: 2048,
      sortOrder: 0,
    ),
  ],
  updatedAt: DateTime.utc(2026, 8, 10, 7, 30),
);

final class _FakeStickerGateway implements StickerGateway {
  _FakeStickerGateway({
    List<CustomStickerItem> custom = const [],
    List<StickerPackItemGroup> packs = const [],
  }) : custom = List<CustomStickerItem>.from(custom),
       packs = List<StickerPackItemGroup>.from(packs);

  final List<CustomStickerItem> custom;
  final List<StickerPackItemGroup> packs;
  final List<String> importedSetNames = [];
  final List<String> removedPackIds = [];
  final List<String> deletedStickerIds = [];

  @override
  Future<List<CustomStickerItem>> listCustomStickers({
    required Uri origin,
    required String accessToken,
  }) async => List<CustomStickerItem>.unmodifiable(custom);

  @override
  Future<CustomStickerItem> createCustomSticker({
    required Uri origin,
    required String accessToken,
    required String mediaId,
    required int width,
    required int height,
  }) async {
    final item = _custom('created-${custom.length}');
    custom.add(item);
    return item;
  }

  @override
  Future<void> deleteCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  }) async {
    deletedStickerIds.addAll(stickerIds);
    custom.removeWhere((item) => stickerIds.contains(item.id));
  }

  @override
  Future<void> reorderCustomStickers({
    required Uri origin,
    required String accessToken,
    required List<String> stickerIds,
  }) async {}

  @override
  Future<List<StickerPackItemGroup>> listStickerPacks({
    required Uri origin,
    required String accessToken,
  }) async => List<StickerPackItemGroup>.unmodifiable(packs);

  @override
  Future<StickerPackItemGroup> importTelegramPack({
    required Uri origin,
    required String accessToken,
    required String setName,
  }) async {
    importedSetNames.add(setName);
    final pack = _pack('imported-pack', 'Imported');
    packs.add(pack);
    return pack;
  }

  @override
  Future<void> removeStickerPack({
    required Uri origin,
    required String accessToken,
    required String packId,
  }) async {
    removedPackIds.add(packId);
    packs.removeWhere((pack) => pack.id == packId);
  }

  @override
  void close() {}
}
