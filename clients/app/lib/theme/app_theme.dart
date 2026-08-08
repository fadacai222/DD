import 'package:flutter/material.dart';

abstract final class DdColors {
  static const Color green = Color(0xFF18B866);
  static const Color greenPressed = Color(0xFF109854);
  static const Color chatBackground = Color(0xFFEDEDED);
  static const Color panel = Color(0xFFF7F7F7);
  static const Color panelStrong = Color(0xFFFFFFFF);
  static const Color divider = Color(0xFFE5E5E5);
  static const Color textPrimary = Color(0xFF191919);
  static const Color textSecondary = Color(0xFF888888);
  static const Color textTertiary = Color(0xFFB2B2B2);
  static const Color ownBubble = Color(0xFF95EC69);
  static const Color desktopRail = Color(0xFF2E2E2E);
  static const Color danger = Color(0xFFFA5151);
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: DdColors.green,
      brightness: brightness,
      primary: DdColors.green,
      error: DdColors.danger,
      surface: dark ? const Color(0xFF202020) : DdColors.panelStrong,
    );

    final base = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      // InkSparkle can compile a shader on first interaction on some Android GPUs.
      // The simpler ripple gives immediate feedback without that first-tap hitch.
      splashFactory: InkRipple.splashFactory,
      fontFamilyFallback: const [
        'PingFang SC',
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Noto Sans CJK SC',
      ],
    );

    final scaffold = dark ? const Color(0xFF191919) : DdColors.panel;
    final surface = dark ? const Color(0xFF232323) : DdColors.panelStrong;
    final subtle = dark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5);
    final divider = dark ? const Color(0xFF353535) : DdColors.divider;

    return base.copyWith(
      scaffoldBackgroundColor: scaffold,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: surface,
        foregroundColor: dark ? Colors.white : DdColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: dark ? Colors.white : DdColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: 0.5,
        space: 0.5,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: subtle,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: DdColors.green, width: 1),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return dark ? const Color(0xFF3A3A3A) : const Color(0xFFDADADA);
            }
            if (states.contains(WidgetState.pressed)) {
              return DdColors.greenPressed;
            }
            return DdColors.green;
          }),
          foregroundColor: const WidgetStatePropertyAll(Colors.white),
          elevation: const WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return DdColors.textTertiary;
            }
            return DdColors.greenPressed;
          }),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(
            dark ? const Color(0xFFD8D8D8) : const Color(0xFF555555),
          ),
          overlayColor: WidgetStatePropertyAll(
            dark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 58,
        elevation: 0,
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            size: 23,
            color: states.contains(WidgetState.selected)
                ? DdColors.green
                : (dark ? const Color(0xFFAAAAAA) : const Color(0xFF666666)),
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return TextStyle(
            fontSize: 11,
            color: states.contains(WidgetState.selected)
                ? DdColors.green
                : (dark ? const Color(0xFFAAAAAA) : const Color(0xFF666666)),
          );
        }),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark
            ? const Color(0xFF333333)
            : const Color(0xFF333333),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}
