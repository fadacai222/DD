import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

final class DesktopInspectorEntry {
  const DesktopInspectorEntry({
    required this.id,
    required this.title,
    required this.builder,
  });

  final String id;
  final String title;
  final WidgetBuilder builder;
}

final class DesktopInspectorController extends ChangeNotifier {
  final List<DesktopInspectorEntry> _stack = <DesktopInspectorEntry>[];

  List<DesktopInspectorEntry> get stack =>
      List<DesktopInspectorEntry>.unmodifiable(_stack);
  DesktopInspectorEntry? get current => _stack.isEmpty ? null : _stack.last;
  bool get isOpen => _stack.isNotEmpty;
  bool get canPop => _stack.length > 1;

  void open(DesktopInspectorEntry entry) {
    _stack
      ..clear()
      ..add(entry);
    notifyListeners();
  }

  void push(DesktopInspectorEntry entry) {
    _stack.add(entry);
    notifyListeners();
  }

  void pop() {
    if (_stack.length <= 1) {
      close();
      return;
    }
    _stack.removeLast();
    notifyListeners();
  }

  void close() {
    if (_stack.isEmpty) return;
    _stack.clear();
    notifyListeners();
  }
}

class RightInspectorPane extends StatelessWidget {
  const RightInspectorPane({
    super.key,
    required this.controller,
    this.width = 340,
  });

  final DesktopInspectorController controller;
  final double width;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final entry = controller.current;
        if (entry == null) return const SizedBox.shrink();
        return SizedBox(
          key: const Key('desktop-right-inspector'),
          width: width,
          child: Material(
            color: DdDesktopTokens.contentSurface(Theme.of(context).brightness),
            child: Column(
              children: [
                SizedBox(
                  height: 50,
                  child: Row(
                    children: [
                      IconButton(
                        key: const Key('desktop-inspector-back'),
                        tooltip: controller.canPop ? '返回' : '关闭',
                        onPressed: controller.pop,
                        icon: Icon(
                          controller.canPop
                              ? Icons.arrow_back_rounded
                              : Icons.close_rounded,
                          size: 20,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('desktop-inspector-close'),
                        tooltip: '关闭',
                        onPressed: controller.close,
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 0.5,
                  color: DdDesktopTokens.borderSubtle(
                    Theme.of(context).brightness,
                  ),
                ),
                Expanded(
                  child: KeyedSubtree(
                    key: ValueKey('inspector-entry-${entry.id}'),
                    child: entry.builder(context),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class DesktopInspectorOverlay extends StatelessWidget {
  const DesktopInspectorOverlay({
    super.key,
    required this.controller,
    this.width = 340,
  });

  final DesktopInspectorController controller;
  final double width;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.isOpen) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('desktop-inspector-barrier'),
                behavior: HitTestBehavior.opaque,
                onTap: controller.close,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.10),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              child: Material(
                elevation: 16,
                child: RightInspectorPane(
                  controller: controller,
                  width: width,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
