import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/calls/presentation/call_debug_controller.dart';
import 'package:im_client/features/calls/presentation/widgets/call_video_grid.dart';

void main() {
  test('PiP layout clamps and snaps inside the safe video stage', () {
    const stage = Size(360, 640);
    const pip = Size(108, 145);
    const input = Offset(-200, 700);

    final clamped = CallVideoPipLayout.clamp(
      input,
      stageSize: stage,
      pipSize: pip,
    );
    final bounds = CallVideoPipLayout.bounds(stageSize: stage, pipSize: pip);

    expect(clamped.dx, bounds.left);
    expect(clamped.dy, bounds.bottom);
    expect(clamped.dy + pip.height, lessThanOrEqualTo(640 - 104));

    final snappedLeft = CallVideoPipLayout.snapHorizontal(
      const Offset(80, 200),
      stageSize: stage,
      pipSize: pip,
    );
    final snappedRight = CallVideoPipLayout.snapHorizontal(
      const Offset(220, 200),
      stageSize: stage,
      pipSize: pip,
    );
    expect(snappedLeft.dx, bounds.left);
    expect(snappedRight.dx, bounds.right);
  });

  testWidgets('PiP top hit layer swaps primary video and supports dragging', (
    tester,
  ) async {
    final controller = CallDebugController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 640,
              child: CallVideoStage(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('call-video-primary-remote')), findsOneWidget);
    final hitTarget = find.byKey(const Key('call-video-pip-hit-target'));
    expect(hitTarget, findsOneWidget);

    await tester.tap(hitTarget);
    await tester.pump();
    expect(find.byKey(const Key('call-video-primary-local')), findsOneWidget);

    final pip = find.byKey(const Key('call-video-pip'));
    final before = tester.getTopLeft(pip);
    await tester.timedDrag(
      hitTarget,
      const Offset(-140, -80),
      const Duration(milliseconds: 320),
    );
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(pip);

    expect(after, isNot(before));
    expect(after.dx, greaterThanOrEqualTo(14));
    expect(after.dy, greaterThanOrEqualTo(14));
    expect(after.dy + tester.getSize(pip).height, lessThanOrEqualTo(640 - 104));
  });
}
