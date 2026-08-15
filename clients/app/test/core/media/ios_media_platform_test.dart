import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/media/camera_capture_service.dart';
import 'package:im_client/core/media/dd_file_picker.dart';
import 'package:im_client/core/media/media_export_service.dart';
import 'package:im_client/core/media/remote_media_action_service_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('iOS media platform routing', () {
    testWidgets('Photos picker stays path based and preserves limits', (
      tester,
    ) async {
      const channel = MethodChannel('dd/file_picker');
      MethodCall? captured;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        captured = call;
        return <Map<String, Object?>>[
          <String, Object?>{
            'path': '/private/var/mobile/Containers/Data/DD/photo.mov',
            'name': 'photo.mov',
            'mimeType': 'video/quicktime',
            'size': 524288000,
          },
        ];
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final files = await ddOpenFiles(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: '媒体',
            mimeTypes: <String>['image/jpeg', 'video/quicktime'],
          ),
        ],
        source: DdFilePickerSource.photos,
        maxFiles: 30,
        maxBytes: 2 * 1024 * 1024 * 1024,
      );
      debugDefaultTargetPlatformOverride = null;

      expect(captured?.method, 'openFiles');
      expect(captured?.arguments, <String, Object?>{
        'allowMultiple': true,
        'source': 'photos',
        'mimeTypes': <String>['image/jpeg', 'video/quicktime'],
        'maxFiles': 30,
        'maxBytes': 2 * 1024 * 1024 * 1024,
        'preserveLivePhoto': false,
      });
      expect(files, hasLength(1));
      expect(files.single.path, endsWith('photo.mov'));
      expect(files.single.mimeType, 'video/quicktime');
    });

    testWidgets('Live Photo picker preserves still and motion pair metadata', (
      tester,
    ) async {
      const channel = MethodChannel('dd/file_picker');
      MethodCall? captured;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        captured = call;
        return <Map<String, Object?>>[
          <String, Object?>{
            'kind': 'livePhoto',
            'assetIdentifier': 'PH-LIVE-1',
            'still': <String, Object?>{
              'path': '/private/dd_picker/live.heic',
              'name': 'IMG_0001.HEIC',
              'mimeType': 'image/heic',
              'size': 4096,
            },
            'motion': <String, Object?>{
              'path': '/private/dd_picker/live.mov',
              'name': 'IMG_0001.MOV',
              'mimeType': 'video/quicktime',
              'size': 8192,
            },
          },
        ];
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final picked = await ddOpenMediaFiles(
        source: DdFilePickerSource.photos,
        maxFiles: 5,
        maxBytes: 64 * 1024 * 1024,
      );
      debugDefaultTargetPlatformOverride = null;

      expect(
        (captured?.arguments as Map<Object?, Object?>?)?['preserveLivePhoto'],
        isTrue,
      );
      expect(picked, hasLength(1));
      expect(picked.single.kind, DdPickedMediaKind.livePhoto);
      expect(picked.single.assetIdentifier, 'PH-LIVE-1');
      expect(picked.single.primary.path, endsWith('live.heic'));
      expect(picked.single.motion?.path, endsWith('live.mov'));
      expect(picked.single.primarySizeBytes, 4096);
      expect(picked.single.motionSizeBytes, 8192);
    });

    testWidgets('Files picker routes through native path contract', (
      tester,
    ) async {
      const channel = MethodChannel('dd/file_picker');
      MethodCall? captured;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        captured = call;
        return const <Map<String, Object?>>[];
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await ddOpenFile(maxBytes: 500 * 1024 * 1024);
      debugDefaultTargetPlatformOverride = null;

      expect(captured?.method, 'openFiles');
      expect(
        (captured?.arguments as Map<Object?, Object?>?)?['source'],
        'files',
      );
      expect(
        (captured?.arguments as Map<Object?, Object?>?)?['maxBytes'],
        500 * 1024 * 1024,
      );
    });

    testWidgets('Photos picker keeps denial code and settings recovery', (
      tester,
    ) async {
      const channel = MethodChannel('dd/file_picker');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'openAppSettings') return null;
        throw PlatformException(
          code: 'PHOTO_LIBRARY_PERMISSION_DENIED',
          message: '照片权限被拒绝。',
        );
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await expectLater(
        ddOpenFile(source: DdFilePickerSource.photos),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'PHOTO_LIBRARY_PERMISSION_DENIED',
          ),
        ),
      );
      await ddOpenFilePickerAppSettings();
      debugDefaultTargetPlatformOverride = null;
      expect(calls, <String>['openFiles', 'openAppSettings']);
    });

    testWidgets('camera is supported and surfaces permission denial', (
      tester,
    ) async {
      const channel = MethodChannel('dd/camera_capture');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        throw PlatformException(
          code: 'CAMERA_PERMISSION_DENIED',
          message: '相机权限被拒绝。',
        );
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      final service = CameraCaptureService(platform: TargetPlatform.iOS);
      expect(service.isSupported, isTrue);
      await expectLater(
        service.capturePhoto(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'CAMERA_PERMISSION_DENIED',
          ),
        ),
      );
    });

    test('local video save share and copy use native path APIs', () async {
      const channel = MethodChannel('dd/media_export');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final directory = await Directory.systemTemp.createTemp('dd-ios-media-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}large.mov');
      await file.writeAsBytes(<int>[0, 1, 2, 3]);
      final actions = RemoteMediaActionService(platform: TargetPlatform.iOS);

      final saved = await actions.saveVideo(
        url: file.uri,
        mimeType: 'video/quicktime',
        suggestedName: 'large.mov',
      );
      final shared = await actions.shareVideo(
        url: file.uri,
        mimeType: 'video/quicktime',
        suggestedName: 'large.mov',
      );
      final copied = await actions.copyVideo(
        url: file.uri,
        mimeType: 'video/quicktime',
        suggestedName: 'large.mov',
      );

      expect(calls.map((call) => call.method), <String>[
        'saveLocalVideoToGallery',
        'shareLocalFile',
        'copyLocalFileToClipboard',
      ]);
      expect(
        (calls.first.arguments as Map<Object?, Object?>)['path'],
        file.path,
      );
      expect(saved, contains('相册'));
      expect(shared, contains('系统分享'));
      expect(copied, contains('复制'));
    });

    test('native share false is not reported as success', () async {
      const channel = MethodChannel('dd/media_export');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final directory = await Directory.systemTemp.createTemp('dd-ios-share-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}clip.mp4');
      await file.writeAsBytes(<int>[0, 1, 2, 3]);

      await expectLater(
        RemoteMediaActionService(platform: TargetPlatform.iOS).shareVideo(
          url: file.uri,
          mimeType: 'video/mp4',
          suggestedName: 'clip.mp4',
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'MEDIA_SHARE_FAILED',
          ),
        ),
      );
    });

    testWidgets('image export uses native Photos channel', (tester) async {
      const channel = MethodChannel('dd/media_export');
      MethodCall? captured;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        captured = call;
        return 'ph://asset/42';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      final message = await MediaExportService(platform: TargetPlatform.iOS)
          .saveImage(
            bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
            mimeType: 'image/png',
            suggestedName: 'DD-image.png',
          );

      expect(captured?.method, 'saveImageToGallery');
      expect(message, contains('相册'));
    });
  });
}
