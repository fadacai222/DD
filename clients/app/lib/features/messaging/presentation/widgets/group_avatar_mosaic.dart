import 'package:flutter/material.dart';

import '../../../auth/presentation/widgets/profile_avatar.dart';
import '../../domain/messaging_models.dart';

typedef GroupAvatarMemberBuilder = Widget Function(
  BuildContext context,
  MessagingUserPreview member,
  double size,
  int index,
);

class GroupAvatarMosaic extends StatelessWidget {
  const GroupAvatarMosaic({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.groupName,
    required this.members,
    this.size = 46,
    this.memberBuilder,
  });

  final Uri origin;
  final String accessToken;
  final String groupName;
  final List<MessagingUserPreview> members;
  final double size;
  final GroupAvatarMemberBuilder? memberBuilder;

  @override
  Widget build(BuildContext context) {
    final visible = members.take(4).toList(growable: false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.18),
      child: ColoredBox(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF444444)
            : const Color(0xFFE5E5E5),
        child: SizedBox.square(
          dimension: size,
          child: visible.isEmpty
              ? _fallback()
              : Stack(
                  clipBehavior: Clip.hardEdge,
                  children: _placements(visible.length)
                      .asMap()
                      .entries
                      .map((entry) {
                        final member = visible[entry.key];
                        final placement = entry.value;
                        final slotSize = placement.width * size;
                        return Positioned(
                          key: Key('group-avatar-member-${entry.key}'),
                          left: placement.left * size,
                          top: placement.top * size,
                          width: slotSize,
                          height: placement.height * size,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              (slotSize * 0.12).clamp(1.5, 4.0),
                            ),
                            child: memberBuilder?.call(
                                  context,
                                  member,
                                  slotSize,
                                  entry.key,
                                ) ??
                                ProfileAvatar(
                                  origin: origin,
                                  accessToken: accessToken,
                                  userId: member.id,
                                  displayName: member.displayName,
                                  size: slotSize,
                                ),
                          ),
                        );
                      })
                      .toList(growable: false),
                ),
        ),
      ),
    );
  }

  Widget _fallback() {
    final trimmed = groupName.trim();
    final letter = trimmed.isEmpty ? '群' : trimmed.characters.first;
    return Center(
      child: Text(
        letter,
        style: TextStyle(
          color: const Color(0xFF5D7185),
          fontSize: size * 0.40,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  List<_Placement> _placements(int count) {
    const pad = 0.055;
    const gap = 0.045;
    final half = (1 - pad * 2 - gap) / 2;
    if (count <= 1) {
      return const [_Placement(pad, pad, 1 - pad * 2, 1 - pad * 2)];
    }
    if (count == 2) {
      final height = half;
      final top = (1 - height) / 2;
      return [
        _Placement(pad, top, half, height),
        _Placement(pad + half + gap, top, half, height),
      ];
    }
    if (count == 3) {
      return [
        _Placement((1 - half) / 2, pad, half, half),
        _Placement(pad, pad + half + gap, half, half),
        _Placement(pad + half + gap, pad + half + gap, half, half),
      ];
    }
    return [
      _Placement(pad, pad, half, half),
      _Placement(pad + half + gap, pad, half, half),
      _Placement(pad, pad + half + gap, half, half),
      _Placement(pad + half + gap, pad + half + gap, half, half),
    ];
  }
}

final class _Placement {
  const _Placement(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;
}
