import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/windows_clipboard_image_service.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows image bytes consume Ctrl+V as image paste', () async {
    final bytes = _pngBytes(2, 3);
    final gateway = _FakeClipboardGateway(imageBytes: bytes);
    final decider = _windowsDecider(gateway);

    final decision = await decider.decide();

    expect(decision.kind, ClipboardPasteDecisionKind.consumeImage);
    expect(decision.shouldConsumeShortcut, isTrue);
    expect(decision.image?.bytes, bytes);
    expect(decision.image?.path, isNull);
    expect(decision.image?.mimeType, 'image/png');
    expect(decision.image?.sizeBytes, bytes.length);
    expect(decision.image?.suggestedName, endsWith('.png'));
    expect(await decision.image!.toXFile().readAsBytes(), bytes);
  });

  test(
    'Windows clipboard image file path is recognized without loading it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dd-clipboard-test-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File(
        '${directory.path}${Platform.pathSeparator}screen shot.PNG',
      );
      final bytes = _pngBytes(4, 5);
      await file.writeAsBytes(bytes, flush: true);
      final gateway = _FakeClipboardGateway(files: <String>[file.path]);
      final decider = _windowsDecider(gateway);

      final decision = await decider.decide();

      expect(decision.kind, ClipboardPasteDecisionKind.consumeImage);
      expect(decision.image?.bytes, isNull);
      expect(decision.image?.path, file.path);
      expect(decision.image?.mimeType, 'image/png');
      expect(decision.image?.sizeBytes, bytes.length);
      expect(decision.image?.suggestedName, 'screen shot.PNG');
      expect(decision.image!.toXFile().path, file.path);
    },
  );

  test(
    'clipboard containing only text passes through to native TextField paste',
    () async {
      final gateway = _FakeClipboardGateway(text: 'hello');
      final decider = _windowsDecider(gateway);

      final decision = await decider.decide();

      expect(decision.kind, ClipboardPasteDecisionKind.passThrough);
      expect(decision.shouldConsumeShortcut, isFalse);
    },
  );

  test('bitmap wins when clipboard also exposes text representation', () async {
    final bytes = _pngBytes(2, 2);
    final gateway = _FakeClipboardGateway(
      imageBytes: bytes,
      text: 'screenshot',
    );
    final decider = _windowsDecider(gateway);

    final decision = await decider.decide();

    expect(decision.kind, ClipboardPasteDecisionKind.consumeImage);
    expect(
      gateway.textReads,
      0,
      reason: 'image success must not fall back to text',
    );
  });

  test('empty clipboard passes through', () async {
    final decider = _windowsDecider(_FakeClipboardGateway());

    final decision = await decider.decide();

    expect(decision.kind, ClipboardPasteDecisionKind.passThrough);
  });

  test(
    'malformed image returns typed visible error instead of throwing',
    () async {
      final gateway = _FakeClipboardGateway(
        imageBytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      );
      final decider = _windowsDecider(gateway);

      final decision = await decider.decide();

      expect(decision.kind, ClipboardPasteDecisionKind.showImageError);
      expect(decision.error?.code, ClipboardImageErrorCode.malformedImage);
      expect(decision.shouldConsumeShortcut, isTrue);
    },
  );

  test(
    'clipboard image read exception falls back to native text paste when text exists',
    () async {
      final gateway = _FakeClipboardGateway(
        imageError: StateError('clipboard busy'),
        text: 'fallback text',
      );
      final decider = _windowsDecider(gateway);

      final decision = await decider.decide();

      expect(decision.kind, ClipboardPasteDecisionKind.passThrough);
      expect(decision.shouldConsumeShortcut, isFalse);
    },
  );

  test(
    'non-Windows platform never intercepts or reads clipboard image',
    () async {
      final gateway = _FakeClipboardGateway(imageBytes: _pngBytes(1, 1));
      final adapter = WindowsClipboardImageAdapter(gateway: gateway);
      final decider = WindowsClipboardPasteDecider(
        adapter: adapter,
        platform: TargetPlatform.android,
        isWeb: false,
      );

      final decision = await decider.decide();

      expect(decision.kind, ClipboardPasteDecisionKind.passThrough);
      expect(gateway.imageReads, 0);
      expect(gateway.fileReads, 0);
    },
  );

  test(
    'image key repeat is consumed without creating another send task',
    () async {
      final gateway = _FakeClipboardGateway(imageBytes: _pngBytes(2, 2));
      final decider = _windowsDecider(gateway);

      final first = await decider.decide();
      final repeated = await decider.decide(isKeyRepeat: true);

      expect(first.kind, ClipboardPasteDecisionKind.consumeImage);
      expect(repeated.kind, ClipboardPasteDecisionKind.consumeDuplicateImage);
      expect(repeated.shouldConsumeShortcut, isTrue);
      expect(repeated.image, isNull);
    },
  );

  test('each fresh Ctrl+V reads the latest clipboard image', () async {
    final firstBytes = _pngBytes(2, 2);
    final secondBytes = _pngBytes(3, 3);
    final gateway = _FakeClipboardGateway(imageBytes: firstBytes);
    final decider = _windowsDecider(gateway);

    final first = await decider.decide();
    gateway.imageBytes = secondBytes;
    final second = await decider.decide();

    expect(first.image?.sizeBytes, firstBytes.length);
    expect(second.image?.sizeBytes, secondBytes.length);
    expect(gateway.imageReads, 2);
  });
}

WindowsClipboardPasteDecider _windowsDecider(_FakeClipboardGateway gateway) {
  return WindowsClipboardPasteDecider(
    adapter: WindowsClipboardImageAdapter(gateway: gateway),
    platform: TargetPlatform.windows,
    isWeb: false,
  );
}

Uint8List _pngBytes(int width, int height) {
  return Uint8List.fromList(
    img.encodePng(img.Image(width: width, height: height)),
  );
}

final class _FakeClipboardGateway implements ClipboardGateway {
  _FakeClipboardGateway({
    this.imageBytes,
    this.files = const <String>[],
    this.text,
    this.imageError,
  });

  Uint8List? imageBytes;
  List<String> files;
  String? text;
  Object? imageError;
  int imageReads = 0;
  int fileReads = 0;
  int textReads = 0;

  @override
  Future<Uint8List?> readImageBytes() async {
    imageReads++;
    final error = imageError;
    if (error != null) throw error;
    return imageBytes;
  }

  @override
  Future<List<String>> readFiles() async {
    fileReads++;
    return files;
  }

  @override
  Future<String?> readText() async {
    textReads++;
    return text;
  }
}
