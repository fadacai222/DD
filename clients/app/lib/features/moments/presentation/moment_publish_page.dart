import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/media/chat_image_processor.dart';
import '../../../core/media/dd_file_picker.dart';
import '../../../theme/app_theme.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/domain/contact_models.dart';
import '../../messaging/data/media_api_client.dart';
import '../../messaging/data/messaging_api_client.dart';
import '../../messaging/data/video_media_probe.dart';
import '../data/moments_api_client.dart';

class MomentPublishPage extends StatefulWidget {
  const MomentPublishPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.onUnauthorized,
    this.gateway,
    this.contactsGateway,
    this.mediaApi,
  });

  final Uri origin;
  final String accessToken;
  final Future<String?> Function() onUnauthorized;
  final MomentsGateway? gateway;
  final ContactsGateway? contactsGateway;
  final MediaApiClient? mediaApi;

  @override
  State<MomentPublishPage> createState() => _MomentPublishPageState();
}

class _MomentPublishPageState extends State<MomentPublishPage> {
  late final MomentsGateway _gateway;
  late final ContactsGateway _contacts;
  late final MediaApiClient _media;
  late final bool _ownsGateway;
  late final bool _ownsContacts;
  late final bool _ownsMedia;
  final TextEditingController _text = TextEditingController();
  final List<_SelectedMomentImage> _images = [];
  _SelectedMomentVideo? _video;
  String _visibility = 'ALL_CONTACTS';
  List<ContactItem> _visibilityContacts = const [];
  bool _busy = false;
  String? _error;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _ownsContacts = widget.contactsGateway == null;
    _ownsMedia = widget.mediaApi == null;
    _gateway = widget.gateway ?? MomentsApiClient();
    _contacts = widget.contactsGateway ?? ContactsApiClient();
    _media = widget.mediaApi ?? MediaApiClient();
  }

  @override
  void dispose() {
    _text.dispose();
    if (_ownsGateway) _gateway.close();
    if (_ownsContacts) _contacts.close();
    if (_ownsMedia) _media.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '发表朋友圈',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              key: const Key('moment-publish-submit'),
              onPressed:
                  _busy ||
                      (_text.text.trim().isEmpty &&
                          _images.isEmpty &&
                          _video == null)
                  ? null
                  : () => unawaited(_publish()),
              style: FilledButton.styleFrom(
                backgroundColor: DdColors.green,
                minimumSize: const Size(58, 34),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('发表'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            if (_error != null) ...[
              Material(
                color: const Color(0xFFFFE8E8),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: DdColors.danger,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('moment-publish-text'),
              controller: _text,
              enabled: !_busy,
              minLines: 5,
              maxLines: 12,
              maxLength: 2000,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '这一刻的想法…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            _mediaComposer(),
            if (_busy && (_images.isNotEmpty || _video != null)) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: _progress <= 0 ? null : _progress.clamp(0, 1),
              ),
            ],
            const SizedBox(height: 22),
            const Divider(height: 1),
            ListTile(
              key: const Key('moment-publish-visibility'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.people_outline_rounded),
              title: const Text('谁可以看'),
              subtitle: Text(_visibilityLabel()),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => unawaited(_chooseVisibility()),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Text(
                '朋友圈媒体会先上传到当前 DD 实例的私有对象存储；服务端按好友关系、黑名单和本条可见范围重新鉴权。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: DdColors.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediaComposer() {
    final video = _video;
    if (video != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            height: 150,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Image.memory(video.posterJpeg, fit: BoxFit.cover),
                ),
                const Center(
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: Color(0x99000000),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 34,
                      color: Colors.white,
                    ),
                  ),
                ),
                Positioned(
                  right: 6,
                  top: 6,
                  child: InkWell(
                    key: const Key('moment-publish-remove-video'),
                    onTap: _busy ? null : () => setState(() => _video = null),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 17,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 7,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.58),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: Text(
                        _durationLabel(video.durationMs),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '视频朋友圈每条支持 1 个视频',
            style: TextStyle(fontSize: 11, color: DdColors.textTertiary),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _imageGrid(),
        if (_images.isEmpty) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('moment-publish-add-video'),
            onPressed: _busy ? null : () => unawaited(_pickVideo()),
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('选择视频'),
          ),
        ],
      ],
    );
  }

  Widget _imageGrid() {
    final count = _images.length + (_images.length < 9 ? 1 : 0);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 7,
        mainAxisSpacing: 7,
      ),
      itemCount: count,
      itemBuilder: (context, index) {
        if (index == _images.length) {
          return Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              key: const Key('moment-publish-add-media'),
              onTap: _busy ? null : () => unawaited(_pickImages()),
              child: const Center(
                child: Icon(
                  Icons.add_rounded,
                  size: 34,
                  color: DdColors.textSecondary,
                ),
              ),
            ),
          );
        }
        final item = _images[index];
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                item.bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
            Positioned(
              right: 4,
              top: 4,
              child: InkWell(
                key: Key('moment-publish-remove-$index'),
                onTap: _busy
                    ? null
                    : () => setState(() => _images.removeAt(index)),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.58),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickImages() async {
    if (_video != null) return;
    const imageGroup = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
      mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
    );
    late final List<XFile> files;
    try {
      files = await ddOpenFiles(
        acceptedTypeGroups: const [imageGroup],
        source: DdFilePickerSource.photos,
        maxFiles: 9 - _images.length,
        maxBytes: maxChatImageSourceBytes,
      );
    } on PlatformException catch (error) {
      _handlePhotoPickerError(error);
      return;
    }
    if (files.isEmpty || !mounted) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final remaining = 9 - _images.length;
      for (final file in files.take(remaining)) {
        final length = await file.length();
        if (length <= 0) throw const FormatException('不能发表空图片。');
        if (length > maxChatImageSourceBytes) {
          throw FormatException(
            '${file.name.isEmpty ? '图片' : file.name} 超过 96 MiB。',
          );
        }
        final bytes = await file.readAsBytes();
        final processed = await processChatImage(bytes);
        if (!mounted) return;
        _images.add(
          _SelectedMomentImage(
            bytes: processed.bytes,
            fileName: '${DateTime.now().microsecondsSinceEpoch}.jpg',
          ),
        );
      }
    } catch (error) {
      _error = _friendlyError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickVideo() async {
    if (_images.isNotEmpty || _video != null) return;
    const videoGroup = XTypeGroup(
      label: '视频',
      extensions: ['mp4', 'webm', 'mov', 'mkv'],
      mimeTypes: [
        'video/mp4',
        'video/webm',
        'video/quicktime',
        'video/x-matroska',
      ],
    );
    XFile? file;
    try {
      file = await ddOpenFile(
        acceptedTypeGroups: const [videoGroup],
        source: DdFilePickerSource.photos,
        maxBytes: 2 * 1024 * 1024 * 1024,
      );
    } on PlatformException catch (error) {
      _handlePhotoPickerError(error);
      return;
    }
    final selectedFile = file;
    if (selectedFile == null || !mounted) return;
    final length = await selectedFile.length();
    if (!mounted) return;
    if (length <= 0) {
      setState(() => _error = '不能发表空视频。');
      return;
    }
    if (length > 2 * 1024 * 1024 * 1024) {
      setState(() => _error = '视频超过 2 GiB，当前实例拒绝上传。');
      return;
    }
    final mimeType = _videoMimeType(selectedFile.name);
    if (mimeType == null) {
      setState(() => _error = '当前只支持 MP4、WebM、MOV、MKV 视频。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final metadata = await const VideoMediaProbe().probeFile(selectedFile);
      if (!mounted) return;
      setState(() {
        _video = _SelectedMomentVideo(
          file: selectedFile,
          fileName: selectedFile.name.isEmpty
              ? 'moment-video.mp4'
              : selectedFile.name,
          mimeType: mimeType,
          sizeBytes: length,
          posterJpeg: metadata.posterJpeg,
          durationMs: metadata.durationMs,
        );
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法解析这个视频，请换一个可正常播放的视频。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _videoMimeType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    return null;
  }

  String _durationLabel(int durationMs) {
    final totalSeconds = (durationMs ~/ 1000).clamp(0, 24 * 60 * 60 - 1);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _handlePhotoPickerError(PlatformException error) {
    if (!mounted) return;
    final message = error.message ?? '读取所选媒体失败。';
    setState(() => _error = message);
    if (!isDdPhotoLibraryPermissionError(error)) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: '去设置',
          onPressed: () => unawaited(ddOpenFilePickerAppSettings()),
        ),
      ),
    );
  }

  Future<void> _chooseVisibility() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          _visibilityTile(
            sheetContext,
            'ALL_CONTACTS',
            '公开给所有联系人',
            Icons.public_rounded,
          ),
          _visibilityTile(sheetContext, 'PRIVATE', '部分可见', Icons.group_rounded),
          _visibilityTile(
            sheetContext,
            'EXCLUDE',
            '不给谁看',
            Icons.visibility_off_outlined,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'ALL_CONTACTS') {
      setState(() {
        _visibility = choice;
        _visibilityContacts = const [];
      });
      return;
    }
    final selected = await _pickContacts(
      title: choice == 'PRIVATE' ? '选择可见联系人' : '选择不给谁看',
      initial: _visibility == choice
          ? _visibilityContacts.map((item) => item.user.id).toSet()
          : const <String>{},
    );
    if (selected == null ||
        !mounted ||
        (choice == 'PRIVATE' && selected.isEmpty)) {
      return;
    }
    setState(() {
      _visibility = choice;
      _visibilityContacts = selected;
    });
  }

  Widget _visibilityTile(
    BuildContext sheetContext,
    String value,
    String label,
    IconData icon,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: _visibility == value
          ? const Icon(Icons.check_rounded, color: DdColors.green)
          : null,
      onTap: () => Navigator.pop(sheetContext, value),
    );
  }

  Future<List<ContactItem>?> _pickContacts({
    required String title,
    required Set<String> initial,
  }) async {
    try {
      final page = await _authorized(
        (token) =>
            _contacts.listContacts(origin: widget.origin, accessToken: token),
      );
      if (!mounted) return null;
      return Navigator.of(context).push<List<ContactItem>>(
        MaterialPageRoute<List<ContactItem>>(
          builder: (_) => _MomentContactPickerPage(
            title: title,
            contacts: page.items,
            initialIds: initial,
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
      return null;
    }
  }

  Future<void> _publish() async {
    if (_busy ||
        (_text.text.trim().isEmpty && _images.isEmpty && _video == null)) {
      return;
    }
    if (_visibility == 'PRIVATE' && _visibilityContacts.isEmpty) {
      setState(() => _error = '“部分可见”至少选择一个联系人。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    try {
      final mediaIds = <String>[];
      for (var index = 0; index < _images.length; index++) {
        final item = _images[index];
        final grant = await _authorized(
          (token) => _media.uploadMedia(
            origin: widget.origin,
            accessToken: token,
            bytes: item.bytes,
            fileName: item.fileName,
            mimeType: 'image/jpeg',
            purpose: 'MOMENT_IMAGE',
            onProgress: (sent, total) {
              if (!mounted || total <= 0) return;
              final partial = sent / total;
              setState(() => _progress = (index + partial) / _images.length);
            },
          ),
        );
        mediaIds.add(grant.mediaId);
      }
      final video = _video;
      if (video != null) {
        final grant = await _authorized(
          (token) => _media.uploadStream(
            origin: widget.origin,
            accessToken: token,
            streamFactory: video.file.openRead,
            size: video.sizeBytes,
            fileName: video.fileName,
            mimeType: video.mimeType,
            purpose: 'MOMENT_VIDEO',
            onProgress: (sent, total) {
              if (!mounted || total <= 0) return;
              setState(() => _progress = sent / total);
            },
          ),
        );
        mediaIds.add(grant.mediaId);
      }
      await _authorized(
        (token) => _gateway.createMoment(
          origin: widget.origin,
          accessToken: token,
          text: _text.text.trim(),
          mediaIds: mediaIds,
          visibility: _visibility,
          visibilityUserIds: _visibilityContacts
              .map((item) => item.user.id)
              .toList(growable: false),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    try {
      return await action(widget.accessToken);
    } on MomentsApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    } on ContactsApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    } on MessagingApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    }
  }

  String _visibilityLabel() {
    return switch (_visibility) {
      'PRIVATE' =>
        _visibilityContacts.isEmpty
            ? '部分可见'
            : '部分可见 · ${_visibilityContacts.length} 人',
      'EXCLUDE' =>
        _visibilityContacts.isEmpty
            ? '不给谁看'
            : '不给 ${_visibilityContacts.length} 人看',
      _ => '所有联系人',
    };
  }

  String _friendlyError(Object error) {
    if (error is MomentsApiException) return error.message;
    if (error is ContactsApiException) return error.message;
    return error.toString().replaceFirst('FormatException: ', '');
  }
}

final class _SelectedMomentImage {
  const _SelectedMomentImage({required this.bytes, required this.fileName});
  final Uint8List bytes;
  final String fileName;
}

final class _SelectedMomentVideo {
  const _SelectedMomentVideo({
    required this.file,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.posterJpeg,
    required this.durationMs,
  });

  final XFile file;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final Uint8List posterJpeg;
  final int durationMs;
}

class _MomentContactPickerPage extends StatefulWidget {
  const _MomentContactPickerPage({
    required this.title,
    required this.contacts,
    required this.initialIds,
  });

  final String title;
  final List<ContactItem> contacts;
  final Set<String> initialIds;

  @override
  State<_MomentContactPickerPage> createState() =>
      _MomentContactPickerPageState();
}

class _MomentContactPickerPageState extends State<_MomentContactPickerPage> {
  late final Set<String> _selected = {...widget.initialIds};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              widget.contacts
                  .where((item) => _selected.contains(item.user.id))
                  .toList(growable: false),
            ),
            child: Text('完成(${_selected.length})'),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: widget.contacts.length,
        itemBuilder: (context, index) {
          final item = widget.contacts[index];
          return CheckboxListTile(
            value: _selected.contains(item.user.id),
            title: Text(
              item.remark.isEmpty ? item.user.displayName : item.remark,
            ),
            subtitle: Text('@${item.user.handle}'),
            onChanged: (value) => setState(() {
              if (value == true) {
                _selected.add(item.user.id);
              } else {
                _selected.remove(item.user.id);
              }
            }),
          );
        },
      ),
    );
  }
}
