import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/data/link_preview_api_client.dart';
import 'package:im_client/features/messaging/presentation/widgets/message_link_preview.dart';

void main() {
  testWidgets('preview renders metadata and opens final URL', (tester) async {
    Uri? opened;
    final requested = Uri.parse('https://example.com/article');
    final finalUrl = Uri.parse('https://example.com/article?canonical=1');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageLinkPreview(
            url: requested,
            loader: (url) async {
              expect(url, requested);
              return LinkPreviewData(
                url: finalUrl,
                siteName: 'Example News',
                title: 'A useful article',
                description: 'A short summary for the message preview.',
              );
            },
            onOpen: (url) => opened = url,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-link-preview')), findsOneWidget);
    expect(find.text('Example News'), findsOneWidget);
    expect(find.text('A useful article'), findsOneWidget);
    expect(find.text('A short summary for the message preview.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('message-link-preview')));
    expect(opened, finalUrl);
  });

  testWidgets('preview failure stays silent and does not break message layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageLinkPreview(
            url: Uri.parse('https://example.com/'),
            loader: (_) async => throw StateError('network unavailable'),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-link-preview')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
