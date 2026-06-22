import 'package:threadable_better_player/threadable_better_player.dart';
import 'package:threadable_better_player/src/core/better_player_with_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'better_player_mock_controller.dart';

void main() {
  late BetterPlayerMockController mockController;

  setUp(() {
    mockController = BetterPlayerMockController(
      const BetterPlayerConfiguration(),
    );
  });

  testWidgets("One of children is BetterPlayerWithControls", (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrapWidget(BetterPlayer(controller: mockController)),
    );
    expect(
      find.byWidgetPredicate((widget) => widget is BetterPlayerWithControls),
      findsOneWidget,
    );
  });
}

///Wrap widget with material app to handle all features like navigation and
///localization properly.
Widget _wrapWidget(Widget widget) {
  return MaterialApp(home: widget);
}
