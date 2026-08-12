import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/media/dd_file_picker.dart';
import '../../../theme/app_theme.dart';
import '../../groups/domain/group_models.dart';
import '../data/qr_api_client.dart';
import '../domain/dd_qr_payload.dart';

enum QrScanResultKind { user, group, loginApproved }

final class QrScanResult {
  const QrScanResult._({required this.kind, this.userId, this.group});

  const QrScanResult.user(String userId)
    : this._(kind: QrScanResultKind.user, userId: userId);

  const QrScanResult.group(GroupInfo group)
    : this._(kind: QrScanResultKind.group, group: group);

  const QrScanResult.loginApproved()
    : this._(kind: QrScanResultKind.loginApproved);

  final QrScanResultKind kind;
  final String? userId;
  final GroupInfo? group;
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.onUnauthorized,
    this.gateway,
  });

  final Uri origin;
  final String accessToken;
  final Future<String?> Function() onUnauthorized;
  final QrGateway? gateway;

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage>
    with WidgetsBindingObserver {
  late final QrGateway _gateway;
  late final bool _ownsGateway;
  late final MobileScannerController _scannerController;
  final TextEditingController _manualController = TextEditingController();
  bool _processing = false;
  String? _error;

  bool get _cameraSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  bool get _galleryAnalyzeSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get _manualCameraLifecycle =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? QrApiClient();
    _scannerController = MobileScannerController(
      autoStart: !_manualCameraLifecycle,
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    if (_manualCameraLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_startIosScanner());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_manualCameraLifecycle ||
        !_scannerController.value.hasCameraPermission) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_startIosScanner());
      case AppLifecycleState.inactive:
        unawaited(_scannerController.stop());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        return;
    }
  }

  Future<void> _startIosScanner() async {
    try {
      await _scannerController.start();
    } catch (error) {
      if (mounted) setState(() => _error = '摄像头无法启动：$error');
    }
  }

  @override
  void dispose() {
    if (_manualCameraLifecycle) WidgetsBinding.instance.removeObserver(this);
    _manualController.dispose();
    unawaited(_scannerController.dispose());
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          '扫一扫',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        actions: [
          if (_galleryAnalyzeSupported)
            IconButton(
              key: const Key('qr-scan-gallery'),
              tooltip: '从相册识别',
              onPressed: _processing
                  ? null
                  : () => unawaited(_scanFromGallery()),
              icon: const Icon(Icons.photo_library_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _cameraSupported ? _cameraView() : _desktopFallback(),
            ),
            if (_error != null)
              Container(
                width: double.infinity,
                color: const Color(0xFF2A1515),
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFF9C9C),
                    fontSize: 12,
                  ),
                ),
              ),
            Container(
              width: double.infinity,
              color: const Color(0xFF101010),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    key: const Key('qr-scan-paste'),
                    onPressed: _processing
                        ? null
                        : () => unawaited(_pastePayload()),
                    icon: const Icon(Icons.content_paste_rounded),
                    label: const Text('粘贴二维码内容'),
                  ),
                  if (_cameraSupported) ...[
                    const SizedBox(width: 14),
                    IconButton(
                      key: const Key('qr-scan-torch'),
                      tooltip: '手电筒',
                      onPressed: _processing
                          ? null
                          : () => unawaited(_scannerController.toggleTorch()),
                      icon: const Icon(Icons.flashlight_on_outlined),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cameraView() {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          key: const Key('dd-mobile-scanner'),
          controller: _scannerController,
          onDetect: (capture) {
            if (_processing) return;
            for (final barcode in capture.barcodes) {
              final raw = barcode.rawValue?.trim();
              if (raw != null && raw.isNotEmpty) {
                unawaited(_handlePayload(raw));
                break;
              }
            }
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Text(
                '摄像头无法启动：${error.errorCode.name}\n\n可以使用下方“粘贴二维码内容”。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 246,
              height: 246,
              decoration: BoxDecoration(
                border: Border.all(color: DdColors.green, width: 2.4),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ),
        if (_processing)
          const ColoredBox(
            color: Color(0x44000000),
            child: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
      ],
    );
  }

  Widget _desktopFallback() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.qr_code_scanner_rounded,
                size: 58,
                color: Colors.white70,
              ),
              const SizedBox(height: 16),
              const Text(
                '当前桌面平台不启用摄像头扫码',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Windows 主要用于展示扫码登录二维码。若要在这里处理 DD 二维码，可粘贴二维码内容。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, height: 1.5),
              ),
              const SizedBox(height: 18),
              TextField(
                key: const Key('qr-scan-manual-input'),
                controller: _manualController,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'dd://qr/v1/...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF252525),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('qr-scan-manual-submit'),
                onPressed: _processing
                    ? null
                    : () => unawaited(_handlePayload(_manualController.text)),
                child: const Text('解析'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _scanFromGallery() async {
    const images = XTypeGroup(
      label: '二维码图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
      mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
    );
    XFile? file;
    try {
      file = await ddOpenFile(
        acceptedTypeGroups: const [images],
        source: DdFilePickerSource.photos,
        maxBytes: 32 * 1024 * 1024,
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      final message = error.message ?? '无法读取所选二维码图片。';
      setState(() => _error = message);
      if (isDdPhotoLibraryPermissionError(error)) {
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
      return;
    }
    if (file == null || !mounted) return;
    try {
      final capture = await _scannerController.analyzeImage(file.path);
      String? raw;
      for (final barcode in capture?.barcodes ?? const <Barcode>[]) {
        final value = barcode.rawValue?.trim();
        if (value != null && value.isNotEmpty) {
          raw = value;
          break;
        }
      }
      if (raw == null) {
        setState(() => _error = '这张图片里没有识别到二维码。');
        return;
      }
      await _handlePayload(raw);
    } catch (error) {
      if (mounted) setState(() => _error = '无法识别这张图片：$error');
    }
  }

  Future<void> _pastePayload() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      if (mounted) setState(() => _error = '剪贴板里没有文本二维码内容。');
      return;
    }
    _manualController.text = raw;
    await _handlePayload(raw);
  }

  Future<void> _handlePayload(String raw) async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      final payload = DdQrPayload.parse(raw);
      if (!payload.belongsTo(widget.origin)) {
        throw FormatException(
          '这个二维码属于 ${payload.instance.host}，当前登录的是 ${widget.origin.host}。当前版本不跨实例自动跳转。',
        );
      }
      switch (payload.kind) {
        case DdQrKind.user:
          if (!mounted) return;
          Navigator.pop(context, QrScanResult.user(payload.userId!));
        case DdQrKind.group:
          final group = await _authorized(
            (token) => _gateway.redeemGroupInvite(
              origin: widget.origin,
              accessToken: token,
              nonce: payload.nonce!,
            ),
          );
          if (!mounted) return;
          Navigator.pop(context, QrScanResult.group(group));
        case DdQrKind.login:
          final scanned = await _authorized(
            (token) => _gateway.scanLogin(
              origin: widget.origin,
              accessToken: token,
              nonce: payload.nonce!,
            ),
          );
          if (!mounted) return;
          final approved = await _confirmDevice(scanned);
          if (!mounted || approved == null) return;
          await _authorized(
            (token) => _gateway.confirmLogin(
              origin: widget.origin,
              accessToken: token,
              nonce: payload.nonce!,
              approved: approved,
            ),
          );
          if (!mounted) return;
          if (approved) {
            Navigator.pop(context, const QrScanResult.loginApproved());
          } else {
            setState(() => _error = '已拒绝这次扫码登录。');
          }
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on QrApiException catch (error) {
      if (mounted) setState(() => _error = _friendlyApiError(error));
    } catch (error) {
      if (mounted) setState(() => _error = '扫码处理失败：$error');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<bool?> _confirmDevice(QrLoginState state) {
    final device = state.device;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认登录 DD？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('你正在授权以下新设备登录当前账号：'),
            const SizedBox(height: 14),
            _deviceLine(Icons.devices_rounded, '设备', device.name),
            _deviceLine(Icons.memory_rounded, '平台', device.platform),
            if (device.appVersion.isNotEmpty)
              _deviceLine(Icons.info_outline_rounded, '版本', device.appVersion),
            const SizedBox(height: 12),
            const Text(
              '如果不是你本人刚刚在这台设备上打开的二维码，请选择拒绝。',
              style: TextStyle(
                color: DdColors.danger,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('拒绝', style: TextStyle(color: DdColors.danger)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认登录'),
          ),
        ],
      ),
    );
  }

  Widget _deviceLine(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 19, color: DdColors.textSecondary),
          const SizedBox(width: 8),
          Text(
            '$label：',
            style: const TextStyle(color: DdColors.textSecondary),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    try {
      return await action(widget.accessToken);
    } on QrApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    }
  }

  String _friendlyApiError(QrApiException error) => switch (error.code) {
    'QR_EXPIRED' => '这个二维码已经过期，请重新生成。',
    'QR_CONSUMED' => '这个登录二维码已经使用过，不能重复使用。',
    'QR_LOGIN_REJECTED' => '这次扫码登录已被拒绝。',
    'QR_STATE_CONFLICT' => '二维码状态已经变化，请刷新后重试。',
    'QR_FORBIDDEN' => '当前账号没有权限使用这个二维码。',
    'QR_NOT_FOUND' => '二维码凭证不存在或已经失效。',
    _ => error.message,
  };
}
