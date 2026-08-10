import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/avatar_crop_page.dart';
import 'package:im_client/core/media/avatar_image_processor.dart';

void main() {
  group('AvatarCropGeometry', () {
    test(
      'long, wide and square images start equal-width without distortion',
      () {
        const editor = Size(332, 450);
        for (final source in <Size>[
          const Size(1080, 2400),
          const Size(2400, 1080),
          const Size(1080, 1080),
        ]) {
          final layout = AvatarCropGeometry.initialLayout(
            editorSize: editor,
            imageWidth: source.width.toInt(),
            imageHeight: source.height.toInt(),
          );
          final displayedWidth = source.width * layout.imageScale;
          final displayedHeight = source.height * layout.imageScale;

          expect(displayedWidth, closeTo(editor.width, 0.001));
          expect(
            displayedWidth / displayedHeight,
            closeTo(source.width / source.height, 0.000001),
          );
          expect(layout.cropRect.width, closeTo(layout.cropRect.height, 0.001));
          expect(layout.cropRect.width, greaterThan(0));

          final visibleImage =
              (layout.imageOffset & Size(displayedWidth, displayedHeight))
                  .intersect(Offset.zero & editor);
          expect(visibleImage.contains(layout.cropRect.topLeft), isTrue);
          expect(visibleImage.contains(layout.cropRect.bottomRight), isTrue);
        }
      },
    );

    test('all eight handles resize a square without escaping image bounds', () {
      const start = Rect.fromLTWH(80, 90, 150, 150);
      const bounds = Rect.fromLTWH(20, 30, 280, 280);
      const delta = Offset(30, 20);

      for (final handle in AvatarCropHandle.values) {
        final resized = AvatarCropGeometry.resizeCrop(
          start: start,
          handle: handle,
          delta: delta,
          bounds: bounds,
          minSide: 88,
        );
        expect(resized, isNot(start), reason: handle.name);
        expect(
          resized.width,
          closeTo(resized.height, 0.000001),
          reason: handle.name,
        );
        expect(resized.width, greaterThanOrEqualTo(88), reason: handle.name);
        expect(
          resized.left,
          greaterThanOrEqualTo(bounds.left),
          reason: handle.name,
        );
        expect(
          resized.top,
          greaterThanOrEqualTo(bounds.top),
          reason: handle.name,
        );
        expect(
          resized.right,
          lessThanOrEqualTo(bounds.right),
          reason: handle.name,
        );
        expect(
          resized.bottom,
          lessThanOrEqualTo(bounds.bottom),
          reason: handle.name,
        );
        expect(resized.left.isFinite, isTrue, reason: handle.name);
        expect(resized.top.isFinite, isTrue, reason: handle.name);
      }
    });

    test('image offset clamp always covers the crop rect', () {
      const imageSize = Size(1080, 2400);
      const crop = Rect.fromLTWH(80, 100, 180, 180);
      const scale = 0.35;
      final offset = AvatarCropGeometry.clampImageOffset(
        desired: const Offset(9999, -9999),
        scale: scale,
        imageSize: imageSize,
        cropRect: crop,
      );
      final imageRect =
          offset & Size(imageSize.width * scale, imageSize.height * scale);

      expect(imageRect.left, lessThanOrEqualTo(crop.left));
      expect(imageRect.top, lessThanOrEqualTo(crop.top));
      expect(imageRect.right, greaterThanOrEqualTo(crop.right));
      expect(imageRect.bottom, greaterThanOrEqualTo(crop.bottom));
    });

    test('selection uses oriented dimensions after quarter turns', () {
      final selection = AvatarCropGeometry.selection(
        cropRect: const Rect.fromLTWH(50, 100, 100, 100),
        imageOffset: Offset.zero,
        imageScale: 1,
        imageWidth: 400,
        imageHeight: 200,
        quarterTurns: 1,
      );

      // After a 90-degree turn the logical image is 200x400.
      expect(selection.left, closeTo(0.25, 0.000001));
      expect(selection.top, closeTo(0.25, 0.000001));
      expect(selection.width, closeTo(0.5, 0.000001));
      expect(selection.height, closeTo(0.25, 0.000001));
      expect(selection.quarterTurns, 1);
    });
  });

  testWidgets(
    'editor exposes eight anchors and four required toolbar actions',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: AvatarCropPage(
            preview: AvatarCropPreview(
              bytes: Uint8List.fromList(<int>[1, 2, 3]),
              width: 1080,
              height: 2400,
            ),
          ),
        ),
      );
      await tester.pump();

      for (final handle in AvatarCropHandle.values) {
        expect(
          find.byKey(Key('avatar-crop-handle-${handle.name}')),
          findsOneWidget,
          reason: handle.name,
        );
      }
      expect(find.byKey(const Key('avatar-crop-cancel')), findsOneWidget);
      expect(find.byKey(const Key('avatar-crop-rotate')), findsOneWidget);
      expect(find.byKey(const Key('avatar-crop-reset')), findsOneWidget);
      expect(find.byKey(const Key('avatar-crop-complete')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rotate four times returns completion to original orientation', (
    tester,
  ) async {
    AvatarCropSelection? result;
    final preview = AvatarCropPreview(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      width: 1080,
      height: 2400,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<AvatarCropSelection>(
                MaterialPageRoute<AvatarCropSelection>(
                  builder: (_) => AvatarCropPage(preview: preview),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (var index = 0; index < 4; index++) {
      await tester.tap(find.byKey(const Key('avatar-crop-rotate')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('avatar-crop-complete')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.quarterTurns, 0);
    expect(result!.width, greaterThan(0));
    expect(result!.height, greaterThan(0));
    expect(result!.left + result!.width, lessThanOrEqualTo(1.000001));
    expect(result!.top + result!.height, lessThanOrEqualTo(1.000001));
  });

  testWidgets('cancel returns without a crop result', (tester) async {
    AvatarCropSelection? result;
    var finished = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<AvatarCropSelection>(
                MaterialPageRoute<AvatarCropSelection>(
                  builder: (_) => AvatarCropPage(
                    preview: AvatarCropPreview(
                      bytes: Uint8List.fromList(<int>[1]),
                      width: 2400,
                      height: 1080,
                    ),
                  ),
                ),
              );
              finished = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('avatar-crop-cancel')));
    await tester.pumpAndSettle();

    expect(finished, isTrue);
    expect(result, isNull);
  });
}
