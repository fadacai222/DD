import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../contacts/domain/contact_models.dart';

class MentionSuggestionOverlay extends StatelessWidget {
  const MentionSuggestionOverlay({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.suggestions,
    required this.selectedIndex,
    required this.loading,
    required this.onSelect,
    this.width = 360,
  });

  final Uri origin;
  final String accessToken;
  final List<ContactMentionSuggestion> suggestions;
  final int selectedIndex;
  final bool loading;
  final ValueChanged<int> onSelect;
  final double width;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final panelColor = dark ? const Color(0xFF242424) : Colors.white;
    return Material(
      key: const Key('mention-suggestion-overlay'),
      color: Colors.transparent,
      child: Container(
        width: width,
        constraints: const BoxConstraints(maxHeight: 292),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: panelColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: dark ? const Color(0xFF393939) : const Color(0x17000000),
            width: 0.7,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.28 : 0.13),
              blurRadius: 20,
              offset: const Offset(0, 8),
              spreadRadius: -4,
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: loading && suggestions.isEmpty
            ? const SizedBox(
                height: 54,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DdColors.green,
                    ),
                  ),
                ),
              )
            : ListView.builder(
                key: const Key('mention-suggestion-list'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = suggestions[index];
                  final selected = index == selectedIndex;
                  return GestureDetector(
                    key: Key('mention-suggestion-$index'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelect(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 110),
                      curve: Curves.easeOut,
                      height: 54,
                      color: selected
                          ? (dark
                                ? const Color(0xFF2E3B32)
                                : const Color(0xFFEAF7EF))
                          : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          ProfileAvatar(
                            origin: origin,
                            accessToken: accessToken,
                            userId: suggestion.user.id,
                            displayName: suggestion.user.displayName,
                            size: 36,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  suggestion.user.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '@${suggestion.user.handle}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: selected
                                        ? DdColors.greenPressed
                                        : DdColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selected)
                            const Icon(
                              Icons.keyboard_return_rounded,
                              size: 17,
                              color: DdColors.greenPressed,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
