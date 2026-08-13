import 'package:file_selector/file_selector.dart';

import 'avatar_image_processor.dart';
import 'dd_file_picker.dart';

const XTypeGroup _profileAvatarImageGroup = XTypeGroup(
  label: '图片',
  extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
  mimeTypes: <String>['image/jpeg', 'image/png', 'image/webp'],
);

Future<XFile?> pickProfileAvatarImage() {
  return ddOpenFile(
    acceptedTypeGroups: const <XTypeGroup>[_profileAvatarImageGroup],
    source: DdFilePickerSource.photos,
    maxBytes: maxAvatarSourceBytes,
  );
}

Future<void> openProfileAvatarPickerSettings() => ddOpenFilePickerAppSettings();
