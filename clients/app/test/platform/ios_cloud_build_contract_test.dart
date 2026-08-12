import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cloud analyzer ignores generated iOS build dependencies', () {
    final analysisOptions = File('analysis_options.yaml').readAsStringSync();

    expect(analysisOptions, contains('exclude:'));
    expect(analysisOptions, contains('- build/**'));
  });
}
