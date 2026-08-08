import 'package:flutter/material.dart';

import 'core/window/desktop_window_frame.dart';
import 'features/auth/presentation/auth_page.dart';
import 'theme/app_theme.dart';

class ImClientApp extends StatelessWidget {
  const ImClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DD',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      builder: (context, child) =>
          DesktopWindowFrame(child: child ?? const SizedBox.shrink()),
      home: const AuthPage(),
    );
  }
}
