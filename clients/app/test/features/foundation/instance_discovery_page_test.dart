import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/core/network/api_client.dart';
import 'package:im_client/features/foundation/presentation/instance_discovery_page.dart';

void main() {
  testWidgets('loads and renders formal instance discovery contract', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: InstanceDiscoveryPage(
          loader: (_) async => ApiEnvelope(
            requestId: 'req_widget',
            data: InstanceInfo(
              name: 'DD',
              apiVersion: 'v1',
              apiBaseUrl: Uri.parse('https://chat.test/api/v1'),
              realtimeUrl: Uri.parse('wss://chat.test/api/v1/realtime'),
              liveKitUrl: Uri.parse('wss://media.test'),
              features: const InstanceFeatures(
                calls: true,
                registrationMode: 'open',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('loadInstanceButton')));
    await tester.pumpAndSettle();

    expect(find.text('DD'), findsOneWidget);
    expect(find.text('req_widget'), findsOneWidget);
    expect(find.text('https://chat.test/api/v1'), findsOneWidget);
    expect(find.text('wss://media.test'), findsOneWidget);
  });
}
