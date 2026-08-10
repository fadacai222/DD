import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

Future<Source> createAppSoundSource(Uint8List bytes) async =>
    BytesSource(bytes);
