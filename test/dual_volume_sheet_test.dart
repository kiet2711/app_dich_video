import 'package:capsub_flutter/ui/player/dual_volume_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'DualVolumeSheet updates slider and percentages live inside modal bottom sheet',
    (tester) async {
      double latestOrig = 0.25;
      double latestAi = 1.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => DualVolumeSheet(
                      originalVolume: latestOrig,
                      aiVolume: latestAi,
                      onOriginalVolumeChanged: (v) => latestOrig = v,
                      onAiVolumeChanged: (v) => latestAi = v,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('25%'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      // Tap mute icon on AI volume -> toggles to 0%
      await tester.tap(find.byIcon(Icons.volume_down).last);
      await tester.pump();
      expect(latestAi, 0.0);
      expect(find.text('0%'), findsOneWidget);

      // Drag original video slider to the right -> value and label increase live
      final origSlider = find.byType(Slider).first;
      await tester.drag(origSlider, const Offset(120, 0));
      await tester.pump();

      expect(latestOrig, greaterThan(0.25));
      expect(
        tester.widget<Slider>(origSlider).value,
        closeTo(latestOrig, 0.0001),
      );
      expect(find.text('${(latestOrig * 100).toInt()}%'), findsOneWidget);
    },
  );
}

