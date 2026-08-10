import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../data/qr_api_client.dart';
import 'qr_code_card.dart';

class MyQrPage extends StatefulWidget {
  const MyQrPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.displayName,
    required this.handle,
    required this.onUnauthorized,
    this.avatarRevision = 0,
    this.gateway,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String displayName;
  final String handle;
  final int avatarRevision;
  final Future<String?> Function() onUnauthorized;
  final QrGateway? gateway;

  @override
  State<MyQrPage> createState() => _MyQrPageState();
}

class _MyQrPageState extends State<MyQrPage> {
  late final QrGateway _gateway;
  late final bool _ownsGateway;
  QrPayloadData? _payload;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? QrApiClient();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '我的二维码',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _payload == null
              ? _error == null
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: DdColors.danger,
                            size: 36,
                          ),
                          const SizedBox(height: 10),
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () => unawaited(_load()),
                            child: const Text('重试'),
                          ),
                        ],
                      )
              : DdQrCodeCard(
                  payload: _payload!.value,
                  title: widget.displayName,
                  subtitle: 'DDID：${widget.handle}',
                  footer: '使用 DD 的“扫一扫”即可打开我的资料；二维码绑定当前 DD 实例。',
                ),
        ),
      ),
      bottomNavigationBar: _payload == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: ProfileAvatar(
                        origin: widget.origin,
                        accessToken: widget.accessToken,
                        userId: widget.userId,
                        displayName: widget.displayName,
                        revision: widget.avatarRevision,
                        size: 34,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'DD 个人二维码',
                      style: TextStyle(
                        fontSize: 12,
                        color: DdColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _payload = null;
        _error = null;
      });
    }
    try {
      final payload = await _authorized(
        (token) => _gateway.myQr(
          origin: widget.origin,
          accessToken: token,
        ),
      );
      if (!mounted) return;
      setState(() => _payload = payload);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
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

  String _friendlyError(Object error) {
    if (error is QrApiException) return error.message;
    return error.toString().replaceFirst('FormatException: ', '');
  }
}
