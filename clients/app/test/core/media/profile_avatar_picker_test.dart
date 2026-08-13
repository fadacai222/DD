import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/profile_avatar_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS avatar picker uses DD native Photos path contract', (tester) async {
    const channel = MethodChannel('dd/file_picker');
    MethodCall? captured;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return <Map<String, Object?>>[
        <String, Object?>{
          'path': '/private/var/mobile/Containers/Data/DD/avatar.jpg',
          'name': 'avatar.jpg',
          'mimeType': 'image/jpeg',
          'size': 2048,
        },
      ];
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final file = await pickProfileAvatarImage();
    debugDefaultTargetPlatformOverride = null;

    expect(file?.path, endsWith('avatar.jpg'));
    expect(captured?.method, 'openFiles');
    expect(
      (captured?.arguments as Map<Object?, Object?>?)?['source'],
      'photos',
    );
  });
}
