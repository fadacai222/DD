import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shell/presentation/main_shell_page.dart';
import '../data/auth_api_client.dart';
import '../data/auth_session_vault.dart';
import '../domain/auth_session.dart';
import 'password_reset_page.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.gateway});

  final AuthGateway? gateway;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AuthGateway _gateway;
  late final bool _ownsGateway;
  late final TabController _tabs;
  late final TextEditingController _origin;
  late final TextEditingController _email;
  late final TextEditingController _code;
  late final TextEditingController _password;
  late final TextEditingController _handle;
  late final TextEditingController _displayName;
  late final AuthSessionVault _vault;

  AuthSession? _session;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  Timer? _refreshTimer;
  bool _refreshingSession = false;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? AuthApiClient();
    _tabs = TabController(length: 2, vsync: this);
    _origin = TextEditingController(text: 'http://127.0.0.1:18473');
    _email = TextEditingController();
    _code = TextEditingController();
    _password = TextEditingController();
    _handle = TextEditingController();
    _displayName = TextEditingController();
    _vault = AuthSessionVault();
    WidgetsBinding.instance.addObserver(this);
    _restoreSession();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final session = _session;
    if (session == null) return;
    if (session.tokens.accessExpiresAt.difference(DateTime.now().toUtc()) <=
        const Duration(minutes: 2)) {
      unawaited(_refreshSession(silent: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _tabs.dispose();
    _origin.dispose();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _handle.dispose();
    _displayName.dispose();
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session != null) {
      return MainShellPage(
        key: ValueKey(session.tokens.accessToken),
        origin: _validatedOrigin(),
        session: session,
        authGateway: _gateway,
        onRefreshSession: _refresh,
        onLogout: _clearSession,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('账号注册 / 登录'),
            Text(
              'P2 · Auth vertical slice',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final padding = constraints.maxWidth < 480 ? 12.0 : 24.0;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(padding),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildEndpointCard(),
                      const SizedBox(height: 14),
                      if (_message != null) ...[
                        _buildMessage(_message!, _messageIsError),
                        const SizedBox(height: 14),
                      ],
                      _buildAuthCard(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEndpointCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          key: const Key('auth-origin'),
          controller: _origin,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '服务地址',
            hintText: 'http://127.0.0.1:18473',
            prefixIcon: Icon(Icons.dns_outlined),
            border: OutlineInputBorder(),
          ),
        ),
      ),
    );
  }

  Widget _buildAuthCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '注册'),
                Tab(text: '登录'),
              ],
            ),
            const SizedBox(height: 18),
            AnimatedBuilder(
              animation: _tabs,
              builder: (context, _) =>
                  _tabs.index == 0 ? _buildRegisterForm() : _buildLoginForm(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRegisterForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _emailField(),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('auth-code'),
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '6 位验证码',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonal(
              key: const Key('auth-send-code'),
              onPressed: _busy ? null : _sendCode,
              child: const Text('发送验证码'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _passwordField(),
        const SizedBox(height: 12),
        TextField(
          key: const Key('auth-handle'),
          controller: _handle,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '账号短号',
            hintText: 'alice_01',
            helperText: '3–32 位，以字母开头，只用小写字母、数字和下划线。',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('auth-display-name'),
          controller: _displayName,
          enabled: !_busy,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: '昵称',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          key: const Key('auth-register'),
          onPressed: _busy ? null : _register,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('创建账号并登录'),
        ),
      ],
    );
  }

  Widget _buildLoginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _emailField(),
        const SizedBox(height: 12),
        _passwordField(),
        const SizedBox(height: 18),
        FilledButton.icon(
          key: const Key('auth-login'),
          onPressed: _busy ? null : _login,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login_rounded),
          label: const Text('登录'),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          key: const Key('auth-forgot-password'),
          onPressed: _busy ? null : _openPasswordReset,
          icon: const Icon(Icons.password_rounded),
          label: const Text('忘记密码 / 重置密码'),
        ),
      ],
    );
  }

  Widget _emailField() {
    return TextField(
      key: const Key('auth-email'),
      controller: _email,
      enabled: !_busy,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: '邮箱',
        hintText: 'name@example.com',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _passwordField() {
    return TextField(
      key: const Key('auth-password'),
      controller: _password,
      enabled: !_busy,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: '密码',
        helperText: '至少 10 个字符；服务端使用 Argon2id 保存。',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _buildMessage(String message, bool error) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: error ? colors.errorContainer : colors.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          message,
          style: TextStyle(
            color: error
                ? colors.onErrorContainer
                : colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }

  Uri _validatedOrigin() {
    final uri = Uri.tryParse(_origin.text.trim());
    if (uri == null) throw const FormatException('服务地址格式不正确。');
    return normalizeAuthOrigin(uri);
  }

  Future<void> _sendCode() => _run(() async {
    await _gateway.sendRegistrationCode(
      origin: _validatedOrigin(),
      email: _email.text.trim(),
    );
    _setMessage('验证码请求已接受。开发环境请到 Mailpit 查看邮件。');
  });

  Future<void> _register() => _run(() async {
    final session = await _gateway.register(
      origin: _validatedOrigin(),
      email: _email.text.trim(),
      code: _code.text.trim(),
      password: _password.text,
      handle: _handle.text.trim(),
      displayName: _displayName.text.trim(),
      device: AuthDeviceInput.current(),
    );
    if (!mounted) return;
    setState(() => _session = session);
    await _persistSession(session);
    _scheduleSessionRefresh(session);
    _setMessage('注册成功，服务端已创建用户、首设备和 Refresh Token。');
  });

  Future<void> _login() => _run(() async {
    final session = await _gateway.login(
      origin: _validatedOrigin(),
      email: _email.text.trim(),
      password: _password.text,
      device: AuthDeviceInput.current(),
    );
    if (!mounted) return;
    setState(() => _session = session);
    await _persistSession(session);
    _scheduleSessionRefresh(session);
    _setMessage('登录成功。');
  });

  Future<void> _refresh() => _refreshSession(silent: true);

  Future<void> _refreshSession({required bool silent}) async {
    if (_refreshingSession) return;
    final current = _session;
    if (current == null) return;
    _refreshingSession = true;
    try {
      final next = await _gateway.refresh(
        origin: _validatedOrigin(),
        refreshToken: current.tokens.refreshToken,
      );
      if (!mounted) return;
      setState(() => _session = next);
      await _persistSession(next);
      _scheduleSessionRefresh(next);
      if (!silent) _setMessage('会话已刷新，Refresh Token 已完成轮换。');
    } catch (error) {
      if (!mounted) return;
      if (!silent) _setMessage(_friendlyError(error), error: true);
      _refreshTimer?.cancel();
      _refreshTimer = Timer(
        const Duration(seconds: 30),
        () => unawaited(_refreshSession(silent: true)),
      );
    } finally {
      _refreshingSession = false;
    }
  }

  void _scheduleSessionRefresh(AuthSession session) {
    _refreshTimer?.cancel();
    final untilExpiry = session.tokens.accessExpiresAt.difference(
      DateTime.now().toUtc(),
    );
    var delay = untilExpiry - const Duration(seconds: 90);
    if (delay < const Duration(seconds: 5)) delay = const Duration(seconds: 5);
    _refreshTimer = Timer(
      delay,
      () => unawaited(_refreshSession(silent: true)),
    );
  }

  Future<void> _restoreSession() async {
    try {
      if (kIsWeb) {
        final origin = _validatedOrigin();
        final session = await _gateway.refresh(
          origin: origin,
          refreshToken: '',
        );
        if (!mounted) return;
        setState(() => _session = session);
        _scheduleSessionRefresh(session);
        _setMessage('已通过 HttpOnly Cookie 自动恢复登录会话。');
        return;
      }

      final stored = await _vault.read();
      if (stored == null) return;
      _origin.text = stored.origin.toString();
      final session = await _gateway.refresh(
        origin: stored.origin,
        refreshToken: stored.refreshToken,
      );
      if (!mounted) return;
      setState(() => _session = session);
      await _persistSession(session);
      _scheduleSessionRefresh(session);
      _setMessage('已从系统安全存储自动恢复登录会话。');
    } catch (_) {
      try {
        await _vault.clear();
      } catch (_) {
        // Secure storage may be unavailable on an unsupported desktop runtime.
      }
    }
  }

  Future<void> _persistSession(AuthSession session) => _vault.save(
    origin: _validatedOrigin(),
    refreshToken: session.tokens.refreshToken,
  );

  Future<void> _clearSession() async {
    _refreshTimer?.cancel();
    final current = _session;
    if (current != null) {
      try {
        await _gateway.revokeDevice(
          origin: _validatedOrigin(),
          accessToken: current.tokens.accessToken,
          deviceId: current.device.id,
        );
      } catch (_) {
        // A session may already have been revoked remotely; local cleanup must still finish.
      }
    }
    try {
      await _vault.clear();
    } catch (_) {
      // Local logout should not be blocked by an unavailable secure-storage backend.
    }
    if (!mounted) return;
    setState(() => _session = null);
    _setMessage('本机已退出，服务端设备会话也已撤销。');
  }

  Future<void> _openPasswordReset() async {
    final origin = _validatedOrigin();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PasswordResetPage(gateway: _gateway, origin: origin),
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      _setMessage(_friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setMessage(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = error;
    });
  }

  static String _friendlyError(Object error) {
    if (error is AuthApiException) {
      return switch (error.code) {
        'RATE_LIMITED' => '验证码发送太频繁，请稍后再试。',
        'LOGIN_RATE_LIMITED' => '登录失败次数过多，请 15 分钟后再试。',
        'INVALID_VERIFICATION_CODE' => '验证码错误或已过期。',
        'EMAIL_ALREADY_REGISTERED' => '这个邮箱已经注册。',
        'HANDLE_UNAVAILABLE' => '这个账号短号不可用。',
        'INVALID_CREDENTIALS' => '邮箱或密码错误。',
        'SESSION_EXPIRED' => '登录会话已失效，请重新登录。',
        'REGISTRATION_DISABLED' => '当前实例没有开放注册。',
        _ =>
          '${error.message}${error.requestId == null ? '' : ' · ${error.requestId}'}',
      };
    }
    if (error is FormatException || error is ArgumentError) {
      return error.toString().replaceFirst(
        RegExp(r'^(FormatException|Invalid argument[^:]*):\s*'),
        '',
      );
    }
    return '请求失败：$error';
  }
}
