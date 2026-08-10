import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// Windows 使用 DD 自己的窗口栏，底层 Win32 只保留阴影、缩放边界和窗口生命周期。
/// Web / Android / iOS / macOS / Linux 不插入这一层。
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame> {
  static const MethodChannel _windowChannel = MethodChannel('dd/window');

  bool _alwaysOnTop = false;
  bool _maximized = false;

  bool get _enabled =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (_enabled) {
      _refreshWindowState();
    }
  }

  Future<void> _refreshWindowState() async {
    try {
      final maximized =
          await _windowChannel.invokeMethod<bool>('isMaximized') ?? false;
      if (mounted) setState(() => _maximized = maximized);
    } on PlatformException {
      // Keep the UI usable if the native runner is older than the Dart layer.
    } on MissingPluginException {
      // Widget tests and non-Windows embedders do not expose the native channel.
    }
  }

  Future<void> _invoke(String method) async {
    try {
      await _windowChannel.invokeMethod<void>(method);
    } on PlatformException {
      // Native window actions are best-effort and should not crash the client.
    } on MissingPluginException {
      // Expected in tests.
    }
  }

  Future<void> _toggleMaximize() async {
    try {
      final next =
          await _windowChannel.invokeMethod<bool>('toggleMaximize') ??
          !_maximized;
      if (mounted) setState(() => _maximized = next);
    } on PlatformException {
      if (mounted) setState(() => _maximized = !_maximized);
    } on MissingPluginException {
      if (mounted) setState(() => _maximized = !_maximized);
    }
  }

  Future<void> _toggleAlwaysOnTop() async {
    try {
      final next =
          await _windowChannel.invokeMethod<bool>('toggleAlwaysOnTop') ??
          !_alwaysOnTop;
      if (mounted) setState(() => _alwaysOnTop = next);
    } on PlatformException {
      if (mounted) setState(() => _alwaysOnTop = !_alwaysOnTop);
    } on MissingPluginException {
      if (mounted) setState(() => _alwaysOnTop = !_alwaysOnTop);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;

    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final background = DdDesktopTokens.titleBarSurface(brightness);
    final border = DdDesktopTokens.borderSubtle(brightness);

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: background,
            child: Column(
              children: [
                Container(
                  key: const Key('desktop-window-titlebar'),
                  height: DdDesktopTokens.titleBarHeight,
                  decoration: BoxDecoration(
                    color: background,
                    border: Border(
                      bottom: BorderSide(color: border, width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => _invoke('startDrag'),
                          onDoubleTap: _toggleMaximize,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 11),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'DD',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: dark
                                      ? const Color(0xFFBDBDBD)
                                      : const Color(0xFF7B7B7B),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _WindowButton(
                        tooltip: _alwaysOnTop ? '取消置顶窗口' : '置顶窗口',
                        onPressed: _toggleAlwaysOnTop,
                        icon: Icons.push_pin_outlined,
                        selected: _alwaysOnTop,
                      ),
                      _WindowButton(
                        tooltip: '最小化',
                        onPressed: () => _invoke('minimize'),
                        icon: Icons.remove_rounded,
                      ),
                      _WindowButton(
                        tooltip: _maximized ? '还原' : '最大化',
                        onPressed: _toggleMaximize,
                        icon: _maximized
                            ? Icons.filter_none_rounded
                            : Icons.crop_square_rounded,
                      ),
                      _WindowButton(
                        tooltip: '关闭',
                        onPressed: () => _invoke('close'),
                        icon: Icons.close_rounded,
                        danger: true,
                      ),
                    ],
                  ),
                ),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.selected = false,
    this.danger = false,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final bool selected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hoverColor = danger
        ? const Color(0xFFE81123)
        : (dark ? const Color(0xFF353535) : const Color(0xFFE5E5E5));
    final selectedColor = dark
        ? const Color(0xFF2E4A3D)
        : const Color(0xFFDDF3E8);
    final foreground = dark ? const Color(0xFFD0D0D0) : const Color(0xFF4A4A4A);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 550),
      child: Material(
        color: selected ? selectedColor : Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          hoverColor: hoverColor,
          splashColor: Colors.transparent,
          highlightColor: hoverColor,
          child: SizedBox(
            width: 42,
            height: DdDesktopTokens.titleBarHeight,
            child: Icon(icon, size: 14, color: danger ? null : foreground),
          ),
        ),
      ),
    );
  }
}
