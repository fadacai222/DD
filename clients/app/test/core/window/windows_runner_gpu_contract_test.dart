import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runner explicitly prefers the high performance GPU', () {
    final source = File('windows/runner/main.cpp').readAsStringSync();

    expect(source, contains('project.set_gpu_preference('));
    expect(
      source,
      contains('flutter::GpuPreference::HighPerformancePreference);'),
    );
  });
}
