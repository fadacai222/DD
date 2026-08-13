import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/network/app_endpoints.dart';
import '../../../theme/app_theme.dart';
import '../data/auth_api_client.dart';
import '../data/auth_session_vault.dart';
import '../data/login_history_store.dart';
import '../domain/auth_session.dart';
import 'auth_page.dart';

typedef AuthBootAuthenticatedBuilder =
    Widget Function(BuildContext context, AuthSession session, Uri origin);
typedef AuthBootUnauthenticatedBuilder =
    Widget Function(BuildContext context, Uri origin);

class AuthBootPage extends StatefulWidget {
  const AuthBootPage({
    super.key,
    this.gateway,
    this.vault,
    this.historyStore,
    this.authenticatedBuilder,
    this.unauthenticatedBuilder,
  });

  final AuthGateway? gateway;
  final AuthSessionVault? vault;
  final LoginHistoryRepository? historyStore;
  final AuthBootAuthenticatedBuilder? authenticatedBuilder;
  final AuthBootUnauthenticatedBuilder? unauthenticatedBuilder;

  @override
  State<AuthBootPage> createState() => _AuthBootPageState();
}

class _AuthBootPageState extends State<AuthBootPage> {
  static final Uri _defaultOrigin = Uri.parse(defaultApiOrigin);

  late final AuthGateway _gateway;
  late final bool _ownsGateway;
  late final AuthSessionVault _vault;

  Uri _origin = _defaultOrigin;
  AuthSession? _session;
  bool _finished = false;
  bool _restoring = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? AuthApiClient();
    _vault = widget.vault ?? AuthSessionVault();
    unawaited(_restore());
  }

  @override
  void dispose() {
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) {
      final session = _session;
      if (session != null && widget.authenticatedBuilder != null) {
        return widget.authenticatedBuilder!(context, session, _origin);
      }
      if (session == null && widget.unauthenticatedBuilder != null) {
        return widget.unauthenticatedBuilder!(context, _origin);
      }
      return AuthPage(
        gateway: _gateway,
        vault: _vault,
        historyStore: widget.historyStore,
        initialSession: _session,
        initialOrigin: _origin,
        restoreSession: false,
      );
    }
    return _buildBootScreen(context);
  }

  Widget _buildBootScreen(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      key: const Key('auth-boot-screen'),
      backgroundColor: dark ? const Color(0xFF191919) : const Color(0xFFF7F7F7),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 82,
                    height: 82,
                    decoration: BoxDecoration(
                      color: DdColors.green,
                      borderRadius: BorderRadius.circular(25),
                      boxShadow: [
                        BoxShadow(
                          color: DdColors.green.withValues(alpha: 0.18),
                          blurRadius: 26,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.chat_bubble_rounded,
                      color: Colors.white,
                      size: 42,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'DD',
                    style: TextStyle(
                      color: dark ? Colors.white : DdColors.textPrimary,
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _error ?? (_restoring ? '正在恢复会话…' : '正在启动…'),
                    key: const Key('auth-boot-status'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _error == null
                          ? (dark
                                ? const Color(0xFFAAAAAA)
                                : DdColors.textSecondary)
                          : DdColors.danger,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_error == null)
                    const SizedBox(
                      key: Key('auth-boot-progress'),
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: DdColors.green,
                      ),
                    )
                  else ...[
                    FilledButton.icon(
                      key: const Key('auth-boot-retry'),
                      onPressed: _restoring ? null : _restore,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      key: const Key('auth-boot-use-login'),
                      onPressed: _restoring ? null : _discardSessionAndLogin,
                      child: const Text('退出旧会话并重新登录'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _restore() async {
    if (_restoring) return;
    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      if (kIsWeb) {
        try {
          final session = await _gateway.refresh(
            origin: _defaultOrigin,
            refreshToken: '',
          );
          _finishAuthenticated(_defaultOrigin, session);
        } on AuthApiException catch (error) {
          if (error.statusCode == 401) {
            _finishUnauthenticated(_defaultOrigin);
          } else {
            rethrow;
          }
        }
        return;
      }

      final stored = await _vault.read();
      if (stored == null) {
        _finishUnauthenticated(_defaultOrigin);
        return;
      }
      _origin = stored.origin;
      try {
        final session = await _gateway.refresh(
          origin: stored.origin,
          refreshToken: stored.refreshToken,
        );
        try {
          await _vault.save(
            origin: stored.origin,
            refreshToken: session.tokens.refreshToken,
          );
          await _vault.saveAccount(
            origin: stored.origin,
            userId: session.user.id,
            refreshToken: session.tokens.refreshToken,
          );
        } catch (_) {
          // A rotated server session remains valid in memory. A temporary
          // secure-storage write failure must not flash the login page.
        }
        _finishAuthenticated(stored.origin, session);
      } on AuthApiException catch (error) {
        if (error.statusCode != 401) rethrow;
        try {
          await _vault.clear();
        } catch (_) {
          // The server is authoritative. Local cleanup can be retried later.
        }
        _finishUnauthenticated(stored.origin);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _restoring = false;
        _error = _bootError(error);
      });
    }
  }

  void _finishAuthenticated(Uri origin, AuthSession session) {
    if (!mounted) return;
    setState(() {
      _origin = origin;
      _session = session;
      _finished = true;
      _restoring = false;
      _error = null;
    });
  }

  void _finishUnauthenticated(Uri origin) {
    if (!mounted) return;
    setState(() {
      _origin = origin;
      _session = null;
      _finished = true;
      _restoring = false;
      _error = null;
    });
  }

  Future<void> _discardSessionAndLogin() async {
    try {
      await _vault.clear();
    } catch (_) {
      // Explicit local sign-in should remain available when secure storage is
      // unavailable; the next successful login will attempt to persist again.
    }
    _finishUnauthenticated(_origin);
  }

  String _bootError(Object error) {
    if (error is AuthApiException) return error.message;
    return '暂时无法恢复登录会话，请检查网络或服务地址后重试。';
  }
}
