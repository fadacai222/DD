import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

final class DdFloatingNavigationDestination {
  const DdFloatingNavigationDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final Widget icon;
  final Widget selectedIcon;
  final String label;
}

class DdFloatingNavigationBar extends StatelessWidget {
  const DdFloatingNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.hidden = false,
  }) : assert(destinations.length > 0);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<DdFloatingNavigationDestination> destinations;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final media = MediaQuery.of(context);
    if (hidden) {
      return const SizedBox.shrink(key: Key('dd-floating-navigation-hidden'));
    }

    final safeSelectedIndex = selectedIndex.clamp(0, destinations.length - 1);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(
        DdFloatingNavigationTokens.horizontalMargin,
        DdFloatingNavigationTokens.topGap,
        DdFloatingNavigationTokens.horizontalMargin,
        DdFloatingNavigationTokens.bottomGap,
      ),
      child: RepaintBoundary(
        child: Container(
          key: const Key('dd-floating-navigation-bar'),
          height: DdFloatingNavigationTokens.height,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: DdFloatingNavigationTokens.surface(brightness),
            borderRadius: BorderRadius.circular(
              DdFloatingNavigationTokens.outerRadius,
            ),
            border: Border.all(
              color: DdFloatingNavigationTokens.border(brightness),
              width: 0.7,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: DdFloatingNavigationTokens.shadow(brightness),
                blurRadius: 18,
                offset: const Offset(0, 5),
                spreadRadius: -4,
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = constraints.maxWidth / destinations.length;
              return Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedPositioned(
                    key: const Key('dd-floating-navigation-indicator'),
                    duration: DdFloatingNavigationTokens.animationDuration,
                    curve: Curves.easeOutCubic,
                    left: itemWidth * safeSelectedIndex,
                    top: 0,
                    bottom: 0,
                    width: itemWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: DdFloatingNavigationTokens.selectedSurface(
                          brightness,
                        ),
                        borderRadius: BorderRadius.circular(
                          DdFloatingNavigationTokens.itemRadius,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: List<Widget>.generate(destinations.length, (
                      index,
                    ) {
                      final destination = destinations[index];
                      final selected = safeSelectedIndex == index;
                      final foreground = selected
                          ? DdColors.greenPressed
                          : DdFloatingNavigationTokens.unselected(brightness);
                      return Expanded(
                        child: Semantics(
                          button: true,
                          selected: selected,
                          label: destination.label,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: Key('dd-floating-navigation-item-$index'),
                              borderRadius: BorderRadius.circular(
                                DdFloatingNavigationTokens.itemRadius,
                              ),
                              onTap: selected
                                  ? null
                                  : () => onDestinationSelected(index),
                              child: SizedBox.expand(
                                key: Key('dd-floating-navigation-pill-$index'),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        height: 27,
                                        child: IconTheme(
                                          data: IconThemeData(
                                            size: 22,
                                            color: foreground,
                                          ),
                                          child: Center(
                                            child: selected
                                                ? destination.selectedIcon
                                                : destination.icon,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        destination.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.clip,
                                        textScaler: TextScaler.linear(
                                          media.textScaler
                                              .scale(1)
                                              .clamp(1, 1.25),
                                        ),
                                        style: TextStyle(
                                          color: foreground,
                                          fontSize: 10.5,
                                          height: 1.15,
                                          fontWeight: selected
                                              ? FontWeight.w600
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
