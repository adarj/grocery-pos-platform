import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/main.dart';

class FakeConnectedPosCoreClient implements PosCoreClient {
  @override
  Future<PosCoreHealth> fetchHealth() async {
    return const PosCoreHealth(
      ok: true,
      service: 'grocery-pos-core',
      version: '0.0.0-dev',
      environment: 'dev',
    );
  }
}

class FakeUnavailablePosCoreClient implements PosCoreClient {
  @override
  Future<PosCoreHealth> fetchHealth() async {
    throw const PosCoreUnavailableException('Connection refused.');
  }
}

void main() {
  testWidgets('shows connected state when POS Core is healthy', (tester) async {
    await tester.pumpWidget(
      PosTerminalApp(client: FakeConnectedPosCoreClient()),
    );

    await tester.pumpAndSettle();

    expect(find.text('Grocery POS Terminal'), findsOneWidget);
    expect(find.text('POS Core Connected'), findsOneWidget);
    expect(find.text('grocery-pos-core 0.0.0-dev (dev)'), findsOneWidget);
  });

  testWidgets('shows unavailable state when POS Core cannot be reached',
      (tester) async {
    await tester.pumpWidget(
      PosTerminalApp(client: FakeUnavailablePosCoreClient()),
    );

    await tester.pumpAndSettle();

    expect(find.text('Grocery POS Terminal'), findsOneWidget);
    expect(find.text('POS Core Unavailable'), findsOneWidget);
    expect(find.text('Connection refused.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
