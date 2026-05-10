import 'package:flutter_test/flutter_test.dart';

import 'package:emotion_fer_demo/main.dart';

void main() {
  testWidgets('App loads', (WidgetTester tester) async {
    await tester.pumpWidget(const EmotionFerApp());
    expect(find.text('FER · int8'), findsOneWidget);
  });
}
