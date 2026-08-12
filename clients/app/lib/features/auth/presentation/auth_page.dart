import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../theme/app_theme.dart';
import '../../push/application/push_registration_service.dart';
import '../../shell/presentation/main_shell_page.dart';
import '../data/auth_api_client.dart';
import '../data/auth_session_vault.dart';
import '../data/login_history_store.dart';
import '../domain/account_management.dart';
import '../domain/auth_session.dart';
import 'password_reset_page.dart';

enum _PushCleanupOutcome { endpointReleased, deviceRevoked, unconfirmed }

class AuthPage extends StatefulWidget {
  const AuthPage({
    super.key,
    this.gateway,
    this.historyStore,
    this.vault,
    this.initialSession,
    this.initialOrigin,
    this.restoreSession = true,
    this.pushAccountLeaseController,
  });

  final AuthGateway? gateway;
  final LoginHistoryRepository? historyStore;
  final AuthSessionVault? vault;
  final AuthSession? initialSession;
  final Uri? initialOrigin;
  final bool restoreSession;
  final PushAccountLeaseController? pushAccountLeaseController;

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
  late final FocusNode _passwordFocus;
  late final AuthSessionVault _vault;
  late final LoginHistoryRepository _historyStore;
  late final PushAccountLeaseController _pushAccountLeaseController;

  AuthSession? _session;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  Timer? _refreshTimer;
  Future<AuthSession?>? _refreshInFlight;
  int? _refreshInFlightEpoch;
  String? _refreshInFlightUserId;
  String? _refreshInFlightDeviceId;
  String? _refreshInFlightOrigin;
  int _sessionEpoch = 0;
  bool _sessionTransitionInProgress = false;
  List<LoginHistoryEntry> _loginHistory = const [];

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? AuthApiClient();
    _tabs = TabController(length: 2, vsync: this);
    _origin = TextEditingController(
      text: (widget.initialOrigin ?? Uri.parse('http://127.0.0.1:18473'))
          .toString(),
    );
    _email = TextEditingController();
    _code = TextEditingController();
    _password = TextEditingController();
    _handle = TextEditingController();
    _displayName = TextEditingController();
    _passwordFocus = FocusNode(debugLabel: 'auth-password');
    _vault = widget.vault ?? AuthSessionVault();
    _historyStore = widget.historyStore ?? LoginHistoryStore();
    _pushAccountLeaseController =
        widget.pushAccountLeaseController ?? PushRegistrationService.shared;
    _session = widget.initialSession;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadLoginHistory());
    final initialSession = _session;
    if (initialSession != null) {
      _scheduleSessionRefresh(initialSession);
    } else if (widget.restoreSession) {
      unawaited(_restoreSession());
    }
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
    _passwordFocus.dispose();
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session != null) {
      return MainShellPage(
        key: ValueKey('${session.user.id}-${session.device.id}'),
        origin: _validatedOrigin(),
        session: session,
        authGateway: _gateway,
        onRefreshSession: _refresh,
        onProfileChanged: _applyProfile,
        onManageAccounts: _openAccountManager,
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
            labelText: 'DDID',
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
        if (_loginHistory.isNotEmpty) ...[
          _buildLoginHistory(),
          const SizedBox(height: 18),
          const Row(
            children: [
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '其他账号登录',
                  style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
                ),
              ),
              Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 18),
        ],
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

  Widget _buildLoginHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '历史登录',
          style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
        ),
        const SizedBox(height: 8),
        for (final entry in _loginHistory)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(DdRadii.surface),
              child: InkWell(
                key: Key('login-history-${entry.userId}'),
                borderRadius: BorderRadius.circular(DdRadii.surface),
                onTap: () => _selectLoginHistory(entry),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      _historyAvatar(entry),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'DDID：${entry.ddid} · ${entry.email}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF888888),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: Key('login-history-remove-${entry.userId}'),
                        tooltip: '移除历史账号',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _removeLoginHistory(entry),
                        icon: const Icon(Icons.close_rounded, size: 17),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _historyAvatar(LoginHistoryEntry entry) {
    final bytes = entry.avatarBytes;
    return ClipOval(
      child: SizedBox(
        width: 42,
        height: 42,
        child: bytes != null && bytes.isNotEmpty
            ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
            : ColoredBox(
                color: const Color(0xFF6F9FCA),
                child: Center(
                  child: Text(
                    entry.displayName.trim().isEmpty
                        ? 'D'
                        : entry.displayName
                              .trim()
                              .characters
                              .first
                              .toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  void _selectLoginHistory(LoginHistoryEntry entry) {
    _origin.text = entry.origin.toString();
    _email.text = entry.email;
    _password.clear();
    _tabs.animateTo(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _passwordFocus.requestFocus();
    });
  }

  Future<void> _removeLoginHistory(LoginHistoryEntry entry) async {
    try {
      await _historyStore.remove(entry);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loginHistory = _loginHistory
          .where(
            (item) =>
                item.userId != entry.userId ||
                item.origin.origin != entry.origin.origin,
          )
          .toList(growable: false);
    });
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
      focusNode: _passwordFocus,
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
      borderRadius: BorderRadius.circular(DdRadii.control),
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

  Future<void> _loadLoginHistory() async {
    final entries = await _historyStore.list();
    if (!mounted) return;
    setState(() => _loginHistory = entries);
  }

  Future<void> _rememberLogin(AuthSession session) async {
    Uint8List? avatarBytes;
    try {
      avatarBytes = await _fetchAvatarSnapshot(session);
    } catch (_) {
      avatarBytes = null;
    }
    final entry = LoginHistoryEntry(
      origin: _validatedOrigin(),
      userId: session.user.id,
      email: session.user.email,
      ddid: session.user.handle,
      displayName: session.user.displayName,
      lastUsedAt: DateTime.now().toUtc(),
      avatarBytes: avatarBytes,
    );
    try {
      await _historyStore.upsert(entry);
      final entries = await _historyStore.list();
      if (mounted) setState(() => _loginHistory = entries);
    } catch (_) {
      // Login must never fail because non-secret history metadata could not be
      // persisted. The active session remains authoritative.
    }
  }

  Future<Uint8List?> _fetchAvatarSnapshot(AuthSession session) async {
    final client = http.Client();
    try {
      final response = await client
          .get(
            _validatedOrigin().resolve('/api/v1/avatars/${session.user.id}'),
            headers: {
              'Accept': 'image/avif,image/webp,image/png,image/jpeg,*/*',
              'Authorization': 'Bearer ${session.tokens.accessToken}',
            },
          )
          .timeout(const Duration(milliseconds: 1500));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      // Keep login history light; very large avatar responses are ignored and
      // the UI falls back to the account initial.
      if (response.bodyBytes.length > 512 * 1024) return null;
      return response.bodyBytes;
    } finally {
      client.close();
    }
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
    _sessionEpoch++;
    setState(() => _session = session);
    final persisted = await _persistSessionBestEffort(session);
    _scheduleSessionRefresh(session);
    unawaited(_rememberLogin(session));
    _setMessage(
      persisted
          ? '注册成功，服务端已创建用户、首设备和 Refresh Token。'
          : '注册成功；本机安全存储暂时被占用，本次会话可继续使用，但下次启动可能需要重新登录。',
      error: !persisted,
    );
  });

  Future<void> _login() => _run(() async {
    final session = await _gateway.login(
      origin: _validatedOrigin(),
      email: _email.text.trim(),
      password: _password.text,
      device: AuthDeviceInput.current(),
    );
    if (!mounted) return;
    _sessionEpoch++;
    setState(() => _session = session);
    final persisted = await _persistSessionBestEffort(session);
    _scheduleSessionRefresh(session);
    unawaited(_rememberLogin(session));
    _setMessage(
      persisted ? '登录成功。' : '登录成功；本机安全存储暂时被占用，本次会话可继续使用，但下次启动可能需要重新登录。',
      error: !persisted,
    );
  });

  Future<void> _applyProfile(AccountProfile profile) async {
    final current = _session;
    if (current == null || current.user.id != profile.id) return;
    final next = AuthSession(
      user: AuthUser(
        id: current.user.id,
        email: profile.email,
        handle: profile.handle,
        displayName: profile.displayName,
      ),
      device: current.device,
      tokens: current.tokens,
    );
    if (!mounted) return;
    setState(() => _session = next);
    unawaited(_rememberLogin(next));
  }

  Future<String?> _refresh() async {
    final refreshed = await _refreshSession(silent: true);
    return refreshed?.tokens.accessToken ?? _session?.tokens.accessToken;
  }

  Future<AuthSession?> _refreshSession({required bool silent}) {
    if (_sessionTransitionInProgress) {
      return Future<AuthSession?>.value(null);
    }
    final current = _session;
    if (current == null) return Future<AuthSession?>.value(null);
    final origin = _validatedOrigin();
    final epoch = _sessionEpoch;
    final inFlight = _refreshInFlight;
    if (inFlight != null &&
        _refreshInFlightEpoch == epoch &&
        _refreshInFlightUserId == current.user.id &&
        _refreshInFlightDeviceId == current.device.id &&
        _refreshInFlightOrigin == origin.origin) {
      return inFlight;
    }

    final request = _performRefresh(
      current,
      origin: origin,
      epoch: epoch,
      silent: silent,
    );
    _refreshInFlight = request;
    _refreshInFlightEpoch = epoch;
    _refreshInFlightUserId = current.user.id;
    _refreshInFlightDeviceId = current.device.id;
    _refreshInFlightOrigin = origin.origin;
    request.whenComplete(() {
      if (!identical(_refreshInFlight, request)) return;
      _refreshInFlight = null;
      _refreshInFlightEpoch = null;
      _refreshInFlightUserId = null;
      _refreshInFlightDeviceId = null;
      _refreshInFlightOrigin = null;
    });
    return request;
  }

  bool _isCurrentRefreshContext(
    AuthSession captured, {
    required Uri origin,
    required int epoch,
  }) {
    if (!mounted || epoch != _sessionEpoch) return false;
    final active = _session;
    if (active == null) return false;
    return active.user.id == captured.user.id &&
        active.device.id == captured.device.id &&
        _validatedOrigin().origin == origin.origin;
  }

  Future<void> _persistStaleRefreshResult(
    AuthSession session,
    Uri origin,
  ) async {
    try {
      // Rotation already happened server-side. Preserve only this account's
      // new refresh token; never overwrite the active-session pointer.
      await _vault.saveAccount(
        origin: origin,
        userId: session.user.id,
        refreshToken: session.tokens.refreshToken,
      );
    } catch (_) {
      // The active session must never be replaced because stale persistence
      // failed. A future explicit login can recover this account.
    }
  }

  Future<void> _removeStaleAccount(
    AuthSession session,
    Uri origin,
  ) async {
    try {
      await _vault.removeAccount(origin: origin, userId: session.user.id);
    } catch (_) {
      // Stale-account cleanup must not mutate or block the active account.
    }
  }

  Future<AuthSession?> _performRefresh(
    AuthSession current, {
    required Uri origin,
    required int epoch,
    required bool silent,
  }) async {
    try {
      final next = await _gateway.refresh(
        origin: origin,
        refreshToken: current.tokens.refreshToken,
      );
      if (!_isCurrentRefreshContext(current, origin: origin, epoch: epoch)) {
        await _persistStaleRefreshResult(next, origin);
        return next;
      }
      setState(() => _session = next);
      _scheduleSessionRefresh(next);
      try {
        await _persistSessionAtOrigin(next, origin);
      } catch (storageError) {
        // A successful server-side rotation must remain active in memory even
        // if Windows secure storage is temporarily busy. DdSecureStorage
        // already retries and serializes writes; do not roll the UI back to an
        // expired access token just because local persistence failed.
        if (!silent) {
          _setMessage('会话已刷新，但本机安全存储暂时不可用：$storageError', error: true);
        }
      }
      if (!silent) _setMessage('会话已刷新，Refresh Token 已完成轮换。');
      return next;
    } catch (error) {
      if (error is AuthApiException && error.statusCode == 401) {
        final currentContext = _isCurrentRefreshContext(
          current,
          origin: origin,
          epoch: epoch,
        );
        if (!currentContext) {
          await _removeStaleAccount(current, origin);
          return null;
        }
        if (_sessionTransitionInProgress) {
          // A refresh that finishes while the same active account is inside a
          // logout/account transition is not stale yet. The transition may
          // still fail and roll back, so deleting this account credential here
          // would lose the only safe cleanup ownership we are required to keep.
          return null;
        }

        _sessionTransitionInProgress = true;
        _refreshTimer?.cancel();
        try {
          final cleanupOutcome = error.code == 'DEVICE_SESSION_REVOKED'
              ? await _abandonAuthoritativelyRevokedPushLease()
              : await _attemptSafePushCleanup(current, origin);
          if (cleanupOutcome == _PushCleanupOutcome.unconfirmed) {
            _showPushCleanupRequired(
              '登录会话已失效，但 Push 清理尚未完成。无法确认本设备已安全退出，请重试。',
            );
            return null;
          }

          _sessionEpoch++;
          try {
            await _vault.removeAccount(
              origin: origin,
              userId: current.user.id,
            );
            await _vault.clear();
          } catch (_) {
            // Safe Push ownership cleanup is already complete; local secure
            // storage cleanup can be retried by the next login.
          }
          if (mounted) {
            setState(() => _session = null);
            _setMessage('登录状态已失效，请重新登录。', error: true);
          }
        } finally {
          _sessionTransitionInProgress = false;
        }
        return null;
      }
      if (_isCurrentRefreshContext(current, origin: origin, epoch: epoch)) {
        if (!silent) _setMessage(_friendlyError(error), error: true);
        _refreshTimer?.cancel();
        _refreshTimer = Timer(
          const Duration(seconds: 30),
          () => unawaited(_refreshSession(silent: true)),
        );
      }
      return null;
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
        _sessionEpoch++;
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
      _sessionEpoch++;
      setState(() => _session = session);
      final persisted = await _persistSessionBestEffort(session);
      _scheduleSessionRefresh(session);
      unawaited(_rememberLogin(session));
      _setMessage(
        persisted ? '已从系统安全存储自动恢复登录会话。' : '登录会话已恢复，但本机安全存储暂时不可写；当前会话仍可继续使用。',
        error: !persisted,
      );
    } catch (_) {
      try {
        await _vault.clear();
      } catch (_) {
        // Secure storage may be unavailable on an unsupported desktop runtime.
      }
    }
  }

  Future<void> _persistSessionAtOrigin(AuthSession session, Uri origin) async {
    await _vault.save(
      origin: origin,
      refreshToken: session.tokens.refreshToken,
    );
    await _vault.saveAccount(
      origin: origin,
      userId: session.user.id,
      refreshToken: session.tokens.refreshToken,
    );
  }

  Future<bool> _persistSessionBestEffort(
    AuthSession session, {
    Uri? origin,
  }) async {
    try {
      await _persistSessionAtOrigin(session, origin ?? _validatedOrigin());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openAccountManager() async {
    await _loadLoginHistory();
    if (!mounted) return;
    final current = _session;
    if (current == null) return;
    final action = await showModalBottomSheet<Object>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 2, 8, 10),
              child: Text(
                '账号管理',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            for (final entry in _loginHistory)
              ListTile(
                key: Key('account-manager-${entry.userId}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: _historyAvatar(entry),
                title: Text(
                  entry.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'DDID：${entry.ddid}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing:
                    current.user.id == entry.userId &&
                        _validatedOrigin().origin == entry.origin.origin
                    ? const Icon(Icons.check_circle_rounded, color: DdColors.green)
                    : const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(sheetContext, entry),
              ),
            const Divider(height: 14),
            ListTile(
              key: const Key('account-manager-add'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFF0F0F0),
                foregroundColor: DdColors.textSecondary,
                child: Icon(Icons.add_rounded),
              ),
              title: const Text('添加账号'),
              subtitle: const Text('进入登录页，当前账号不会被退出'),
              onTap: () => Navigator.pop(sheetContext, 'add-account'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'add-account') {
      await _startAddingAccount();
      return;
    }
    if (action is LoginHistoryEntry) {
      await _switchToAccount(action);
    }
  }

  Future<void> _startAddingAccount() async {
    if (_sessionTransitionInProgress) return;
    final current = _session;
    _sessionTransitionInProgress = true;
    _refreshTimer?.cancel();
    try {
      await _pushAccountLeaseController.releaseCurrentEndpoint();
    } catch (error) {
      _sessionTransitionInProgress = false;
      if (mounted && current != null) _scheduleSessionRefresh(current);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂时无法暂停当前账号 Push，请重试：${_friendlyError(error)}')),
      );
      return;
    }
    _sessionEpoch++;
    _sessionTransitionInProgress = false;
    _password.clear();
    _email.clear();
    if (!mounted) return;
    setState(() {
      _session = null;
      _message = '登录新账号；原账号仍保留在账号管理中。';
      _messageIsError = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tabs.animateTo(1);
    });
  }

  Future<void> _switchToAccount(LoginHistoryEntry entry) async {
    if (_sessionTransitionInProgress) return;
    final current = _session;
    if (current == null) return;
    final currentOrigin = _validatedOrigin();
    final currentEpoch = _sessionEpoch;
    if (current.user.id == entry.userId &&
        currentOrigin.origin == entry.origin.origin) {
      return;
    }
    final stored = await _vault.readAccount(
      origin: entry.origin,
      userId: entry.userId,
    );
    if (!mounted) return;
    if (stored == null) {
      _openLoginForHistory(entry, '该账号尚未保存可切换会话，请输入密码登录一次。');
      return;
    }

    final pendingCurrentRefresh =
        _refreshInFlight != null &&
            _refreshInFlightEpoch == currentEpoch &&
            _refreshInFlightUserId == current.user.id &&
            _refreshInFlightDeviceId == current.device.id &&
            _refreshInFlightOrigin == currentOrigin.origin
        ? _refreshInFlight
        : null;

    _sessionTransitionInProgress = true;
    _refreshTimer?.cancel();
    try {
      // Release A before consuming B's one-time rotating refresh token. While
      // this waits, transition gating prevents a new A timer refresh from
      // starting; an already in-flight A refresh is isolated by the epoch below.
      await _pushAccountLeaseController.releaseCurrentEndpoint();
    } catch (error) {
      _sessionTransitionInProgress = false;
      final active = _session;
      if (mounted &&
          _sessionEpoch == currentEpoch &&
          active != null &&
          active.user.id == current.user.id &&
          active.device.id == current.device.id) {
        _scheduleSessionRefresh(active);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂时无法切换账号：${_friendlyError(error)}')),
      );
      return;
    }

    if (!mounted) {
      _sessionTransitionInProgress = false;
      return;
    }
    final activeBeforeSwitch = _session;
    final rollbackSession =
        activeBeforeSwitch != null &&
            activeBeforeSwitch.user.id == current.user.id &&
            activeBeforeSwitch.device.id == current.device.id
        ? activeBeforeSwitch
        : current;

    // Point of no return for A's active lease. Any A refresh that finishes
    // after this line may preserve A's rotated account token, but cannot mutate
    // active UI/session/Push state.
    _sessionEpoch++;
    final switchEpoch = _sessionEpoch;

    try {
      final next = await _gateway.refresh(
        origin: stored.origin,
        refreshToken: stored.refreshToken,
      );
      final persisted = await _persistSessionBestEffort(
        next,
        origin: stored.origin,
      );
      if (!mounted || _sessionEpoch != switchEpoch) {
        _sessionTransitionInProgress = false;
        return;
      }
      _origin.text = stored.origin.toString();
      _sessionTransitionInProgress = false;
      setState(() {
        _session = next;
        _message = null;
      });
      _scheduleSessionRefresh(next);
      unawaited(_rememberLogin(next));
      if (!persisted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('账号已切换，但安全存储暂时不可写。')),
        );
      }
    } on AuthApiException catch (error) {
      if (error.statusCode == 401) {
        try {
          await _vault.removeAccount(
            origin: entry.origin,
            userId: entry.userId,
          );
        } catch (_) {}
      }
      _sessionTransitionInProgress = false;
      await _restorePushAfterFailedAccountSwitch(
        rollbackSession,
        currentOrigin,
        epoch: switchEpoch,
        pendingRefresh: pendingCurrentRefresh,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.statusCode == 401
                  ? '目标账号登录状态已失效，当前账号保持登录。'
                  : _friendlyError(error),
            ),
          ),
        );
      }
    } catch (error) {
      _sessionTransitionInProgress = false;
      await _restorePushAfterFailedAccountSwitch(
        rollbackSession,
        currentOrigin,
        epoch: switchEpoch,
        pendingRefresh: pendingCurrentRefresh,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    }
  }

  Future<void> _restorePushAfterFailedAccountSwitch(
    AuthSession session,
    Uri origin, {
    required int epoch,
    Future<AuthSession?>? pendingRefresh,
  }) async {
    try {
      await _pushAccountLeaseController.start(
        origin: origin,
        accessToken: session.tokens.accessToken,
        userId: session.user.id,
        deviceId: session.device.id,
      );
    } catch (_) {
      // The UI/session remains on A. Push start itself owns logging/retry paths.
    }
    if (!mounted ||
        !_isCurrentRefreshContext(session, origin: origin, epoch: epoch)) {
      return;
    }
    if (pendingRefresh == null) {
      _scheduleSessionRefresh(session);
      return;
    }
    unawaited(
      _reconcileRollbackRefresh(
        pendingRefresh,
        session,
        origin,
        epoch,
      ),
    );
  }

  Future<void> _reconcileRollbackRefresh(
    Future<AuthSession?> pendingRefresh,
    AuthSession rollbackSession,
    Uri origin,
    int epoch,
  ) async {
    final refreshed = await pendingRefresh;
    if (!mounted ||
        !_isCurrentRefreshContext(
          rollbackSession,
          origin: origin,
          epoch: epoch,
        )) {
      return;
    }
    if (refreshed != null &&
        refreshed.user.id == rollbackSession.user.id &&
        refreshed.device.id == rollbackSession.device.id) {
      setState(() => _session = refreshed);
      await _persistSessionAtOrigin(refreshed, origin);
      _scheduleSessionRefresh(refreshed);
      return;
    }
    _scheduleSessionRefresh(_session ?? rollbackSession);
  }

  void _openLoginForHistory(LoginHistoryEntry entry, String message) {
    _refreshTimer?.cancel();
    _sessionEpoch++;
    _origin.text = entry.origin.toString();
    _email.text = entry.email;
    _password.clear();
    setState(() {
      _session = null;
      _message = message;
      _messageIsError = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tabs.animateTo(1);
      _passwordFocus.requestFocus();
    });
  }

  Future<_PushCleanupOutcome> _abandonAuthoritativelyRevokedPushLease() async {
    await _pushAccountLeaseController
        .abandonCurrentEndpointLeaseAfterAuthoritativeRevocation();
    return _PushCleanupOutcome.deviceRevoked;
  }

  Future<_PushCleanupOutcome> _attemptSafePushCleanup(
    AuthSession current,
    Uri origin,
  ) async {
    var endpointReleased = false;
    try {
      await _pushAccountLeaseController.releaseCurrentEndpoint();
      endpointReleased = true;
    } catch (_) {
      // Fail-closed: local ownership remains until endpoint deletion or an
      // authoritative device revocation is confirmed below.
    }

    var deviceRevoked = false;
    try {
      await _gateway.revokeDevice(
        origin: origin,
        accessToken: current.tokens.accessToken,
        deviceId: current.device.id,
      );
      deviceRevoked = true;
    } on AuthApiException catch (error) {
      deviceRevoked = error.code == 'DEVICE_SESSION_REVOKED';
    } catch (_) {
      // Network/5xx/transport failures are not authoritative revocation facts.
    }

    if (deviceRevoked) {
      if (!endpointReleased) {
        await _pushAccountLeaseController
            .abandonCurrentEndpointLeaseAfterAuthoritativeRevocation();
      }
      return _PushCleanupOutcome.deviceRevoked;
    }
    if (endpointReleased) return _PushCleanupOutcome.endpointReleased;
    return _PushCleanupOutcome.unconfirmed;
  }

  void _showPushCleanupRequired(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _clearSession() async {
    if (_sessionTransitionInProgress) return;
    _sessionTransitionInProgress = true;
    _refreshTimer?.cancel();
    final current = _session;
    final currentOrigin = current == null ? null : _validatedOrigin();
    try {
      var cleanupOutcome = _PushCleanupOutcome.endpointReleased;
      if (current != null && currentOrigin != null) {
        cleanupOutcome = await _attemptSafePushCleanup(current, currentOrigin);
        if (cleanupOutcome == _PushCleanupOutcome.unconfirmed) {
          if (mounted && identical(_session, current)) {
            _scheduleSessionRefresh(current);
          }
          _showPushCleanupRequired(
            '无法确认本设备已安全退出，请重试。当前账号会保留以完成 Push 安全清理。',
          );
          return;
        }
        _sessionEpoch++;
      }

      try {
        if (current != null && currentOrigin != null) {
          await _vault.removeAccount(
            origin: currentOrigin,
            userId: current.user.id,
          );
        }
        await _vault.clear();
      } catch (_) {
        // Push ownership is already safe, so local logout must not be blocked
        // by a temporarily unavailable secure-storage backend.
      }
      if (!mounted) return;
      setState(() => _session = null);
      _setMessage(
        cleanupOutcome == _PushCleanupOutcome.deviceRevoked
            ? '本机已退出，服务端设备会话也已撤销。'
            : '本机已安全退出，Push endpoint 已解绑。',
      );
    } finally {
      _sessionTransitionInProgress = false;
    }
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
        'HANDLE_UNAVAILABLE' => '这个 DDID 不可用。',
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
