import 'package:flutter/material.dart';

import 'features/realtime/presentation/realtime_debug_page.dart';
import 'theme/app_theme.dart';

class ImClientApp extends StatelessWidget {
  const ImClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OpenIMX Realtime Console',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const RealtimeDebugPage(),
    );
  }
}
