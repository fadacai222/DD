import 'package:flutter/material.dart';

import '../data/auth_api_client.dart';

class PasswordResetPage extends StatefulWidget {
  const PasswordResetPage({
    super.key,
    required this.gateway,
    required this.origin,
  });

  final AuthGateway gateway;
  final Uri origin;

  @override
  State<PasswordResetPage> createState() => _PasswordResetPageState();
}

class _PasswordResetPageState extends State<PasswordResetPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('找回密码')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '验证码有效期 10 分钟。重置成功后，旧设备和旧 Refresh Token 会全部失效。',
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: '邮箱',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: _busy ? null : _sendCode,
                        child: const Text('发送重置验证码'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _code,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: '6 位验证码',
                          counterText: '',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '新密码',
                          helperText: '至少 10 个字符。',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _busy ? null : _reset,
                        icon: const Icon(Icons.password_rounded),
                        label: const Text('重置密码并注销旧会话'),
                      ),
                      if (_message != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _message!,
                          style: TextStyle(
                            color: _error
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _sendCode() => _run(() async {
    await widget.gateway.sendPasswordResetCode(
      origin: widget.origin,
      email: _email.text.trim(),
    );
    _setMessage('请求已接受。开发环境请到 Mailpit 查看验证码。');
  });

  Future<void> _reset() => _run(() async {
    await widget.gateway.resetPassword(
      origin: widget.origin,
      email: _email.text.trim(),
      code: _code.text.trim(),
      newPassword: _password.text,
    );
    _setMessage('密码已重置，旧设备会话已全部撤销。请返回登录。');
  });

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      _setMessage('操作失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setMessage(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _error = error;
    });
  }
}
