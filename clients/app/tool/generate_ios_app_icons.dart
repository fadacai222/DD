import 'dart:io';

import 'ios_app_icon_generator.dart';

Future<void> main() async {
  final source = File('../../设计图/brand-assets/DD-logo-master.png');
  final contents = File(
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
  );
  final output = Directory(
    'ios/Runner/Assets.xcassets/AppIcon.appiconset',
  );
  if (!source.existsSync()) {
    stderr.writeln('Missing canonical DD logo master: ${source.path}');
    exitCode = 1;
    return;
  }
  await generateIosAppIcons(
    sourceFile: source,
    contentsFile: contents,
    outputDirectory: output,
  );
  stdout.writeln('DD iOS AppIcon assets generated from ${source.path}');
}
