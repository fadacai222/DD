import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/presentation/peer_profile_page.dart';

Future<void> showDesktopMentionProfileDialog({
  required BuildContext context,
  required Uri origin,
  required String accessToken,
  required String userId,
  required String handle,
  required String displayName,
  ContactsGateway? gateway,
  Future<void> Function()? onMessage,
  Future<void> Function()? onAudioCall,
  Future<void> Function()? onVideoCall,
  Future<void> Function()? onOpenMoments,
  Future<void> Function()? onOpenMomentPrivacy,
  Future<void> Function()? onContactUpdated,
}) {
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.36),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialogContext, _, _) {
      final viewport = MediaQuery.sizeOf(dialogContext);
      final width = math.min(530.0, math.max(0.0, viewport.width - 40));
      final height = math.min(630.0, math.max(0.0, viewport.height - 28));

      Future<void> closeAndRun(Future<void> Function()? action) async {
        if (action == null) return;
        if (Navigator.of(dialogContext).canPop()) {
          Navigator.of(dialogContext).pop();
        }
        await action();
      }

      return SafeArea(
        minimum: const EdgeInsets.all(8),
        child: Center(
          child: Dialog(
            insetPadding: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            elevation: 18,
            shadowColor: Colors.black.withValues(alpha: 0.22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DdRadii.dialog),
            ),
            child: SizedBox(
              key: const Key('desktop-mention-profile-dialog'),
              width: width,
              height: height,
              child: PeerProfilePage(
                origin: origin,
                accessToken: accessToken,
                userId: userId,
                handle: handle,
                displayName: displayName,
                gateway: gateway,
                onContactUpdated: onContactUpdated,
                embedded: true,
                desktopDialog: true,
                onClose: () => Navigator.of(dialogContext).pop(),
                onMessage: onMessage == null
                    ? null
                    : () => closeAndRun(onMessage),
                onAudioCall: onAudioCall == null
                    ? null
                    : () => closeAndRun(onAudioCall),
                onVideoCall: onVideoCall == null
                    ? null
                    : () => closeAndRun(onVideoCall),
                onOpenMoments: onOpenMoments == null
                    ? null
                    : () => closeAndRun(onOpenMoments),
                onOpenMomentPrivacy: onOpenMomentPrivacy == null
                    ? null
                    : () => closeAndRun(onOpenMomentPrivacy),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.965, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}
