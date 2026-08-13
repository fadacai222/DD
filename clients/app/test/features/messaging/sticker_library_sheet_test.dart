import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/sticker_api_client.dart';
import 'package:im_client/features/messaging/domain/sticker_models.dart';
import 'package:im_client/features/messaging/presentation/sticker_library_sheet.dart';
import 'package:im_client/features/messaging/presentation/widgets/telegram_tgs_sticker.dart';

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
    'GIF custom sticker renders actual animated image instead of label',
    (tester) async {
      final gateway = _FakeStickerGateway(custom: [_custom('gif-1')]);
      await _openSheet(tester, gateway);

      await tester.tap(find.byKey(const Key('sticker-tab-custom')));
      await tester.pumpAndSettle();

      final cell = find.byKey(const Key('custom-sticker-gif-1'));
      expect(cell, findsOneWidget);
      expect(
        find.descendant(of: cell, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cell, matching: find.text('GIF')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'video custom stickers retry visibility after bottom sheet entrance animation',
    (tester) async {
      final resolved = <String>[];
      final gateway = _FakeStickerGateway(custom: [_videoCustom('video-1')]);
      await _openSheet(
        tester,
        gateway,
        initialTabKey: 'custom',
        mediaUrlResolver: (mediaId, expectedSizeBytes) async {
          resolved.add('$mediaId:$expectedSizeBytes');
          throw StateError('stop before native playback in widget test');
        },
      );

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.byKey(const Key('custom-sticker-video-1')), findsOneWidget);
      expect(resolved, contains('media-video-1:1024'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Telegram TGS sticker animates without unsupported warning', (
    tester,
  ) async {
    final gateway = _FakeStickerGateway(packs: [_tgsPack()]);
    await _openSheet(tester, gateway, mediaBytesLoader: _tgsMediaBytes);

    await tester.tap(find.byKey(const Key('sticker-tab-pack-tgs-pack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(TelegramTgsSticker), findsWidgets);
    expect(find.textContaining('动态/视频表情暂不支持'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy partial Telegram pack refreshes when opened', (
    tester,
  ) async {
    final refreshed = _refreshedPartialPack();
    final gateway = _FakeStickerGateway(
      packs: [_legacyPartialPack()],
      partialRefreshResult: refreshed,
    );
    await _openSheet(
      tester,
      gateway,
      mediaBytesLoader: _mixedPartialMediaBytes,
    );

    await tester.tap(find.byKey(const Key('sticker-tab-pack-partial-pack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    expect(gateway.importedSetNames, ['Animated_by_TestBot']);
    expect(find.textContaining('动态/视频表情暂不支持'), findsNothing);
    expect(find.textContaining('个表情导入失败'), findsNothing);
    expect(find.byType(TelegramTgsSticker), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet restores semantic tab and reports tab changes', (
    tester,
  ) async {
    final gateway = _FakeStickerGateway(packs: [_pack('pack-1', 'Animals')]);
    final changedTabs = <String>[];
    await _openSheet(
      tester,
      gateway,
      initialTabKey: 'pack:pack-1',
      onTabChanged: changedTabs.add,
    );

    expect(find.text('Animals'), findsOneWidget);
    expect(find.byKey(const Key('pack-sticker-item-pack-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sticker-tab-custom')));
    await tester.pumpAndSettle();
    expect(changedTabs, ['custom']);
    expect(find.byKey(const Key('sticker-custom-grid')), findsOneWidget);
  });

  testWidgets(
    'open sticker sheet silently syncs packs added on another device',
    (tester) async {
      final gateway = _FakeStickerGateway();
      await _openSheet(tester, gateway);

      expect(
        find.byKey(const Key('sticker-tab-pack-remote-pack')),
        findsNothing,
      );

      gateway.packs.add(_pack('remote-pack', 'Remote'));
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();

      expect(
        find.byKey(const Key('sticker-tab-pack-remote-pack')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing remembered pack falls back to custom stickers', (
    tester,
  ) async {
    final gateway = _FakeStickerGateway(custom: [_custom('custom-1')]);
    await _openSheet(tester, gateway, initialTabKey: 'pack:removed-pack');

    expect(find.byKey(const Key('sticker-custom-grid')), findsOneWidget);
    expect(find.byKey(const Key('custom-sticker-custom-1')), findsOneWidget);
  });

  testWidgets('adding a custom sticker appears immediately without reopening', (
    tester,
  ) async {
    final gateway = _FakeStickerGateway();
    await _openSheet(
      tester,
      gateway,
      onAddCustomSticker: (_) async {
        final created = _custom('fresh-custom');
        gateway.custom.add(created);
        return created;
      },
    );

    await tester.tap(find.byKey(const Key('sticker-tab-custom')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('custom-sticker-fresh-custom')), findsNothing);

    await tester.tap(find.byKey(const Key('sticker-custom-add')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('custom-sticker-fresh-custom')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import adds a pack tab and remove makes it disappear immediately',
    (tester) async {
      final gateway = _FakeStickerGateway();
      await _openSheet(tester, gateway);

      await _submitTelegramImport(
        tester,
        'https://t.me/addstickers/Animals_by_TestBot',
      );

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

  testWidgets(
    'invalid Telegram link stays visible in sheet after dialog closes without request',
    (tester) async {
      final gateway = _FakeStickerGateway();
      await _openSheet(tester, gateway);

      await _submitTelegramImport(
        tester,
        'https://example.com/addstickers/Animals_by_TestBot',
      );

      expect(gateway.importedSetNames, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      final feedback = find.byKey(const Key('sticker-operation-feedback'));
      expect(feedback, findsOneWidget);
      expect(
        find.descendant(
          of: feedback,
          matching: find.textContaining('只允许导入 Telegram 官方贴纸包链接'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Telegram import exposes stable friendly error matrix and diagnostic codes',
    (tester) async {
      final gateway = _FakeStickerGateway(
        importHandler: (setName) async {
          switch (setName) {
            case 'NoRelay':
              throw const StickerApiException(
                statusCode: 503,
                code: 'TELEGRAM_STICKER_RELAY_NOT_CONFIGURED',
                message: 'relay not configured',
              );
            case 'RelayBusy':
              throw const StickerApiException(
                statusCode: 502,
                code: 'TELEGRAM_STICKER_RELAY_UNAVAILABLE',
                message: 'relay unavailable',
              );
            case 'RelayLimited':
              throw const StickerApiException(
                statusCode: 429,
                code: 'TELEGRAM_STICKER_RELAY_RATE_LIMITED',
                message: 'telegram rate limited',
              );
            case 'RelayTimeout':
              throw const StickerApiException(
                statusCode: 504,
                code: 'TELEGRAM_STICKER_RELAY_TIMEOUT',
                message: 'telegram timeout',
              );
            case 'MissingPack':
              throw const StickerApiException(
                statusCode: 404,
                code: 'TELEGRAM_STICKER_PACK_NOT_FOUND',
                message: 'not found',
              );
            case 'UnsupportedPack':
              throw const StickerApiException(
                statusCode: 422,
                code: 'TELEGRAM_STICKER_FORMAT_UNSUPPORTED',
                message: 'unsupported',
              );
            case 'TooLargePack':
              throw const StickerApiException(
                statusCode: 422,
                code: 'TELEGRAM_STICKER_TOO_LARGE',
                message: 'too large',
              );
            case 'NetworkTimeout':
              throw const StickerApiException(
                statusCode: 0,
                code: 'STICKER_REQUEST_TIMEOUT',
                message: 'timeout',
              );
            case 'ServerBoom':
              throw const StickerApiException(
                statusCode: 500,
                code: 'STICKER_INTERNAL_ERROR',
                message: 'internal',
              );
          }
          throw StateError('unexpected set name $setName');
        },
      );
      await _openSheet(tester, gateway);

      final cases = <(String, String, String)>[
        ('NoRelay', '服务端未配置 Telegram sticker relay', 'TELEGRAM_STICKER_RELAY_NOT_CONFIGURED'),
        ('RelayBusy', 'Telegram 贴纸中继暂时不可用', 'TELEGRAM_STICKER_RELAY_UNAVAILABLE'),
        ('RelayLimited', 'Telegram 当前正在限流', 'TELEGRAM_STICKER_RELAY_RATE_LIMITED'),
        ('RelayTimeout', 'Telegram 贴纸中继请求超时', 'TELEGRAM_STICKER_RELAY_TIMEOUT'),
        ('MissingPack', '没有找到这个 Telegram 贴纸包', 'TELEGRAM_STICKER_PACK_NOT_FOUND'),
        ('UnsupportedPack', '支持静态 WebP/PNG、动态 TGS、视频 WebM', 'TELEGRAM_STICKER_FORMAT_UNSUPPORTED'),
        ('TooLargePack', '文件超过当前实例允许的大小', 'TELEGRAM_STICKER_TOO_LARGE'),
        ('NetworkTimeout', '网络请求超时', 'STICKER_REQUEST_TIMEOUT'),
        ('ServerBoom', 'DD 表情服务暂时异常', 'STICKER_INTERNAL_ERROR'),
      ];

      for (final item in cases) {
        await _submitTelegramImport(tester, item.$1);
        final feedback = find.byKey(const Key('sticker-operation-feedback'));
        expect(feedback, findsOneWidget);
        expect(
          find.descendant(of: feedback, matching: find.textContaining(item.$2)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: feedback, matching: find.textContaining(item.$3)),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets('partial Telegram import keeps supported stickers and shows counts', (
    tester,
  ) async {
    final partial = _packWithCounts(
      'partial-import',
      'Partial',
      supportedStickerCount: 2,
      unsupportedStickerCount: 1,
    );
    final gateway = _FakeStickerGateway(
      importHandler: (_) async => partial,
    );
    await _openSheet(tester, gateway);

    await _submitTelegramImport(tester, 'Partial_by_TestBot');

    expect(
      find.byKey(const Key('sticker-tab-pack-partial-import')),
      findsOneWidget,
    );
    expect(find.text('Partial'), findsOneWidget);
    final feedback = find.byKey(const Key('sticker-operation-feedback'));
    expect(feedback, findsOneWidget);
    expect(
      find.descendant(
        of: feedback,
        matching: find.textContaining('已添加 2 个表情；1 个文件导入失败'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('successful retry clears old Telegram import error and selects pack', (
    tester,
  ) async {
    var attempts = 0;
    final gateway = _FakeStickerGateway(
      importHandler: (_) async {
        attempts++;
        if (attempts == 1) {
          throw const StickerApiException(
            statusCode: 503,
            code: 'TELEGRAM_STICKER_RELAY_NOT_CONFIGURED',
            message: 'relay not configured',
          );
        }
        return _pack('retry-pack', 'RetrySuccess');
      },
    );
    await _openSheet(tester, gateway);

    await _submitTelegramImport(tester, 'Retry_by_TestBot');
    expect(find.byKey(const Key('sticker-operation-feedback')), findsOneWidget);

    await _submitTelegramImport(tester, 'Retry_by_TestBot');

    expect(find.byKey(const Key('sticker-operation-feedback')), findsNothing);
    expect(find.byKey(const Key('sticker-tab-pack-retry-pack')), findsOneWidget);
    expect(find.text('RetrySuccess'), findsOneWidget);
  });

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

  testWidgets('emoji library exposes standard category navigation', (
    tester,
  ) async {
    await _openSheet(tester, _FakeStickerGateway());

    expect(find.byKey(const Key('emoji-category-tabs')), findsOneWidget);
    expect(
      find.byKey(const Key('emoji-category-smileysPeople')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('emoji-category-flags')));
    await tester.pump();

    expect(find.text('🇱🇰'), findsOneWidget);
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

Future<void> _openSheet(
  WidgetTester tester,
  StickerGateway gateway, {
  Future<CustomStickerItem?> Function(StickerGateway gateway)?
  onAddCustomSticker,
  String initialTabKey = 'emoji',
  ValueChanged<String>? onTabChanged,
  Future<Uint8List> Function(String mediaId)? mediaBytesLoader,
  Future<Uri> Function(String mediaId, int expectedSizeBytes)?
  mediaUrlResolver,
}) async {
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
                mediaBytesLoader: mediaBytesLoader ?? _mediaBytes,
                mediaUrlResolver: mediaUrlResolver,
                onAddCustomSticker: onAddCustomSticker ?? (_) async => null,
                initialTabKey: initialTabKey,
                onTabChanged: onTabChanged,
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

Future<void> _submitTelegramImport(
  WidgetTester tester,
  String value,
) async {
  await tester.tap(find.byKey(const Key('sticker-import-pack')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('telegram-sticker-link-input')),
    value,
  );
  await tester.tap(find.byKey(const Key('telegram-sticker-import-confirm')));
  await tester.pumpAndSettle();
}

Future<Uint8List> _mediaBytes(String _) async => Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);

Future<Uint8List> _tgsMediaBytes(String _) async => Uint8List.fromList(
  gzip.encode(
    utf8.encode(
      '{"v":"5.7.4","fr":60,"ip":0,"op":60,"w":512,"h":512,"nm":"DD test","ddd":0,"assets":[],"layers":[]}',
    ),
  ),
);

Future<Uint8List> _mixedPartialMediaBytes(String mediaId) =>
    mediaId == 'media-static' ? _mediaBytes(mediaId) : _tgsMediaBytes(mediaId);

StickerPackItemGroup _tgsPack() => StickerPackItemGroup(
  id: 'tgs-pack',
  setName: 'Animated_by_TestBot',
  title: 'Animated',
  coverMediaId: 'media-tgs',
  supportedStickerCount: 1,
  unsupportedStickerCount: 0,
  sortOrder: 0,
  items: [
    StickerPackItem(
      id: 'item-tgs',
      mediaId: 'media-tgs',
      emoji: '✨',
      mimeType: 'application/x-tgsticker',
      width: 512,
      height: 512,
      sizeBytes: 1024,
      sortOrder: 0,
    ),
  ],
  updatedAt: DateTime.utc(2026, 8, 12, 3, 49),
);

StickerPackItemGroup _legacyPartialPack() => StickerPackItemGroup(
  id: 'partial-pack',
  setName: 'Animated_by_TestBot',
  title: 'Animated',
  coverMediaId: 'media-static',
  supportedStickerCount: 1,
  unsupportedStickerCount: 1,
  sortOrder: 0,
  items: [
    StickerPackItem(
      id: 'item-static',
      mediaId: 'media-static',
      emoji: '🙂',
      mimeType: 'image/webp',
      width: 512,
      height: 512,
      sizeBytes: 2048,
      sortOrder: 0,
    ),
  ],
  updatedAt: DateTime.utc(2026, 8, 11, 23, 30),
);

StickerPackItemGroup _refreshedPartialPack() => StickerPackItemGroup(
  id: 'partial-pack',
  setName: 'Animated_by_TestBot',
  title: 'Animated',
  coverMediaId: 'media-tgs',
  supportedStickerCount: 1,
  unsupportedStickerCount: 0,
  sortOrder: 0,
  items: [
    StickerPackItem(
      id: 'item-tgs-refreshed',
      mediaId: 'media-tgs',
      emoji: '✨',
      mimeType: 'application/x-tgsticker',
      width: 512,
      height: 512,
      sizeBytes: 1024,
      sortOrder: 0,
    ),
  ],
  updatedAt: DateTime.utc(2026, 8, 12, 4, 20),
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

CustomStickerItem _videoCustom(String id) => CustomStickerItem(
  id: id,
  mediaId: 'media-$id',
  mimeType: 'video/mp4',
  width: 288,
  height: 512,
  sizeBytes: 1024,
  sortOrder: 0,
  createdAt: DateTime.utc(2026, 8, 12, 3, 55),
);

StickerPackItemGroup _pack(String id, String title) => _packWithCounts(
  id,
  title,
  supportedStickerCount: 1,
  unsupportedStickerCount: 0,
);

StickerPackItemGroup _packWithCounts(
  String id,
  String title, {
  required int supportedStickerCount,
  required int unsupportedStickerCount,
}) => StickerPackItemGroup(
  id: id,
  setName: '${title}_by_TestBot',
  title: title,
  coverMediaId: 'cover-$id',
  supportedStickerCount: supportedStickerCount,
  unsupportedStickerCount: unsupportedStickerCount,
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
    this.partialRefreshResult,
    this.importHandler,
  }) : custom = List<CustomStickerItem>.from(custom),
       packs = List<StickerPackItemGroup>.from(packs);

  final List<CustomStickerItem> custom;
  final List<StickerPackItemGroup> packs;
  final StickerPackItemGroup? partialRefreshResult;
  final Future<StickerPackItemGroup> Function(String setName)? importHandler;
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
    final handler = importHandler;
    if (handler != null) {
      final pack = await handler(setName);
      final index = packs.indexWhere((item) => item.id == pack.id);
      if (index >= 0) {
        packs[index] = pack;
      } else {
        packs.add(pack);
      }
      return pack;
    }
    final refresh = partialRefreshResult;
    if (refresh != null && refresh.setName == setName) {
      final index = packs.indexWhere((pack) => pack.setName == setName);
      if (index >= 0) {
        packs[index] = refresh;
      } else {
        packs.add(refresh);
      }
      return refresh;
    }
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
