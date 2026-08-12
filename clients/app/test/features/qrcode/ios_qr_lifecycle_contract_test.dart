import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'QR scanner explicitly manages iOS camera lifecycle and duplicate scans',
    () {
      final scanner = File(
        'lib/features/qrcode/presentation/qr_scanner_page.dart',
      ).readAsStringSync();

      expect(scanner, contains('TargetPlatform.iOS'));
      expect(scanner, contains('DetectionSpeed.noDuplicates'));
      expect(scanner, contains('with WidgetsBindingObserver'));
      expect(scanner, contains('autoStart: !_manualCameraLifecycle'));
      expect(scanner, contains('didChangeAppLifecycleState'));
      expect(scanner, contains('_scannerController.stop()'));
      expect(scanner, contains('_scannerController.start()'));
      expect(scanner, contains('DdFilePickerSource.photos'));
      expect(scanner, contains('DdQrPayload.parse(raw)'));
    },
  );
}
