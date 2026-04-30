import 'package:flutter_test/flutter_test.dart';

import 'package:assistantapp/app.dart';

void main() {
  testWidgets('App starts without error', (WidgetTester tester) async {
    await tester.pumpWidget(const VoiceAssistantApp());
    expect(find.byType(VoiceAssistantApp), findsOneWidget);
  });
}