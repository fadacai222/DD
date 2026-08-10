import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/data/auth_api_client.dart';
import '../../auth/domain/auth_session.dart';
import '../data/qr_api_client.dart';
import 'qr_code_card.dart';

class QrLoginPage extends StatefulWidget {
  const QrLoginPage({
    super.key,
    required this.origin,
    this.gateway,
  });

  final Uri origin;
  final QrGateway? gateway;

  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  late final QrGateway _gateway;
  late final bool _ownsGateway;
  QrLoginState? _state;
  Timer? _pollTimer;
  bool _polling = false;
  bool _consuming = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? QrApiClient();
    unawaited(_create());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '扫码登录',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: state == null
              ? _error == null
                    ? const CircularProgressIndicator()
                    : _failedState()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.payload case final payload? when payload.isNotEmpty)
                      DdQrCodeCard(
                        payload: payload,
                        title: '使用手机 DD 扫码',
                        subtitle: _statusLabel(state.status),
                        footer:
                            '二维码仅在当前 DD 实例有效 · 约 2 分钟过期 · 必须在手机上再次确认',
                      )
                    else
                      _statusOnly(state),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: DdColors.danger,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  Widget _statusOnly(QrLoginState state) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          state.status == 'REJECTED' || state.status == 'EXPIRED'
              ? Icons.error_outline_rounded
              : Icons.qr_code_2_rounded,
          size: 68,
          color: state.status == 'REJECTED' || state.status == 'EXPIRED'
              ? DdColors.danger
              : DdColors.green,
        ),
        const SizedBox(height: 14),
        Text(
          _statusLabel(state.status),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        if (state.status == 'REJECTED' || state.status == 'EXPIRED') ...[
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('qr-login-regenerate'),
            onPressed: () => unawaited(_create()),
            child: const Text('重新生成二维码'),
          ),
        ],
      ],
    );
  }

  Widget _failedState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded, size: 52, color: DdColors.danger),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () => unawaited(_create()),
          child: const Text('重试'),
        ),
      ],
    );
  }

  Future<void> _create() async {
    _pollTimer?.cancel();
    setState(() {
      _state = null;
      _error = null;
      _consuming = false;
    });
    try {
      final state = await _gateway.createLogin(
        origin: widget.origin,
        device: AuthDeviceInput.current(),
      );
      if (!mounted) return;
      if (state.nonce == null || state.nonce!.isEmpty || state.payload == null) {
        throw const FormatException('服务端没有返回完整的扫码登录凭证。');
      }
      setState(() => _state = state);
      _pollTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_poll()),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _poll() async {
    final current = _state;
    final nonce = current?.nonce;
    if (_polling || _consuming || nonce == null || nonce.isEmpty) return;
    _polling = true;
    try {
      final next = await _gateway.loginStatus(
        origin: widget.origin,
        nonce: nonce,
      );
      if (!mounted) return;
      final merged = QrLoginState(
        status: next.status,
        device: next.device,
        expiresAt: next.expiresAt,
        nonce: nonce,
        payload: current?.payload,
        scannedAt: next.scannedAt,
        confirmedAt: next.confirmedAt,
      );
      setState(() {
        _state = merged;
        _error = null;
      });
      if (next.status == 'CONFIRMED') {
        _pollTimer?.cancel();
        await _consume(nonce);
        return;
      }
      if (next.status == 'REJECTED' ||
          next.status == 'EXPIRED' ||
          next.status == 'CONSUMED') {
        _pollTimer?.cancel();
      }
    } on QrApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'QR_EXPIRED') {
        _pollTimer?.cancel();
        setState(() {
          _state = QrLoginState(
            status: 'EXPIRED',
            device: current!.device,
            expiresAt: current.expiresAt,
            nonce: nonce,
          );
        });
      } else {
        setState(() => _error = error.message);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      _polling = false;
    }
  }

  Future<void> _consume(String nonce) async {
    if (_consuming) return;
    _consuming = true;
    if (mounted) {
      setState(() => _error = null);
    }
    try {
      final session = await _gateway.consumeLogin(
        origin: widget.origin,
        nonce: nonce,
      );
      if (!mounted) return;
      Navigator.of(context).pop<AuthSession>(session);
    } on QrApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
      if (error.code == 'QR_CONSUMED' || error.code == 'QR_EXPIRED') {
        _pollTimer?.cancel();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      _consuming = false;
    }
  }

  String _statusLabel(String status) => switch (status) {
    'PENDING' => '打开手机 DD → 发现 → 扫一扫',
    'SCANNED' => '已扫描，请在手机上确认登录',
    'CONFIRMED' => '手机已确认，正在登录…',
    'REJECTED' => '这次扫码登录已在手机上拒绝',
    'EXPIRED' => '二维码已过期',
    'CONSUMED' => '二维码已经使用过',
    _ => '等待扫码…',
  };

  String _friendlyError(Object error) {
    if (error is QrApiException) return error.message;
    return error.toString().replaceFirst('FormatException: ', '');
  }
}
