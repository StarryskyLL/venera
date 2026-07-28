import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('system back pops a popup detail page before closing the popup', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            key: const ValueKey('open-popup'),
            onPressed: () {
              Navigator.of(context).push(PopUpWidget(const _PopupListPage()));
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-popup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('download-list')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-detail')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('download-detail')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('download-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-detail')), findsNothing);
  });
}

class _PopupListPage extends StatelessWidget {
  const _PopupListPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Downloads', key: ValueKey('download-list')),
            FilledButton(
              key: const ValueKey('open-detail'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const _PopupDetailPage()),
                );
              },
              child: const Text('Details'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PopupDetailPage extends StatelessWidget {
  const _PopupDetailPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Detail', key: ValueKey('download-detail'))),
    );
  }
}
