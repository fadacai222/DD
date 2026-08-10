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
  static const Color danger = Color(0xFFFA5151);
}

abstract final class DdRadii {
  static const double pill = 999;
  static const double messageBubble = 20;
  static const double media = 16;
  static const double surface = 18;
  static const double sheet = 22;
  static const double control = 12;
}

abstract final class DdDesktopTokens {
  static const double navigationWidth = 66;
  static const double sidebarWidth = 264;
  static const double titleBarHeight = 30;
  static const double listRowHeight = 68;
  static const double chatHeaderHeight = 58;
  static const double compactControlHeight = 34;
  static const double navigationItemExtent = 46;

  static Color navigationSurface(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF1F2224)
      : const Color(0xFFF4F6F7);

  static Color sidebarSurface(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF202326)
      : const Color(0xFFF9FAFB);

  static Color contentSurface(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF191B1D)
      : const Color(0xFFF2F4F5);

  static Color hoverSurface(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF2A2E31)
      : const Color(0xFFE9EEF0);

  static Color selectedSurface(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF193529)
      : const Color(0xFFE2F4E9);

  static Color borderSubtle(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF303437)
      : const Color(0xFFDDE2E4);

  static Color titleBarSurface(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF202326)
      : const Color(0xFFF7F9FA);

  static Color navigationIcon(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFFAEB6BA)
      : const Color(0xFF667077);

  static Color activeIndicator(Brightness brightness) => DdColors.green;
}

abstract final class DdFloatingNavigationTokens {
  static const double height = 70;
  static const double horizontalMargin = 12;
  static const double topGap = 6;
  static const double bottomGap = 8;
  static const double outerRadius = 34;
  static const double itemRadius = 25;
  static const Duration animationDuration = Duration(milliseconds: 180);

  static Color surface(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF242424)
      : const Color(0xFFFCFCFC);

  static Color selectedSurface(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF153D28)
      : const Color(0xFFE1F6E9);

  static Color border(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF383838)
      : const Color(0x14000000);

  static Color unselected(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFFAAAAAA)
      : const Color(0xFF737373);

  static Color shadow(Brightness brightness) => brightness == Brightness.dark
      ? Colors.black.withValues(alpha: 0.28)
      : Colors.black.withValues(alpha: 0.11);
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DdRadii.surface),
        ),
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
          borderRadius: BorderRadius.circular(DdRadii.pill),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DdRadii.pill),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DdRadii.pill),
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
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DdRadii.pill),
            ),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DdRadii.surface),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(DdRadii.sheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        backgroundColor: dark
            ? const Color(0xFF333333)
            : const Color(0xFF333333),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DdRadii.control),
        ),
      ),
    );
  }
}
