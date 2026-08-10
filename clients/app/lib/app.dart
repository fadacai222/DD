import 'dart:async';

import 'package:flutter/material.dart';

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
  final AppThemeModeStore _themeModeStore = AppThemeModeStore.shared;

  @override
  void initState() {
    super.initState();
    _themeModeStore.addListener(_handleThemeChanged);
    unawaited(_themeModeStore.load());
  }

  @override
  void dispose() {
    _themeModeStore.removeListener(_handleThemeChanged);
    super.dispose();
  }

  void _handleThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DD',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeModeStore.mode,
      builder: (context, child) =>
          DesktopWindowFrame(child: child ?? const SizedBox.shrink()),
      home: const AuthBootPage(),
    );
  }
}
