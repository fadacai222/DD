import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cloud analyzer only scans DD-owned Dart source roots', () {
    final analysisOptions = File('analysis_options.yaml').readAsStringSync();
    final codemagic = File('../../codemagic.yaml').readAsStringSync();

    expect(analysisOptions, contains('exclude:'));
    expect(analysisOptions, contains('- build/**'));
    expect(
      RegExp(r'dart analyze --fatal-infos lib').allMatches(codemagic).length,
      2,
    );
    expect(
      RegExp(r'dart analyze --fatal-infos test').allMatches(codemagic).length,
      2,
    );
    expect(
      RegExp(r'dart analyze --fatal-infos tool').allMatches(codemagic).length,
      2,
    );
    expect(codemagic, isNot(contains('script: dart analyze --fatal-infos\n')));
    expect(codemagic, contains('Package unsigned IPA for manual re-signing'));
    expect(
      codemagic,
      contains(r'- $CM_BUILD_DIR/clients/app/build/ios/DD-unsigned.ipa'),
    );
    expect(codemagic, contains('Transient SwiftPM/network download failure'));
    expect(codemagic, contains("grep -Eiq 'downloadError|could not connect to server"));
    expect(RegExp(r'#!/usr/bin/env bash').allMatches(codemagic).length, greaterThanOrEqualTo(2));
    expect(codemagic, contains(r'${PIPESTATUS[0]}'));
    expect(codemagic, contains(r'exit "$status"'));
  });
}
