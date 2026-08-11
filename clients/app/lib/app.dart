import 'dart:async';

import 'package:flutter/material.dart';

import 'core/performance/app_performance_store.dart';
import 'core/theme/app_theme_mode_store.dart';
import 'core/window/desktop_window_frame.dart';
import 'features/auth/presentation/auth_boot_page.dart';
import 'theme/app_theme.dart';

class ImClientApp extends StatefulWidget {
  const ImClientApp({super.key});

  @override
  State<ImClientApp> createState() => _ImClientAppState();
}

class _ImClientAppState extends State<ImClientApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final AppThemeModeStore _themeModeStore = AppThemeModeStore.shared;
  final AppPerformanceStore _performanceStore = AppPerformanceStore.shared;

  @override
  void initState() {
    super.initState();
    _themeModeStore.addListener(_handleThemeChanged);
    _performanceStore.addListener(_handlePerformanceChanged);
    unawaited(_themeModeStore.load());
    unawaited(_performanceStore.load());
  }

  @override
  void dispose() {
    _themeModeStore.removeListener(_handleThemeChanged);
    _performanceStore.removeListener(_handlePerformanceChanged);
    super.dispose();
  }

  void _handleThemeChanged() {
    if (mounted) setState(() {});
  }

  void _handlePerformanceChanged() {
    if (mounted) setState(() {});
  }

  void _handleDesktopBack() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    unawaited(navigator.maybePop());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'DD',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeModeStore.mode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            disableAnimations: _performanceStore.effectiveReduceMotion,
          ),
          child: DesktopWindowFrame(
            onBackRequested: _handleDesktopBack,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const AuthBootPage(),
    );
  }
}
